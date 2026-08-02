@echo off
rem deromine.cmd - unified launcher (Windows cmd)
rem Prefers pwsh, falls back to Windows PowerShell 5.1.
rem Uses its own directory when run from the repo, or the standard
rem install location when run from the PATH shim that install.ps1
rem copies to %USERPROFILE%\.local\bin\deromine.cmd.
setlocal EnableDelayedExpansion
set "DIR=%~dp0"
if not exist "%DIR%mine.ps1" set "DIR=%USERPROFILE%\.local\share\deromine\"
where pwsh >nul 2>nul
if not errorlevel 1 (
    pwsh -NoProfile -File "%DIR%mine.ps1" %*
    exit /b !errorlevel!
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%mine.ps1" %*
exit /b %errorlevel%
