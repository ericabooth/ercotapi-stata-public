#!/usr/bin/env python3
"""
Live tests for _ercotapi_client.py: these do call ERCOT.

They need working credentials, and they spend about a dozen requests against
your account's rate limit. Without credentials every test is skipped rather
than failed, so this file is safe to run in CI.

    python3 tests/test_client_live.py

Each test states what it is proving about ERCOT's behaviour, because these
double as the evidence behind the claims the README and the help file make.
Where ERCOT's own behaviour changes, one of these fails and the documentation
needs revisiting.
"""
from __future__ import annotations

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import _ercotapi_client as C  # noqa: E402

# A report every public subscription can see, with a long archive.
EMIL = "np4-190-cd"
ARTIFACT = "dam_stlmnt_pnt_prices"
# A settled date well inside the archive, chosen because its posting is a
# single file and its delivery date is the day after.
ARCHIVE_DAY = "2024-03-01"


def credentials_available() -> bool:
    try:
        C.load_credentials()
        return True
    except C.ErcotAuthError:
        return False


HAVE_CREDS = credentials_available()
skip_reason = "no ERCOT credentials configured; see the README"


@unittest.skipUnless(HAVE_CREDS, skip_reason)
class TestLive(unittest.TestCase):
    session: C.ErcotSession

    @classmethod
    def setUpClass(cls):
        cls.session = C.ErcotSession()

    def test_01_sign_in_returns_a_token(self):
        token = self.session.token()
        self.assertTrue(token)
        self.assertGreater(len(token), 50)

    def test_02_token_is_cached_not_refetched(self):
        # ERCOT tokens last an hour and cannot be refreshed, so a client that
        # signed in on every request would burn the rate limit for nothing.
        first = self.session.token()
        self.assertEqual(first, self.session.token())

    def test_03_catalog_returns_products(self):
        products = C.get_catalog(self.session)
        self.assertGreater(len(products), 50)
        self.assertTrue(any(p.get("emilId") == EMIL.upper() for p in products))

    def test_04_catalog_reports_retention(self):
        # The README tells readers to choose between pull and archive by
        # reading live_days and archive_days. That advice only holds if ERCOT
        # keeps publishing both numbers.
        rows = C.catalog_rows(C.get_catalog(self.session))
        dam = [r for r in rows if r["emil_id"] == EMIL.upper()][0]
        self.assertIsNotNone(dam["live_days"])
        self.assertIsNotNone(dam["archive_days"])
        self.assertGreater(dam["archive_days"], dam["live_days"])

    def test_05_describe_reports_the_range_flag(self):
        info = C.describe_report(self.session, EMIL, ARTIFACT)
        names = {f["name"]: f for f in info["fields"]}
        self.assertIn("deliveryDate", names)
        self.assertTrue(names["deliveryDate"].get("hasRange"))
        self.assertFalse(names["settlementPoint"].get("hasRange"))

    def test_06_a_bare_value_on_a_range_field_is_rejected(self):
        # This is the failure the client's 400 handler explains, and the
        # reason build_range_params exists. If ERCOT ever starts accepting a
        # bare value, this test fails and that guidance can be softened.
        with self.assertRaises(C.ErcotApiError) as cm:
            C.query(self.session, EMIL, ARTIFACT, {"deliveryDate": "2026-09-19"})
        self.assertIn("400", str(cm.exception))

    def test_07_a_range_query_returns_rows(self):
        info = C.describe_report(self.session, EMIL, ARTIFACT)
        import datetime
        day = (datetime.date.today() - datetime.timedelta(days=2)).isoformat()
        params = C.build_range_params(info["fields"], "deliveryDate", day, day)
        params["settlementPoint"] = "HB_HOUSTON"
        rows = C.query(self.session, EMIL, ARTIFACT, params)
        self.assertGreaterEqual(len(rows), 24)
        self.assertTrue(all(r["settlementPoint"] == "HB_HOUSTON" for r in rows))

    def test_08_an_old_date_returns_empty_rather_than_erroring(self):
        # The trap the package exists to document: no error, no warning, just
        # an empty table that looks like a quiet day.
        info = C.describe_report(self.session, EMIL, ARTIFACT)
        params = C.build_range_params(info["fields"], "deliveryDate",
                                      "2019-01-05", "2019-01-05")
        rows = C.query(self.session, EMIL, ARTIFACT, params)
        self.assertEqual(rows, [])

    def test_09_archive_lists_postings_in_a_window(self):
        docs = C.list_archive(self.session, EMIL, "2024-03-01", "2024-03-05")
        self.assertEqual(len(docs), 5)
        for d in docs:
            self.assertTrue(d["doc_id"])
            self.assertTrue(d["post_datetime"].startswith("2024-03-"))

    def test_10_archive_refuses_a_one_sided_window(self):
        with self.assertRaises(C.ErcotApiError):
            C.list_archive(self.session, EMIL, "2024-03-01", None)

    def test_11_archive_download_returns_the_posted_file(self):
        rows = C.fetch_archive(self.session, EMIL, ARCHIVE_DAY, ARCHIVE_DAY,
                               progress_every=0)
        self.assertGreater(len(rows), 1000)
        self.assertIn("SettlementPoint", rows[0])
        self.assertIn("source_doc_id", rows[0])

    def test_12_posting_date_runs_ahead_of_delivery_date(self):
        # A day-ahead file posted on 1 March carries delivery date 2 March.
        # Everything the docs say about widening an archive window rests on
        # this, so it is asserted rather than assumed.
        rows = C.fetch_archive(self.session, EMIL, ARCHIVE_DAY, ARCHIVE_DAY,
                               progress_every=0)
        delivery = {r["DeliveryDate"] for r in rows}
        self.assertEqual(delivery, {"03/02/2024"})

    def test_13_max_docs_refuses_rather_than_truncating(self):
        with self.assertRaises(C.ErcotApiError) as cm:
            C.fetch_archive(self.session, EMIL, "2024-01-01", "2024-12-31", max_docs=5)
        self.assertIn("max_docs", str(cm.exception))


if __name__ == "__main__":
    if not HAVE_CREDS:
        print(f"SKIPPING every live test: {skip_reason}")
    unittest.main(verbosity=2)
