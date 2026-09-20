*! test_ercotapi.do -- self-checking test script for the ercotapi package
*!
*! WHAT THIS DOES
*!     Runs every ercotapi subcommand and checks the result, counting passes
*!     and failures as it goes and printing a summary at the end. A failing
*!     run ends with error 9, so a batch job notices.
*!
*! HOW TO RUN IT
*!     From the package folder, in Stata:
*!         do tests/test_ercotapi.do
*!     Or from a shell:
*!         stata-mp -b do tests/test_ercotapi.do
*!     Then read the log and search it for FAIL.
*!
*! WHAT IT NEEDS
*!     The offline sections need nothing but Stata and Python.
*!     The live section needs working ERCOT credentials; without them it is
*!     skipped and says so, rather than failing.
*!
*! WHY IT CHECKS VALUES RATHER THAN READING THE SCREEN
*!     A command that prints a reassuring message and loads nothing looks
*!     fine in a log. Every check below tests a value: a return code, a row
*!     count, a variable name, a stored characteristic.

version 16.0
clear all
set more off

* ---------------------------------------------------------------------------
* Point Stata at the package. This script sits in tests/, so the package is
* one level up. Set the global yourself to test a copy somewhere else.
* ---------------------------------------------------------------------------
if "$ERCOTAPI_DIR" == "" {
    local here = subinstr("`c(pwd)'", "\", "/", .)
    if substr("`here'", -6, 6) == "/tests" {
        global ERCOTAPI_DIR = substr("`here'", 1, length("`here'") - 6)
    }
    else global ERCOTAPI_DIR "`here'"
}
adopath ++ "$ERCOTAPI_DIR"
display as text "Testing the package in: $ERCOTAPI_DIR"

global TPASS 0
global TFAIL 0
global TSKIP 0

* tcheck takes an already-evaluated 0/1 and a message. Call sites pass the
* condition through `=(...)' so that it arrives as a single token; a bare
* (_rc == 198) would be split on its spaces and silently mis-parsed.
capture program drop tcheck
program define tcheck
    version 16.0
    args pass msg
    if `pass' {
        global TPASS = $TPASS + 1
        display as text "  pass  " as result `"`msg'"'
    }
    else {
        global TFAIL = $TFAIL + 1
        display as error "  FAIL  `msg'"
    }
end

capture program drop tskip
program define tskip
    version 16.0
    args msg
    global TSKIP = $TSKIP + 1
    display as text "  skip  " as result `"`msg'"'
end

capture program drop tsection
program define tsection
    version 16.0
    args msg
    display as text ""
    display as text "{hline 70}"
    display as text `"`msg'"'
    display as text "{hline 70}"
end


* ===========================================================================
tsection "1. The package loads and reports what it found"
* ===========================================================================

capture noisily ercotapi version
tcheck `=(_rc == 0)' "ercotapi version runs"

capture ercotapi_findfile
tcheck `=(_rc == 0)' "the Python engine files are findable"

capture ercotapi_python
local pyrc = _rc
local pyver "`r(pyver)'"
tcheck `=(`pyrc' == 0)' "a working Python 3 interpreter is available"
local dot = strpos("`pyver'", ".")
local pymajor = cond(`dot' > 1, real(substr("`pyver'", 1, `dot' - 1)), 0)
tcheck `=(`pymajor' >= 3)' "the interpreter reports Python 3 or newer (`pyver')"


* ===========================================================================
tsection "2. Bad input is refused before a request is spent"
* ===========================================================================

capture noisily ercotapi
tcheck `=(_rc == 198)' "a bare ercotapi asks for a subcommand"

capture noisily ercotapi wibble
tcheck `=(_rc == 198)' "an unknown subcommand is refused"

capture noisily ercotapi describe
tcheck `=(_rc == 198)' "describe without a report id is refused"

capture noisily ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///
    from(2026-09-01) to(2026-09-07) clear
tcheck `=(_rc == 198)' "pull refuses from and to with no field to filter on"

capture noisily ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///
    field(deliveryDate) from(2026-09-01) clear
tcheck `=(_rc == 198)' "pull refuses field with only one end of the range"

capture noisily ercotapi archive np4-190-cd, clear
tcheck `=(_rc == 198)' "archive refuses a download with no date window"

capture noisily ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) noimport
tcheck `=(_rc == 198)' "noimport without saving is refused"

* A command that would replace the data has to say so first.
quietly set obs 10
quietly generate keeper = _n
capture noisily ercotapi catalog
tcheck `=(_rc == 4)' "catalog refuses to discard unsaved data without clear"
clear


* ===========================================================================
tsection "3. Talking to ERCOT (skipped without credentials)"
* ===========================================================================

