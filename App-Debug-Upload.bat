@echo off
setlocal EnableExtensions EnableDelayedExpansion
pushd "%~dp0"
if errorlevel 1 (
    echo Could not open the AllApp project folder.
    echo Closing in 3 seconds...
    timeout /t 3 /nobreak >nul
    exit /b 1
)

set "SOURCE=%CD%"
set "REPO_URL=https://github.com/jakirfile/allapp.git"
set "REPO_SLUG=jakirfile/allapp"
set "REPO_OWNER=jakirfile"
set "REPO_NAME=allapp"
set "BRANCH=main"
set "GIT_PAGER=cat"
set "WORK=%TEMP%\allapp-jakirfile-upload-%RANDOM%-%RANDOM%"
set "UPLOAD_DIRECTORY=."
set "REPO_CONFIG=%LOCALAPPDATA%\AllApp\App-Debug-Upload.repository"
if exist "%REPO_CONFIG%" set /p "REPO_URL="<"%REPO_CONFIG%"
set "MANIFEST=%SOURCE%\update.json"
set "APK=%SOURCE%\app\build\outputs\apk\debug\app-debug.apk"
set "APK_METADATA=%SOURCE%\app\build\outputs\apk\debug\output-metadata.json"
set "INDEX=%SOURCE%\index.html"
set "QR=%SOURCE%\qr.png"

echo.
echo Using the existing debug APK; no new build will be started.
echo App details and files to upload:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SOURCE%\Show-App-Debug-Upload-Preview.ps1" -ApkPath "%APK%" -ApkMetadataPath "%APK_METADATA%" -StringsPath "%SOURCE%\app\src\main\res\values\strings.xml" -ManifestPath "%MANIFEST%" -IndexPath "%INDEX%" -QrPath "%QR%" -UploadDirectory "."
if errorlevel 1 (
    echo Could not read the existing APK upload details. Nothing was uploaded.
    goto fail
)

:chooseDirectory
echo.
echo GitHub repository: %REPO_URL%
echo 1. Use this repository (repository root)
echo 2. Change and remember GitHub repository
echo 3. Upload to a directory in this repository
echo 4. Show upload list only
set "DIRECTORY_CHOICE="
set /p "DIRECTORY_CHOICE=Choose 1, 2, 3, or 4: "
if "%DIRECTORY_CHOICE%"=="1" (
    set "UPLOAD_DIRECTORY=."
    set "REPO_INPUT=%REPO_URL%"
) else if "%DIRECTORY_CHOICE%"=="2" (
    set "REPO_INPUT="
    set /p "REPO_INPUT=Enter GitHub repository URL: "
    if not defined REPO_INPUT (
        echo A GitHub repository URL is required.
        goto fail
    )
    set "UPLOAD_DIRECTORY=."
) else if "%DIRECTORY_CHOICE%"=="3" (
    set "UPLOAD_DIRECTORY="
    set /p "UPLOAD_DIRECTORY=Enter a relative directory inside %REPO_SLUG%: "
    if not defined UPLOAD_DIRECTORY (
        echo A directory is required. Choose option 1 for the repository root.
        goto fail
    )
    set "REPO_INPUT=%REPO_URL%"
    set "DIRECTORY_CHOICE=3"
    goto normalizeDestination
) else if "%DIRECTORY_CHOICE%"=="4" (
    set "REPO_INPUT=%REPO_URL%"
    set "UPLOAD_DIRECTORY=."
) else (
    echo Invalid choice. Select 1, 2, 3, or 4.
    goto fail
)

