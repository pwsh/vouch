@echo off
rem Vouch Designer: double-click to open the Designer window.
rem Drop a configuration file (.json) on this file to open it straight away.
setlocal
where pwsh >nul 2>nul
if errorlevel 1 goto nopwsh
if "%~1"=="" (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0vouch.ps1" -Designer
) else (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0vouch.ps1" -Designer -ConfigPath "%~1"
)
if errorlevel 1 pause
exit /b %errorlevel%

:nopwsh
echo.
echo Vouch Designer needs PowerShell 7, and it is not installed on this computer.
echo Install it from the Microsoft Store - search for PowerShell, published by
echo Microsoft Corporation - or ask your IT department to install it.
echo Then double-click Vouch-Designer.cmd again.
echo See docs\getting-started.md, step 3, for the details.
echo.
pause
exit /b 1
