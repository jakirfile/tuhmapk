@echo off
setlocal
set "PROJECT_FOLDER=%~dp0"
cd /d "%TEMP%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_FOLDER%Kill-Activity.ps1"
set "RESULT=%ERRORLEVEL%"
echo.
echo This window will close automatically in 12 seconds.
timeout /t 12 /nobreak >nul
exit %RESULT%
