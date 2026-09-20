# ercotapi — ERCOT grid data in Stata

`ercotapi` is a Stata command that pulls Texas electricity grid data from the
[ERCOT Public API](https://apiexplorer.ercot.com/) directly into memory.
Wholesale prices, load, generation by fuel, resource outages, and roughly a
hundred other published reports become a dataset you can work with in one
line:

```stata
ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///
    field(deliveryDate) from(2026-09-01) to(2026-09-07) ///
    param(settlementPoint=HB_HOUSTON) clear
```

We wrote it because getting data out of the ERCOT API is harder than the
documentation suggests, and most of the difficulty is undocumented. The
authentication takes two separate credentials. Date filters are rejected
unless you send them in a shape the error message never names. Reports keep
only a few weeks of history on the endpoint you would naturally query, and a
request for anything older comes back empty with no error at all. Each of
those cost us an afternoon; this package handles all three so they cost you
nothing.

`ercotapi` is not affiliated with or endorsed by ERCOT. It reads a public API
under your own registered account.

**Contents**

- [Install](#install)
- [Getting an ERCOT API key](#getting-an-ercot-api-key)
- [Storing your credentials](#storing-your-credentials)
- [Your first pull](#your-first-pull)
- [The commands](#the-commands)
- [Two traps worth knowing about](#two-traps-worth-knowing-about)
- [Worked examples](#worked-examples)
- [Using the Python module on its own](#using-the-python-module-on-its-own)
- [When something goes wrong](#when-something-goes-wrong)
- [What is in the repository](#what-is-in-the-repository)
- [Author and license](#author-and-license)

---

## Install

```stata
net install ercotapi, from("https://raw.githubusercontent.com/ericabooth/ercotapi-stata-public/main/") replace force
help ercotapi
```

That one command copies everything the package needs, the command and its
helper ado files, the help file, and the Python engine, straight to your
adopath. Stata files the `.py` files under `PLUS/py/` and the package looks for
them there, so there is no manual `adopath` step. Run the same line again
whenever you want to update.

Requires Stata 16.0 or newer, and Python 3.8 or newer on the machine. Nothing
to pip install, ever: the engine uses the Python standard library only, and
Stata's own Python integration does not have to be configured.

You also need a free ERCOT Public API account, which the next section walks
through.

Why Python is in the picture at all: every ERCOT request carries an OAuth
bearer token and an Azure subscription key sent as an HTTP header. Stata's own
file and URL commands cannot set custom headers, so the network work happens in
a small Python module that ships with this package. `ercotapi` finds an
interpreter, runs the query, and reads the result into memory. From where you
sit it is a Stata command.

### Confirming the install

```stata
ercotapi setup
```

That reports which Python interpreter it found, where the engine files are,
where it read your credentials from, and whether ERCOT accepted the sign-in.
The key and password are shown as a length and last four characters, and the
account only partly, so the report is safe to paste into a bug report. Run it
once after installing and again any time something stops working.

### Working from a clone instead

```bash
git clone https://github.com/ericabooth/ercotapi-stata-public.git
```

```stata
adopath ++ "/full/path/to/ercotapi-stata-public"
```

Everything sits in one folder, so the clone needs no build step. If a machine
cannot reach GitHub at all, mirror the repository somewhere it can and point
the package there before your first call:

```stata
global ercotapi_remote_base "https://your.mirror/ercotapi/"
```

---

## Getting an ERCOT API key

ERCOT gives these out free to anyone who registers. Two credentials come out of
the process and you need both: the **email and password** you register with,
and a **Primary key** (ERCOT's name for an Azure subscription key). Budget five
minutes.

These steps follow ERCOT's own
[registration and authentication guide](https://developer.ercot.com/applications/pubapi/user-guide/registration-and-authentication/),
checked on 20 September 2026. If a button has moved, that page is the
authority.

### Step 1 — create the account

1. Open <https://apiexplorer.ercot.com/> in a browser.
2. Click **Sign In/Sign Up** at the top right.
3. Type your email address and click **Send verification code**.
4. ERCOT emails you a code. Paste it into the **Verification Code** field and
   click **Verify code**.
5. Fill in the rest of the form: a password, a display name, your first name
   and your last name.
6. Click **Create**.

Write down the email address and password. `ercotapi` signs in with them on
every run, so a password manager entry is worth making now.

### Step 2 — subscribe to a product and copy the key

1. Sign in at <https://apiexplorer.ercot.com/>.
2. Go to the **Products** page in the top navigation.
3. Choose a product from the table. The public reports product is the one that
   covers everything this package reaches.
4. Give the subscription a name. Anything works; "Public API" is fine.
5. Click **Subscribe**. ERCOT sends you to your **Profile** page.
6. Find the active subscription there and click **Show**.
7. Copy the **Primary key**.

You only ever have to do this once. ERCOT's guide says as much: the key does
not rotate on its own and the same key works for every report your
subscription covers.

### What you should have now

Three values:

| Value | Where it came from | Looks like |
|---|---|---|
| Username | the email you registered with | `you@example.org` |
| Password | the one you set in step 1 | your own |
| API key | the Primary key from step 2 | 32 hexadecimal characters |

---

## Storing your credentials

`ercotapi` never takes a password as a command argument. Anything typed as a
Stata argument is written to the command history and shows up in the review
window, and anything typed on a shell command line is written to the shell
history, so a password passed that way outlives the session that used it.
Instead, put the three values in a file that only you can read, or in
environment variables.

### The simple way: a credentials file

In Stata, run:

```stata
ercotapi setup, template
```

That creates `~/.ercotapi/credentials.json` with owner-only permissions and
tells you where it is. On Windows the path is
`C:\Users\<you>\.ercotapi\credentials.json`. Open it in a text editor and fill
in the three values:

```json
{
  "api_key": "your 32-character Primary key",
  "username": "you@example.org",
  "password": "your ERCOT password"
}
```

Save it, then run `ercotapi setup` to confirm it works. If the file already
exists, the template command leaves it alone rather than overwriting it.

### The alternative: environment variables

If you would rather keep secrets out of files, or you are running on a server,
set three variables before Stata starts:

```bash
export ERCOT_API_KEY="..."
export ERCOT_USERNAME="you@example.org"
export ERCOT_PASSWORD="..."
```

Set all three. The environment is used in preference to the file only when all
three variables are present; if any one of them is missing, every value comes
from the file instead. `ercotapi setup` reports which of the two it actually
read.

### What not to do

Do not put your key in a do-file, and do not commit one to a repository. If you
work on a shared drive, remember that the credentials file lives in your home
directory rather than in the project folder, which is the point: the project
can be shared and the credentials cannot.

---

## Your first pull

```stata
* what reports can I see?
ercotapi catalog, clear
list emil_id artifact live_days archive_days if strpos(lower(name), "fuel mix")

* what does one of them contain?
ercotapi describe np4-190-cd

* get a week of Houston hub day-ahead prices
ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///
    field(deliveryDate) from(2026-09-01) to(2026-09-07) ///
    param(settlementPoint=HB_HOUSTON) clear

list in 1/5
```

The order matters more than it looks. ERCOT's field names are not guessable
and are case sensitive, so `describe` before `pull` saves a round trip. Reading
the catalog first tells you something you cannot get any other way, which the
next section takes up.

---

## The commands

| Command | What it does |
|---|---|
| `ercotapi setup` | Checks Python, the engine files, and your credentials, then signs in to prove it works. Add `template` to create the credentials file; add `offline` to skip the sign-in. |
| `ercotapi catalog` | Loads one row per queryable table across every report your subscription can see, plus a row with a blank `artifact` for each report that has no queryable table but may still have an archive. |
| `ercotapi describe <id>` | Shows a report's tables and, for one table, every field with its type and whether it accepts a range. |
| `ercotapi pull <id>` | Queries the live endpoint and loads the rows. This is the command for recent dates. |
| `ercotapi archive <id>` | Downloads the original files ERCOT posted, which reach back years, and stitches them into one table. This is the command for older dates. |
| `ercotapi version` | Reports the installed version and what it found on the machine. |

Full option lists, with examples, are in the help file: `help ercotapi`.

---

## Two traps worth knowing about

### 1. A date field that accepts ranges will reject a single value

Ask for `deliveryDate=2026-09-19` and ERCOT answers HTTP 400 with
"One or more of the query parameters specified are not available for this
resource" and names the field. The message is misleading: the field exists and
is queryable, but only as a pair, `deliveryDateFrom` and `deliveryDateTo`.

Which fields behave this way is discoverable rather than guessable. Run
`ercotapi describe` and read the last column:

```
fields on dam_stlmnt_pnt_prices:
    name                              type        range?
    deliveryDate                      DATE        YES - use From/To
    hourEnding                        VARCHAR     no
    settlementPoint                   VARCHAR     no
    settlementPointPrice              DOUBLE      YES - use From/To
    DSTFlag                           BOOLEAN     no
```

Anything marked `YES` goes through `field()` `from()` `to()`, which builds the
pair for you and refuses to guess if the field cannot take a range. Everything
marked `no` goes through `param()` as a plain `key=value`.

### 2. An empty result is not the same as nothing happening

Each report keeps a limited window of history on its live endpoint. Query
further back than that and ERCOT returns an empty table with HTTP 200, which
looks exactly like a day on which nothing was published. Nothing in the reply
says you asked for a date the endpoint does not hold.

How far back each report goes is published, and `ercotapi catalog` reads it for
you:

```stata
ercotapi catalog, clear
list emil_id artifact live_days archive_days in 1/5, noobs
```

```
  +-------------------------------------------------------------------+
  |    emil_id                    artifact   live_days   archive_days |
  |-------------------------------------------------------------------|
  |   COPG-316                                      31           2555 |
  | EIA-930-CD                                       7           2555 |
  | EIA-930-ER                                     365           2555 |
  |  GEN-55-CD   hrly_rt_load_fcast_actual           7           2555 |
  |    NP1-300                                     184           2555 |
  +-------------------------------------------------------------------+
```

`live_days` is how far back `ercotapi pull` can reach. `archive_days` is how
far back `ercotapi archive` can reach, and it is usually 2,555 days, or seven
years. So a question about last week goes to `pull`, and a question about 2022
goes to `archive`.

One detail about the archive catches people out, so it is worth stating plainly.
The archive filters on the date ERCOT **published** a file, not the date of the
data inside it. A day-ahead price report published on 1 March carries delivery
date 2 March. Ask for a window a day or two wider than you need, then filter on
the data's own date column once it is in Stata.

---

## Worked examples

### Day-ahead prices at a hub, last week

```stata
ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///
    field(deliveryDate) from(2026-09-13) to(2026-09-19) ///
    param(settlementPoint=HB_HOUSTON) clear

generate double price = settlementPointPrice
generate date = date(deliveryDate, "YMD")
format date %td
collapse (mean) price, by(date)
```

### The same series for 2022, from the archive

```stata
ercotapi archive np4-190-cd, from(2022-06-30) to(2022-07-08) clear

keep if SettlementPoint == "HB_HOUSTON"
generate date  = date(DeliveryDate, "MDY")
generate price = real(SettlementPointPrice)
format date %td
```

Two things differ from the live pull and both come from the archive being the
original posted file rather than a rendered query result. The column names are
capitalised differently, and the values arrive as text, so you convert them
yourself. Every row also carries `source_doc_id` and `source_post_datetime`, so
a table assembled from hundreds of postings can still be traced back to the
file each row came from.

### Look before you download

A wide archive window is many separate downloads, so it is worth checking the
size first:

```stata
ercotapi archive np4-190-cd, list from(2022-01-01) to(2022-12-31) clear
count
```

If that count is larger than you want to sit through, narrow the window.
The two paths treat their ceiling differently. A listing stops at 2,000
postings and says so, meaning a count that comes back at exactly that number is
not the whole archive. A download stops at 400 and refuses the range outright
rather than returning part of it. Raise either with `maxdocs()` when you mean
it.

### Keep the CSV as well as the data

```stata
ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///
    field(deliveryDate) from(2026-09-01) to(2026-09-07) ///
    saving("dam_prices.csv") replace clear
```

Add `noimport` to write the CSV and leave memory untouched, which is useful
inside a loop that assembles many months.

### Record where the data came from

Every successful `pull` and `archive` writes its own provenance into the
dataset:

```stata
notes
char list _dta[]
```

```
_dta:
  1.  ERCOT Public API, report np4-190-cd, table dam_stlmnt_pnt_prices,
      deliveryDate from 2026-09-19 to 2026-09-19; retrieved 20 Sep 2026 by
      ercotapi 1.0.0
```

Save the `.dta` and the note travels with it, which means a file found on a
shared drive a year later can still say what it is.

---

## Using the Python module on its own

The engine is a plain module with no dependencies, so it works outside Stata
too, in a notebook or a scheduled job:

```python
import sys
sys.path.insert(0, "/path/to/ercotapi-stata-public")
from _ercotapi_client import ErcotSession, describe_report, build_range_params, query

session = ErcotSession()                       # reads the same credentials
info   = describe_report(session, "np4-190-cd", "dam_stlmnt_pnt_prices")
params = build_range_params(info["fields"], "deliveryDate", "2026-09-01", "2026-09-07")
rows   = query(session, "np4-190-cd", "dam_stlmnt_pnt_prices", params)
```

`query()` walks every page and compares the rows it received against the
`totalRecords` count the API reports, raising rather than handing back a short
table that looks complete. Truncated-but-plausible output is the most dangerous
failure this API has, so the client refuses to produce it.

The command line the Stata side drives is also usable directly:

```bash
python3 _ercotapi_cli.py catalog --out catalog.csv
python3 _ercotapi_cli.py describe --emil np4-190-cd
python3 _ercotapi_cli.py pull --emil np4-190-cd --artifact dam_stlmnt_pnt_prices \
    --field deliveryDate --from 2026-09-01 --to 2026-09-07 --out prices.csv
```

---

## When something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| `no working Python 3 interpreter was found` | Python is missing, or it is installed somewhere Stata's shell does not look. | Install Python 3.8+, or set `global ercotapi_python "/full/path/to/python3"`. |
| `the Python engine files could not be found or downloaded` | The engine did not arrive with the install, or only half of it did. | Re-run the `net install` line at the top, or clone the repo and `adopath ++` it. |
| `No ERCOT credentials found` | Neither the environment variables nor the credentials file is set. | Run `ercotapi setup, template` and fill in the file. |
| `ERCOT rejected the sign-in (HTTP 400)` | Wrong username or password. This is about the account, not the key. | Sign in at apiexplorer.ercot.com by hand to confirm the password, then update the credentials file. |
| `ERCOT returned 401 twice` | The subscription key is wrong, or the subscription does not cover this product. | Check the Primary key on your Profile page, and that the subscription is active. |
| `ERCOT rejected the query (HTTP 400)` | Almost always a range field sent as a single value. | Run `ercotapi describe` and move that field to `field()` `from()` `to()`. |
| `the query succeeded and returned no rows` | Often a date older than the live endpoint holds. | Check `live_days` in the catalog, then use `ercotapi archive` for the same range. |
| `Pagination mismatch` | The API reported more rows than it delivered. | Rerun. If it persists, narrow the date range and report it as an issue. |
| `That range covers N+ postings` | The archive window is wider than the safety ceiling. | Narrow the window, or raise `maxdocs()` deliberately. |
| A Windows note about file locking | Windows has no `fcntl`, so the rate limiter cannot coordinate across processes. | Harmless if you run one pull at a time. Avoid running two at once on Windows. |

Add `verbose` to any command to see the exact command line being run and the
receipt that came back.

### About rate limits, and how long an archive pull takes

ERCOT documents 30 requests a minute per account, and throttles by account, so
two scripts running at once share one budget. The client holds itself to 25 a
minute and coordinates through a lock file, so the ceiling holds across
separate Stata sessions on macOS and Linux. It also spaces the requests evenly
rather than letting them go out in a burst, because a burst well under 25 a
minute still earns an HTTP 429. If one arrives anyway, the client waits and
retries rather than failing.

The practical consequence shows up in `ercotapi archive`, where each posting is
a separate download. At 25 a minute the calls are 2.4 seconds apart, so a month
of daily postings takes about 75 seconds and the 400-posting default ceiling
takes roughly 16 minutes. Plan a year-long backfill accordingly, and consider
running it once with `saving()` rather than repeating it.

If you know your own account's limit differs, raise it with `rate()`.

---

## What is in the repository

These seven are declared in `ercotapi.pkg` and are what `net install` copies:

| File | Role |
|---|---|
| `ercotapi.ado` | The command you type, and its subcommands. |
| `ercotapi_findfile.ado` | Finds the Python engine, and fetches it if an install left it behind. |
| `ercotapi_python.ado` | Works out which Python interpreter to use and proves it runs. |
| `ercotapi_shell.ado` | Runs one engine command and reads back its result. |
| `ercotapi.sthlp` | The help file. |
| `_ercotapi_client.py` | The client: auth, rate limiting, pagination, the archive. Usable on its own. |
| `_ercotapi_cli.py` | The command line the Stata side drives. |

The rest stays in the repository and is not copied to your adopath:

| File | Role |
|---|---|
| `ercotapi.pkg`, `stata.toc` | What `net install` reads to know which files to copy. |
| `tests/` | Test scripts and how to run them. Clone the repository to run them. |
| `LICENSE`, `README.md` | This file, and the licence. |

---

## Author and license

Eric A. Booth, Sr Researcher, Texas 2036 (eric.a.booth@gmail.com). MIT-licensed.
See [LICENSE](LICENSE).

Issues and pull requests are welcome at
<https://github.com/ericabooth/ercotapi-stata-public>. If you hit an ERCOT
behaviour this package does not handle, an issue with the report id, the
options you passed, and the message you got is enough to work from.

If this package supports published work, please cite it:

> Booth, E. A. (2026). *ercotapi: ERCOT Public API data in Stata* (version
> 1.0.0) [Stata package]. https://github.com/ericabooth/ercotapi-stata-public

The data are ERCOT's and their terms govern their use. This package is an
independent client and carries no endorsement from ERCOT.
