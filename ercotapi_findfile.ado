*! ercotapi_findfile v1.0.0  2026-09-20
*! Locate the two Python helper files that ercotapi drives.
*!
*! Stata's -net install- copies only file types it recognises (.ado, .sthlp,
*! and a short list of others).  A .py file is not on that list, so a user who
*! installs ercotapi the usual way gets the Stata commands and no engine.
*! This program closes that gap: it looks on the adopath, then in the package
*! cache under sysdir PLUS, and finally downloads the two files from the
*! project's GitHub mirror into the cache, where later calls reuse them.
*!
*! Both files must end up in the SAME folder, because _ercotapi_cli.py imports
*! _ercotapi_client.py from its own directory.  A half-present pair is treated
*! as missing rather than used.
*!
*! Returns:
*!     r(clipath)  full path to _ercotapi_cli.py
*!     r(dir)      the folder holding both files
program define ercotapi_findfile, rclass
    version 16.0
    syntax , [QUIETly]

    local cli    "_ercotapi_cli.py"
    local client "_ercotapi_client.py"

    * ---- pass 1: the adopath (which includes the working directory) --------
    local dir ""
    capture findfile "`cli'"
    if !_rc {
        local found "`r(fn)'"
        local dir = substr("`found'", 1, length("`found'") - length("`cli'"))
        capture confirm file "`dir'`client'"
        if _rc local dir ""
    }

    * ---- pass 2: the package cache ----------------------------------------
    local plus     : sysdir PLUS
    local personal : sysdir PERSONAL
    if "`dir'" == "" {
        foreach base in "`plus'e/ercotapi/" "`personal'ercotapi/" {
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
    * Set global ercotapi_remote_base (a URL or a local folder, with a
    * trailing slash) to point this somewhere else, such as an internal mirror
    * or a clone on a shared drive.
    if "`dir'" == "" {
        local remote "$ercotapi_remote_base"
        if "`remote'" == "" {
            local remote "https://raw.githubusercontent.com/texas-2036/ercotapi-stata-public/main/"
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
        display as error "  ercotapi needs `cli' and `client' in one folder."
        display as error "  Any one of these fixes it:"
        display as error `"    (a) net get ercotapi, from("https://raw.githubusercontent.com/texas-2036/ercotapi-stata-public/main/")"'
        display as error `"    (b) clone https://github.com/texas-2036/ercotapi-stata-public and run: adopath ++ "<clone folder>""'
        display as error `"    (c) if you mirror the files yourself, set: global ercotapi_remote_base "<url or folder>/""'
        exit 601
    }

    return local dir     "`dir'"
    return local clipath "`dir'`cli'"
end
