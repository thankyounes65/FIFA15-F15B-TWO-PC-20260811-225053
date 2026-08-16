@echo off
setlocal EnableExtensions
cd /d "%~dp0"
call "%~dp0RUN-FIFA15-F15B-V18.bat"
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
