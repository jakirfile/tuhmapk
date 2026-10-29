@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
if errorlevel 1 (
    echo Could not open the AllApp project folder.
    goto fail
)

set "SDK=%ANDROID_SDK_ROOT%"
if not defined SDK set "SDK=%ANDROID_HOME%"
if not defined SDK set "SDK=%LOCALAPPDATA%\Android\Sdk"

set "ADB=%SDK%\platform-tools\adb.exe"
set "UNSIGNED_APK=%~dp0app\build\outputs\apk\release\app-release-unsigned.apk"
set "APK=%~dp0app\build\outputs\apk\release\app-release.apk"
set "DEBUG_KEYSTORE=%USERPROFILE%\.android\debug.keystore"
set "APP_PACKAGE="
for /f "delims=" %%P in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-ApplicationId.ps1"') do set "APP_PACKAGE=%%P"
if not defined APP_PACKAGE (
    echo Could not read the Android application ID from app\build.gradle.kts.
    goto fail
)
set "DEVICE_SERIAL=%ADB_SERIAL%"
set "ONLINE_DEVICE_COUNT=0"
set "INSTALL_RESTRICTED=0"
set "BUILD_ATTEMPT=1"

if not exist "%ADB%" (
    echo Android Debug Bridge was not found: "%ADB%"
    goto fail
)

for /f "skip=1 tokens=1,2" %%A in ('"%ADB%" devices') do (
    if "%%B"=="device" (
        set /a ONLINE_DEVICE_COUNT+=1
        if not defined DEVICE_SERIAL set "DEVICE_SERIAL=%%A"
    )
)

if not defined DEVICE_SERIAL (
    echo No authorized Android device is connected.
    "%ADB%" devices -l
    goto fail
)

set "DEVICE_STATE="
for /f "skip=1 tokens=1,2" %%A in ('"%ADB%" devices') do (
    if /I "%%A"=="!DEVICE_SERIAL!" set "DEVICE_STATE=%%B"
)
if /I not "!DEVICE_STATE!"=="device" (
    if defined DEVICE_STATE (
        echo Android device "%DEVICE_SERIAL%" is not available or authorized. State: !DEVICE_STATE!
    ) else (
        echo Android device "%DEVICE_SERIAL%" was not found in the current ADB device list.
    )
    "%ADB%" devices -l
    goto fail
)

echo Using Android device: %DEVICE_SERIAL%
if %ONLINE_DEVICE_COUNT% GTR 1 echo Multiple devices are connected. Set ADB_SERIAL to choose another device.

echo.
:buildRelease
echo Building the AllApp release APK (attempt !BUILD_ATTEMPT!)...
call "%~dp0gradlew.bat" :app:assembleRelease --console=plain
if not errorlevel 1 goto releaseBuildComplete
if "!BUILD_ATTEMPT!"=="2" (
    echo Release build failed after two attempts.
    goto fail
)
set "BUILD_ATTEMPT=2"
echo.
echo The first release build attempt failed. Retrying once in case Gradle's
echo release profile compilation failed transiently...
goto buildRelease

:releaseBuildComplete

if not exist "%UNSIGNED_APK%" (
    echo Release build completed, but the unsigned APK was not found:
    echo "%UNSIGNED_APK%"
    goto fail
)

if not exist "%DEBUG_KEYSTORE%" (
    echo The local Android debug keystore was not found:
    echo "%DEBUG_KEYSTORE%"
    echo Create a debug keystore or configure release signing before installing.
    goto fail
)

set "APKSIGNER="
for /f "delims=" %%D in ('dir /b /ad /o-n "%SDK%\build-tools" 2^>nul') do (
    if not defined APKSIGNER if exist "%SDK%\build-tools\%%D\apksigner.bat" set "APKSIGNER=%SDK%\build-tools\%%D\apksigner.bat"
)
if not defined APKSIGNER (
    echo Android SDK apksigner was not found under "%SDK%\build-tools".
    goto fail
)

if exist "%APK%" del /q "%APK%"
call "%APKSIGNER%" sign --ks "%DEBUG_KEYSTORE%" --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out "%APK%" "%UNSIGNED_APK%"
if errorlevel 1 (
    echo Could not sign the release APK with the local Android debug key.
    goto fail
)

