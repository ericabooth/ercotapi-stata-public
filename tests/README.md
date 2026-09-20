# Tests

Three scripts, split by what they need. Run them from the package folder.

| Script | Needs | Roughly |
|---|---|---|
| `test_client_offline.py` | Python only | under a second |
| `test_client_live.py` | Python and ERCOT credentials | about 40 seconds |
| `test_ercotapi.do` | Stata, Python, and credentials for the live half | about a minute |

## Running them

```bash
python3 tests/test_client_offline.py
python3 tests/test_client_live.py
```

```stata
do tests/test_ercotapi.do
```

Or in batch:

```bash
stata-mp -b do tests/test_ercotapi.do
```

Then read `test_ercotapi.log` and search it for `FAIL`. Stata's exit code will
not tell you whether the checks passed, so read the summary at the bottom of
the log: it counts passes, failures and skips, and a failing run ends with
error 9.

## What each one covers

**`test_client_offline.py`** exercises the parts of the client that reshape
what ERCOT sends and the guards that refuse a bad request before spending one:
positional rows zipped back onto their field names, the From/To builder and its
refusals, the catalog flattening, archive zip reading, CSV writing, credential
resolution and its error messages, secret masking, and the rate limiter's
pacing arithmetic. It never opens a socket and never needs a key, so it runs in
CI.

**`test_client_live.py`** calls ERCOT. Without credentials every test is
skipped rather than failed, so it is also safe in CI. These tests double as the
evidence behind the claims the README and help file make about ERCOT's
behaviour, and each one says which claim it is standing behind:

- a bare value on a range field returns HTTP 400
- a date older than the live window returns an empty table and HTTP 200
- the catalog publishes both retention figures, and the archive one is larger
- a day-ahead file posted on 1 March carries delivery date 2 March

If ERCOT changes any of that, one of these fails and the documentation needs
revisiting. That is the point of writing them this way.

**`test_ercotapi.do`** drives the Stata layer end to end: dispatch, every
option guard, the data-in-memory protection, and then the live path through
`catalog`, `describe`, `pull` and `archive`. It checks values rather than
reading the screen, because a command that prints a reassuring message and
loads nothing looks fine in a log.

## Setting up credentials for the live tests

Either set `ERCOT_API_KEY`, `ERCOT_USERNAME` and `ERCOT_PASSWORD` in the
environment, or fill in `~/.ercotapi/credentials.json`. The main README
explains how to register with ERCOT and where the key comes from. No credential
belongs in this repository, and `.gitignore` is written to make an accidental
commit hard.

## A note on live-test dates

`test_client_live.py` and the live half of `test_ercotapi.do` query the day
before yesterday, which should always be settled and published. The archive
checks use 1 March 2024, a date chosen because its posting is a single file
whose delivery date is the following day, which is what makes the posting-date
offset visible. Both are inside the seven-year archive window and should stay
valid until 2031.
