@echo off
rem ---------------------------------------------------------------------------
rem  Double-click launcher for the Windows desktop app.
rem
rem  Why this file exists:
rem  `flutter run -d windows` is the normal way, but it needs Developer Mode for
rem  plugin symlinks and it needs the China mirrors for asset downloads. This
rem  script sets both, builds if needed, then launches the app.
rem
rem  Usage:  double-click, or run `run_app.bat` from a terminal.
rem ---------------------------------------------------------------------------
chcp 65001 >nul
cd /d "%~dp0"

rem Prefer the Release build (that is what we actually ship); fall back to Debug.
set "EXE=app\build\windows\x64\runner\Release\kaoyan_math_agent.exe"
set "EXE_FALLBACK=app\build\windows\x64\runner\Debug\kaoyan_math_agent.exe"

rem --- China mirrors -----------------------------------------------------------
rem Without them, engine asset downloads and `pub get` hang instead of failing.
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"

rem --- Local accelerator (optional) --------------------------------------------
rem A build only needs this when a step must fetch from GitHub or sqlite.org --
rem those downloads hang forever instead of failing (see docs/SETUP.md section 3).
rem
rem WARNING: setting HTTP_PROXY unconditionally is actively harmful. It routes
rem *every* request through it -- including the pub.flutter-io.cn mirror above --
rem so a proxy that is not running makes `pub get` fail with
rem   "远程计算机拒绝网络连接 ... address = 127.0.0.1"
rem even though the mirror itself is perfectly reachable.
rem
rem So we only set it when something is actually listening on that port.
rem Change the port below if yours differs. Read the system proxy with:
rem   reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer
set "PROXY_PORT=26561"
for /f %%L in ('powershell -NoProfile -Command "if ((Test-NetConnection -ComputerName 127.0.0.1 -Port %PROXY_PORT% -InformationLevel Quiet -WarningAction SilentlyContinue) -eq $true) { 'LIVE' } else { 'DEAD' }" 2^>nul') do set "PROXY_STATE=%%L"

if /i "%PROXY_STATE%"=="LIVE" (
  set "HTTP_PROXY=http://127.0.0.1:%PROXY_PORT%"
  set "HTTPS_PROXY=http://127.0.0.1:%PROXY_PORT%"
  echo [proxy] 127.0.0.1:%PROXY_PORT% is live -- routing build downloads through it.
) else (
  echo [proxy] nothing listening on 127.0.0.1:%PROXY_PORT% -- going direct.
  echo         ^(if a download hangs later, start your accelerator and re-run^)
)

rem --- Generated assets ---------------------------------------------------------
rem app\assets\data is generated (see .gitignore), so a fresh clone has none.
rem Flutter fails to build when a declared asset directory is missing.
if not exist "app\assets\data\knowledge_points\math1.json" (
  echo Syncing knowledge assets from data\ ...
  where python >nul 2>nul
  if errorlevel 1 (
    echo.
    echo ERROR: python not found on PATH, cannot build app\assets\data.
    echo        Install Python, then run: python tools\data\sync_assets.py
    pause
    exit /b 1
  )
  python "tools\data\sync_assets.py"
  if errorlevel 1 (
    echo.
    echo ERROR: asset sync failed.
    pause
    exit /b 1
  )
)

rem --- Already built? Just launch -----------------------------------------------
if exist "%EXE%" (
  echo Launching %EXE%
  start "" "%EXE%"
  exit /b 0
)
if exist "%EXE_FALLBACK%" (
  echo Launching %EXE_FALLBACK%
  echo ^(no Release build found -- building a Release one is recommended:^)
  echo ^    cd app ^&^& flutter build windows --release
  start "" "%EXE_FALLBACK%"
  exit /b 0
)

rem --- Build --------------------------------------------------------------------
rem Release, not Debug: it is what we ship, it needs no Dart VM, and it is what
rem gets measured for package size. Debug would also work but is ~4x larger.
echo No build found. Building Release (a few minutes the first time)...
pushd app
call "D:\software\flutter\bin\flutter.bat" build windows --release
set "BUILD_RC=%ERRORLEVEL%"
popd

if not "%BUILD_RC%"=="0" (
  echo.
  echo Build failed. Check the output above.
  echo.
  echo If it failed while downloading packages, and you normally use a local
  echo accelerator, start it first -- this script only routes through it when it
  echo is actually listening.
  pause
  exit /b %BUILD_RC%
)

start "" "%EXE"
