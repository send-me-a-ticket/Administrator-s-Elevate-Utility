@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "PSHOST="
where pwsh.exe >nul 2>&1
if %errorlevel%==0 (
    set "PSHOST=pwsh.exe"
) else (
    if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PSHOST=%ProgramFiles%\PowerShell\7\pwsh.exe"
    if not defined PSHOST if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "PSHOST=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
)
if not defined PSHOST (
    set "PSHOST=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
)
"%PSHOST%" "./Elevate.ps1"
endlocal
exit /b %errorlevel%
