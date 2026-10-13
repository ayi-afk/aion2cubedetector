@echo off
setlocal
cd /d "%~dp0"

set "REMOTE=kk@185.228.81.175"
set "BINARY=server\build\linux\cubewatch-server"
set "DEST=/home/kk/cube_tech/binary"

echo [1/3] Building...
call server\build.bat --linux
if errorlevel 1 exit /b 1

echo [2/3] Uploading...
ssh %REMOTE% "mkdir -p %DEST%"
if errorlevel 1 exit /b 1

scp "%BINARY%" %REMOTE%:%DEST%/cubewatch-server.new
if errorlevel 1 exit /b 1

echo [3/3] Deploying and restarting...
ssh %REMOTE% "mv %DEST%/cubewatch-server.new %DEST%/cubewatch-server && chmod +x %DEST%/cubewatch-server && sudo systemctl restart cube-tech"
if errorlevel 1 exit /b 1

echo Deployment successful!