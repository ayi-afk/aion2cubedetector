@echo off
rem Cross-compiles a fully static Linux x86-64 binary: server\build\linux\cubewatch-server
rem (musl, no runtime dependencies - runs on any x86-64 distro; web pages, map
rem image and SQLite inside).
rem
rem How: V only generates C code for Linux; zig cc (bundled clang + musl) compiles
rem it together with the C libraries V needs (libgc, mbedtls, SQLite, cJSON) and
rem links statically.
rem
rem Requirements: V (same as build.bat), zig 0.12+ in PATH (winget install zig.zig),
rem and the SQLite amalgamation in %%VROOT%%\thirdparty\sqlite (see build.bat).
rem Usage: build_linux.bat            - incremental (third-party objects are cached)
rem        build_linux.bat clean      - rebuild everything
setlocal EnableDelayedExpansion
cd /d "%~dp0.."

where zig >nul 2>nul || (echo [build_linux] zig not found in PATH - install it: winget install zig.zig & exit /b 1)
set "VEXE="
for /f "delims=" %%i in ('where v 2^>nul') do if not defined VEXE set "VEXE=%%i"
if not defined VEXE (echo [build_linux] v not found in PATH & exit /b 1)
for %%i in ("%VEXE%") do set "VROOT=%%~dpi"
set "TP=%VROOT%thirdparty"
if not exist "%TP%\sqlite\sqlite3.c" (echo [build_linux] missing %TP%\sqlite\sqlite3.c - run: v run "%VROOT%vlib\db\sqlite\install_thirdparty_sqlite.vsh" & exit /b 1)

set "OUT=server\build\linux"
set "OBJ=%OUT%\obj"
if /i "%~1"=="clean" if exist "%OUT%" rmdir /s /q "%OUT%"
if not exist "%OBJ%" mkdir "%OBJ%"

set "ZT=-target x86_64-linux-musl"
set "GCDEF=-DGC_THREADS=1 -DGC_BUILTIN_ATOMIC=1 -DNO_GETCONTEXT"
rem (no outer quotes: the value contains quoted paths)
set MBINC=-I "%TP%\mbedtls\include" -I "%TP%\mbedtls\library" -I "%TP%\mbedtls\3rdparty\everest\include" -I "%TP%\mbedtls\3rdparty\everest\include\everest" -I "%TP%\mbedtls\3rdparty\everest\include\everest\kremlib"

echo [build_linux] 1/4 generating C (V -os linux)
rem On Linux V's HTTPS client is mbedtls with a 550 ms read timeout by default;
rem the official AION 2 API often needs longer -> 20 s.
v -os linux -prod -d musl -d mbedtls_client_read_timeout_ms=20000 -o "%OUT%\cubewatch-server.c" server
if errorlevel 1 exit /b 1

echo [build_linux] 2/4 third-party libraries (cached in %OBJ%)
if not exist "%OBJ%\gc.o" (
  echo   libgc
  zig cc %ZT% -O2 -w %GCDEF% -I "%TP%\libgc\include" -c -o "%OBJ%\gc.o" "%TP%\libgc\gc.c" || exit /b 1
)
if not exist "%OBJ%\mbedtls.o" (
  echo   mbedtls
  if exist "%OBJ%\mbedtls.rsp" del "%OBJ%\mbedtls.rsp"
  rem response file with forward slashes (backslashes would be read as escapes)
  for %%f in ("%TP%\mbedtls\library\*.c" "%TP%\mbedtls\3rdparty\everest\library\Hacl_Curve25519_joined.c" "%TP%\mbedtls\3rdparty\everest\library\everest.c" "%TP%\mbedtls\3rdparty\everest\library\x25519.c") do (
    set "SRC=%%~f"
    echo "!SRC:\=/!">> "%OBJ%\mbedtls.rsp"
  )
  zig cc %ZT% -O2 -w %MBINC% -c -o "%OBJ%\mbedtls.o" @"%OBJ%\mbedtls.rsp" || exit /b 1
)
if not exist "%OBJ%\sqlite3.o" (
  echo   sqlite
  zig cc %ZT% -O2 -w -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -I "%TP%\sqlite" -c -o "%OBJ%\sqlite3.o" "%TP%\sqlite\sqlite3.c" || exit /b 1
)
if not exist "%OBJ%\cJSON.o" (
  echo   cJSON
  zig cc %ZT% -O2 -w -I "%TP%\cJSON" -c -o "%OBJ%\cJSON.o" "%TP%\cJSON\cJSON.c" || exit /b 1
)

echo [build_linux] 3/4 compiling the application
zig cc %ZT% -O2 -w -fwrapv -fno-strict-aliasing -std=gnu11 -D_DEFAULT_SOURCE %GCDEF% -I "%TP%\libgc\include" %MBINC% -I "%TP%\cJSON" -I "%TP%\zstd" -I "%TP%\sqlite" -I "%TP%\zip" -c -o "%OBJ%\main.o" "%OUT%\cubewatch-server.c" || exit /b 1

echo [build_linux] 4/4 linking (static)
zig cc %ZT% -static -s -O2 -o "%OUT%\cubewatch-server" "%OBJ%\main.o" "%OBJ%\gc.o" "%OBJ%\mbedtls.o" "%OBJ%\sqlite3.o" "%OBJ%\cJSON.o" -lm || exit /b 1

echo [build_linux] done: %OUT%\cubewatch-server
echo   copy it to the server, then: chmod +x cubewatch-server ^&^& ./cubewatch-server --port 8081 --password ... --password-admin ...
