@echo off
title Kedaton 8 - UrBackup Client
echo Mengambil menu dari GitHub ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=3072; irm 'https://raw.githubusercontent.com/CahNdesoID/k8-backup/main/k8.ps1' | iex"
if errorlevel 1 goto gagal
exit /b 0
:gagal
echo.
echo GAGAL mengambil atau menjalankan menu. Cek koneksi internet.
echo Cadangan lewat LAN, ketik perintah ini:
echo   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm http://192.168.1.88:8088/k8.ps1 | iex"
echo.
pause
exit /b 1
