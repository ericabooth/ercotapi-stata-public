#!/usr/bin/env python3
"""
_ercotapi_client.py -- a small, dependency-free client for the ERCOT Public API.

WHAT THIS IS
    ERCOT publishes Texas grid data (prices, load, generation by fuel,
    resource-level dispatch) through a public REST API. Getting data out of it
    is harder than it looks, and most of the difficulty is undocumented. This
    module handles the parts that bite:

      * Two-factor auth on every request. ERCOT wants BOTH an Azure API
        subscription key (a header) and an OAuth bearer token obtained from a
        separate Azure AD B2C endpoint. The token lasts one hour and cannot be
        refreshed, so it is cached and re-fetched on expiry.

      * Rate limiting that survives more than one script. ERCOT throttles by
        account, so two scripts running at once share one budget. The limiter
        here coordinates through a lock file rather than an in-process counter.

      * Pagination you can trust. Every response carries a `_meta.totalRecords`
        count. This client walks every page and compares what it received
        against that number, raising rather than handing back a short table
        that looks complete.

      * Positional rows. ERCOT returns data rows as bare arrays, with a
        separate `fields` list giving the column order. parse_rows() zips them
        back together.

    It is written against the standard library only, so it runs wherever
    Python does without an install step. That matters because it is driven
    from Stata, where asking a user to pip-install is a real barrier.

CREDENTIALS
    Never hardcoded and never read from this repository. The client looks, in
    order, at:

      1. Environment variables:
             ERCOT_API_KEY, ERCOT_USERNAME, ERCOT_PASSWORD
      2. A JSON file at ~/.ercotapi/credentials.json:
             {"api_key": "...", "username": "...", "password": "..."}

    See the README for how to get these from ERCOT and where to put them.

TWO GOTCHAS WORTH KNOWING BEFORE YOU QUERY
    1. A date field that supports ranges will NOT accept a bare value. Passing
       deliveryDate=2026-09-15 returns HTTP 400; you must send deliveryDateFrom
       and deliveryDateTo. Which fields behave this way is discoverable: call
       describe_report() and read the `hasRange` flag. build_range_params()
       does this check for you and refuses to guess.

    2. The live query endpoints hold a limited recent history. For older dates
       some reports return ZERO ROWS AND HTTP 200 rather than an error, which
       is indistinguishable from "nothing happened that day" unless you know
       to expect it. Treat an empty result for an old date as unproven, not as
       evidence of absence.

       How far back a report's live endpoint goes is published, and this client
       reads it: get_catalog() returns each product's `live_days` (ERCOT calls
       it misDisplayDuration) and `archive_days` (archiveDuration). A report
       with live_days=31 and archive_days=2555 holds one month on the live
       endpoint and seven years in its archive. For anything older than
       live_days, use the archive functions below instead of query().

THE ARCHIVE
    Alongside the live endpoint, most reports keep an archive of the original
    files ERCOT posted, one zipped CSV per posting, going back years.
    list_archive() lists the postings and fetch_archive() downloads a date
    range and stitches the CSVs into one table.

    The archive filters on POST date, which is the moment ERCOT published the
    file, not the date of the data inside it. For a day-ahead report the file
    posted on 3 March carries delivery date 4 March. Ask for a slightly wider
    window than you need and filter on the data's own date column afterwards.

LICENSE
    MIT. See LICENSE.
"""
from __future__ import annotations

import io
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from typing import Any, Dict, List, Optional

__version__ = "1.0.0"

# These three are ERCOT's own public settings, identical for every user of the
# API. They are configuration, not secrets, and are published in ERCOT's
# registration guide.
TOKEN_URL = (
    "https://ercotb2c.b2clogin.com/ercotb2c.onmicrosoft.com/"
    "B2C_1_PUBAPI-ROPC-FLOW/oauth2/v2.0/token"
)
CLIENT_ID = "fec253ea-0d06-4272-a5e6-b478baeecd70"
BASE_URL = "https://api.ercot.com/api/public-reports"

USER_AGENT = f"ercotapi-stata/{__version__} (+https://github.com/texas-2036/ercotapi-stata-public)"

CRED_PATH = os.path.join(os.path.expanduser("~"), ".ercotapi", "credentials.json")

