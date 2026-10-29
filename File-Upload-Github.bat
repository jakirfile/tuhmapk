@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
pushd "%~dp0"
if errorlevel 1 (
    echo Could not open the AllApp project folder.
    timeout /t 10 >nul
    exit /b 1
)

set "SOURCE=%CD%"
set "REPO_CONFIG=%LOCALAPPDATA%\AllApp\File-Upload-Github.repository"
set "REPO_URL=https://github.com/jakirfile/AllApp-Android-Source.git"
if exist "%REPO_CONFIG%" set /p "REPO_URL="<"%REPO_CONFIG%"
if defined REPO_URL (
    echo.
    echo Last uploaded GitHub link: %REPO_URL%
    echo 1. Upload to this previous link
    echo 2. Enter a new GitHub link
    set "DESTINATION_CHOICE="
    set /p "DESTINATION_CHOICE=Choose 1 or 2: "
    if "!DESTINATION_CHOICE!"=="1" goto destinationReady
    if not "!DESTINATION_CHOICE!"=="2" (
        echo Invalid choice. Enter 1 or 2.
        goto fail
    )
)

:newDestination
echo.
set "REPO_INPUT="
set /p "REPO_INPUT=Enter a GitHub repository link (e.g. https://github.com/owner/repo): "
if not defined REPO_INPUT (
    echo A GitHub repository link is required.
    goto fail
)
if /I "%REPO_INPUT:~0,19%"=="https://github.com/" (
    set "REPO_SLUG=%REPO_INPUT:https://github.com/=%"
) else if /I "%REPO_INPUT:~0,18%"=="http://github.com/" (
    set "REPO_SLUG=%REPO_INPUT:http://github.com/=%"
) else (
    echo Use a GitHub link in the format github.com/owner/repo.
    goto fail
)
if "%REPO_SLUG:~0,1%"=="/" set "REPO_SLUG=%REPO_SLUG:~1%"
if "%REPO_SLUG:~-4%"==".git" set "REPO_SLUG=%REPO_SLUG:~0,-4%"
set "REPO_OWNER="
set "REPO_NAME="
set "REPO_EXTRA="
for /f "tokens=1,2,3 delims=/" %%A in ("%REPO_SLUG%") do (
    set "REPO_OWNER=%%A"
    set "REPO_NAME=%%B"
    set "REPO_EXTRA=%%C"
)
if not defined REPO_OWNER (
    echo Could not find the owner and repository in the GitHub link.
    goto fail
)
if not defined REPO_NAME (
    echo Could not find the repository name in the GitHub link.
    goto fail
)
if defined REPO_EXTRA (
    echo Enter a repository link only; additional paths are not allowed.
    goto fail
)
set "REPO_SLUG=%REPO_OWNER%/%REPO_NAME%"
set "REPO_URL=https://github.com/%REPO_SLUG%.git"

:destinationReady
for /f "tokens=1,2 delims=/" %%A in ("%REPO_URL:https://github.com/=%") do (
    set "REPO_OWNER=%%A"
    set "REPO_NAME=%%B"
)
if "%REPO_NAME:~-4%"==".git" set "REPO_NAME=%REPO_NAME:~0,-4%"
set "REPO_SLUG=%REPO_OWNER%/%REPO_NAME%"
set "REPO_URL=https://github.com/%REPO_SLUG%.git"
set "REPO_PAGE=https://github.com/%REPO_SLUG%"
set "BRANCH=main"
set "GIT_PAGER=cat"
set "WORK=%TEMP%\AllApp-Android-Source-upload-%RANDOM%-%RANDOM%"

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

rem Stop Gradle daemons so files in .gradle / build are not locked.
if exist "%SOURCE%\gradlew.bat" call "%SOURCE%\gradlew.bat" --stop >nul 2>nul

