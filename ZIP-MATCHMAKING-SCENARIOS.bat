@echo off
setlocal EnableExtensions
cd /d "%~dp0"
if not exist "runs\matchmaking-scenarios\player-b" (
  echo ERROR: No Player B matchmaking scenario evidence exists yet.
  exit /b 1
)
for /f "delims=" %%S in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%S"
set "OUT=runs\PLAYER-B-MATCHMAKING-SCENARIOS-%STAMP%.zip"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path 'runs\matchmaking-scenarios\player-b' -DestinationPath '%OUT%' -Force"
if errorlevel 1 exit /b 1
echo Created: %OUT%
endlocal & exit /b 0