# ERCOT documents 30 requests per minute per account. The default here sits
# under that so a script sharing the account with another does not trip it.
# At 25 a minute the limiter spaces calls 2.4 seconds apart, which makes a
# wide archive window genuinely slow: 400 postings takes about 16 minutes.
# That is the cost of not being throttled, and callers who know their own
# limit differs can raise it.
DEFAULT_CALLS_PER_MINUTE = 25


class ErcotAuthError(RuntimeError):
    """Raised when credentials are missing, malformed, or rejected."""


class ErcotApiError(RuntimeError):
    """Raised when the API returns an error, or returns something unusable."""


# ---------------------------------------------------------------------------
# credentials
# ---------------------------------------------------------------------------
def load_credentials(explicit: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """Resolve credentials from an explicit dict, the environment, or the
    config file, in that order. Raises with a message that tells the reader
    exactly what to do rather than just reporting a missing key."""
    if explicit and all(explicit.get(k) for k in ("api_key", "username", "password")):
        return dict(explicit)

    env = {
        "api_key": os.environ.get("ERCOT_API_KEY", "").strip(),
        "username": os.environ.get("ERCOT_USERNAME", "").strip(),
        "password": os.environ.get("ERCOT_PASSWORD", "").strip(),
    }
    if all(env.values()):
        return env

    if os.path.exists(CRED_PATH):
        try:
            with open(CRED_PATH, "r", encoding="utf-8") as fh:
                cfg = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            raise ErcotAuthError(
                f"Found {CRED_PATH} but could not read it as JSON ({exc}). "
                'It should contain exactly: {"api_key": "...", "username": "...", '
                '"password": "..."}'
            ) from exc
        missing = [k for k in ("api_key", "username", "password") if not cfg.get(k)]
        if missing:
            raise ErcotAuthError(
                f"{CRED_PATH} is missing: {', '.join(missing)}. "
                'The file needs all three of api_key, username, password.'
            )
        return {k: str(cfg[k]).strip() for k in ("api_key", "username", "password")}

    raise ErcotAuthError(
        "No ERCOT credentials found.\n"
        "Set three environment variables:\n"
        "    ERCOT_API_KEY, ERCOT_USERNAME, ERCOT_PASSWORD\n"
        f"or create {CRED_PATH} containing:\n"
        '    {"api_key": "...", "username": "...", "password": "..."}\n'
        "The README explains how to register with ERCOT and where the "
        "subscription key comes from."
    )


def mask(secret: str) -> str:
    """Render a secret safely for logs: length plus last four characters."""
    s = str(secret or "")
    return f"<len {len(s)}, ends {s[-4:]}>" if len(s) >= 4 else "<set>"


# ---------------------------------------------------------------------------
# rate limiting
# ---------------------------------------------------------------------------
class RateLimiter:
    """Pace requests so ERCOT does not throttle them.

    Two rules apply together. No more than `calls_per_minute` requests go out
    in any rolling 60 seconds, and consecutive requests are spaced by at least
    60/calls_per_minute seconds.

    The second rule matters more than it looks. A rolling-window counter alone
    permits a burst: 15 requests in 9 seconds is comfortably under 25 a minute
    and still earns an HTTP 429, because ERCOT measures over a shorter window
    than a minute. Spacing the calls evenly spends the same budget without the
    burst, and a retry avoided is faster than a retry handled.

    ERCOT throttles per account, so two scripts running side by side share one
    budget. Where the platform supports file locking (macOS, Linux) the window
    is kept in a small JSON file guarded by an exclusive lock, which makes the
    ceiling hold ACROSS processes. On Windows, where fcntl does not exist, it
    degrades to an in-process limiter and says so once, because a quiet
    downgrade would be worse than a slow script.
    """

    _warned = False

    def __init__(self, calls_per_minute: int = DEFAULT_CALLS_PER_MINUTE,
                 state_path: Optional[str] = None):
        self.calls_per_minute = max(1, int(calls_per_minute))
        self.min_gap = 60.0 / self.calls_per_minute
        self.state_path = state_path or os.path.join(
            os.path.dirname(CRED_PATH), "rate_limit.json"
        )
        self._local: List[float] = []
        try:
            import fcntl  # noqa: F401
            self._cross_process = True
        except ImportError:
            self._cross_process = False
            if not RateLimiter._warned:
                print(
                    "[ercotapi] note: file locking is unavailable on this platform, "
                    "so the rate limit applies within this process only. Running two "
                    "pulls at once may exceed ERCOT's ceiling."
                )
                RateLimiter._warned = True

    def wait(self) -> None:
        if self._cross_process:
            self._wait_shared()
        else:
            self._wait_local()

    def _sleep_needed(self, stamps: List[float], now: float) -> float:
        """Seconds to wait before the next request, given the recent ones.
        Returns 0 when the request can go out immediately."""
        if stamps and (now - stamps[-1]) < self.min_gap:
            return self.min_gap - (now - stamps[-1])
        if len(stamps) >= self.calls_per_minute:
            return 60 - (now - stamps[0]) + 0.05
        return 0.0

    def _wait_local(self) -> None:
        while True:
            now = time.time()
            self._local = [t for t in self._local if now - t < 60]
            wait = self._sleep_needed(self._local, now)
            if wait <= 0:
                self._local.append(now)
                return
            time.sleep(wait)

    def _wait_shared(self) -> None:
        import fcntl
        os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
        while True:
            with open(self.state_path, "a+", encoding="utf-8") as fh:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
                fh.seek(0)
                raw = fh.read().strip()
                try:
                    stamps = json.loads(raw) if raw else []
                except json.JSONDecodeError:
                    stamps = []
                now = time.time()
                stamps = sorted(t for t in stamps if now - t < 60)
                wait = self._sleep_needed(stamps, now)
                if wait <= 0:
                    stamps.append(now)
                    fh.seek(0)
                    fh.truncate()
                    json.dump(stamps, fh)
                    fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
                    return
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
            time.sleep(wait)


# ---------------------------------------------------------------------------
# session
# ---------------------------------------------------------------------------
class ErcotSession:
    """An authenticated, rate-limited connection to the ERCOT Public API."""

    def __init__(self, credentials: Optional[Dict[str, str]] = None,
                 calls_per_minute: int = DEFAULT_CALLS_PER_MINUTE,
                 base_url: str = BASE_URL, timeout: int = 60):
        self.cred = load_credentials(credentials)
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.limiter = RateLimiter(calls_per_minute)
        self._token: Optional[str] = None
        self._token_at: float = 0.0
        # ERCOT tokens last one hour with no refresh, so renew five minutes
        # early rather than discovering expiry mid-pull.
        self._token_ttl: int = 3300

    # -- auth ---------------------------------------------------------------
    def _fetch_token(self) -> str:
        body = urllib.parse.urlencode({
            "grant_type": "password",
            "username": self.cred["username"],
            "password": self.cred["password"],
            "scope": f"openid {CLIENT_ID} offline_access",
            "client_id": CLIENT_ID,
            "response_type": "id_token",
        }).encode()
        req = urllib.request.Request(
            TOKEN_URL, data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded",
                     "User-Agent": USER_AGENT},
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                payload = json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:400]
            raise ErcotAuthError(
                f"ERCOT rejected the sign-in (HTTP {exc.code}). This is almost always a "
                f"wrong username or password, not a wrong subscription key. "
                f"Username used: {self.cred['username']!r}. Server said: {detail}"
            ) from exc
        token = payload.get("id_token") or payload.get("access_token")
        if not token:
            raise ErcotAuthError(
                f"Sign-in succeeded but returned no token. Keys present: {list(payload)}"
            )
        self._token, self._token_at = token, time.time()
        return token

    def token(self) -> str:
        if self._token is None or (time.time() - self._token_at) > self._token_ttl:
            return self._fetch_token()
        return self._token

    def _headers(self) -> Dict[str, str]:
        return {
            "Authorization": f"Bearer {self.token()}",
            "Ocp-Apim-Subscription-Key": self.cred["api_key"],
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        }

    # -- requests -----------------------------------------------------------
    def get_json(self, url: str, params: Optional[dict] = None,
                 max_retries: int = 4) -> dict:
        """GET one JSON response, retrying on throttling and server errors.
        Raises rather than returning something partial."""
        last: Optional[BaseException] = None
        for attempt in range(max_retries):
            self.limiter.wait()
            full = url if not params else f"{url}?{urllib.parse.urlencode(params, doseq=True)}"
            req = urllib.request.Request(full, headers=self._headers())
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    return json.loads(resp.read())
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")[:400]
                last = exc
                if exc.code == 401:
                    # token may have aged out mid-pull; force one refresh
                    self._token = None
                    if attempt == 0:
                        continue
                    raise ErcotAuthError(
                        f"ERCOT returned 401 twice for {full}. The subscription key may not "
                        f"be subscribed to this product. Server said: {detail}"
                    ) from exc
                if exc.code == 429 or exc.code >= 500:
                    time.sleep(2 * (attempt + 1))
                    continue
                if exc.code == 400:
                    raise ErcotApiError(
                        f"ERCOT rejected the query (HTTP 400) for {full}\n"
                        f"Server said: {detail}\n"
                        "A very common cause: a date field that supports ranges will not "
                        "accept a bare value. Use <field>From and <field>To instead. Run "
                        "describe_report() and check the hasRange flag."
                    ) from exc
                raise ErcotApiError(f"HTTP {exc.code} for {full}. Server said: {detail}") from exc
            except (urllib.error.URLError, TimeoutError) as exc:
                last = exc
                time.sleep(2 * (attempt + 1))
        raise ErcotApiError(f"Request failed after {max_retries} attempts: {url}") from last

    def get_bytes(self, url: str, params: Optional[dict] = None,
                  max_retries: int = 4) -> bytes:
        """GET a binary response, such as an archive zip. Same retry rules as
        get_json, but the body is returned untouched."""
        last: Optional[BaseException] = None
        for attempt in range(max_retries):
            self.limiter.wait()
            full = url if not params else f"{url}?{urllib.parse.urlencode(params, doseq=True)}"
            req = urllib.request.Request(full, headers=self._headers())
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    return resp.read()
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")[:300]
                last = exc
                if exc.code == 401 and attempt == 0:
                    self._token = None
                    continue
                if exc.code == 429 or exc.code >= 500:
                    time.sleep(2 * (attempt + 1))
                    continue
                raise ErcotApiError(f"HTTP {exc.code} downloading {full}. Server said: {detail}") from exc
            except (urllib.error.URLError, TimeoutError) as exc:
                last = exc
                time.sleep(2 * (attempt + 1))
        raise ErcotApiError(f"Download failed after {max_retries} attempts: {url}") from last

    def get_all_pages(self, url: str, params: Optional[dict] = None,
                      page_size: int = 5000, max_pages: int = 500) -> List[dict]:
        """Walk every page of a paginated report.

        Verifies the number of rows received against the `_meta.totalRecords`
        the API itself reports, and raises on a mismatch. A short table that
        looks complete is the most dangerous failure mode this API has.
        """
        params = dict(params or {})
        params.setdefault("size", page_size)
        pages: List[dict] = []
        expected: Optional[int] = None
        seen = 0
        page = 1
        while True:
            params["page"] = page
            resp = self.get_json(url, params)
            pages.append(resp)
            meta = resp.get("_meta", {}) or {}
            if expected is None:
                expected = meta.get("totalRecords")
            rows = resp.get("data", []) or []
            seen += len(rows)
            total_pages = meta.get("totalPages", 1) or 1
            if page >= total_pages or not rows:
                break
            page += 1
            if page > max_pages:
                raise ErcotApiError(
                    f"Stopped after {max_pages} pages for {url}: {seen} rows so far, "
                    f"source reports {expected}. Narrow the date range or raise max_pages."
                )
        if expected is not None and seen != expected:
            raise ErcotApiError(
                f"Pagination mismatch for {url}: received {seen} rows but the source "
                f"reports totalRecords={expected}. Refusing to return a possibly "
                f"truncated table."
            )
        return pages


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def parse_rows(page: dict) -> List[dict]:
    """Turn one ERCOT page into a list of dictionaries.

    ERCOT sends data rows as positional arrays and the column order separately
    in `fields`. Some endpoints (the catalog, for instance) already return
    dictionaries, which pass through unchanged.
    """
    fields = [f.get("name") for f in (page.get("fields") or [])]
    data = page.get("data", []) or []
    if not fields:
        return data
    return [dict(zip(fields, row)) for row in data]


