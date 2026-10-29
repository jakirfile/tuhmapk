@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul

set "REPO_CONFIG=%LOCALAPPDATA%\AllApp\Delete-Repo.repository"
set "REPO_URL=https://github.com/jakirfile/AllApp-Android-Source.git"
if exist "%REPO_CONFIG%" set /p "REPO_URL="<"%REPO_CONFIG%"
echo.
echo Last GitHub repository selected for deletion: %REPO_URL%
echo 1. Keep this repository
echo 2. Enter a new GitHub repository link
set "DESTINATION_CHOICE="
set /p "DESTINATION_CHOICE=Choose 1 or 2: "
if "!DESTINATION_CHOICE!"=="1" goto destinationReady
if "!DESTINATION_CHOICE!"=="2" goto newDestination
echo Invalid choice. Enter 1 or 2.
goto failed

:newDestination
echo.
set "REPO_INPUT="
set /p "REPO_INPUT=Enter a GitHub repository link (e.g. https://github.com/owner/repo): "
if not defined REPO_INPUT (
  echo A GitHub repository link is required.
  goto failed
)
if /I "!REPO_INPUT:~0,19!"=="https://github.com/" (
  set "REPO_SLUG=!REPO_INPUT:~19!"
) else if /I "!REPO_INPUT:~0,18!"=="http://github.com/" (
  set "REPO_SLUG=!REPO_INPUT:~18!"
) else (
  echo Use a GitHub link in the format github.com/owner/repo.
  goto failed
)
if "!REPO_SLUG:~-1!"=="/" set "REPO_SLUG=!REPO_SLUG:~0,-1!"
if /I "!REPO_SLUG:~-4!"==".git" set "REPO_SLUG=!REPO_SLUG:~0,-4!"
set "REPO_OWNER="
set "REPO_NAME="
set "REPO_EXTRA="
for /f "tokens=1,2,3 delims=/" %%A in ("!REPO_SLUG!") do (
  set "REPO_OWNER=%%A"
  set "REPO_NAME=%%B"
  set "REPO_EXTRA=%%C"
)
if not defined REPO_OWNER (
  echo Could not find the owner in the GitHub link.
  goto failed
)
if not defined REPO_NAME (
  echo Could not find the repository name in the GitHub link.
  goto failed
)
if defined REPO_EXTRA (
  echo Enter a repository link only; additional paths are not allowed.
  goto failed
)
set "REPO_URL=https://github.com/!REPO_OWNER!/!REPO_NAME!.git"

:destinationReady
for /f "tokens=1,2 delims=/" %%A in ("!REPO_URL:https://github.com/=!") do (
  set "REPO_OWNER=%%A"
  set "REPO_NAME=%%B"
)
if not defined REPO_OWNER (
  echo The saved repository link is invalid.
  goto failed
)
if not defined REPO_NAME (
  echo The saved repository link is invalid.
  goto failed
)
if /I "!REPO_NAME:~-4!"==".git" set "REPO_NAME=!REPO_NAME:~0,-4!"
set "REPO_SLUG=!REPO_OWNER!/!REPO_NAME!"
set "REPO_URL=https://github.com/!REPO_SLUG!.git"
set "REPO_PAGE=https://github.com/!REPO_SLUG!"

where gh >nul 2>&1
if errorlevel 1 (
  echo GitHub CLI (gh) was not found.
  echo Install it from https://cli.github.com/ and run "gh auth login".
  goto failed
)
gh auth status --hostname github.com >nul 2>&1
if errorlevel 1 (
  echo GitHub CLI is not signed in. Run "gh auth login" and try again.
  goto failed
)

echo.
echo WARNING: This will permanently delete the entire GitHub repository:
echo %REPO_PAGE%
echo This removes all branches, tags, files, commit history, settings, and Pages deployments.
echo.
set "CONFIRM="
set /p "CONFIRM=Type %REPO_NAME% to permanently delete this repository: "
if /i not "!CONFIRM!"=="!REPO_NAME!" (
  echo Confirmation did not match. No changes were made.
  goto failed
)

echo.
echo Deleting %REPO_SLUG% from GitHub ...
gh repo delete "%REPO_SLUG%" --yes
set "GIT_RESULT=%ERRORLEVEL%"
if not "%GIT_RESULT%"=="0" (
  echo Repository deletion failed. Check GitHub sign-in and repository permissions.
  goto failed
)

echo.
echo Done. The entire repository was deleted from GitHub.
echo GitHub may allow the repository owner to restore it for a limited time.
if not exist "%LOCALAPPDATA%\AllApp" mkdir "%LOCALAPPDATA%\AllApp" >nul 2>&1
>"%REPO_CONFIG%" echo %REPO_URL%
if errorlevel 1 (
  echo Warning: The selected repository link could not be saved.
) else (
  echo Last repository link saved: %REPO_PAGE%
)
goto done

:failed
echo.
echo Operation stopped. Review the message above.
:done
echo.
echo This window will close automatically in 3 seconds...
timeout /t 3 /nobreak >nul
endlocal