:normalizeDestination
set "NORMALIZED_UPLOAD_DIRECTORY="
set "UPLOAD_URL_DIRECTORY="
set "NORMALIZED_REPO_SLUG="
set "NORMALIZED_REPO_OWNER="
set "NORMALIZED_REPO_NAME="
set "DESTINATION_RESULT=%TEMP%\allapp-upload-destination-%RANDOM%-%RANDOM%.txt"
set "APP_UPLOAD_REPOSITORY_URL=%REPO_INPUT%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SOURCE%\Set-App-Upload-Directory.ps1" -ProjectRoot "%SOURCE%" -SaveRepositoryPreference -ResultPath "%DESTINATION_RESULT%"
set "NORMALIZE_RESULT=!ERRORLEVEL!"
if not "!NORMALIZE_RESULT!"=="0" (
    set "APP_UPLOAD_REPOSITORY_URL="
    if exist "%DESTINATION_RESULT%" del /F /Q "%DESTINATION_RESULT%" >nul 2>nul
    echo Could not validate or save the selected repository and directory.
    goto fail
)
if not exist "%DESTINATION_RESULT%" (
    set "APP_UPLOAD_REPOSITORY_URL="
    echo Could not read the selected repository and directory.
    goto fail
)
for /f "usebackq tokens=1,2,3,4,5 delims=|" %%D in ("%DESTINATION_RESULT%") do (
    set "NORMALIZED_UPLOAD_DIRECTORY=%%D"
    set "UPLOAD_URL_DIRECTORY=%%E"
    set "NORMALIZED_REPO_SLUG=%%F"
    set "NORMALIZED_REPO_OWNER=%%G"
    set "NORMALIZED_REPO_NAME=%%H"
)
del /F /Q "%DESTINATION_RESULT%" >nul 2>nul
set "APP_UPLOAD_REPOSITORY_URL="
if not defined NORMALIZED_REPO_NAME (
    echo Invalid destination. Use a GitHub URL such as https://github.com/jakirfile/allapp.git.
    echo Directory paths must be relative, for example releases or releases\debug.
    goto fail
)
set "UPLOAD_DIRECTORY=%NORMALIZED_UPLOAD_DIRECTORY%"
set "REPO_SLUG=%NORMALIZED_REPO_SLUG%"
set "REPO_OWNER=%NORMALIZED_REPO_OWNER%"
set "REPO_NAME=%NORMALIZED_REPO_NAME%"
set "REPO_URL=https://github.com/%REPO_SLUG%.git"
set "REPO_PAGE=https://github.com/%REPO_SLUG%"
set "PAGES_URL=https://%REPO_OWNER%.github.io/%REPO_NAME%"
if "%UPLOAD_DIRECTORY%"=="." set "UPLOAD_URL_DIRECTORY="

set "UPLOAD_PATH=%UPLOAD_DIRECTORY:/=\%"
set "RAW_DIRECTORY=https://raw.githubusercontent.com/%REPO_SLUG%/%BRANCH%"
set "GITHUB_DIRECTORY=%REPO_PAGE%/tree/%BRANCH%"
set "PAGES_DIRECTORY=%PAGES_URL%"
if not "%UPLOAD_DIRECTORY%"=="." (
    set "RAW_DIRECTORY=%RAW_DIRECTORY%/%UPLOAD_URL_DIRECTORY%"
    set "GITHUB_DIRECTORY=%GITHUB_DIRECTORY%/%UPLOAD_URL_DIRECTORY%"
    set "PAGES_DIRECTORY=%PAGES_DIRECTORY%/%UPLOAD_URL_DIRECTORY%"
)
set "MANIFEST_URL=%RAW_DIRECTORY%/update.json"
set "RAW_APK_URL=%RAW_DIRECTORY%/app-debug.apk"

echo.
echo Using the existing debug APK; no new build will be started.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SOURCE%\Show-App-Debug-Upload-Preview.ps1" -ApkPath "%APK%" -ApkMetadataPath "%APK_METADATA%" -StringsPath "%SOURCE%\app\src\main\res\values\strings.xml" -ManifestPath "%MANIFEST%" -IndexPath "%INDEX%" -QrPath "%QR%" -UploadDirectory "%UPLOAD_DIRECTORY%"
if errorlevel 1 (
    echo Could not read the existing APK upload details. Nothing was uploaded.
    goto fail
)

if "%DIRECTORY_CHOICE%"=="4" (
    echo.
    echo Upload list shown. No upload was started.
    goto chooseDirectory
)

