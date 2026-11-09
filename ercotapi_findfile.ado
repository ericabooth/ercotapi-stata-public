*! ercotapi_findfile v1.0.2  2026-11-09
*! Locate the two Python helper files that ercotapi drives.
*!
*! Stata 16 and later file a package's .py files under sysdir PLUS/py/, and
*! -findfile- searches there, so an ordinary -net install- puts the engine
*! where this program will find it.  Pass 1 below is the case that normally
*! applies, and passes 2 and 3 exist for installs that went another way: a
*! folder copied by hand, a clone added with -adopath-, or a partial install.
*!
*! Both files must end up in the SAME folder, because _ercotapi_cli.py imports
*! _ercotapi_client.py from its own directory.  A half-present pair is treated
*! as missing rather than used, since importing a stale client would be worse
*! than reporting the engine as absent.
*!
*! v1.0.2: pass 3 keeps a downloaded engine only when it reports the same
*!         version as this package, so an older ado never runs whatever
*!         the main branch holds that day.
*! v1.0.1: search PLUS/py/ and PERSONAL/py/ explicitly in pass 2.  Pass 1
*!         already finds them there through -findfile-, but an installation
*!         that has been moved or partially copied may not be on the adopath.
*!
*! Returns:
*!     r(clipath)  full path to _ercotapi_cli.py
*!     r(dir)      the folder holding both files
program define ercotapi_findfile, rclass
    version 16.0
    syntax , [QUIETly]

    local cli    "_ercotapi_cli.py"
    local client "_ercotapi_client.py"
    * the engine version this ado belongs with (kept in step with ercotapi.ado
    * and __version__ in _ercotapi_client.py; tests/test_ercotapi.do checks it)
    local want   "1.0.2"

    * ---- pass 1: the adopath, which is where net install puts them ---------
    local dir ""
    capture findfile "`cli'"
    if !_rc {
        local found "`r(fn)'"
        local dir = substr("`found'", 1, length("`found'") - length("`cli'"))
        capture confirm file "`dir'`client'"
        if _rc local dir ""
    }

    * ---- pass 2: places an unusual install may have left them --------------
    local plus     : sysdir PLUS
    local personal : sysdir PERSONAL
    if "`dir'" == "" {
        foreach base in "`plus'py/" "`personal'py/" "`plus'e/ercotapi/" ///
                        "`personal'ercotapi/" {
            if "`dir'" == "" {
                capture confirm file "`base'`cli'"
                if !_rc {
                    capture confirm file "`base'`client'"
                    if !_rc local dir "`base'"
                }
            }
        }
    }

    * ---- pass 3: fetch from the mirror ------------------------------------
    * A last resort, for an install that did not bring the engine with it.
    * Set global ercotapi_remote_base (a URL or a local folder, with a
    * trailing slash) to point this somewhere else, such as an internal mirror
    * or a clone on a shared drive.
    *
    * The main branch moves on, so what is fetched is checked before it is
    * used: the client must report the version this ado was written for.  A
    * different version is removed again and the reinstall message below is
    * shown, because reinstalling brings the ado and the engine back in step.
    local mismatch ""
    if "`dir'" == "" {
        local remote "$ercotapi_remote_base"
        if "`remote'" == "" {
            local remote "https://raw.githubusercontent.com/ericabooth/ercotapi-stata-public/main/"
        }
        local dest "`plus'e/ercotapi/"
        capture mkdir "`plus'e"
        capture mkdir "`dest'"
        local ok 1
        foreach f in "`cli'" "`client'" {
            if "`quietly'" == "" display as text "  ercotapi: fetching `f' from `remote'"
            capture copy "`remote'`f'" "`dest'`f'", replace
            if _rc local ok 0
        }
        if `ok' {
            * read in Mata: Python source holds quote sequences that a
            * Stata macro cannot carry safely
            local got ""
            capture mata: st_local("got", _ercotapi_engver(st_local("dest") + st_local("client")))
            if "`got'" != "`want'" {
                local ok 0
                local mismatch "`got'"
                if "`mismatch'" == "" local mismatch "unknown"
                capture erase "`dest'`cli'"
                capture erase "`dest'`client'"
            }
        }
        if `ok' local dir "`dest'"
    }

    if "`dir'" == "" {
        display as error "ercotapi: the Python engine files could not be found or downloaded."
        if "`mismatch'" != "" {
            display as error "  The copy at `remote' is version `mismatch', but this ercotapi is `want',"
            display as error "  so it was not used."
        }
        display as error "  ercotapi needs `cli' and `client' together in one folder."
        display as error "  Reinstalling puts them there, so start with:"
        display as error `"    net install ercotapi, from("https://raw.githubusercontent.com/ericabooth/ercotapi-stata-public/main/") replace force"'
        display as error "  If this machine cannot reach GitHub, either:"
        display as error `"    clone https://github.com/ericabooth/ercotapi-stata-public and run: adopath ++ "<clone folder>""'
        display as error `"    or mirror the files and set: global ercotapi_remote_base "<url or folder>/""'
        exit 601
    }

    return local dir     "`dir'"
    return local clipath "`dir'`cli'"
end

mata:
// the version an engine file reports: the value on its  __version__ = "x.y.z"
// line, or "" when the file cannot be read or has no such line
string scalar _ercotapi_engver(string scalar fn)
{
    real scalar   fh
    string scalar v
    string matrix line

    v  = ""
    fh = _fopen(fn, "r")
    if (fh < 0) return("")
    while ((line = fget(fh)) != J(0, 0, "")) {
        if (regexm(line, "^__version__ *= *.([0-9][0-9A-Za-z.]*)")) {
            v = regexs(1)
            break
        }
    }
    fclose(fh)
    return(v)
}
end
