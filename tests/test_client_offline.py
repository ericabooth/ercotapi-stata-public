#!/usr/bin/env python3
"""
Offline tests for _ercotapi_client.py.

These never touch the network and never need credentials, so they run
anywhere, including in CI. They cover the parts of the client that turn
ERCOT's shapes into usable ones, and the guards that are supposed to refuse a
bad request before it is sent.

    python3 tests/test_client_offline.py

Exits non-zero on failure. Run test_client_live.py separately for the checks
that need a key.
"""
from __future__ import annotations

import json
import io
import os
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import _ercotapi_client as C  # noqa: E402


class TestParseRows(unittest.TestCase):
    """ERCOT sends data rows as bare arrays and the column order separately."""

    def test_zips_fields_onto_positional_rows(self):
        page = {
            "fields": [{"name": "deliveryDate"}, {"name": "price"}],
            "data": [["2026-09-01", 33.59], ["2026-09-02", 27.97]],
        }
        rows = C.parse_rows(page)
        self.assertEqual(rows[0], {"deliveryDate": "2026-09-01", "price": 33.59})
        self.assertEqual(len(rows), 2)

    def test_passes_dictionaries_through(self):
        page = {"data": [{"a": 1}]}
        self.assertEqual(C.parse_rows(page), [{"a": 1}])

    def test_empty_page_is_not_an_error(self):
        self.assertEqual(C.parse_rows({"fields": [{"name": "a"}], "data": []}), [])


class TestRangeParams(unittest.TestCase):
    """The From/To rule is the single most common cause of an HTTP 400."""

    FIELDS = [
        {"name": "deliveryDate", "dataType": "DATE", "hasRange": True},
        {"name": "settlementPoint", "dataType": "VARCHAR", "hasRange": False},
    ]

    def test_builds_the_pair(self):
        out = C.build_range_params(self.FIELDS, "deliveryDate", "2026-09-01", "2026-09-07")
        self.assertEqual(out, {"deliveryDateFrom": "2026-09-01",
                               "deliveryDateTo": "2026-09-07"})

    def test_refuses_a_field_that_cannot_take_a_range(self):
        with self.assertRaises(C.ErcotApiError) as cm:
            C.build_range_params(self.FIELDS, "settlementPoint", "a", "b")
        self.assertIn("does not support ranges", str(cm.exception))

    def test_unknown_field_lists_what_is_available(self):
        with self.assertRaises(C.ErcotApiError) as cm:
            C.build_range_params(self.FIELDS, "deliverydate", "a", "b")
        # Case matters, and the message has to say what the real names are or
        # the user cannot act on it.
        self.assertIn("deliveryDate", str(cm.exception))
        self.assertIn("settlementPoint", str(cm.exception))


class TestCatalogRows(unittest.TestCase):
    """The catalog is flattened to one row per queryable table."""

    PRODUCTS = [
        {
            "emilId": "NP4-190-CD", "name": "DAM Settlement Point Prices",
            "generationFrequency": "Chron - Daily", "misDisplayDuration": 31,
            "archiveDuration": 2555, "firstRun": "2010-12-08",
            "lastPostDatetime": "2026-09-20T13:00:57",
            "artifacts": [{"displayName": "DAM SPP", "_links": {"endpoint": {
                "href": "https://api.ercot.com/api/public-reports/np4-190-cd/dam_stlmnt_pnt_prices"}}}],
            "_links": {"archive": {"href": "https://api.ercot.com/api/public-reports/archive/np4-190-cd"}},
        },
        {
            "emilId": "COPG-316", "name": "Load Estimation Counts",
            "misDisplayDuration": 31, "archiveDuration": 2555,
            "artifacts": [], "_links": {},
        },
    ]

    def test_artifact_slug_comes_off_the_endpoint(self):
        rows = C.catalog_rows(self.PRODUCTS)
        dam = [r for r in rows if r["emil_id"] == "NP4-190-CD"][0]
        self.assertEqual(dam["artifact"], "dam_stlmnt_pnt_prices")

    def test_retention_columns_survive(self):
        dam = [r for r in C.catalog_rows(self.PRODUCTS) if r["emil_id"] == "NP4-190-CD"][0]
        self.assertEqual(dam["live_days"], 31)
        self.assertEqual(dam["archive_days"], 2555)
        self.assertEqual(dam["has_archive"], 1)

    def test_a_product_with_no_table_still_gets_a_row(self):
        # Its archive may still hold the history the user wants, so dropping
        # it would hide a usable source.
        rows = C.catalog_rows(self.PRODUCTS)
        copg = [r for r in rows if r["emil_id"] == "COPG-316"]
        self.assertEqual(len(copg), 1)
        self.assertEqual(copg[0]["artifact"], "")
        self.assertEqual(copg[0]["has_archive"], 0)


