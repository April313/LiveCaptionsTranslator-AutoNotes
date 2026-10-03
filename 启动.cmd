@echo off
rem ============================================================
rem  LiveCaptions Translator + Auto Notes  launcher
rem  Keep this file ASCII-only: cmd.exe code pages vary.
rem  Real logic lives in launch.ps1 (UTF-8, Chinese messages).
rem ============================================================
setlocal
cd /d "%~dp0"

set "PS=powershell.exe"
where pwsh.exe >nul 2>nul && set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" %*
if errorlevel 1 (
  echo.
  echo [!] Launch failed. Re-run in a visible window to see why:
  echo     powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Wait
  echo.
  pause
)
endlocal
