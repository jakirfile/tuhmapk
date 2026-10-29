@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
for %%I in ("%~dp0.") do set "MAIN_FOLDER=%%~fI"
set "DESTINATION_PATH="
echo Main folder: !MAIN_FOLDER!
set /p "DESTINATION_PATH=Enter the full destination path for the main folder: "
if not defined DESTINATION_PATH (
    echo A full destination path is required.
    pause
    exit /b 1
)
if "!DESTINATION_PATH:~1,2!"==":\" if "!DESTINATION_PATH:~3!"=="" (
    echo A drive root cannot be used as the destination folder.
    pause
    exit /b 1
)
:trimDestinationPath
if "!DESTINATION_PATH:~-1!"=="\" (
    set "DESTINATION_PATH=!DESTINATION_PATH:~0,-1!"
    goto trimDestinationPath
)

echo.
echo Main folder will be moved/renamed to:
echo !DESTINATION_PATH!
echo 1. Close the folder window and rename now
echo 2. Cancel
set "RENAME_CHOICE="
set /p "RENAME_CHOICE=Press 1 to rename now or 2 to cancel: "
if "!RENAME_CHOICE!"=="2" (
    echo Rename canceled. No changes were made.
    exit /b 0
)
if not "!RENAME_CHOICE!"=="1" (
    echo Invalid choice. Press 1 to rename or 2 to cancel.
    pause
    exit /b 1
)

cd /d "%TEMP%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Rename-Main-Folder.ps1" -RootPath "!MAIN_FOLDER!" -DestinationPath "!DESTINATION_PATH!"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
    echo Could not start the folder rename.
    pause
    exit /b %RESULT%
)
exit /b 0
