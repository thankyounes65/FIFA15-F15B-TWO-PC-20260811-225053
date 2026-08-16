@echo off
setlocal EnableExtensions
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN-FIFA15-F15B-V17.ps1"
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