def get_catalog(session: ErcotSession, size: int = 200) -> List[dict]:
    """List the report products visible to this subscription, as ERCOT sends
    them. Use catalog_rows() for a flat table."""
    resp = session.get_json(session.base_url, params={"size": size})
    return (resp.get("_embedded", {}) or {}).get("products", []) or []


def catalog_rows(products: List[dict]) -> List[dict]:
    """Flatten the catalog to one row per queryable table.

    Two columns carry more weight than the rest. `live_days` is how many days
    of history the live endpoint keeps, so a query reaching further back than
    that returns an empty table and HTTP 200 rather than an error.
    `archive_days` is how far the report's archive goes, which is usually
    years. Together they tell you which of query() and fetch_archive() can
    answer a given date range before you spend a request finding out.

    A product with no queryable table still gets a row, with an empty
    `artifact`, because its archive may still hold the history you want.
    """
    rows: List[dict] = []
    for p in products:
        arts = p.get("artifacts") or []
        has_archive = bool(((p.get("_links") or {}).get("archive") or {}).get("href"))
        common = {
            "emil_id": p.get("emilId") or "",
            "name": p.get("name") or p.get("displayName") or "",
            "frequency": p.get("generationFrequency") or "",
            "live_days": p.get("misDisplayDuration"),
            "archive_days": p.get("archiveDuration"),
            "has_archive": int(has_archive),
            "first_run": p.get("firstRun") or "",
            "last_post": p.get("lastPostDatetime") or "",
            "n_tables": len(arts),
        }
        if not arts:
            rows.append(dict(common, artifact=""))
            continue
        for a in arts:
            href = ((a.get("_links") or {}).get("endpoint") or {}).get("href", "") or ""
            rows.append(dict(common, artifact=href.rstrip("/").split("/")[-1]))
    rows.sort(key=lambda r: (str(r["emil_id"]), str(r["artifact"])))
    return rows


