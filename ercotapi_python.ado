*! ercotapi_python v1.0.2  2026-11-09
*! Work out which Python interpreter to use, and prove it runs.
*!
*! ercotapi needs a Python 3 interpreter on the machine, but it does not need
*! Stata's own Python integration to be configured, and it does not need any
*! package installed through pip.  The engine uses the standard library only.
*!
*! Search order:
*!     1. the python() option passed by the caller
*!     2. global ercotapi_python, if you set one
*!     3. whatever Stata's own Python integration already points at
*!     4. python3, then python, then (on Windows) the py launcher
*!
*! An interpreter you name yourself, with python() or by setting the global,
*! is used or refused: if it does not answer, this program stops with an
*! error naming it rather than quietly falling through to python3 (v1.0.2).
*! A leading ~ in either is expanded from HOME (USERPROFILE on Windows),
*! because the shell never sees it unquoted.
*!
*! Each candidate is tried by running a one-line program and reading back what
*! it printed, because Stata's -shell- does not report the exit status of the
*! program it ran.  The first candidate that answers is stored in the global
*! ercotapi_python, so later commands in the same session skip the search.
*!
*! Returns:
*!     r(python)   the interpreter to call, already quoted for the shell
*!     r(pyver)    the version string it reported
program define ercotapi_python, rclass
    version 16.0
    syntax , [PYTHON(string) FORCEsearch]

    if "`forcesearch'" != "" global ercotapi_python ""

    * Each candidate is a complete, shell-ready command prefix.  Paths are
    * quoted here because they often contain spaces; the Windows py launcher
    * is deliberately left bare because "py -3" is a program plus an argument,
    * not a path.
    local k 0
    * nexpl = how many leading candidates the user named (python() or the
    * global); those are never fallen through silently.
    local nexpl 0
    if `"`python'"' != "" {
        * A value that is already shell-ready (quoted, or one of the bare
        * names the search itself returns) is used as given, so a caller can
        * hand back r(python) unchanged.  Anything else is a path: expand a
        * leading ~ and quote it.
        if substr(`"`python'"', 1, 1) == `"""' | inlist(`"`python'"', "python3", "python", "py -3") {
            local k = `k' + 1
            local c`k' `"`python'"'
        }
        else {
            _ercotapi_py_tilde `"`python'"'
            local python `"`r(path)'"'
            local k = `k' + 1
            local c`k' `""`python'""'
        }
        local nexpl `k'
    }
    local g `"$ercotapi_python"'
    if `"`g'"' != "" & `nexpl' == 0 {
        if substr(`"`g'"', 1, 1) != `"""' {
            _ercotapi_py_tilde `"`g'"'
            local g `"`r(path)'"'
        }
        * A value this program stored earlier is already shell-ready. A value
        * the user typed by hand is usually a bare path, and this author's own
        * machines have spaces in nearly every path, so an unquoted one would
        * be word-split by the shell and the search would fall through to a
        * different interpreter without saying so. Quote a bare path that
        * names a real file, and leave anything else alone so a command plus
        * argument, such as the Windows "py -3", still works.
        if substr(`"`g'"', 1, 1) != `"""' {
            capture confirm file `"`g'"'
            if !_rc local g `""`g'""'
        }
        local k = `k' + 1
        local c`k' `"`g'"'
        local nexpl `k'
    }
    * If Stata's own Python integration is already pointed at an interpreter,
    * reuse it: the user has already told Stata which Python they want.
    capture local pyexec `"`c(python_exec)'"'
    if _rc local pyexec ""
    if `"`pyexec'"' != "" {
        local k = `k' + 1
        local c`k' `""`pyexec'""'
    }
    local k = `k' + 1
    local c`k' "python3"
    local k = `k' + 1
    local c`k' "python"
    if "`c(os)'" == "Windows" {
        local k = `k' + 1
        local c`k' "py -3"
    }
    local ncand `k'

    tempfile probe
    local winner ""
    local winver ""
    forvalues i = 1/`ncand' {
        if `"`winner'"' == "" {
            local cand `"`c`i''"'
            capture erase "`probe'"
            local probecmd `"`cand' -c "import sys;print('ERCOTAPI_PY '+sys.version.split()[0])""'
            if "`c(os)'" == "Windows" {
                capture qui shell cmd /c "`probecmd' > "`probe'" 2>&1"
            }
            else {
                capture qui shell `probecmd' > "`probe'" 2>&1
            }
            capture confirm file "`probe'"
            if !_rc {
                tempname fh
                capture file open `fh' using "`probe'", read text
                if !_rc {
                    file read `fh' line
                    while r(eof) == 0 {
                        local hit = strpos(`"`macval(line)'"', "ERCOTAPI_PY ")
                        if `hit' > 0 {
                            local winner `"`cand'"'
                            local winver = trim(substr(`"`macval(line)'"', `hit' + 12, .))
                        }
                        file read `fh' line
                    }
                    file close `fh'
                }
            }
            if `"`winner'"' == "" & `i' <= `nexpl' {
                * an interpreter the user named did not answer: say so and stop
                local show : subinstr local cand `"""' "", all
                if `"`python'"' != "" {
                    display as error `"ercotapi: the interpreter named in python() did not run: `show'"'
                    display as error "  Check the path, or leave python() out to let ercotapi search."
                }
                else {
                    display as error `"ercotapi: global ercotapi_python names an interpreter that did not run: `show'"'
                    display as error `"  Fix it, or clear it to let ercotapi search:  global ercotapi_python """'
                }
                exit 601
            }
        }
    }

    if `"`winner'"' == "" {
        display as error "ercotapi: no working Python 3 interpreter was found."
        display as error "  ercotapi calls Python to talk to ERCOT, because Stata cannot send the"
        display as error "  authentication headers the API requires.  You do not need any pip"
        display as error "  packages; the Python standard library is enough."
        display as error "  Install Python 3.8 or newer from https://www.python.org/downloads/ ,"
        display as error "  then either restart Stata or point ercotapi at it directly:"
        display as error `"      global ercotapi_python "/full/path/to/python3""'
        exit 601
    }

    * An old interpreter answers the probe and then fails inside the engine
    * with a message the user cannot act on, so check the version here and say
    * plainly what is wrong. The minimum checked matches the one documented.
    local dot = strpos("`winver'", ".")
    local major = cond(`dot' > 1, real(substr("`winver'", 1, `dot' - 1)), .)
    local rest  = substr("`winver'", `dot' + 1, .)
    local dot2  = strpos("`rest'", ".")
    local minor = cond(`dot2' > 1, real(substr("`rest'", 1, `dot2' - 1)), real("`rest'"))
    local tooold = 0
    if !missing(`major') & `major' < 3                          local tooold 1
    if !missing(`major') & !missing(`minor') & `major' == 3 & `minor' < 8 local tooold 1
    if `tooold' {
        display as error "ercotapi: `winner' reports Python `winver'; version 3.8 or newer is required."
        display as error `"  Point ercotapi at a newer interpreter: global ercotapi_python "/path/to/python3""'
        exit 601
    }

    global ercotapi_python `"`winner'"'
    return local python `"`winner'"'
    return local pyver   "`winver'"
end


* Expand a leading ~ (alone, or followed by / or a backslash) from HOME, or on
* Windows from USERPROFILE (HOMEDRIVE+HOMEPATH as a last resort).  Anything
* else comes back unchanged.
program define _ercotapi_py_tilde, rclass
    version 16.0
    args path
    local p `"`macval(path)'"'
    if substr(`"`p'"', 1, 1) == "~" & inlist(substr(`"`p'"', 2, 1), "", "/", "\") {
        local home : env HOME
        if "`c(os)'" == "Windows" {
            local up : env USERPROFILE
            if `"`up'"' != "" local home `"`up'"'
            if `"`home'"' == "" {
                local hd : env HOMEDRIVE
                local hp : env HOMEPATH
                local home `"`hd'`hp'"'
            }
        }
        if `"`home'"' != "" {
            local rest = substr(`"`p'"', 2, .)
            local p `"`home'`rest'"'
        }
    }
    return local path `"`p'"'
end
