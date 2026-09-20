*! ercotapi v1.0.0  2026-09-20
*! Pull Texas grid data from the ERCOT Public API straight into Stata.
*!
*! Eric A. Booth, Texas 2036.  MIT licensed.  See ercotapi.sthlp for the help
*! file and README.md for how to register with ERCOT and get a key.
*!
*! SUBCOMMANDS
*!     ercotapi setup                  check the install and the credentials
*!     ercotapi catalog                list the reports you can query
*!     ercotapi describe <emil>        show a report's tables and fields
*!     ercotapi pull <emil>, ...       query the live endpoint (recent dates)
*!     ercotapi archive <emil>, ...    download the posted files (older dates)
*!     ercotapi version                report the installed version
*!
*! HOW IT WORKS
*!     ERCOT requires two credentials on every request: an OAuth bearer token
*!     and an Azure subscription key sent as a header.  Stata cannot set custom
*!     HTTP headers, so the network work happens in a small Python module that
*!     ships with this package and uses the standard library only.  You never
*!     call Python yourself.  This command finds an interpreter, runs the
*!     query, and reads the resulting CSV into memory.
*!
*! CREDENTIALS
*!     Never stored in this package, never typed as a Stata argument, and never
*!     shown in full.  Run -ercotapi setup, template- once and paste your three
*!     values into the file it creates.

program define ercotapi
    version 16.0

    gettoken sub rest : 0, parse(" ,")
    local sub = trim(`"`sub'"')

    if `"`sub'"' == "" {
        display as error "ercotapi requires a subcommand."
        ercotapi_usage
        exit 198
    }

    local known "setup catalog describe pull archive version"
    local hit ""
    foreach s of local known {
        if "`sub'" == "`s'" local hit "`s'"
    }
    if "`hit'" == "" {
        display as error `"ercotapi: "`sub'" is not a subcommand."'
        ercotapi_usage
        exit 198
    }

    ercotapi_`hit' `rest'
end


program define ercotapi_usage
    display as text "  Subcommands:"
    display as text "      ercotapi setup                  check the install and your credentials"
    display as text "      ercotapi catalog                list the reports you can query"
    display as text "      ercotapi describe <emil-id>     show a report's tables and fields"
    display as text "      ercotapi pull <emil-id>, ...    query the live endpoint (recent dates)"
    display as text "      ercotapi archive <emil-id>, ... download the posted files (older dates)"
    display as text "      ercotapi version                report the installed version"
    display as text "  See {help ercotapi} for details and worked examples."
end


program define ercotapi_version, rclass
    version 16.0
    syntax [, *]
    display as text "ercotapi version 1.0.0 (2026-09-20)"
    capture ercotapi_findfile, quietly
    if !_rc display as text "  Python engine: " as result "`r(dir)'"
    capture ercotapi_python
    if !_rc display as text "  Python:        " as result `"`r(python)'"' as text "  (`r(pyver)')"
    return local version "1.0.0"
end


