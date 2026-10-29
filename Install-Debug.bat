@echo off
setlocal EnableExtensions EnableDelayedExpansion
pushd "%~dp0"
if errorlevel 1 (
    echo Could not open the AllApp project folder.
    pause
    exit /b 1
)

set "SDK=%ANDROID_SDK_ROOT%"
if not defined SDK set "SDK=%ANDROID_HOME%"
if not defined SDK set "SDK=%LOCALAPPDATA%\Android\Sdk"
set "ADB=%SDK%\platform-tools\adb.exe"
set "APK=%~dp0app\build\outputs\apk\debug\app-debug.apk"
set "APP_PACKAGE="
set "VERSION_NAME="
set "VERSION_CODE="
set "APP_NAME="
if not exist "%APK%" (
    echo Debug APK was not found: "%APK%"
    echo Build it first, or copy app-debug.apk to the expected output path.
    popd
    pause
    exit /b 1
)
if not exist "%~dp0app\build\outputs\apk\debug\output-metadata.json" (
    echo APK build metadata was not found. Cannot safely show APK details.
    popd
    pause
    exit /b 1
)
for /f "tokens=1-4 delims=|" %%A in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-Debug-Apk-Info.ps1" -MetadataPath "%~dp0app\build\outputs\apk\debug\output-metadata.json" -StringsPath "%~dp0app\src\main\res\values\strings.xml"') do (
    set "APP_PACKAGE=%%A"
    set "VERSION_NAME=%%B"
    set "VERSION_CODE=%%C"
    set "APP_NAME=%%D"
)
if not defined APP_PACKAGE (
    echo Could not read package name, version, and app name for the existing debug APK.
    popd
    pause
    exit /b 1
)
set "DEVICE_SERIAL=%ADB_SERIAL%"
set "DEVICE_COUNT=0"

echo Using the latest existing debug build. No new build will be started.
echo Installing APK directly with ADB:
echo "%APK%"
echo.
echo App Name: %APP_NAME%
echo Package Name: %APP_PACKAGE%
echo Version Name: %VERSION_NAME%
echo Version Code: %VERSION_CODE%
echo.
if exist "%ADB%" (
    echo Android devices detected by ADB:
    "%ADB%" devices -l
) else (
    echo Android Debug Bridge was not found, so connected devices cannot be listed.
)
echo.
set "INSTALL_CONFIRM="
set /p "INSTALL_CONFIRM=Press Y to install and run this app, or any other key to cancel: "
if /I not "!INSTALL_CONFIRM!"=="Y" (
    echo Installation canceled. No changes were made to the device.
    popd
    exit /b 0
)

if not exist "%ADB%" (
    echo.
    echo Android Debug Bridge was not found: "%ADB%"
    echo Set ANDROID_SDK_ROOT or install Android SDK platform-tools.
    popd
    pause
    exit /b 1
)

if defined DEVICE_SERIAL (
    set "DEVICE_STATE="
    for /f "delims=" %%S in ('"%ADB%" -s "%DEVICE_SERIAL%" get-state 2^>nul') do set "DEVICE_STATE=%%S"
    if /I not "!DEVICE_STATE!"=="device" (
        echo.
        echo ADB_SERIAL "%DEVICE_SERIAL%" is not an authorized, connected device.
        echo Connect the device, enable USB debugging, and accept the authorization prompt.
        "%ADB%" devices -l
        popd
        pause
        exit /b 1
    )
) else (
    for /f "skip=1 tokens=1,2" %%A in ('"%ADB%" devices') do (
        if "%%B"=="device" (
            set /a DEVICE_COUNT+=1
            set "DEVICE_SERIAL=%%A"
        )
    )
    if !DEVICE_COUNT! EQU 0 (
        echo.
        echo No authorized Android device is connected.
        echo Connect the device, enable USB debugging, accept the authorization prompt, and run this script again.
        "%ADB%" devices -l
        popd
        pause
        exit /b 1
    )
    if !DEVICE_COUNT! GTR 1 (
        echo.
        echo Multiple Android devices are connected. Set ADB_SERIAL to the device serial and retry.
        "%ADB%" devices -l
        popd
        pause
        exit /b 1
    )
)

echo Device: %DEVICE_SERIAL%
echo.
:installAttempt
echo Installing or replacing %APP_PACKAGE% and preserving existing app data...
"%ADB%" -s "%DEVICE_SERIAL%" install -r -d "%APK%"
if not errorlevel 1 goto installSucceeded

:installFailed
echo.
echo ADB installation failed.
echo A different signing key can prevent replacing the existing app.
echo 1. Retry installation
echo 2. Close
set "RETRY_CHOICE="
set /p "RETRY_CHOICE=Choose 1 or 2: "
if "!RETRY_CHOICE!"=="1" goto installAttempt
if "!RETRY_CHOICE!"=="2" (
    popd
    exit /b 1
)
echo Invalid choice. Enter 1 to retry or 2 to close.
goto installFailed

:installSucceeded
echo.
echo APK installed successfully. Launching AllApp...
"%ADB%" -s "%DEVICE_SERIAL%" shell monkey -p "%APP_PACKAGE%" 1
if errorlevel 1 (
    echo.
    echo The APK was installed, but AllApp could not be launched.
    popd
    pause
    exit /b 1
)
echo AllApp was installed and launched successfully.
popd
exit /b 0
