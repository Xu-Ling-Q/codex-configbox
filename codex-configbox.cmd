@echo off
setlocal
title Codex ConfigBox
set "PS_SCRIPT=%~dp0codex-configbox.ps1"
set "UI_URL=http://127.0.0.1:17855/"
set "NO_BROWSER="

for %%A in (%*) do (
  if /I "%%~A"=="-NoBrowser" set "NO_BROWSER=1"
)

if not exist "%PS_SCRIPT%" (
  echo ConfigBox script not found: "%PS_SCRIPT%"
  pause
  exit /b 1
)

rem Reuse an already healthy ConfigBox instead of starting a second listener.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { $s = Invoke-RestMethod -Uri '%UI_URL%api/status' -TimeoutSec 2; if ($s.ok) { exit 0 }; exit 1 } catch { exit 1 }"
if not errorlevel 1 (
  if not defined NO_BROWSER start "" "%UI_URL%"
  exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
if errorlevel 1 (
  echo.
  echo ConfigBox exited with an error. Review the message above.
  pause
  exit /b 1
)
