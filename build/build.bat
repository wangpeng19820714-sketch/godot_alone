@echo off

if /I not "%OS%"=="Windows_NT" (
  echo This script only supports Windows_NT.
  exit /b 1
)

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" -Target template_release -Jobs 12 -SConsOptions d3d12=no %*
if errorlevel 1 pause
