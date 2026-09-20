#!/usr/bin/env python3
"""
_ercotapi_cli.py -- the command line that ercotapi.ado drives.

Stata cannot speak HTTPS with custom headers, so the Stata command shells out
to this script and then imports the CSV it writes. Keeping the boundary at
"write a CSV, print a one-line receipt" means the Stata side never has to
parse JSON and the Python side never has to know about Stata.

Every subcommand prints a single line starting with OK: or ERROR: as its last
line, which is what the .ado reads to decide whether to continue.

SUBCOMMANDS
    template                    write an empty credentials file for you to fill in
    check                       confirm credentials work and report what was found
    catalog   --out FILE        list available report products and their tables
    describe  --emil ID [--artifact SLUG] [--out FILE]
                                show a report's artifacts and queryable fields
    pull      --emil ID --artifact SLUG --out FILE
              [--field NAME --from DATE --to DATE] [--param k=v ...]
                                run a live query and write tidy rows to CSV
    archive-list --emil ID --out FILE [--from DATE --to DATE]
                                list the files a report's archive holds
    archive-pull --emil ID --from DATE --to DATE --out FILE [--max-docs N]
                                download an archive date range into one CSV

Run any subcommand with --help for its own options.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ercotapi_client import (  # noqa: E402
    DEFAULT_CALLS_PER_MINUTE, CRED_PATH, ErcotApiError, ErcotAuthError,
    ErcotSession, build_range_params, catalog_rows, describe_report,
    fetch_archive, get_catalog, list_archive, mask, query, write_csv,
    __version__,
)


def _session(args) -> ErcotSession:
    return ErcotSession(calls_per_minute=args.rate)


def cmd_template(args) -> int:
    """Create an empty credentials file for the user to edit by hand.

    Credentials are never taken as arguments. Anything typed as an argument in
    Stata is written to the command history and the review window, and anything
    typed on a shell command line is written to the shell history, so a password
    passed that way outlives the session that used it. The user opens this file
    in a text editor and pastes the three values in.
    """
    if os.path.exists(CRED_PATH):
        print(f"A credentials file already exists at {CRED_PATH}.")
        print("Refusing to overwrite it. Open it in a text editor to change the values.")
        print(f"OK: {CRED_PATH} already exists and was left alone")
        return 0
    os.makedirs(os.path.dirname(CRED_PATH), exist_ok=True)
    skeleton = {"api_key": "", "username": "", "password": ""}
    with open(CRED_PATH, "w", encoding="utf-8") as fh:
        json.dump(skeleton, fh, indent=2)
        fh.write("\n")
    try:
        os.chmod(CRED_PATH, 0o600)  # owner read/write only; a no-op on some systems
    except OSError:
        pass
    print(f"Created {CRED_PATH}")
    print("Open that file in a text editor and fill in the three values:")
    print('    "api_key"  : your ERCOT Primary key, from the Profile page at apiexplorer.ercot.com')
    print('    "username" : the email address you registered with ERCOT')
    print('    "password" : the password you set for that ERCOT account')
    print("Save the file, then run: ercotapi setup")
    print(f"OK: wrote an empty credentials file to {CRED_PATH}")
    return 0


def cmd_check(args) -> int:
    from _ercotapi_client import load_credentials
    print(f"credentials file     : {CRED_PATH}")
    cred = load_credentials()
    source = (
        "environment variables" if os.environ.get("ERCOT_API_KEY")
        else "the credentials file above"
    )
    print(f"credentials read from: {source}")
    print(f"  username           : {cred['username']}")
    print(f"  subscription key   : {mask(cred['api_key'])}")
    print(f"  password           : {mask(cred['password'])}")
    session = _session(args)
    session.token()
    print("sign-in              : OK (token issued)")
    products = get_catalog(session)
    print(f"catalog reachable    : OK ({len(products)} products visible)")
    print(f"OK: ercotapi {__version__} is configured and working")
    return 0


def cmd_catalog(args) -> int:
    session = _session(args)
    rows = catalog_rows(get_catalog(session))
    n = write_csv(args.out, rows)
    print(f"OK: wrote {n} rows to {args.out}")
    return 0


def cmd_archive_list(args) -> int:
    session = _session(args)
    if bool(args.date_from) != bool(args.date_to):
        raise ErcotApiError("--from and --to go together; ERCOT ignores one without the other.")
    docs = list_archive(session, args.emil, args.date_from, args.date_to,
                        max_docs=args.max_docs)
    n = write_csv(args.out, docs)
    if docs:
        stamps = sorted(d["post_datetime"] for d in docs if d.get("post_datetime"))
        if stamps:
            print(f"posting dates run from {stamps[0]} to {stamps[-1]}")
    print(f"OK: wrote {n} rows to {args.out}")
    return 0


def cmd_archive_pull(args) -> int:
    session = _session(args)
    if not (args.date_from and args.date_to):
        raise ErcotApiError("archive-pull needs both --from and --to.")
    rows = fetch_archive(session, args.emil, args.date_from, args.date_to,
                         max_docs=args.max_docs)
    n = write_csv(args.out, rows)
    if n == 0:
        print(
            "NOTE: no postings fell in that window. The archive filters on the date\n"
            "ERCOT published the file, not the date of the data inside it, so a\n"
            "day-ahead report posted on 3 March carries delivery date 4 March.\n"
            "Run archive-list with no date range to see what the archive holds."
        )
    print(f"OK: wrote {n} rows to {args.out}")
    return 0


def cmd_describe(args) -> int:
    session = _session(args)
    info = describe_report(session, args.emil, args.artifact)
    print(f"report   : {info['emil_id']}")
    print("artifacts:")
    for a in info["artifacts"]:
        mark = " <- described below" if a["slug"] == info["artifact"] else ""
        print(f"    {a['slug']}   {a['name']}{mark}")
    if info["fields"]:
        print(f"fields on {info['artifact']}:")
        print(f"    {'name':<34}{'type':<12}{'range?'}")
        for f in info["fields"]:
            rng = "YES - use From/To" if f.get("hasRange") else "no"
            print(f"    {str(f.get('name','')):<34}{str(f.get('dataType','')):<12}{rng}")
    elif not args.artifact and len(info["artifacts"]) > 1:
        print("This report has more than one artifact; rerun with --artifact to see its fields.")
    if args.out:
        write_csv(args.out, [
            {"artifact": info["artifact"], "field": f.get("name"),
             "data_type": f.get("dataType"), "has_range": int(bool(f.get("hasRange")))}
            for f in info["fields"]
        ])
        print(f"fields written to {args.out}")
    print(f"OK: described {info['emil_id']}")
    return 0


def cmd_pull(args) -> int:
    session = _session(args)
    params = {}
    for item in args.param or []:
        if "=" not in item:
            raise ErcotApiError(f"--param expects key=value, got {item!r}")
        k, v = item.split("=", 1)
        params[k.strip()] = v.strip()

    if args.field:
        if not (args.date_from and args.date_to):
            raise ErcotApiError("--field requires both --from and --to")
        info = describe_report(session, args.emil, args.artifact)
        params.update(build_range_params(info["fields"], args.field,
                                         args.date_from, args.date_to))

    rows = query(session, args.emil, args.artifact, params=params,
                 page_size=args.page_size)
    n = write_csv(args.out, rows)
    if n == 0:
        print(
            "NOTE: the query succeeded and returned no rows. For older dates some\n"
            "ERCOT live endpoints answer with an empty result and HTTP 200 rather\n"
            "than an error, so an empty table does not prove nothing happened.\n"
            "Check whether the report has a separate historical archive product."
        )
    print(f"OK: wrote {n} rows to {args.out}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="_ercotapi_cli.py",
        description="Command line used by the Stata ercotapi command.",
    )
    p.add_argument("--rate", type=int, default=DEFAULT_CALLS_PER_MINUTE,
                   help=f"max requests per minute (default {DEFAULT_CALLS_PER_MINUTE})")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("template", help="write an empty credentials file to fill in")
    s.set_defaults(func=cmd_template)

    s = sub.add_parser("check", help="verify credentials and connectivity")
    s.set_defaults(func=cmd_check)

    s = sub.add_parser("catalog", help="list report products and their tables")
    s.add_argument("--out", required=True)
    s.set_defaults(func=cmd_catalog)

    s = sub.add_parser("archive-list", help="list the files a report's archive holds")
    s.add_argument("--emil", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--from", dest="date_from")
    s.add_argument("--to", dest="date_to")
    s.add_argument("--max-docs", dest="max_docs", type=int, default=2000)
    s.set_defaults(func=cmd_archive_list)

    s = sub.add_parser("archive-pull", help="download an archive date range into one CSV")
    s.add_argument("--emil", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--from", dest="date_from", required=True)
    s.add_argument("--to", dest="date_to", required=True)
    s.add_argument("--max-docs", dest="max_docs", type=int, default=400)
    s.set_defaults(func=cmd_archive_pull)

    s = sub.add_parser("describe", help="show a report's artifacts and fields")
    s.add_argument("--emil", required=True)
    s.add_argument("--artifact")
    s.add_argument("--out")
    s.set_defaults(func=cmd_describe)

    s = sub.add_parser("pull", help="query a report and write CSV")
    s.add_argument("--emil", required=True)
    s.add_argument("--artifact", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--field", help="date field to filter on (must support ranges)")
    s.add_argument("--from", dest="date_from")
    s.add_argument("--to", dest="date_to")
    s.add_argument("--param", action="append", help="extra key=value filter; repeatable")
    s.add_argument("--page-size", type=int, default=5000)
    s.set_defaults(func=cmd_pull)
    return p


def main() -> int:
    # Stata captures this run by redirecting both streams into one log file.
    # Block buffering would let stderr overtake stdout there and scramble the
    # order the reader sees, so everything goes to stdout and the stream is
    # flushed after each write.
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:  # Python 3.6 and earlier
        pass

    args = build_parser().parse_args()
    try:
        return args.func(args)
    except (ErcotAuthError, ErcotApiError) as exc:
        # The full text explains what to do about it; the last line is the
        # receipt the Stata side reads, so it has to be one line and last.
        print(str(exc))
        print(f"ERROR: {str(exc).splitlines()[0]}")
        return 1
    except Exception as exc:  # noqa: BLE001
        import traceback
        traceback.print_exc(file=sys.stdout)
        print(f"ERROR: unexpected {type(exc).__name__}: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
