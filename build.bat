@echo off
rem Builds cube_watch.exe with V's bundled compiler and runs the protocol tests.
rem Every build gets a fresh 7-day trial stamp (build_stamp.v, see tools\stamp)
rem and is packed into cube_watch_<date>_<time>.rar for distribution.
setlocal
cd /d "%~dp0"
tasklist /fi "imagename eq cube_watch.exe" | findstr /i "cube_watch.exe" >nul && (echo cube_watch.exe is running - close it first ^(tray: Exit^) & exit /b 1)
v test proto || exit /b 1
v run tools\stamp build_stamp.v || exit /b 1
v -subsystem windows -o cube_watch.exe . || exit /b 1
echo Built cube_watch.exe

for /f %%d in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HHmm"') do set BUILD_DATE=%%d
set RAR=rar
where rar >nul 2>&1 || set RAR="%ProgramFiles%\WinRAR\Rar.exe"
set ARCHIVE=cube_watch_%BUILD_DATE%.rar
if exist "%ARCHIVE%" del "%ARCHIVE%"
%RAR% a -ep -m5 -idq "%ARCHIVE%" cube_watch.exe || (echo Packing failed: install WinRAR or put rar on PATH & exit /b 1)
echo Packed %ARCHIVE%
