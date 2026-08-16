@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo [preflight] Verifying exact v18 Player-B package before networking/FIFA...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN-FIFA15-F15B-V18.ps1" -SelfTest
if errorlevel 1 (
    echo ERROR: v18 Player-B package self-test failed. FIFA was not launched.
    endlocal & exit /b 1
)

call "%~dp0RUN-FIFA15-F15B-V18.bat"
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
