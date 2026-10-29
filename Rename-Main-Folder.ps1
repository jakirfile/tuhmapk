param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath
)

$ErrorActionPreference = 'Stop'
$destinationInput = $DestinationPath.Trim().Trim('"')
if ([string]::IsNullOrWhiteSpace($destinationInput)) {
    throw 'A full destination path is required.'
}
if (-not [IO.Path]::IsPathRooted($destinationInput)) {
    throw 'Enter an absolute destination path, for example D:\All-Android-Source.'
}

$target = [IO.Path]::GetFullPath($RootPath).TrimEnd('\')
$folder = Get-Item -LiteralPath $target -ErrorAction Stop
if (-not $folder.PSIsContainer) {
    throw "Main folder not found: $target"
}

$destinationFullPath = [IO.Path]::GetFullPath($destinationInput)
if ($destinationFullPath.TrimEnd('\') -ieq [IO.Path]::GetPathRoot($destinationFullPath).TrimEnd('\')) {
    throw 'The destination path cannot be a drive root.'
}
$destination = $destinationFullPath.TrimEnd('\')
if ($destination -ieq $target) {
    throw 'The destination path is the same as the current Main Folder.'
}
if ([IO.Path]::GetPathRoot($destination) -ine [IO.Path]::GetPathRoot($target)) {
    throw 'The destination must be on the same drive as the current Main Folder.'
}
$sourcePrefix = $target + [IO.Path]::DirectorySeparatorChar
if ($destination.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The destination cannot be inside the current Main Folder.'
}

$destinationParent = Split-Path -Parent $destination
if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
    throw "Destination parent folder does not exist: $destinationParent"
}
if (Test-Path -LiteralPath $destination) {
    throw "A file or folder already exists at the destination: $destination"
}

$env:CLOSE_FOLDER_TARGET = $folder.FullName
$env:CLOSE_FOLDER_DESTINATION = $destination
$worker = @'
$ErrorActionPreference = 'Stop'
$target = $env:CLOSE_FOLDER_TARGET
$destination = $env:CLOSE_FOLDER_DESTINATION
Start-Sleep -Seconds 2

try {
    $shell = New-Object -ComObject Shell.Application
    foreach ($window in @($shell.Windows())) {
        try {
            $openPath = [string]$window.Document.Folder.Self.Path
            if (
                -not [string]::IsNullOrWhiteSpace($openPath) -and
                [IO.Path]::GetFullPath($openPath).TrimEnd('\') -ieq $target.TrimEnd('\')
            ) {
                $window.Quit()
                Write-Host 'Closed the File Explorer window that was using the Main Folder.'
            }
        } catch {
            Write-Verbose "Skipped a Shell window that is not a File Explorer folder: $($_.Exception.Message)"
        }
    }
} catch {
    Write-Host "Could not automatically close the File Explorer window: $($_.Exception.Message)" -ForegroundColor Yellow
}

$attempt = 0
while ($true) {
    $attempt++
    try {
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            throw "Main folder no longer exists: $target"
        }
        if (Test-Path -LiteralPath $destination) {
            throw "A file or folder now exists at the destination: $destination"
        }

        [IO.Directory]::Move($target, $destination)
        Write-Host 'Main folder moved/renamed successfully:'
        Write-Host $destination
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$destination`""
        Start-Sleep -Seconds 3
        exit 0
    } catch {
        if (
            $_.Exception -isnot [IO.IOException] -and
            $_.Exception -isnot [UnauthorizedAccessException]
        ) {
            Write-Host "Could not move/rename the Main Folder: $($_.Exception.Message)" -ForegroundColor Red
            Start-Sleep -Seconds 5
            exit 1
        }

        if ($attempt -eq 1 -or $attempt % 15 -eq 0) {
            Write-Host "The Main Folder is still in use by another app. Close that app or terminal. Retrying rename (attempt $attempt)..." -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
    }
}
'@

$encodedWorker = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($worker))
Start-Process `
    -FilePath (Join-Path $PSHOME 'powershell.exe') `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedWorker) `
    -WorkingDirectory $env:TEMP
Write-Host 'Rename started in a separate window. This window can close now.'
