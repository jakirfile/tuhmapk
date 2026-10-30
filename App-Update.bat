@echo off
setlocal
wscript.exe "%~dp0App-Debug-Upload-Launcher.vbs" "%~dp0App-Update.ps1" "%~f0" "-FormMode"
exit /b %ERRORLEVEL%
