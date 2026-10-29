@echo off
setlocal EnableExtensions
pushd "%~dp0"
if errorlevel 1 (
    echo Could not open the project folder.
    pause
    exit /b 1
)

set /p "MAPPINGS=Enter mappings (UPPER=..., lower=...): "
if not defined MAPPINGS goto :missing_mapping

echo Replace exact-case text and file/folder names inside this folder and all subfolders.
echo Git metadata and binary file contents are left unchanged.
echo.
echo Mappings: %MAPPINGS%
echo This changes matching text and file/folder names in the project.
echo.
set "CONFIRM="
set /p "CONFIRM=Continue? [y/N]: "
if /I not "%CONFIRM%"=="Y" (
    echo No changes made.
    popd
    exit /b 0
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Rename-Everything.ps1" -Root "%CD%" -MappingInput "%MAPPINGS%"
set "RESULT=%ERRORLEVEL%"
popd
if not "%RESULT%"=="0" (
    echo Rename did not complete successfully.
    pause
)
exit /b %RESULT%

:missing_mapping
echo Enter both mappings separated by a comma.
popd
pause
exit /b 1