def describe_report(session: ErcotSession, emil_id: str,
                    artifact: Optional[str] = None) -> dict:
    """Ask the API what a report contains and how it can be queried.

    Returns a dict with the report's artifacts and, when `artifact` is given
    (or the report has exactly one), that artifact's queryable fields with
    their data types and the all-important `hasRange` flag.

    Always describe before you query. The field names are not guessable and
    the range rule is not optional.
    """
    emil = emil_id.strip().lower()
    report = session.get_json(f"{session.base_url}/{emil}")
    artifacts = report.get("artifacts", []) or []
    out: Dict[str, Any] = {
        "emil_id": emil_id,
        "artifacts": [
            {"name": a.get("displayName"),
             "slug": (a.get("_links", {}).get("endpoint", {}).get("href", "") or "").rstrip("/").split("/")[-1]}
            for a in artifacts
        ],
        "fields": [],
        "artifact": None,
    }
    slug = artifact
    if slug is None and len(out["artifacts"]) == 1:
        slug = out["artifacts"][0]["slug"]
    if slug:
        detail = session.get_json(f"{session.base_url}/{emil}/{slug}")
        out["artifact"] = slug
        out["fields"] = detail.get("fields", []) or []
    return out


def build_range_params(fields: List[dict], field_name: str,
                       start: str, end: str) -> Dict[str, str]:
    """Build the From/To pair for a range-filterable field, refusing to guess.

    ERCOT returns HTTP 400 for a bare value on a field that supports ranges,
    and the error text does not say so. This checks the field's own `hasRange`
    flag first and explains the problem if the field cannot take a range.
    """
    by_name = {f.get("name"): f for f in (fields or [])}
    if field_name not in by_name:
        raise ErcotApiError(
            f"Field {field_name!r} does not exist on this report. Available fields: "
            f"{', '.join(sorted(by_name)) or '(none reported)'}"
        )
    if not by_name[field_name].get("hasRange"):
        raise ErcotApiError(
            f"Field {field_name!r} does not support ranges on this report, so "
            f"{field_name}From / {field_name}To would be rejected. Pass it as a single "
            f"value instead."
        )
    return {f"{field_name}From": start, f"{field_name}To": end}


