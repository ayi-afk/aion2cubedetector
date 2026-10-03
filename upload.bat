@echo off
rem Uploads the newest cube_watch_*.rar to the Discord channel with the fix
rem list from fixes.txt, then clears that list. "upload.bat --dry-run" only
rem shows the message. The webhook URL is read from .env (DISCORD_WEBHOOK=...).
setlocal
cd /d "%~dp0"
set DRY=
if /i "%~1"=="--dry-run" set DRY=-DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File tools\upload.ps1 %DRY%
exit /b %errorlevel%