echo.
echo Cloning %REPO_URL% ...
set "GCM_INTERACTIVE=always"
git -c credential.helper=manager -c credential.interactive=always clone "%REPO_URL%" "%WORK%"
set "GIT_RESULT=%ERRORLEVEL%"
set "GCM_INTERACTIVE="
if not "%GIT_RESULT%"=="0" (
    echo Clone failed. Checking GitHub access...
    where gh >nul 2>nul
    if errorlevel 1 (
        echo GitHub CLI was not found. Sign in to GitHub and create the repository:
        echo https://github.com/new
        start "" "https://github.com/new"
        set "CREATE_REPO_CONFIRM="
        set /p "CREATE_REPO_CONFIRM=After creating %REPO_SLUG%, enter Y to continue: "
        if /I not "!CREATE_REPO_CONFIRM!"=="Y" goto fail
    ) else (
        gh auth status >nul 2>nul
        if errorlevel 1 (
            echo Starting GitHub sign-in...
            gh auth login
            if errorlevel 1 (
                echo GitHub sign-in failed.
                goto fail
            )
        )
        gh repo view "%REPO_SLUG%" >nul 2>nul
        if not errorlevel 1 (
            echo The repository exists, but cloning failed. Check your GitHub sign-in and write access.
            goto fail
        )
        echo Repository was not found. Creating public repository on GitHub: %REPO_SLUG%
        gh repo create "%REPO_SLUG%" --public
        if errorlevel 1 (
            echo Repository could not be created. Check owner access and the repository name.
            goto fail
        )
    )
    echo.
    echo Cloning the new repository...
    set "GCM_INTERACTIVE=always"
    git -c credential.helper=manager -c credential.interactive=always clone "%REPO_URL%" "%WORK%"
    set "GIT_RESULT=%ERRORLEVEL%"
    set "GCM_INTERACTIVE="
    if not "%GIT_RESULT%"=="0" (
        echo The repository was created, but cloning failed. Check your GitHub write access.
        goto fail
    )
)

rem Upload files byte-for-byte, no line-ending changes, long paths allowed.
git -C "%WORK%" config core.autocrlf false
git -C "%WORK%" config core.safecrlf false
git -C "%WORK%" config core.longpaths true

git -C "%WORK%" show-ref --verify --quiet refs/remotes/origin/%BRANCH%
if errorlevel 1 (
    git -C "%WORK%" rev-parse --verify HEAD >nul 2>nul
    if errorlevel 1 (
        git -C "%WORK%" symbolic-ref HEAD refs/heads/%BRANCH%
    ) else (
        git -C "%WORK%" switch -C %BRANCH%
    )
) else (
    git -C "%WORK%" switch -C %BRANCH% --track origin/%BRANCH%
)
if errorlevel 1 (
    echo Could not prepare the %BRANCH% branch.
    goto fail
)

echo.
echo Copying ALL files from %SOURCE% ...
rem /MIR makes the upload copy an exact mirror (files removed locally are removed on GitHub too).
rem /XD excludes only the two .git metadata folders (source and the upload copy's own).
robocopy "%SOURCE%" "%WORK%" /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:2 /NFL /NDL /NP ^
    /XD .git
if errorlevel 8 (
    echo Some files could not be copied ^(maybe locked by Android Studio^).
    echo Close Android Studio / running builds and try again. Nothing was pushed.
    goto fail
)

echo.
echo Staging every file ^(ignoring .gitignore^) ...
git -C "%WORK%" add -A -f -- .
if errorlevel 1 (
    echo Could not stage files.
    goto fail
)

rem Allow an empty commit so every click creates and pushes a fresh upload.
git -C "%WORK%" commit --allow-empty -q -m "Fresh upload of AllApp-Android-Source"
if errorlevel 1 (
    echo Commit failed.
    goto fail
)

echo.
echo Pushing everything to GitHub ...
set "GCM_INTERACTIVE=always"
git -c credential.helper=manager -c credential.interactive=always -c http.postBuffer=524288000 -C "%WORK%" push origin "HEAD:refs/heads/%BRANCH%"
set "GIT_RESULT=%ERRORLEVEL%"
set "GCM_INTERACTIVE="
if not "%GIT_RESULT%"=="0" (
    echo Push failed. Check sign-in, write access, or a file over GitHub's 100 MB limit.
    echo Upload copy kept here: %WORK%
    goto failKeep
)

echo.
echo Upload complete: %REPO_PAGE%
if not exist "%LOCALAPPDATA%\AllApp" mkdir "%LOCALAPPDATA%\AllApp" >nul 2>nul
>"%REPO_CONFIG%" echo %REPO_URL%
if errorlevel 1 (
    echo Warning: Upload succeeded, but the latest link could not be saved.
) else (
    echo Last uploaded link: %REPO_PAGE%
    echo This link will be shown the next time you run this script.
)
goto success

:fail
if exist "%WORK%" rmdir /S /Q "%WORK%" >nul 2>nul
:failKeep
echo.
echo Upload did NOT complete. This window closes in 10 seconds...
popd
timeout /t 10 >nul
exit /b 1

:success
if exist "%WORK%" rmdir /S /Q "%WORK%" >nul 2>nul
popd
echo.
echo This window closes in 3 seconds...
timeout /t 3 >nul
exit /b 0
