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

set "EXE=app\build\windows\x64\runner\Debug\kaoyan_math_agent.exe"

rem China mirrors. Without them `flutter pub get` / engine asset downloads hang.
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"

rem Local accelerator (FlyingBird / Watt Toolkit). Only needed when a build step
rem has to fetch something from GitHub or sqlite.org -- those downloads otherwise
rem hang forever instead of failing. Change the port if yours differs; the
rem current system proxy is readable from:
rem   reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer
set "HTTP_PROXY=http://127.0.0.1:26561"
set "HTTPS_PROXY=http://127.0.0.1:26561"

if exist "%EXE%" (
  echo Launching %EXE%
  start "" "%EXE%"
  exit /b 0
)

echo No build found. Building (this takes a few minutes the first time)...
pushd app
call "D:\software\flutter\bin\flutter.bat" build windows --debug
set "BUILD_RC=%ERRORLEVEL%"
popd

if not "%BUILD_RC%"=="0" (
  echo.
  echo Build failed. Check the output above.
  pause
  exit /b %BUILD_RC%
)

start "" "%EXE%"
