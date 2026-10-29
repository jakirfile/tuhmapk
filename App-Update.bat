@echo off
setlocal
pushd "%~dp0"
if errorlevel 1 (
    echo Could not open the AllApp project folder.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0App-Update.ps1"
set "RESULT=%ERRORLEVEL%"
popd
if not "%RESULT%"=="0" (
    echo Version update did not complete.
    pause
)
exit /b %RESULT%
