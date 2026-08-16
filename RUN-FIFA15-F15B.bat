@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title FIFA 15 Player B - Matchmaking Scenario Suite

set "SCENARIO=%~1"
if defined SCENARIO goto :validate

:menu
cls
echo ====================================================================
echo   FIFA 15 PLAYER B - MATCHMAKING SCENARIO SUITE
echo ====================================================================
echo   Select the SAME scenario number selected on Player A.
echo.
echo   1. JoinCompleted(A) to B after GameSetup, before 0x16
echo   2. Self mesh registration only; promote on real peer edge
echo   3. Keep first GSU; suppress second peer-edge replay
echo   4. Move the single B GSU to the real peer edge
echo.
echo   Q. Quit
echo ====================================================================
set /p "SCENARIO=Scenario [1-4/Q]: "
if /i "%SCENARIO%"=="Q" endlocal & exit /b 0

:validate
if "%SCENARIO%"=="1" goto :run
if "%SCENARIO%"=="2" goto :run
if "%SCENARIO%"=="3" goto :run
if "%SCENARIO%"=="4" goto :run
echo ERROR: choose scenario 1, 2, 3, or 4.
set "SCENARIO="
pause
goto :menu

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN-FIFA15-F15B-SCENARIO.ps1" -Scenario %SCENARIO%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