capture noisily ercotapi setup
local setuprc = _rc
local live = (`setuprc' == 0)
tcheck `=(`setuprc' == 0 | `setuprc' == 601)' "setup finishes with a clear verdict"

if !`live' {
    display as text ""
    display as text "  No working ERCOT credentials here, so the live checks are skipped."
    display as text "  To run them, set up a key first:  ercotapi setup, template"
    display as text "  The help file explains how to register with ERCOT."
    display as text ""
    foreach s in "catalog" "describe" "pull" "pull with an empty result" ///
                 "archive listing" "archive download" "saving and noimport" {
        tskip "`s'"
    }
}
else {

    * ---- catalog ----------------------------------------------------------
    capture noisily ercotapi catalog, clear
    tcheck `=(_rc == 0)' "catalog runs"
    tcheck `=(_N > 0)' "catalog loads at least one row (`=_N')"
    capture confirm variable emil_id artifact live_days archive_days
    tcheck `=(_rc == 0)' "catalog carries emil_id, artifact, live_days, archive_days"
    quietly count if live_days < archive_days & !missing(live_days, archive_days)
    tcheck `=(r(N) > 0)' "some report keeps less history live than in its archive"
    quietly count if emil_id == "NP4-190-CD"
    tcheck `=(r(N) > 0)' "the day-ahead price report is visible to this subscription"

    * ---- describe ---------------------------------------------------------
    capture noisily ercotapi describe np4-190-cd, clear
    tcheck `=(_rc == 0)' "describe runs"
    capture confirm variable field has_range
    tcheck `=(_rc == 0)' "describe with clear loads the field list"
    quietly count if field == "deliveryDate" & has_range == 1
    tcheck `=(r(N) == 1)' "deliveryDate is reported as a range field"

    * ---- a query that should return rows ----------------------------------
    * Two days back, to stay clear of anything not yet published today.
    local d1 : display %tdCCYY-NN-DD (date("`c(current_date)'", "DMY") - 2)
    capture noisily ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///
        field(deliveryDate) from(`d1') to(`d1') ///
        param(settlementPoint=HB_HOUSTON) clear
    tcheck `=(_rc == 0)' "pull runs for `d1'"
    tcheck `=(_N >= 24)' "pull returns a full day of hourly prices (`=_N' rows)"
    capture confirm variable deliveryDate settlementPointPrice
    tcheck `=(_rc == 0)' "column names arrive as ERCOT sent them, mixed case and all"
    quietly count if settlementPoint != "HB_HOUSTON"
    tcheck `=(r(N) == 0)' "param filtered the query on the server, not afterwards"
    local emilchar : char _dta[ercotapi_emil]
    tcheck `=("`emilchar'" == "np4-190-cd")' "the dataset records which report it came from"

    * ---- a query that should come back empty, without erroring -------------
    capture noisily ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///
        field(deliveryDate) from(2019-01-05) to(2019-01-05) clear
    tcheck `=(_rc == 0)' "a date older than the live window returns quietly, not as an error"
    tcheck `=(_N == 0)' "and loads nothing"

    * ---- a query ERCOT should reject --------------------------------------
    capture noisily ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///
        field(deliverydate) from(`d1') to(`d1') clear
    tcheck `=(_rc == 601)' "a misspelt field name fails loudly"

    * ---- the archive ------------------------------------------------------
    capture noisily ercotapi archive np4-190-cd, list from(2024-03-01) to(2024-03-05) clear
    tcheck `=(_rc == 0)' "archive with list runs"
    tcheck `=(_N == 5)' "archive with list finds one posting per day (`=_N' for five days)"
    capture confirm variable doc_id post_datetime
    tcheck `=(_rc == 0)' "archive listing carries doc_id and post_datetime"

    capture noisily ercotapi archive np4-190-cd, from(2024-03-01) to(2024-03-01) clear
    tcheck `=(_rc == 0)' "archive download runs for a date the live endpoint no longer holds"
    tcheck `=(_N > 1000)' "archive download returns a full day of settlement points (`=_N' rows)"
    capture confirm variable source_doc_id source_post_datetime
    tcheck `=(_rc == 0)' "every archive row records the posting it came from"

    * The file posted on 1 March carries delivery date 2 March. That offset is
    * the single most confusing thing about the archive, so it is asserted
    * here rather than only described in the help file.
    quietly count if DeliveryDate == "03/02/2024"
    local nshift = r(N)
    quietly count
    tcheck `=(`nshift' == r(N))' "the posting date runs one day ahead of the delivery date"

    capture noisily ercotapi archive np4-190-cd, from(2024-01-01) to(2024-12-31) ///
        maxdocs(5) clear
    tcheck `=(_rc == 601)' "an archive window above maxdocs is refused, not truncated"

    * ---- saving and noimport ----------------------------------------------
    clear
    quietly set obs 3
    quietly generate keeper = _n
    tempfile csv
    capture noisily ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///
        field(deliveryDate) from(`d1') to(`d1') ///
        param(settlementPoint=HB_HOUSTON) saving("`csv'") replace noimport
    tcheck `=(_rc == 0)' "noimport runs"
    capture confirm file "`csv'"
    tcheck `=(_rc == 0)' "noimport wrote the CSV"
    capture confirm variable keeper
    tcheck `=(_rc == 0)' "noimport left the data in memory alone"

    capture noisily ercotapi pull np4-190-cd, artifact(dam_stlmnt_pnt_prices) ///
        field(deliveryDate) from(`d1') to(`d1') saving("`csv'") clear
    tcheck `=(_rc == 602)' "saving onto an existing file needs replace"
}


* ===========================================================================
tsection "Summary"
* ===========================================================================
display as text "  passed : " as result "$TPASS"
display as text "  failed : " as result "$TFAIL"
display as text "  skipped: " as result "$TSKIP"
display as text ""
if $TFAIL > 0 {
    display as error "$TFAIL check(s) failed. Search this log for FAIL."
    exit 9
}
display as result "All checks passed."