echo.
echo Upload destination:
echo   Repository: %REPO_PAGE%
if "%UPLOAD_DIRECTORY%"=="." (
    echo   Directory: repository root
) else (
    echo   Directory: %UPLOAD_DIRECTORY%
)
echo   GitHub folder: %GITHUB_DIRECTORY%
echo   Update manifest: %MANIFEST_URL%
echo   Download page: %PAGES_DIRECTORY%
if not "%UPLOAD_DIRECTORY%"=="." (
    echo WARNING: The existing APK keeps the update-manifest URL it was built with; changing the upload directory does not change that APK.
)
if /I not "%REPO_SLUG%"=="jakirfile/allapp" (
    echo WARNING: This existing APK still checks its previously embedded update URL. Uploading here does not change that APK.
)
echo WARNING: The whole repository will be replaced; only the selected directory will contain the upload files.
echo If the repository is missing, it will be created as a public repository and uploaded.
echo.
set "CONFIRM="
set /p "CONFIRM=Upload the existing APK and files listed above to this location? [y/N]: "
if /I not "%CONFIRM%"=="Y" (
    echo Upload canceled. No GitHub changes made.
    popd
    exit /b 0
)

where git >nul 2>nul
if errorlevel 1 (
    echo Git was not found. Install Git for Windows and try again.
    goto fail
)
git config --global user.name >nul 2>nul
if errorlevel 1 (
    echo Git author name is not configured.
    goto fail
)
git config --global user.email >nul 2>nul
if errorlevel 1 (
    echo Git author email is not configured.
    goto fail
)

