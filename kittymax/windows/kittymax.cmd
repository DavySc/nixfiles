@echo off
rem Starts kittymax on native Windows: Emacs with this directory as its configuration.
rem Put a shortcut to this file on the desktop or pin it; arguments are passed on
rem (kittymax.cmd notes.md).  To use a different Emacs, set KITTYMAX_EMACS first.
setlocal
set "KITTYMAX_DIR=%~dp0.."
if defined KITTYMAX_EMACS (
  set "EMACS=%KITTYMAX_EMACS%"
) else (
  where runemacs >nul 2>nul && (set "EMACS=runemacs") || (set "EMACS=emacs")
)
rem runemacs has no console window; "start" returns at once
start "" "%EMACS%" --init-directory "%KITTYMAX_DIR%" %*
