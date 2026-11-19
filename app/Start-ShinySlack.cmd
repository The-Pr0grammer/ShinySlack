@echo off
setlocal
set "SHINYROOT=%~dp0"

rem Files downloaded as a ZIP can inherit Mark-of-the-Web after extraction.
rem Remove that mark before invoking any ShinySlack PowerShell script.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='SilentlyContinue'; Get-ChildItem -LiteralPath $env:SHINYROOT -Recurse -File | Unblock-File"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-ShinySlack.ps1"
exit /b %errorlevel%
