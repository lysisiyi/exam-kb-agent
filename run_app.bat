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
rem   "The remote computer refused the network connection ... address = 127.0.0.1"
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

rem --- Stale build check -------------------------------------------------------
rem Why this block exists: this script used to launch whatever exe it found,
rem without asking whether the sources had changed since. So after a source fix
rem you would double-click, the OLD binary would start, and the bug would still
rem be there -- looking exactly like "the fix did not work". That happened twice
rem (font fixes on 2026-09-21 were invisible because the exe was from 09-14).
rem
rem So: compare the newest source file against the exe timestamp. If sources are
rem newer, fall through to the build step instead of launching.
set "CHECK_EXE=%EXE%"
if not exist "%CHECK_EXE%" set "CHECK_EXE=%EXE_FALLBACK%"
set "STALE="
if exist "%CHECK_EXE%" (
  for /f "usebackq" %%S in (`powershell -NoProfile -Command "$e=(Get-Item '%CHECK_EXE%').LastWriteTime; $n=(Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue 'app\lib','app\assets','app\pubspec.yaml' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime; if ($n -gt $e) { 'STALE' } else { 'FRESH' }" 2^>nul`) do set "STALE=%%S"
)
if /i "%STALE%"=="STALE" echo [stale] sources are newer than %CHECK_EXE% -- will rebuild.

rem --- Already built and up to date? Just launch ---------------------------------
if exist "%EXE%" if /i not "%STALE%"=="STALE" (
  echo Launching %EXE%
  start "" "%EXE%"
  exit /b 0
)
if exist "%EXE_FALLBACK%" if /i not "%STALE%"=="STALE" (
  echo Launching %EXE_FALLBACK%
  echo ^(no Release build found -- building a Release one is recommended:^)
  echo ^    cd app ^&^& flutter build windows --release
  start "" "%EXE_FALLBACK%"
  exit /b 0
)

rem --- Build --------------------------------------------------------------------
rem Release, not Debug: it is what we ship, it needs no Dart VM, and it is what
rem gets measured for package size. Debug would also work but is ~4x larger.

rem Flutter's location MUST be resolved from PATH, never hard-coded.
rem An earlier revision hard-coded the author's own `D:\software\flutter\...`,
rem which made "double-click just works" a false promise for anyone else
rem (the script would only fail at the build step).
rem NOTE: keep this file ASCII-only. A `chcp 65001` batch file with non-ASCII
rem comments gets re-read at a byte offset after the codepage switch, and part
rem of a comment line can be executed as a command (seen 2026-09-22).
set "FLUTTER_BIN="
for /f "delims=" %%F in ('where flutter.bat 2^>nul') do if not defined FLUTTER_BIN set "FLUTTER_BIN=%%F"
if not defined FLUTTER_BIN (
  for /f "delims=" %%F in ('where flutter 2^>nul') do if not defined FLUTTER_BIN set "FLUTTER_BIN=%%F"
)
if not defined FLUTTER_BIN (
  echo.
  echo ERROR: flutter not found on PATH.
  echo        Install the Flutter SDK and make sure `flutter` works in a terminal:
  echo          https://docs.flutter.dev/get-started/install/windows
  echo        Note: `flutter build windows` also requires Windows Developer Mode.
  echo.
  pause
  exit /b 1
)
echo Using Flutter at %FLUTTER_BIN%

echo No build found. Building Release (a few minutes the first time)...
pushd app
call "%FLUTTER_BIN%" build windows --release
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

start "" "%EXE%"
