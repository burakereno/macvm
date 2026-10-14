@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -Command "& ([scriptblock]::Create([System.IO.File]::ReadAllText((Join-Path (Get-Location) 'Integration.ps1'))))"
if errorlevel 1 goto finish
powershell.exe -NoProfile -Command "& ([scriptblock]::Create([System.IO.File]::ReadAllText((Join-Path (Get-Location) 'Install.ps1'))))"
:finish
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%
