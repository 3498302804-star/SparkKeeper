@echo off
setlocal
chcp 65001 >nul 2>&1

rem =====================================================================
rem  One-click: push SparkKeeper to GitHub, build IPA in Actions, download.
rem  Usage:  build.bat ghp_xxxxxxxxxxxxxxxx
rem =====================================================================

set "PS1=%~dp0push_and_build.ps1"

if not exist "%PS1%" (
  echo [ERROR] push_and_build.ps1 not found next to this file.
  pause
  exit /b 1
)

if "%~1"=="" (
  echo.
  echo   Usage:  build.bat YOUR_GITHUB_TOKEN
  echo.
  echo   Token:  GitHub - Settings - Developer settings - Personal access tokens
  echo           - Tokens ^(classic^) - Generate new token - check [repo] + [workflow]
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Token %*

echo.
if errorlevel 1 (
  echo [FAILED] see the messages above.
) else (
  echo [DONE] unsigned IPA is in the out\ folder.
)
pause