def query(session: ErcotSession, emil_id: str, artifact: str,
          params: Optional[dict] = None, page_size: int = 5000) -> List[dict]:
    """Run a query and return tidy dictionaries, pagination already verified."""
    url = f"{session.base_url}/{emil_id.strip().lower()}/{artifact}"
    rows: List[dict] = []
    for page in session.get_all_pages(url, params=params, page_size=page_size):
        rows.extend(parse_rows(page))
    return rows


# ---------------------------------------------------------------------------
# the archive: original posted files, going back years
# ---------------------------------------------------------------------------
def _day_bounds(start: str, end: str) -> Dict[str, str]:
    """Turn two dates into the timestamp pair the archive expects.

    A bare date is widened to cover the whole day, so a range of
    2024-03-01 to 2024-03-03 includes everything posted on the third. A value
    that already carries a time is passed through untouched.
    """
    lo = start if "T" in start else f"{start}T00:00:00"
    hi = end if "T" in end else f"{end}T23:59:59"
    return {"postDatetimeFrom": lo, "postDatetimeTo": hi}


def list_archive(session: ErcotSession, emil_id: str,
                 post_from: Optional[str] = None, post_to: Optional[str] = None,
                 max_docs: int = 2000, page_size: int = 500) -> List[dict]:
    """List the files a report's archive holds, newest first.

    `post_from` and `post_to` filter on the moment ERCOT published the file,
    which for a forecast or day-ahead report is not the date of the data
    inside it. Widen the window and filter on the data's own date column after
    the download.
    """
    url = f"{session.base_url}/archive/{emil_id.strip().lower()}"
    params: Dict[str, Any] = {"size": page_size}
    if post_from and post_to:
        params.update(_day_bounds(post_from, post_to))
    elif post_from or post_to:
        raise ErcotApiError(
            "The archive filter needs both a start and an end date; ERCOT "
            "ignores one without the other."
        )

    docs: List[dict] = []
    page = 1
    while True:
        params["page"] = page
        resp = session.get_json(url, params)
        batch = resp.get("archives") or []
        for a in batch:
            docs.append({
                "doc_id": a.get("docId"),
                "friendly_name": a.get("friendlyName") or "",
                "post_datetime": a.get("postDatetime") or "",
            })
        meta = resp.get("_meta") or {}
        total_pages = meta.get("totalPages", 1) or 1
        if not batch or page >= total_pages or len(docs) >= max_docs:
            break
        page += 1
    if len(docs) > max_docs:
        docs = docs[:max_docs]
    return docs


