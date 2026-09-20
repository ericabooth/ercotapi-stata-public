{smcl}
{* *! version 1.0.0  20sep2026}{...}
{viewerjumpto "Syntax" "ercotapi##syntax"}{...}
{viewerjumpto "Description" "ercotapi##description"}{...}
{viewerjumpto "Getting an ERCOT API key" "ercotapi##key"}{...}
{viewerjumpto "Storing your credentials" "ercotapi##credentials"}{...}
{viewerjumpto "Options" "ercotapi##options"}{...}
{viewerjumpto "Choosing between pull and archive" "ercotapi##choosing"}{...}
{viewerjumpto "Filtering a query" "ercotapi##filtering"}{...}
{viewerjumpto "Remarks" "ercotapi##remarks"}{...}
{viewerjumpto "Stored results" "ercotapi##results"}{...}
{viewerjumpto "Examples" "ercotapi##examples"}{...}
{viewerjumpto "Troubleshooting" "ercotapi##trouble"}{...}
{viewerjumpto "Requirements and installation" "ercotapi##install"}{...}
{viewerjumpto "Author" "ercotapi##author"}{...}
{title:Title}

{phang}
{bf:ercotapi} {hline 2} Load Texas grid data from the ERCOT Public API into Stata


{marker syntax}{...}
{title:Syntax}

{pstd}
Check the installation and your credentials

{p 8 17 2}
{cmd:ercotapi setup}
[{cmd:,} {opt template} {opt offline} {opt python(string)} {opt verbose}]

{pstd}
List the reports you can query

