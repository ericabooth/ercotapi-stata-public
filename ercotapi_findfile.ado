*! ercotapi_findfile v1.0.1  2026-09-20
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
        if `ok' local dir "`dest'"
    }

    if "`dir'" == "" {
        display as error "ercotapi: the Python engine files could not be found or downloaded."
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
