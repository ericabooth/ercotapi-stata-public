*! ercotapi_shell v1.0.0  2026-09-20
*! Run one _ercotapi_cli.py subcommand and read back its result.
*!
*! Stata's -shell- hands a command to the operating system and does not report
*! whether that command succeeded, so this program does not rely on an exit
*! status.  Instead the Python side ends every run with a single receipt line
*! that starts with OK: or ERROR:, and everything the run printed is captured
*! to a log file that the caller supplies.  This program finds the receipt and
*! reports it back.
*!
*! The caller passes an argument string that is already quoted for the shell.
*!
*! Returns:
*!     r(ok)        1 if the run finished with an OK: receipt, 0 otherwise
*!     r(receipt)   the receipt line, without its OK: / ERROR: prefix
program define ercotapi_shell, rclass
    version 16.0
    * ARGS is a plain string, not asis: asis would keep the compound quotes
    * around the value and hand the shell a pair of literal backtick-quote
    * characters, which is a silent failure rather than a loud one.
    syntax , ARGS(string) LOG(string) [PYTHON(string) VERBOSE]

    ercotapi_python, python(`"`python'"')
    local py `"`r(python)'"'

    capture erase "`log'"
    local full `"`py' `args'"'
    if "`verbose'" != "" {
        display as text "  running: " as result `"`full'"'
    }
    if "`c(os)'" == "Windows" {
        capture qui shell cmd /c "`full' > "`log'" 2>&1"
    }
    else {
        capture qui shell `full' > "`log'" 2>&1
    }

    * ---- read the captured output and pick out the receipt ----------------
    local ok 0
    local receipt ""
    local nlines 0
    capture confirm file "`log'"
    if !_rc {
        tempname fh
        file open `fh' using "`log'", read text
        file read `fh' line
        while r(eof) == 0 {
            local nlines = `nlines' + 1
            * The receipt is kept whole, prefix and all. Slicing the prefix off
            * here meant nesting compound quotes inside an inline expression,
            * which silently returned an empty string and made every successful
            * run look like it had fetched nothing.
            if substr(`"`macval(line)'"', 1, 4) == "OK: " {
                local ok 1
                local receipt `"`macval(line)'"'
            }
            else if substr(`"`macval(line)'"', 1, 7) == "ERROR: " {
                local ok 0
                local receipt `"`macval(line)'"'
            }
            file read `fh' line
        }
        file close `fh'
    }
    if "`verbose'" != "" {
        display as text "  receipt: " as result `"`receipt'"'
    }

    if `nlines' == 0 {
        display as error "ercotapi: the Python engine produced no output at all."
        display as error "  This usually means the interpreter could not be launched."
        display as error `"  Interpreter tried: `py'"'
        display as error `"  Set a different one with: global ercotapi_python "/path/to/python3""'
        exit 601
    }

    return local ok `ok'
    return local receipt `"`receipt'"'
end
