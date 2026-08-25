@echo off
@REM ---------------------------------------------------------------------------
@REM Maven Daemon (mvnd) wrapper for this example reactor (Windows).
@REM Downloads a pinned mvnd into .mvnd\ on first use, then runs it with all
@REM passed arguments. Pinned version matches the CI workflow.
@REM Note: unlike the POSIX ./mvndw, this script does not verify the download's
@REM SHA-512 — CI runs on Linux and uses the POSIX script.
@REM
@REM   mvndw.cmd clean verify
@REM   mvndw.cmd -T4 clean verify
@REM ---------------------------------------------------------------------------
setlocal
set "MVND_VERSION=1.0.6"
set "SCRIPT_DIR=%~dp0"
set "CACHE_DIR=%SCRIPT_DIR%.mvnd"
set "ARCHIVE=maven-mvnd-%MVND_VERSION%-windows-amd64"
set "BIN=%CACHE_DIR%\%ARCHIVE%\bin\mvnd.cmd"
set "URL=https://downloads.apache.org/maven/mvnd/%MVND_VERSION%/%ARCHIVE%.zip"
set "ZIP=%CACHE_DIR%\%ARCHIVE%.zip"

if not exist "%BIN%" (
  if not exist "%CACHE_DIR%" mkdir "%CACHE_DIR%"
  echo [mvndw] downloading %URL%
  powershell -NoProfile -Command "Invoke-WebRequest -Uri '%URL%' -OutFile '%ZIP%'" || exit /b 1
  powershell -NoProfile -Command "Expand-Archive -Force -Path '%ZIP%' -DestinationPath '%CACHE_DIR%'" || exit /b 1
)
call "%BIN%" %*
