@echo off
setlocal
cd /d "%~dp0"
if errorlevel 1 (
    echo Could not open the AllApp project folder.
    pause
    exit /b 1
)

echo Cleaning and rebuilding the latest AllApp source...
call "%~dp0gradlew.bat" clean :app:assembleDebug -PskipInstallAndRun=true --no-configuration-cache
if errorlevel 1 (
    echo Build or unit tests failed.
    pause
    exit /b 1
)

set "APK=%~dp0app\build\outputs\apk\debug\app-debug.apk"
if not exist "%APK%" (
    echo Build completed, but the debug APK was not found:
    echo "%APK%"
    pause
    exit /b 1
)

echo.
echo Installing and launching the rebuilt AllApp app...
call "%~dp0Install-Debug-Run.bat"
if errorlevel 1 (
    echo The APK was rebuilt, but installation or launch failed.
    pause
    exit /b 1
)

exit /b 0
