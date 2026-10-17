@echo off
title Kedaton 8 - Penerima Registrasi PC
fltmc >nul 2>&1
if %errorlevel% neq 0 goto minta_admin
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0k8-server.ps1" -BukaFirewall %*
echo.
pause
exit /b
:minta_admin
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b