def read_archive_zip(blob: bytes, doc: dict) -> List[dict]:
    """Unpack one downloaded archive document into rows.

    Each file ERCOT posts is a zip holding one or more CSVs. Two provenance
    columns are added to every row, because a combined table assembled from
    hundreds of postings is impossible to audit without them.
    """
    import csv
    rows: List[dict] = []
    try:
        zf = zipfile.ZipFile(io.BytesIO(blob))
    except zipfile.BadZipFile as exc:
        raise ErcotApiError(
            f"Archive document {doc.get('doc_id')} did not arrive as a zip file. "
            f"It may be a format this client does not read, such as XML."
        ) from exc
    for member in zf.namelist():
        if not member.lower().endswith(".csv"):
            continue
        text = zf.read(member).decode("utf-8-sig", "replace")
        for row in csv.DictReader(io.StringIO(text)):
            row["source_doc_id"] = doc.get("doc_id")
            row["source_post_datetime"] = doc.get("post_datetime")
            rows.append(row)
    return rows


def fetch_archive(session: ErcotSession, emil_id: str,
                  post_from: str, post_to: str, max_docs: int = 400,
                  progress_every: int = 10) -> List[dict]:
    """Download an archive date range and stitch the postings into one table.

    Every posting is a separate HTTPS request, so a wide range is slow and
    counts against the same rate limit as everything else. max_docs stops a
    range that turned out to be far larger than expected, and says so rather
    than quietly returning part of it.
    """
    docs = list_archive(session, emil_id, post_from, post_to, max_docs=max_docs + 1)
    if len(docs) > max_docs:
        raise ErcotApiError(
            f"That range covers {len(docs)}+ postings, above the max_docs limit of "
            f"{max_docs}. Each posting is one download, so this would take a while. "
            f"Either narrow the date range or raise max_docs deliberately."
        )
    if not docs:
        return []
    url = f"{session.base_url}/archive/{emil_id.strip().lower()}"
    rows: List[dict] = []
    docs = sorted(docs, key=lambda d: str(d.get("post_datetime")))
    for i, doc in enumerate(docs, start=1):
        blob = session.get_bytes(url, params={"download": doc["doc_id"]})
        rows.extend(read_archive_zip(blob, doc))
        if progress_every and (i % progress_every == 0 or i == len(docs)):
            print(f"  downloaded {i} of {len(docs)} postings, {len(rows)} rows so far")
    return rows


def write_csv(path: str, rows: List[dict]) -> int:
    """Write rows to CSV using the union of keys, in first-seen order."""
    import csv
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    if not rows:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("")
        return 0
    cols: List[str] = []
    for row in rows:
        for key in row:
            if key not in cols:
                cols.append(key)
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    return len(rows)