call "%APKSIGNER%" verify "%APK%"
if errorlevel 1 (
    echo APK signature verification failed.
    goto fail
)

echo.
echo Installing "%APK%"...
"%ADB%" -s "%DEVICE_SERIAL%" shell pm list packages | findstr /I /X /C:"package:%APP_PACKAGE%" >nul
if errorlevel 1 (
    echo Package %APP_PACKAGE% is not installed. Installing fresh.
    set "INSTALL_LOG=!TEMP!\allapp-release-install-!RANDOM!-!RANDOM!.log"
    "!ADB!" -s "!DEVICE_SERIAL!" install "!APK!" >"!INSTALL_LOG!" 2>&1
    set "INSTALL_RESULT=!ERRORLEVEL!"
    type "!INSTALL_LOG!"
    if not "!INSTALL_RESULT!"=="0" (
        findstr /C:"INSTALL_FAILED_USER_RESTRICTED" "!INSTALL_LOG!" >nul
        if not errorlevel 1 set "INSTALL_RESTRICTED=1"
        del "!INSTALL_LOG!" >nul 2>nul
        goto installFailed
    )
    del "!INSTALL_LOG!" >nul 2>nul
) else (
    echo Package %APP_PACKAGE% is installed. Reinstalling and keeping app data.
    set "INSTALL_LOG=!TEMP!\allapp-release-install-!RANDOM!-!RANDOM!.log"
    "!ADB!" -s "!DEVICE_SERIAL!" install -r -d "!APK!" >"!INSTALL_LOG!" 2>&1
    set "INSTALL_RESULT=!ERRORLEVEL!"
    type "!INSTALL_LOG!"
    if "!INSTALL_RESULT!"=="0" goto success

    findstr /C:"INSTALL_FAILED_UPDATE_INCOMPATIBLE" "!INSTALL_LOG!" >nul
    if errorlevel 1 (
        findstr /C:"INSTALL_FAILED_USER_RESTRICTED" "!INSTALL_LOG!" >nul
        if not errorlevel 1 set "INSTALL_RESTRICTED=1"
        del "!INSTALL_LOG!" >nul 2>nul
        goto installFailed
    )

    echo.
    echo The installed app uses a different signing key.
    echo Uninstalling it will erase its local app data. Installing the release APK now.

    "%ADB%" -s "%DEVICE_SERIAL%" uninstall "%APP_PACKAGE%"
    if errorlevel 1 (
        del "!INSTALL_LOG!" >nul 2>nul
        goto installFailed
    )

    del "!INSTALL_LOG!" >nul 2>nul
    set "INSTALL_LOG=!TEMP!\allapp-release-install-!RANDOM!-!RANDOM!.log"
    "!ADB!" -s "!DEVICE_SERIAL!" install "!APK!" >"!INSTALL_LOG!" 2>&1
    set "INSTALL_RESULT=!ERRORLEVEL!"
    type "!INSTALL_LOG!"
    if not "!INSTALL_RESULT!"=="0" (
        findstr /C:"INSTALL_FAILED_USER_RESTRICTED" "!INSTALL_LOG!" >nul
        if not errorlevel 1 set "INSTALL_RESTRICTED=1"
        del "!INSTALL_LOG!" >nul 2>nul
        goto installFailed
    )
    del "!INSTALL_LOG!" >nul 2>nul
)

:success
echo.
echo Starting AllApp...
"%ADB%" -s "%DEVICE_SERIAL%" shell monkey -p "%APP_PACKAGE%" 1
if errorlevel 1 goto launchFailed
echo Release APK was built, signed, installed, and launched successfully.
echo APK: "%APK%"
exit /b 0

:launchFailed
echo The release APK was installed, but AllApp could not be launched.
echo APK: "%APK%"
goto fail

:installFailed
if "%INSTALL_RESTRICTED%"=="1" (
    echo.
    echo Android cancelled the installation because it is restricted on the device.
    echo Keep the phone unlocked and approve the install prompt if it appears.
    echo On Xiaomi, enable Install via USB in Developer options and allow USB installs in Security settings.
    echo A work-managed or parental-control policy may also block this installation.
)
echo Installation failed. Check the connected device and APK signing key.

:fail
echo.
echo The script is waiting here so the error above remains visible.
echo Press any key to close this window.
pause
exit /b 1