echo.
echo Cloning %REPO_URL% ...
set "GCM_INTERACTIVE=always"
git -c credential.helper=manager -c credential.interactive=always clone "%REPO_URL%" "%WORK%"
set "GIT_RESULT=!ERRORLEVEL!"
set "GCM_INTERACTIVE="
if not "!GIT_RESULT!"=="0" (
    echo Repository clone failed. Checking whether the repository is missing...
    where gh >nul 2>nul
    if errorlevel 1 (
        echo GitHub CLI was not found. Opening GitHub repository creation page...
        echo Sign in with an account allowed to create repositories under %REPO_OWNER%.
        echo Create a PUBLIC repository named %REPO_NAME% under owner %REPO_OWNER%.
        start "" "https://github.com/new"
        set "CREATE_REPO_CONFIRM="
        set /p "CREATE_REPO_CONFIRM=After creating %REPO_SLUG%, enter Y to continue upload: "
        if /I not "!CREATE_REPO_CONFIRM!"=="Y" (
            echo Repository creation was not confirmed. Upload canceled.
            goto fail
        )
    ) else (
        gh auth status >nul 2>nul
        if errorlevel 1 (
            echo GitHub CLI is not signed in. Starting GitHub sign-in...
            gh auth login
            if errorlevel 1 (
                echo GitHub sign-in failed. No repository was created.
                goto fail
            )
        )
        gh repo view %REPO_SLUG% >nul 2>nul
        if not errorlevel 1 (
            echo Repository exists, but clone failed. Verify GitHub access and try again.
            goto fail
        )

        echo Repository %REPO_SLUG% was not found.
        echo Creating public repository %REPO_SLUG%...
        gh repo create %REPO_SLUG% --public
        if errorlevel 1 (
            echo Could not create %REPO_SLUG%. Check GitHub account permissions and whether the repository name is available.
            goto fail
        )
    )

    echo.
    echo Cloning the new repository...
    if exist "%WORK%" rmdir /S /Q "%WORK%"
    set "GCM_INTERACTIVE=always"
    git -c credential.helper=manager -c credential.interactive=always clone "%REPO_URL%" "%WORK%"
    set "GIT_RESULT=!ERRORLEVEL!"
    set "GCM_INTERACTIVE="
    if not "!GIT_RESULT!"=="0" (
        echo Repository creation is confirmed, but clone failed. Verify repository owner and GitHub write access.
        goto fail
    )
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SOURCE%\Set-App-Upload-Directory.ps1" -ProjectRoot "%SOURCE%" -RepositoryUrl "%REPO_URL%" -Apply >nul
if errorlevel 1 (
    echo Could not configure the app, download page, and QR code for the selected destination.
    goto fail
)

git -C "%WORK%" checkout -B %BRANCH% >nul 2>nul
git -C "%WORK%" rev-parse --verify origin/%BRANCH% >nul 2>nul
if not errorlevel 1 git -C "%WORK%" reset --hard origin/%BRANCH% >nul

echo.
echo Replacing the entire repository with a fresh app upload...
for /f "delims=" %%I in ('dir /b /a "%WORK%"') do (
    if /I not "%%I"==".git" (
        if exist "%WORK%\%%I\*" (rmdir /S /Q "%WORK%\%%I") else (del /F /Q "%WORK%\%%I")
    )
)

rem Clear the index so the new lower-case file names are used
git -C "%WORK%" rm -r -q --cached --ignore-unmatch . >nul 2>nul

set "STAGE=%WORK%\%UPLOAD_PATH%"
if not exist "%STAGE%" mkdir "%STAGE%" || goto copyFailed
copy /Y "%MANIFEST%" "%STAGE%\update.json" >nul || goto copyFailed
copy /Y "%APK%"      "%STAGE%\app-debug.apk" >nul || goto copyFailed
copy /Y "%INDEX%"    "%STAGE%\index.html" >nul || goto copyFailed
copy /Y "%QR%"       "%STAGE%\qr.png" >nul || goto copyFailed

rem Check APK version, create a content-addressed URL to bypass GitHub raw CDN path caches, and write its checksum.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SOURCE%\Prepare-App-Debug-Upload.ps1" -TargetDirectory "%STAGE%" -ManifestPath "%MANIFEST%" -ApkPath "%APK%" -ApkMetadataPath "%APK_METADATA%" -StringsPath "%SOURCE%\app\src\main\res\values\strings.xml" -IndexPath "%INDEX%" -RawApkUrl "%RAW_APK_URL%"
if errorlevel 1 (
    echo Version check or update.json preparation failed. Nothing was uploaded.
    goto failKeepWork
)

git -C "%WORK%" add -A
if errorlevel 1 goto failKeepWork

git -C "%WORK%" diff --cached --quiet
if not errorlevel 1 (
    echo No file content changed. Creating a fresh upload commit anyway...
)

echo.
echo Fresh upload contents:
git --no-pager -C "%WORK%" diff --cached --stat

git -C "%WORK%" commit --allow-empty -q -m "Fresh upload of AllApp app-debug.apk, update.json, index.html, qr.png"
if errorlevel 1 (
    echo Commit failed.
    goto failKeepWork
)

echo.
echo Uploading to GitHub...
set "GCM_INTERACTIVE=always"
git -c credential.helper=manager -c credential.interactive=always -C "%WORK%" push -u origin %BRANCH%
set "GIT_RESULT=!ERRORLEVEL!"
set "GCM_INTERACTIVE="
if not "!GIT_RESULT!"=="0" (
    echo Upload failed. Verify GitHub sign-in and write access to %REPO_SLUG%.
    goto failKeepWork
)

echo.
echo Done. Uploaded update.json, APK files, index.html, qr.png to:
echo   %GITHUB_DIRECTORY%
if "%UPLOAD_DIRECTORY%"=="." (
    echo   Directory: repository root
) else (
    echo   Directory: %UPLOAD_DIRECTORY%
)
echo Download page: %PAGES_DIRECTORY%
echo.
echo The Android app checks for updates here: %MANIFEST_URL%
goto success

:copyFailed
echo Could not copy the four upload files.
goto failKeepWork

:fail
if exist "%WORK%" rmdir /S /Q "%WORK%"
popd
echo.
echo Closing in 3 seconds...
timeout /t 3 /nobreak >nul
exit /b 1

:failKeepWork
echo Upload staging copy kept for inspection:
echo %WORK%
popd
echo.
echo Closing in 3 seconds...
timeout /t 3 /nobreak >nul
exit /b 1

:success
if exist "%WORK%" rmdir /S /Q "%WORK%"
popd
echo.
echo Closing in 3 seconds...
timeout /t 3 /nobreak >nul
exit 0
