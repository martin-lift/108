@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-StudentNetwork.ps1"
set "result=%errorlevel%"
if not "%result%"=="0" (
    echo Press any key to close . . .
    pause >nul
)
exit /b %result%
