@echo off
rem Builds server\cubewatch-server.exe: one static executable with the web
rem pages, the map image and SQLite inside.
rem Requirements: V (https://vlang.io), gcc from MSYS2 UCRT64, and the SQLite
rem amalgamation installed once with:
rem   v run %%VROOT%%\vlib\db\sqlite\install_thirdparty_sqlite.vsh
rem
rem   build.bat                  Windows exe
rem   build.bat --linux          static Linux binary (same as build_linux.bat)
rem   build.bat --linux clean    ... rebuilding its cached libraries too
setlocal
if /i "%~1"=="--linux" (
  call "%~dp0build_linux.bat" %2
  exit /b %errorlevel%
)
rem the UCRT64 toolchain first, so gcc does not pick up foreign DLLs (git / anaconda mingw)
set "PATH=C:\msys64\ucrt64\bin;%PATH%"
cd /d "%~dp0.."
v test server\world || exit /b 1
v test wire || exit /b 1
rem Cube Watch itself is built with V's bundled tcc; C objects cached by one
rem compiler do not link with the other, so this build keeps its own cache.
set "VCACHE=%USERPROFILE%\.vmodules\.cache-gcc"
rem -fno-lto: gcc's link-time optimization miscompiles this program (it
rem crashes at start); -O2 without it is fine.
v -prod -cc gcc -cflags "-fno-lto -O2 -static" -o server\cubewatch-server.exe server
if errorlevel 1 exit /b 1
echo Built server\cubewatch-server.exe
