@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe' -Verb RunAs -ArgumentList '-NoProfile -NoExit -ExecutionPolicy Bypass -File ""%~dp0Set-StudentKeyboards.ps1""'"
