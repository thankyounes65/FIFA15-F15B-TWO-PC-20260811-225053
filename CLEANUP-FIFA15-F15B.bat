@echo off
setlocal
cd /d "%~dp0"
title FIFA 15 Remote Player Cleanup - f15b
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0remote-client.ps1" -Cleanup
pause