class TestDayBounds(unittest.TestCase):
    """A bare date has to be widened, or the last day of a range is lost."""

    def test_widens_a_bare_date_to_the_whole_day(self):
        out = C._day_bounds("2024-03-01", "2024-03-03")
        self.assertEqual(out["postDatetimeFrom"], "2024-03-01T00:00:00")
        self.assertEqual(out["postDatetimeTo"], "2024-03-03T23:59:59")

    def test_leaves_an_explicit_time_alone(self):
        out = C._day_bounds("2024-03-01T06:00:00", "2024-03-01T18:00:00")
        self.assertEqual(out["postDatetimeFrom"], "2024-03-01T06:00:00")
        self.assertEqual(out["postDatetimeTo"], "2024-03-01T18:00:00")


class TestReadArchiveZip(unittest.TestCase):
    """Archive postings arrive as zipped CSVs."""

    def _zip(self, name: str, text: str) -> bytes:
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr(name, text)
        return buf.getvalue()

    def test_reads_rows_and_stamps_provenance(self):
        blob = self._zip("cdr.123.csv", "DeliveryDate,Price\n03/02/2024,11.59\n")
        rows = C.read_archive_zip(blob, {"doc_id": 42, "post_datetime": "2024-03-01T12:49:49"})
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["DeliveryDate"], "03/02/2024")
        # Without these a table stitched from hundreds of postings cannot be
        # audited back to the file any given row came from.
        self.assertEqual(rows[0]["source_doc_id"], 42)
        self.assertEqual(rows[0]["source_post_datetime"], "2024-03-01T12:49:49")

    def test_ignores_non_csv_members(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr("readme.txt", "not data")
            zf.writestr("data.csv", "a,b\n1,2\n")
        rows = C.read_archive_zip(buf.getvalue(), {"doc_id": 1, "post_datetime": "x"})
        self.assertEqual(len(rows), 1)

    def test_a_non_zip_reply_says_so(self):
        with self.assertRaises(C.ErcotApiError) as cm:
            C.read_archive_zip(b"<xml>not a zip</xml>", {"doc_id": 7})
        self.assertIn("did not arrive as a zip", str(cm.exception))


class TestWriteCsv(unittest.TestCase):
    def test_uses_the_union_of_keys_in_first_seen_order(self):
        rows = [{"a": 1, "b": 2}, {"b": 3, "c": 4}]
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "out.csv")
            n = C.write_csv(path, rows)
            self.assertEqual(n, 2)
            with open(path) as fh:
                header = fh.readline().strip()
            self.assertEqual(header, "a,b,c")

    def test_no_rows_writes_an_empty_file_rather_than_failing(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "empty.csv")
            self.assertEqual(C.write_csv(path, []), 0)
            self.assertTrue(os.path.exists(path))

    def test_creates_the_directory(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "nested", "deeper", "out.csv")
            C.write_csv(path, [{"a": 1}])
            self.assertTrue(os.path.exists(path))


class TestCredentials(unittest.TestCase):
    """Credentials come from the environment or a file, never from the repo."""

    def setUp(self):
        self._saved = {k: os.environ.pop(k, None)
                       for k in ("ERCOT_API_KEY", "ERCOT_USERNAME", "ERCOT_PASSWORD")}
        self._cred_path = C.CRED_PATH

    def tearDown(self):
        C.CRED_PATH = self._cred_path
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_environment_wins(self):
        os.environ["ERCOT_API_KEY"] = "key"
        os.environ["ERCOT_USERNAME"] = "user"
        os.environ["ERCOT_PASSWORD"] = "pass"
        self.assertEqual(C.load_credentials()["username"], "user")

    def test_explicit_dict_wins_over_everything(self):
        cred = C.load_credentials({"api_key": "k", "username": "u", "password": "p"})
        self.assertEqual(cred["api_key"], "k")

    def test_missing_credentials_explain_both_ways_to_set_them(self):
        C.CRED_PATH = os.path.join(tempfile.gettempdir(), "definitely_not_here.json")
        with self.assertRaises(C.ErcotAuthError) as cm:
            C.load_credentials()
        msg = str(cm.exception)
        self.assertIn("ERCOT_API_KEY", msg)
        self.assertIn(C.CRED_PATH, msg)

    def test_a_half_filled_file_names_what_is_missing(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "credentials.json")
            with open(path, "w") as fh:
                json.dump({"api_key": "k", "username": "", "password": ""}, fh)
            C.CRED_PATH = path
            with self.assertRaises(C.ErcotAuthError) as cm:
                C.load_credentials()
            self.assertIn("username", str(cm.exception))
            self.assertIn("password", str(cm.exception))

    def test_unreadable_file_says_what_the_file_should_contain(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "credentials.json")
            with open(path, "w") as fh:
                fh.write("this is not json")
            C.CRED_PATH = path
            with self.assertRaises(C.ErcotAuthError) as cm:
                C.load_credentials()
            self.assertIn("api_key", str(cm.exception))