{p 8 17 2}
{cmd:ercotapi catalog}
[{cmd:,} {opt clear} {opt saving(filename)} {opt replace} {opt rate(#)}
{opt python(string)} {opt verbose}]

{pstd}
Show a report's tables and fields

{p 8 17 2}
{cmd:ercotapi describe} {it:emil_id}
[{cmd:,} {opt artifact(name)} {opt clear} {opt saving(filename)} {opt replace}
{opt rate(#)} {opt python(string)} {opt verbose}]

{pstd}
Query the live endpoint, for recent dates

{p 8 17 2}
{cmd:ercotapi pull} {it:emil_id}{cmd:,} {opt artifact(name)}
[{opt field(name)} {opt from(date)} {opt to(date)} {opt param(string)}
{opt pagesize(#)} {opt rate(#)} {opt clear} {opt saving(filename)}
{opt replace} {opt noimport} {opt stringcols(numlist|_all)}
{opt python(string)} {opt verbose}]

{pstd}
Download the posted files, for older dates

{p 8 17 2}
{cmd:ercotapi archive} {it:emil_id}{cmd:,}
[{opt from(date)} {opt to(date)} {opt list} {opt maxdocs(#)}
{opt rate(#)} {opt clear} {opt saving(filename)} {opt replace}
{opt noimport} {opt stringcols(numlist|_all)} {opt python(string)} {opt verbose}]

{pstd}
Report the installed version

{p 8 17 2}
{cmd:ercotapi version}

{pstd}
{it:emil_id} is a report identifier such as {cmd:np4-190-cd}. Case does not
matter. Run {cmd:ercotapi catalog} to see the identifiers your subscription
covers.


{marker description}{...}
{title:Description}

{pstd}
{cmd:ercotapi} pulls Texas electricity grid data from the
{browse "https://apiexplorer.ercot.com/":ERCOT Public API} straight into
Stata's memory. Wholesale prices, load, generation by fuel, resource outages,
and roughly a hundred other published reports become a dataset in one command.

{pstd}
The package handles three things that are awkward to do by hand. ERCOT
authenticates every request with two separate credentials, an OAuth bearer
token and a subscription key sent as an HTTP header, and Stata cannot set
custom headers. Date filters are rejected unless sent as a pair whose shape
the error message never names. Reports keep only a few weeks of history on the
endpoint you would naturally query, and a request for anything older returns an
empty table with no error at all.

{pstd}
Because Stata cannot set the headers, the network work happens in a small
Python module that ships with this package and uses the Python standard library
only. You never call Python yourself. {cmd:ercotapi} finds an interpreter, runs
the query, and reads the result into memory. Stata's own Python integration
does not have to be configured, and nothing needs installing through pip.

{pstd}
{cmd:ercotapi} is not affiliated with or endorsed by ERCOT. It reads a public
API under your own registered account, and ERCOT's terms govern the data.


{marker key}{...}
{title:Getting an ERCOT API key}

{pstd}
ERCOT gives these out free to anyone who registers. Two credentials come out of
the process and you need both: the {bf:email and password} you register with,
and a {bf:Primary key}, which is ERCOT's name for an Azure subscription key.
Budget five minutes.

{pstd}
These steps follow ERCOT's own
{browse "https://developer.ercot.com/applications/pubapi/user-guide/registration-and-authentication/":registration and authentication guide},
checked on 20 September 2026. If a button has moved, that page is the
authority.

{dlgtab:Step 1 -- create the account}

{p 8 12 2}1. Open {browse "https://apiexplorer.ercot.com/"} in a browser.{p_end}
{p 8 12 2}2. Click {bf:Sign In/Sign Up} at the top right.{p_end}
{p 8 12 2}3. Type your email address and click {bf:Send verification code}.{p_end}
{p 8 12 2}4. ERCOT emails you a code. Paste it into the {bf:Verification Code}
field and click {bf:Verify code}.{p_end}
{p 8 12 2}5. Fill in the rest of the form: a password, a display name, your
first name and your last name.{p_end}
{p 8 12 2}6. Click {bf:Create}.{p_end}

{pstd}
Write down the email address and password. {cmd:ercotapi} signs in with them on
every run, so a password manager entry is worth making now.

{dlgtab:Step 2 -- subscribe to a product and copy the key}

{p 8 12 2}1. Sign in at {browse "https://apiexplorer.ercot.com/"}.{p_end}
{p 8 12 2}2. Go to the {bf:Products} page in the top navigation.{p_end}
{p 8 12 2}3. Choose a product from the table. The public reports product covers
everything this package reaches.{p_end}
{p 8 12 2}4. Give the subscription a name. Anything works; "Public API" is
fine.{p_end}
{p 8 12 2}5. Click {bf:Subscribe}. ERCOT sends you to your {bf:Profile}
page.{p_end}
{p 8 12 2}6. Find the active subscription there and click {bf:Show}.{p_end}
{p 8 12 2}7. Copy the {bf:Primary key}.{p_end}

{pstd}
You only ever have to do this once. The key does not rotate on its own, and the
same key works for every report your subscription covers.

{pstd}
You should now have three values: a username (the email you registered with), a
password, and a 32-character API key.


{marker credentials}{...}
{title:Storing your credentials}

{pstd}
{cmd:ercotapi} never accepts a password as a command argument. Anything typed
as a Stata argument is written to the command history and appears in the review
window, and anything typed on a shell command line is written to the shell
history, so a password passed that way outlives the session that used it. Put
the three values in a file only you can read, or in environment variables.

{dlgtab:A credentials file}

{pstd}
Run this once:

{p 8 12 2}{cmd:. ercotapi setup, template}{p_end}

{pstd}
That creates {cmd:~/.ercotapi/credentials.json} with owner-only permissions and
tells you where it is. On Windows the path is
{cmd:C:\Users\<you>\.ercotapi\credentials.json}. Open it in a text editor and
fill in the three values:

{p 8 12 2}{cmd:{c -(}}{p_end}
{p 8 12 2}{cmd:  "api_key": "your 32-character Primary key",}{p_end}
{p 8 12 2}{cmd:  "username": "you@example.org",}{p_end}
{p 8 12 2}{cmd:  "password": "your ERCOT password"}{p_end}
{p 8 12 2}{cmd:{c )-}}{p_end}

{pstd}
Save it, then run {cmd:ercotapi setup} to confirm it works. If the file already
exists, {opt template} leaves it alone rather than overwriting it.

{dlgtab:Environment variables}

{pstd}
If you would rather keep secrets out of files, or you are running on a server,
set {cmd:ERCOT_API_KEY}, {cmd:ERCOT_USERNAME} and {cmd:ERCOT_PASSWORD} before
Stata starts. Set all three: the environment is used in preference to the file
only when all three are present, and if any one is missing every value comes
from the file instead.

{dlgtab:What not to do}

{pstd}
Do not put your key in a do-file, and do not commit one to a repository. If you
work on a shared drive, note that the credentials file is in your home
directory rather than the project folder, which is the point: the project can
be shared and the credentials cannot.


{marker options}{...}
{title:Options}

{dlgtab:setup}

{phang}
{opt template} creates an empty credentials file at
{cmd:~/.ercotapi/credentials.json} for you to fill in by hand, and refuses to
overwrite one that already exists.

{phang}
{opt offline} reports what is installed without signing in to ERCOT. Useful
when you want to confirm the Python side works before you have a key.

{dlgtab:catalog}

{phang}
{opt clear} replaces the data in memory. Required, as it is for any command
that loads a new dataset.

{phang}
{opt saving(filename)} also keeps the underlying CSV at {it:filename}.

{phang}
{opt replace} allows {opt saving()} to overwrite an existing file.

{dlgtab:describe}

{phang}
{opt artifact(name)} picks which of the report's tables to describe. A report
with exactly one table does not need it.

{phang}
{opt clear} loads the field list into memory as a dataset, in addition to
printing it. Without {opt clear}, {cmd:describe} only prints and leaves your
data alone.

{dlgtab:pull}

{phang}
{opt artifact(name)} names the table inside the report to query. Required.
{cmd:ercotapi describe} lists the names.

{phang}
{opt field(name)} {opt from(date)} {opt to(date)} filter on a field that
accepts a range. All three go together. {cmd:ercotapi} builds the
{it:name}{cmd:From} and {it:name}{cmd:To} pair the API requires, and refuses if
the field does not accept a range rather than sending a request it knows will
fail. Dates are strings in the format the field expects, usually
{cmd:YYYY-MM-DD}. Field names are case sensitive.

{phang}
{opt param(string)} adds plain filters as space-separated {cmd:key=value}
pairs, for example {cmd:param(settlementPoint=HB_HOUSTON repeatHourFlag=N)}.
Use it for any field {cmd:describe} marks as not accepting a range. Values
cannot contain spaces.

{phang}
{opt pagesize(#)} sets rows per request. The default is 5000, which keeps each
response a manageable size. ERCOT accepts larger pages, so raising it spends
fewer requests against the rate limit on a big pull; lowering it only makes a
pull slower.

{phang}
{opt rate(#)} caps requests per minute. The default is 25. ERCOT throttles by
account, so lower it if you share an account with a colleague or another
script.

{phang}
{opt clear} replaces the data in memory. Required unless {opt noimport} is
specified.

{phang}
{opt saving(filename)} keeps the CSV. {opt replace} allows it to overwrite.

{phang}
{opt noimport} writes the CSV and loads nothing, leaving your data untouched.
Requires {opt saving()}. Useful inside a loop that assembles many months.

{phang}
{opt stringcols(numlist|_all)} is passed straight to
{help import delimited:import delimited}, which identifies columns by position
rather than by name. Use it to stop Stata from reading an identifier with
leading zeros as a number: {cmd:stringcols(3)} keeps the third column as text,
and {cmd:stringcols(_all)} keeps every column as text.

{dlgtab:archive}

{phang}
{opt from(date)} {opt to(date)} select the window to download, by the date
ERCOT {it:published} each file. Both are required unless {opt list} is
specified.

{phang}
{opt list} lists what the archive holds instead of downloading it. With no
dates, that is the full span, which tells you how far back the report goes.

{phang}
{opt maxdocs(#)} caps how many postings a single call will handle. The default
is 400 for a download and 2000 for a listing. Each posting is a separate
request, so the ceiling exists to stop an accidental year-long window from
running for an hour.

{phang2}
The two paths hit that ceiling differently. A {it:download} above the ceiling
is refused with a message rather than returning part of the range. A
{it:listing} stops at the ceiling and says so, so a count that comes back
exactly at {opt maxdocs()} means the archive probably holds more. Raise it, or
narrow the dates, before reading that count as the whole archive.

{phang}
{opt clear}, {opt saving()}, {opt replace}, {opt noimport} and
{opt stringcols()} work as they do for {cmd:pull}.

{dlgtab:All subcommands}

{phang}
{opt python(string)} names the Python interpreter to use, for the case where
several are installed and the first one found is not the one you want. To set
it for a whole session instead, use
{cmd:global ercotapi_python "/full/path/to/python3"}.

{phang}
{opt verbose} shows the exact command line being run and the receipt that came
back. Start here when something behaves oddly.


{marker choosing}{...}
{title:Choosing between pull and archive}

{pstd}
ERCOT publishes each report in two places, and the choice between them is about
how far back you are asking.

{pstd}
{cmd:ercotapi pull} queries the live endpoint. It is fast, it returns tidy
typed columns, and it holds a limited window of recent history. Query further
back than that window and ERCOT returns an empty table with HTTP 200, which is
indistinguishable from a day on which nothing was published.

{pstd}
{cmd:ercotapi archive} downloads the original files ERCOT posted, one per
publication, typically going back seven years. It is slower, because each
posting is a separate download, and the columns arrive as text with the
capitalisation the posted file used.

{pstd}
How far back each report goes is published, and the catalog reads it for you:

{p 8 12 2}{cmd:. ercotapi catalog, clear}{p_end}
{p 8 12 2}{cmd:. list emil_id artifact live_days archive_days in 1/5, noobs}{p_end}

{pstd}
{cmd:live_days} is how far back {cmd:pull} can reach. {cmd:archive_days} is how
far back {cmd:archive} can reach, and it is usually 2,555 days, or seven years.
So a question about last week goes to {cmd:pull}, and a question about 2022
goes to {cmd:archive}.

{pstd}
One detail about the archive catches people out. It filters on the date ERCOT
{it:published} a file, not the date of the data inside it. A day-ahead price
report published on 1 March carries delivery date 2 March. Ask for a window a
day or two wider than you need, then filter on the data's own date column once
it is in Stata.

{pstd}
Rows loaded by {cmd:archive} carry two extra columns, {cmd:source_doc_id} and
{cmd:source_post_datetime}, recording which posting each row came from. A table
assembled from hundreds of files would otherwise be impossible to audit.


{marker filtering}{...}
{title:Filtering a query}

{pstd}
ERCOT splits query fields into two kinds and treats them differently. Sending a
field the wrong way produces HTTP 400 and an error message that names the field
without explaining what is wrong with it.

{pstd}
Run {cmd:ercotapi describe} first. The last column answers the question:

{p 8 12 2}{cmd:. ercotapi describe np4-190-cd}{p_end}

{p 8 12 2}{cmd:fields on dam_stlmnt_pnt_prices:}{p_end}
{p 8 12 2}{cmd:    name                        type       range?}{p_end}
{p 8 12 2}{cmd:    deliveryDate                DATE       YES - use From/To}{p_end}
{p 8 12 2}{cmd:    hourEnding                  VARCHAR    no}{p_end}
{p 8 12 2}{cmd:    settlementPoint             VARCHAR    no}{p_end}
{p 8 12 2}{cmd:    settlementPointPrice        DOUBLE     YES - use From/To}{p_end}
{p 8 12 2}{cmd:    DSTFlag                     BOOLEAN    no}{p_end}

{pstd}
A field marked {cmd:YES} will be rejected if you send it a single value, even
though the field exists and is queryable. It goes through {opt field()}
{opt from()} {opt to()}, which builds the pair for you. A field marked
{cmd:no} goes through {opt param()} as a plain {cmd:key=value}.

{pstd}
Field names are case sensitive, so {cmd:deliverydate} fails where
{cmd:deliveryDate} works. {cmd:ercotapi} catches that one before spending a
request and lists the field names it did find.


{marker remarks}{...}
{title:Remarks}

{dlgtab:Pagination is verified, not assumed}

{pstd}
Every ERCOT response carries a count of how many rows the query matched in
total. {cmd:ercotapi} walks every page and compares what it received against
that count, and raises rather than returning a short table that looks complete.
A truncated-but-plausible dataset is the most dangerous failure this API has,
so the client refuses to produce one.

{dlgtab:Rate limiting, and how long an archive pull takes}

{pstd}
ERCOT documents 30 requests a minute per account, and throttles by account, so
two scripts running at once share one budget. {cmd:ercotapi} holds itself to 25
a minute and coordinates through a lock file, so the ceiling holds across
separate Stata sessions on macOS and Linux. It also spaces requests evenly
rather than letting them go out in a burst, because a burst well under 25 a
minute still earns an HTTP 429. If one arrives anyway, the client waits and
retries rather than failing.

{pstd}
Windows has no file locking of that kind, so there the limit applies within one
process and the command says so once. Running two pulls at the same time on
Windows may trip ERCOT's limit.

{pstd}
The practical consequence shows up in {cmd:ercotapi archive}, where each
posting is a separate download. At 25 a minute the calls are 2.4 seconds apart,
so a month of daily postings takes about 75 seconds and the 400-posting default
ceiling takes roughly 16 minutes. Plan a year-long backfill accordingly, and
consider running it once with {opt saving()} rather than repeating it. Raise
{opt rate()} if you know your own account's limit differs.

{dlgtab:Provenance}

{pstd}
Every successful {cmd:pull} and {cmd:archive} writes a dataset note and a set of
characteristics recording the report, the table, the filter, and the date it was
retrieved. Save the {cmd:.dta} and the record travels with it, so a file found
on a shared drive a year later can still say what it is. See {help notes} and
{help char}.

{dlgtab:Variable names}

{pstd}
Column names are ERCOT's own, kept as sent, so they match what
{cmd:ercotapi describe} showed you. That means mixed case, which Stata allows.
Rows from {cmd:archive} use the capitalisation of the posted file, which is not
always the capitalisation the live endpoint uses for the same field.

{dlgtab:Using the Python module on its own}

{pstd}
{cmd:_ercotapi_client.py} has no dependencies and works outside Stata, in a
notebook or a scheduled job. It reads the same credentials. See the README for
an example.


{marker results}{...}
{title:Stored results}

{pstd}
{cmd:ercotapi catalog}, {cmd:ercotapi pull} and {cmd:ercotapi archive} store in
{cmd:r()}:

{synoptset 20 tabbed}{...}
{p2col 5 20 24 2: Scalars}{p_end}
{synopt:{cmd:r(N)}}number of rows loaded, or 0 if the query returned none{p_end}
{p2colreset}{...}

{pstd}
{cmd:ercotapi version} stores {cmd:r(version)}. {cmd:ercotapi setup} stores
{cmd:r(status)}, which is {cmd:ok}, {cmd:template}, {cmd:offline} or
{cmd:failed}.


{marker examples}{...}
{title:Examples}

{pstd}Confirm everything is installed and your key works{p_end}
{phang2}{cmd:. ercotapi setup}{p_end}

{pstd}See what your subscription covers, and how far back each report goes{p_end}
{phang2}{cmd:. ercotapi catalog, clear}{p_end}
{phang2}{cmd:. list emil_id artifact live_days archive_days if strpos(lower(name), "price")}{p_end}

{pstd}Find out what a report contains before querying it{p_end}
{phang2}{cmd:. ercotapi describe np4-190-cd}{p_end}

{pstd}A week of day-ahead prices at the Houston hub{p_end}
{phang2}{cmd:. ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///}{p_end}
{phang2}{cmd:      field(deliveryDate) from(2026-09-13) to(2026-09-19) ///}{p_end}
{phang2}{cmd:      param(settlementPoint=HB_HOUSTON) clear}{p_end}

{pstd}The same series for 2022, which the live endpoint no longer holds{p_end}
{phang2}{cmd:. ercotapi archive np4-190-cd, from(2022-06-30) to(2022-07-08) clear}{p_end}
{phang2}{cmd:. keep if SettlementPoint == "HB_HOUSTON"}{p_end}
{phang2}{cmd:. generate date  = date(DeliveryDate, "MDY")}{p_end}
{phang2}{cmd:. generate price = real(SettlementPointPrice)}{p_end}

{pstd}Check the size of an archive window before committing to the download{p_end}
{phang2}{cmd:. ercotapi archive np4-190-cd, list from(2022-01-01) to(2022-12-31) clear}{p_end}
{phang2}{cmd:. count}{p_end}

{pstd}Write a CSV without touching the data in memory{p_end}
{phang2}{cmd:. ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///}{p_end}
{phang2}{cmd:      field(deliveryDate) from(2026-09-01) to(2026-09-07) ///}{p_end}
{phang2}{cmd:      saving("dam_prices.csv") replace noimport}{p_end}

{pstd}See where a saved dataset came from{p_end}
{phang2}{cmd:. notes}{p_end}
{phang2}{cmd:. char list _dta[]}{p_end}

{pstd}Slow the request rate when sharing an account{p_end}
{phang2}{cmd:. ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) rate(10) clear}{p_end}


{marker trouble}{...}
{title:Troubleshooting}

{phang}
{bf:no working Python 3 interpreter was found}{break}
Python is missing, or installed where Stata's shell does not look. Install
Python 3.8 or newer, or set
{cmd:global ercotapi_python "/full/path/to/python3"}.

{phang}
{bf:the Python engine files could not be found or downloaded}{break}
The engine did not arrive with the install, or only half of it did. Reinstall
with the {cmd:net install} line under
{help ercotapi##install:Requirements and installation} below, or clone the
repository and add it with {helpb adopath}.

{phang}
{bf:No ERCOT credentials found}{break}
Neither the environment variables nor the credentials file is set. Run
{cmd:ercotapi setup, template} and fill in the file it creates.

{phang}
{bf:ERCOT rejected the sign-in (HTTP 400)}{break}
Wrong username or password. This is about the account, not the key. Sign in at
apiexplorer.ercot.com by hand to confirm the password, then update the file.

{phang}
{bf:ERCOT returned 401 twice}{break}
The subscription key is wrong, or the subscription does not cover this product.
Check the Primary key on your Profile page and that the subscription is active.

{phang}
{bf:ERCOT rejected the query (HTTP 400)}{break}
Almost always a range field sent as a single value. Run
{cmd:ercotapi describe} and move that field to {opt field()} {opt from()}
{opt to()}.

{phang}
{bf:the query succeeded and returned no rows}{break}
Often a date older than the live endpoint holds. Check {cmd:live_days} in the
catalog, then ask {cmd:ercotapi archive} for the same range.

{phang}
{bf:Pagination mismatch}{break}
The API reported more rows than it delivered. Rerun; if it persists, narrow the
date range and report it as an issue.

{phang}
{bf:That range covers N+ postings}{break}
The archive window is wider than the safety ceiling. Narrow it, or raise
{opt maxdocs()} deliberately.

{phang}
{bf:no; data in memory would be lost}{break}
Add {opt clear}, or save what you have first.

{phang}
Add {opt verbose} to any command to see the exact command line being run and
the receipt that came back.


{marker install}{...}
{title:Requirements and installation}

{pstd}
Stata 16.0 or newer, and Python 3.8 or newer installed on the machine. Stata's
own Python integration does not have to be configured, and no pip packages are
needed.

{pstd}
From GitHub:

{p 8 12 2}{cmd:. net install ercotapi, from("https://raw.githubusercontent.com/ericabooth/ercotapi-stata-public/main/") replace force}{p_end}
{p 8 12 2}{cmd:. help ercotapi}{p_end}

{pstd}
That one command copies everything the package needs, the command and its
helper ado files, the help file, and the Python engine, straight to your
adopath. Stata files the {cmd:.py} files under {cmd:PLUS/py/} and
{helpb findfile} looks there, so there is no manual {helpb adopath} step and
nothing to install through pip. Run the same line again whenever you want to
update.

{pstd}
Then confirm it is wired up:

{p 8 12 2}{cmd:. ercotapi setup}{p_end}

{pstd}
Working from a clone instead:

{p 8 12 2}{cmd:. adopath ++ "/full/path/to/ercotapi-stata-public"}{p_end}

{pstd}
If a machine cannot reach GitHub at all, mirror the repository and set
{cmd:global ercotapi_remote_base "https://your.mirror/ercotapi/"} before the
first call.


{marker author}{...}
{title:Author}

{pstd}
Eric A. Booth, Sr Researcher, Texas 2036 (eric.a.booth@gmail.com){break}
{browse "https://github.com/ericabooth/ercotapi-stata-public"}

{pstd}
MIT-licensed. Issues and pull requests are welcome. If you hit an ERCOT
behaviour this package does not handle, an issue with the report id, the
options you passed, and the message you got is enough to work from.

{pstd}
If this package supports published work, please cite it as: Booth, E. A.
(2026). {it:ercotapi: ERCOT Public API data in Stata} (version 1.0.0) [Stata
package]. {browse "https://github.com/ericabooth/ercotapi-stata-public"}


{title:Also see}

{psee}
Manual: {manlink D import delimited}

{psee}
Online: {helpb import delimited}, {helpb notes}, {helpb char}, {helpb adopath},
{helpb net}