* ---------------------------------------------------------------------------
* setup: a diagnostic, not a place to type secrets
* ---------------------------------------------------------------------------
program define ercotapi_setup, rclass
    version 16.0
    syntax [, TEMPLATE OFFLINE PYTHON(string) VERBOSE]

    display as text ""
    display as text "{hline 72}"
    display as text "ercotapi setup"
    display as text "{hline 72}"

    * ---- 1. the Python interpreter ----------------------------------------
    ercotapi_python, python(`"`python'"')
    local py `"`r(python)'"'
    display as text "Python interpreter   : " as result `"`py'"' as text " (version `r(pyver)')"

    * ---- 2. the engine files ----------------------------------------------
    ercotapi_findfile
    local cli `"`r(clipath)'"'
    display as text "Engine files         : " as result `"`r(dir)'"'

    * ---- 3. the credentials -----------------------------------------------
    tempfile log
    if "`template'" != "" {
        ercotapi_shell, args(`""`cli'" template"') log("`log'") python(`"`py'"') `verbose'
        display as text ""
        type "`log'"
        display as text ""
        display as text "Fill in that file, then run {stata ercotapi setup} again."
        return local status "template"
        exit 0
    }

    if "`offline'" != "" {
        display as text "Credentials          : not checked (offline specified)"
        display as text "{hline 72}"
        return local status "offline"
        exit 0
    }

    ercotapi_shell, args(`""`cli'" check"') log("`log'") python(`"`py'"') `verbose'
    local ok = `r(ok)'
    display as text ""
    type "`log'"
    display as text ""
    if `ok' {
        display as text "{hline 72}"
        display as text "ercotapi is ready. Try: " _c
        display as result "{stata ercotapi catalog, clear}"
        display as text "{hline 72}"
        return local status "ok"
    }
    else {
        display as error "{hline 72}"
        display as error "ercotapi is not ready yet. The report above says why."
        display as error "If no credentials are configured, run: " _c
        display as error "ercotapi setup, template"
        display as error "README.md walks through registering with ERCOT step by step."
        display as error "{hline 72}"
        return local status "failed"
        exit 601
    }
end


* ---------------------------------------------------------------------------
* catalog: which reports can this subscription see
* ---------------------------------------------------------------------------
program define ercotapi_catalog, rclass
    version 16.0
    syntax [, CLEAR SAVING(string) REPLACE RATE(integer 25) PYTHON(string) VERBOSE]

    ercotapi_protect_data, clear("`clear'")
    ercotapi_findfile
    local cli `"`r(clipath)'"'

    tempfile log tmpcsv
    local csv `"`tmpcsv'"'
    if `"`saving'"' != "" {
        local csv `"`saving'"'
        ercotapi_checksaving, file(`"`csv'"') replace("`replace'")
    }

    ercotapi_shell, args(`""`cli'" --rate `rate' catalog --out "`csv'""') ///
        log("`log'") python(`"`python'"') `verbose'
    ercotapi_receipt, ok(`r(ok)') receipt(`"`r(receipt)'"') log("`log'")
    local n = `r(nrows)'

    if `n' == 0 {
        display as text "ercotapi catalog: the API returned no products for this subscription."
        display as text "  Check on the Profile page at apiexplorer.ercot.com that your"
        display as text "  subscription is active and covers the products you expect."
        clear
        return scalar N = 0
        exit 0
    }

    quietly import delimited using `"`csv'"', varnames(1) case(preserve) clear
    capture label variable emil_id      "Report id, as ERCOT numbers it"
    capture label variable name         "Report name"
    capture label variable artifact     "Table inside the report; pass to pull, artifact()"
    capture label variable frequency    "How often ERCOT publishes it"
    capture label variable live_days    "Days of history the live endpoint keeps"
    capture label variable archive_days "Days of history the archive keeps"
    capture label variable has_archive  "1 if the report has a downloadable archive"
    capture label variable first_run    "First date this report was ever published"
    capture label variable last_post    "Most recent posting"
    capture label variable n_tables     "Number of queryable tables in the report"

    display as text "ercotapi catalog: loaded " as result "`=_N'" as text " report tables."
    display as text ""
    display as text "  Two columns decide which command can answer a question:"
    display as text "    live_days     how far back {bf:ercotapi pull} can reach. A query older than"
    display as text "                  this returns an empty table and no error at all."
    display as text "    archive_days  how far back {bf:ercotapi archive} can reach, usually years."
    display as text ""
    display as text "  To find a report by subject, search the name column, for example:"
    display as text `"      {stata list emil_id artifact live_days archive_days if strpos(lower(name), "price")}"'
    if `"`saving'"' != "" display as text `"  CSV kept at: `csv'"'
    return scalar N = _N
end


* ---------------------------------------------------------------------------
* archive: the original posted files, which reach back years
* ---------------------------------------------------------------------------
program define ercotapi_archive, rclass
    version 16.0
    gettoken emil 0 : 0, parse(" ,")
    local emil = trim(`"`emil'"')
    if `"`emil'"' == "" | substr(`"`emil'"', 1, 1) == "," {
        display as error "ercotapi archive requires a report id, for example:"
        display as error `"    ercotapi archive np4-190-cd, from(2024-03-01) to(2024-03-07) clear"'
        exit 198
    }
    syntax , [ FROM(string) TO(string) LIST MAXDOCS(integer 0) CLEAR      ///
               SAVING(string) REPLACE NOIMPORT STRINGCOLS(string)         ///
               RATE(integer 25) PYTHON(string) VERBOSE ]

    if "`noimport'" == "" ercotapi_protect_data, clear("`clear'")
    if "`noimport'" != "" & `"`saving'"' == "" {
        display as error "ercotapi archive: noimport writes a CSV and loads nothing, so it needs saving()."
        exit 198
    }
    if "`list'" == "" & (`"`from'"' == "" | `"`to'"' == "") {
        display as error "ercotapi archive: downloading needs both from() and to()."
        display as error "  To see what the archive holds first, add the list option:"
        display as error `"      ercotapi archive `emil', list clear"'
        exit 198
    }
    if `"`from'"' != "" & `"`to'"' == "" | `"`from'"' == "" & `"`to'"' != "" {
        display as error "ercotapi archive: from() and to() go together; ERCOT ignores one without the other."
        exit 198
    }

    ercotapi_findfile
    local cli `"`r(clipath)'"'

    tempfile log tmpcsv
    local csv `"`tmpcsv'"'
    if `"`saving'"' != "" {
        local csv `"`saving'"'
        ercotapi_checksaving, file(`"`csv'"') replace("`replace'")
    }

    if "`list'" != "" {
        local md = cond(`maxdocs' > 0, `maxdocs', 2000)
        local a `""`cli'" --rate `rate' archive-list --emil "`emil'" --out "`csv'" --max-docs `md'"'
        if `"`from'"' != "" local a `"`a' --from "`from'" --to "`to'""'
    }
    else {
        local md = cond(`maxdocs' > 0, `maxdocs', 400)
        local a `""`cli'" --rate `rate' archive-pull --emil "`emil'" --out "`csv'""'
        local a `"`a' --from "`from'" --to "`to'" --max-docs `md'"'
        display as text "ercotapi: downloading the `emil' archive from `from' to `to' ..."
        display as text "  Each posting is a separate download, so a wide window takes a while."
    }

    ercotapi_shell, args(`"`a'"') log("`log'") python(`"`python'"') `verbose'
    ercotapi_receipt, ok(`r(ok)') receipt(`"`r(receipt)'"') log("`log'")
    local n = `r(nrows)'

    if `n' == 0 {
        display as text ""
        display as text "ercotapi archive: nothing came back for that window."
        display as text "  The archive filters on the date ERCOT {it:published} the file, not the"
        display as text "  date of the data inside it. A day-ahead report published on 1 March"
        display as text "  carries delivery date 2 March, so ask for a slightly wider window and"
        display as text "  then filter on the data's own date column."
        display as text `"  To see the full span first: {stata "ercotapi archive `emil', list clear"}"'
        if "`noimport'" == "" clear
        return scalar N = 0
        exit 0
    }

    if "`noimport'" != "" {
        display as text "ercotapi archive: wrote " as result "`n'" as text " rows to `csv' (nothing loaded)."
        return scalar N = `n'
        exit 0
    }

    local imp `"varnames(1) case(preserve) clear"'
    if `"`stringcols'"' != "" local imp `"`imp' stringcols(`stringcols')"'
    quietly import delimited using `"`csv'"', `imp'

    char _dta[ercotapi_emil]   "`emil'"
    char _dta[ercotapi_source] "archive"
    char _dta[ercotapi_from]   `"`from'"'
    char _dta[ercotapi_to]     `"`to'"'
    char _dta[ercotapi_pulled] "`c(current_date)' `c(current_time)'"

    if "`list'" != "" {
        capture label variable doc_id        "Archive document id"
        capture label variable friendly_name "ERCOT's name for the posted file"
        capture label variable post_datetime "When ERCOT published it"
        notes _dta: ERCOT archive listing for `emil'; retrieved `c(current_date)' by ercotapi 1.0.0
        display as text "ercotapi archive: listed " as result "`=_N'" as text " postings."
        display as text "  post_datetime is when ERCOT published each file. Sort on it to see how"
        display as text "  far back the archive goes, then download a window with from() and to()."
    }
    else {
        capture label variable source_doc_id        "Archive document this row came from"
        capture label variable source_post_datetime "When ERCOT published that document"
        notes _dta: ERCOT archive for `emil', posted `from' to `to'; retrieved `c(current_date)' by ercotapi 1.0.0
        display as text "ercotapi archive: loaded " as result "`=_N'" as text " rows, " ///
            as result "`=c(k)'" as text " variables."
        display as text "  Column names are ERCOT's own, kept as the posted file had them."
        display as text "  source_doc_id and source_post_datetime record which posting each row"
        display as text "  came from, so a combined table can still be audited."
    }
    if `"`saving'"' != "" display as text `"  CSV kept at: `csv'"'
    return scalar N = _N
end


* ---------------------------------------------------------------------------
* describe: what a report contains, and how it can be filtered
* ---------------------------------------------------------------------------
program define ercotapi_describe, rclass
    version 16.0
    gettoken emil 0 : 0, parse(" ,")
    local emil = trim(`"`emil'"')
    if `"`emil'"' == "" | substr(`"`emil'"', 1, 1) == "," {
        display as error "ercotapi describe requires a report id, for example:"
        display as error `"    ercotapi describe np4-190-cd"'
        display as error "Run {stata ercotapi catalog, clear} to see the ids available to you."
        exit 198
    }
    syntax [, ARTIFACT(string) CLEAR SAVING(string) REPLACE RATE(integer 25) ///
              PYTHON(string) VERBOSE]

    if "`clear'" != "" ercotapi_protect_data, clear("`clear'")
    ercotapi_findfile
    local cli `"`r(clipath)'"'

    tempfile log tmpcsv
    local csv `"`tmpcsv'"'
    if `"`saving'"' != "" {
        local csv `"`saving'"'
        ercotapi_checksaving, file(`"`csv'"') replace("`replace'")
    }

    local a `""`cli'" --rate `rate' describe --emil "`emil'" --out "`csv'""'
    if `"`artifact'"' != "" local a `"`a' --artifact "`artifact'""'
    ercotapi_shell, args(`"`a'"') log("`log'") python(`"`python'"') `verbose'
    local ok = `r(ok)'

    display as text ""
    type "`log'"
    display as text ""
    if !`ok' {
        display as error "ercotapi describe failed. The message above is ERCOT's own."
        exit 601
    }
    display as text "Reading the table above:"
    display as text "  * Each {it:artifact} is one queryable table inside the report. Pass the"
    display as text "    slug to -pull- with the artifact() option."
    display as text `"  * A field marked "YES - use From/To" will be rejected if you send it a"'
    display as text "    single value. Filter it with the field() from() to() options, which"
    display as text "    build the From/To pair for you."

    if "`clear'" != "" {
        capture confirm file `"`csv'"'
        if !_rc {
            quietly import delimited using `"`csv'"', varnames(1) case(preserve) clear
            display as text "  Field list loaded into memory (`=_N' fields)."
        }
    }
    if `"`saving'"' != "" display as text `"  Field list written to: `csv'"'
end


* ---------------------------------------------------------------------------
* pull: run the query and load the rows
* ---------------------------------------------------------------------------
program define ercotapi_pull, rclass
    version 16.0
    gettoken emil 0 : 0, parse(" ,")
    local emil = trim(`"`emil'"')
    if `"`emil'"' == "" | substr(`"`emil'"', 1, 1) == "," {
        display as error "ercotapi pull requires a report id, for example:"
        display as error `"    ercotapi pull np4-190-cd, artifact(dam_hourly_lmp) clear"'
        exit 198
    }
    syntax , ARTIFACT(string) [ FIELD(string) FROM(string) TO(string)      ///
             PARAM(string) PAGESIZE(integer 5000) RATE(integer 25)         ///
             CLEAR SAVING(string) REPLACE NOIMPORT STRINGCOLS(string)      ///
             PYTHON(string) VERBOSE ]

    if "`noimport'" == "" ercotapi_protect_data, clear("`clear'")
    if "`noimport'" != "" & `"`saving'"' == "" {
        display as error "ercotapi pull: noimport writes a CSV and loads nothing, so it needs saving()."
        exit 198
    }
    if `"`field'"' != "" & (`"`from'"' == "" | `"`to'"' == "") {
        display as error "ercotapi pull: field() filters a date range, so it needs both from() and to()."
        display as error `"    ... , field(deliveryDate) from(2026-09-01) to(2026-09-07)"'
        exit 198
    }
    if `"`field'"' == "" & (`"`from'"' != "" | `"`to'"' != "") {
        display as error "ercotapi pull: from() and to() need field() to say which field they filter."
        display as error "Run {stata ercotapi describe `emil'} to see which fields accept a range."
        exit 198
    }

    ercotapi_findfile
    local cli `"`r(clipath)'"'

    tempfile log tmpcsv
    local csv `"`tmpcsv'"'
    if `"`saving'"' != "" {
        local csv `"`saving'"'
        ercotapi_checksaving, file(`"`csv'"') replace("`replace'")
    }

    local a `""`cli'" --rate `rate' pull --emil "`emil'" --artifact "`artifact'""'
    local a `"`a' --out "`csv'" --page-size `pagesize'"'
    if `"`field'"' != "" {
        local a `"`a' --field "`field'" --from "`from'" --to "`to'""'
    }
    foreach p of local param {
        local a `"`a' --param "`p'""'
    }

    display as text "ercotapi: querying `emil' / `artifact' ..."
    ercotapi_shell, args(`"`a'"') log("`log'") python(`"`python'"') `verbose'
    ercotapi_receipt, ok(`r(ok)') receipt(`"`r(receipt)'"') log("`log'")
    local n = `r(nrows)'

    if `n' == 0 {
        display as text ""
        display as text "ercotapi pull: the query succeeded and returned no rows."
        display as text "  An empty answer is not proof that nothing happened. Several ERCOT"
        display as text "  live endpoints hold only a recent window and answer HTTP 200 with an"
        display as text "  empty table for older dates, which looks exactly like a quiet day."
        display as text "  Worth checking, in order:"
        display as text "    1. the date range, against what the report actually retains;"
        display as text "    2. whether a separate historical archive product covers those dates"
        display as text "       ({stata ercotapi catalog, clear} lists what you can see);"
        display as text "    3. the spelling of any param() filter values."
        if "`noimport'" == "" clear
        return scalar N = 0
        exit 0
    }

    if "`noimport'" != "" {
        display as text "ercotapi pull: wrote " as result "`n'" as text " rows to `csv' (nothing loaded)."
        return scalar N = `n'
        exit 0
    }

    local imp `"varnames(1) case(preserve) clear"'
    if `"`stringcols'"' != "" local imp `"`imp' stringcols(`stringcols')"'
    quietly import delimited using `"`csv'"', `imp'

    * Record where these data came from, so a saved .dta can be traced back.
    char _dta[ercotapi_emil]     "`emil'"
    char _dta[ercotapi_artifact] "`artifact'"
    char _dta[ercotapi_field]    `"`field'"'
    char _dta[ercotapi_from]     `"`from'"'
    char _dta[ercotapi_to]       `"`to'"'
    char _dta[ercotapi_param]    `"`param'"'
    char _dta[ercotapi_pulled]   "`c(current_date)' `c(current_time)'"
    local prov "ERCOT Public API, report `emil', table `artifact'"
    if `"`field'"' != "" local prov `"`prov', `field' from `from' to `to'"'
    notes _dta: `prov'; retrieved `c(current_date)' by ercotapi 1.0.0

    display as text "ercotapi pull: loaded " as result "`=_N'" as text " rows, " ///
        as result "`=c(k)'" as text " variables."
    display as text "  Variable names are ERCOT's own field names, kept as sent."
    if `"`saving'"' != "" display as text `"  CSV kept at: `csv'"'
    return scalar N = _N
end


* ---------------------------------------------------------------------------
* shared checks
* ---------------------------------------------------------------------------
program define ercotapi_protect_data
    version 16.0
    syntax , [CLEAR(string)]
    if "`clear'" == "" & (_N > 0 | c(k) > 0) {
        display as error "no; data in memory would be lost"
        display as error "  ercotapi replaces the data in memory. Add the clear option, or"
        display as error "  save what you have first."
        exit 4
    }
end

program define ercotapi_checksaving
    version 16.0
    syntax , FILE(string) [REPLACE(string)]
    capture confirm file `"`file'"'
    if !_rc & "`replace'" == "" {
        display as error `"file `file' already exists"'
        display as error "  Add the replace option to overwrite it."
        exit 602
    }
end

program define ercotapi_receipt, rclass
    version 16.0
    syntax , OK(integer) [RECEIPT(string) LOG(string)]
    if !`ok' {
        display as error ""
        if `"`log'"' != "" {
            capture noisily type "`log'"
        }
        display as error ""
        display as error "ercotapi: the request failed."
        if `"`receipt'"' != "" display as error `"  `receipt'"'
        exit 601
    }
    * Receipts from the engine read "wrote <n> rows to <path>" or
    * "wrote <n> products to <path>"; pull the count back out.
    local n 0
    if regexm(`"`receipt'"', "wrote ([0-9]+) ") local n = real(regexs(1))
    return scalar nrows = `n'
    return local receipt `"`receipt'"'
end