class TestMask(unittest.TestCase):
    """Nothing in this package ever prints a secret in full."""

    def test_shows_only_length_and_last_four(self):
        out = C.mask("abcdefghijklmnop")
        self.assertNotIn("abcdefghijkl", out)
        self.assertIn("mnop", out)
        self.assertIn("16", out)

    def test_a_short_secret_reveals_none_of_itself(self):
        # Showing the last four characters of a short password prints most of
        # it, and a setup report is exactly what people paste into a bug
        # report. Anything under twelve characters shows its length only.
        for secret in ("abc", "abcd", "hunter2", "abcdefghijk"):
            out = C.mask(secret)
            self.assertNotIn(secret[-4:], out, f"mask leaked the tail of {secret!r}")
            self.assertIn(str(len(secret)), out)

    def test_an_empty_secret_does_not_crash(self):
        self.assertEqual(C.mask(""), "<not set>")

    def test_a_long_secret_still_shows_enough_to_identify_it(self):
        # The point of the tail is letting someone confirm which of two keys
        # is configured, so a real 32-character key must keep showing it.
        out = C.mask("0123456789abcdef0123456789abcdef")
        self.assertIn("cdef", out)
        self.assertIn("32", out)


class TestPublicConfigIsNotSecret(unittest.TestCase):
    """The three ERCOT settings baked in here are published configuration.

    This test exists to make the distinction explicit for anyone auditing the
    repository: the client id and the two URLs are the same for every user and
    appear in ERCOT's own registration guide. No credential is stored here.
    """

    def test_endpoints_point_at_ercot(self):
        self.assertTrue(C.BASE_URL.startswith("https://api.ercot.com/"))
        self.assertIn("ercotb2c.b2clogin.com", C.TOKEN_URL)

    def test_no_credential_shaped_constant_is_set(self):
        for name in ("API_KEY", "USERNAME", "PASSWORD", "SECRET", "TOKEN"):
            self.assertFalse(hasattr(C, name), f"{name} should not exist in the client")


class TestRateLimiter(unittest.TestCase):
    def test_a_silly_ceiling_is_clamped_to_something_workable(self):
        with tempfile.TemporaryDirectory() as d:
            lim = C.RateLimiter(calls_per_minute=0,
                                state_path=os.path.join(d, "rate.json"))
            self.assertEqual(lim.calls_per_minute, 1)

    def test_consecutive_calls_are_spaced_out(self):
        # A rolling-window counter on its own lets a burst through, and a
        # burst is what actually earns an HTTP 429 from ERCOT. 600 a minute
        # means a tenth of a second apart, which keeps this test quick.
        import time
        with tempfile.TemporaryDirectory() as d:
            lim = C.RateLimiter(calls_per_minute=600,
                                state_path=os.path.join(d, "rate.json"))
            start = time.time()
            for _ in range(4):
                lim.wait()
            self.assertGreaterEqual(time.time() - start, 0.25)

    def test_the_first_call_does_not_wait(self):
        import time
        with tempfile.TemporaryDirectory() as d:
            lim = C.RateLimiter(calls_per_minute=2,
                                state_path=os.path.join(d, "rate.json"))
            start = time.time()
            lim.wait()
            self.assertLess(time.time() - start, 1.0)

    def test_sleep_calculation_respects_both_rules(self):
        lim = C.RateLimiter(calls_per_minute=60)   # one second apart
        now = 1000.0
        self.assertEqual(lim._sleep_needed([], now), 0.0)
        # Too soon after the last call: wait out the gap.
        self.assertAlmostEqual(lim._sleep_needed([now - 0.25], now), 0.75)
        # Gap satisfied and the window has room: go now.
        self.assertEqual(lim._sleep_needed([now - 5], now), 0.0)
        # Window full: wait for the oldest call to age out.
        full = [now - 59.0 + i * 0.5 for i in range(60)]
        self.assertGreater(lim._sleep_needed(full, now), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
