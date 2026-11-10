@echo off
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Patch.ps1" -Mode Install %*
set "PATCH_EXIT=%ERRORLEVEL%"
pause
exit /b %PATCH_EXIT%
