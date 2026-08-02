@echo off
rem deromine.cmd — unified launcher (Windows cmd)
rem Prefers pwsh, falls back to Windows PowerShell 5.1.
setlocal
set "DIR=%~dp0"
where pwsh >nul 2>nul
if not errorlevel 1 (
    pwsh -NoProfile -File "%DIR%mine.ps1" %*
    exit /b %errorlevel%
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%mine.ps1" %*
exit /b %errorlevel%
