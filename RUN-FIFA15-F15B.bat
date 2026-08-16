@echo off
setlocal EnableExtensions
cd /d "%~dp0"
echo [preflight] Verifying scenario-aware Player-B package before networking/FIFA...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN-MATCHMAKING-SCENARIO.ps1" -SelfTest
if errorlevel 1 (
  echo ERROR: Player-B scenario package self-test failed. FIFA was not launched.
  endlocal & exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN-MATCHMAKING-SCENARIO.ps1"
set "RC=%ERRORLEVEL%"
echo No evidence upload/publish step was attempted. Evidence is local only.
endlocal & exit /b %RC%
