param(
    [Parameter(Mandatory = $true)]
    [string]$Root,
    [Parameter(Mandatory = $true)]
    [string]$MappingInput
)

function ConvertFrom-RenameMapping([string]$Mapping, [string]$Label) {
    $separator = $Mapping.IndexOf('=')
    if ($separator -le 0 -or $separator -eq ($Mapping.Length - 1)) {
        throw "The $Label mapping must use SOURCE=REPLACEMENT format."
    }

    [pscustomobject]@{
        Old = $Mapping.Substring(0, $separator)
        New = $Mapping.Substring($separator + 1)
        Label = $Label
    }
}

$ErrorActionPreference = 'Stop'
$mappingParts = $MappingInput.Split(',')
if ($mappingParts.Count -ne 2) {
    throw 'Enter exactly two mappings separated by a comma.'
}

$upperMapping = $mappingParts[0].Trim()
$lowerMapping = $mappingParts[1].Trim()
$upper = ConvertFrom-RenameMapping $upperMapping 'upper-case'
$lower = ConvertFrom-RenameMapping $lowerMapping 'lower-case'
$renameMappings = @($upper, $lower)

foreach ($renameMapping in $renameMappings) {
    if ([string]::IsNullOrWhiteSpace($renameMapping.Old) -or [string]::IsNullOrWhiteSpace($renameMapping.New)) {
        throw "The $($renameMapping.Label) source and replacement values must not be blank."
    }
    if ($renameMapping.Old -ceq $renameMapping.New) {
        throw "The $($renameMapping.Label) source and replacement values are identical."
    }
}

$rootPath = [IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
    throw "Project folder does not exist: $rootPath"
}

$protectedScriptPaths = @(
    [IO.Path]::GetFullPath((Join-Path $rootPath 'Rename.bat')),
    [IO.Path]::GetFullPath((Join-Path $rootPath 'Rename-Everything.ps1'))
)

function Get-ScopedEntries {
    $pendingDirectories = [System.Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($rootPath)

    while ($pendingDirectories.Count -gt 0) {
        $directory = $pendingDirectories.Pop()
        foreach ($entry in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
            if ($entry.Name -ieq '.git') {
                continue
            }

            if ($protectedScriptPaths -contains [IO.Path]::GetFullPath($entry.FullName)) {
                continue
            }

            $entry
            if (
                $entry.PSIsContainer -and
                ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
            ) {
                $pendingDirectories.Push($entry.FullName)
            }
        }
    }
}

Write-Host 'Scanning project files and folders (excluding .git)...'
$scopedEntries = @(Get-ScopedEntries)
$files = @($scopedEntries | Where-Object { -not $_.PSIsContainer })
$paths = @($scopedEntries | Sort-Object { $_.FullName.Length } -Descending)
Write-Host "Found $($files.Count) files and $($paths.Count - $files.Count) folders."
Write-Host 'Replacing text in files...'

$updatedFiles = 0
$processedFiles = 0
foreach ($file in $files) {
    $processedFiles++
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -eq 0) {
        if ($processedFiles % 50 -eq 0) {
            Write-Host "Checked $processedFiles of $($files.Count) files..."
        }
        continue
    }

    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $offset = 0
    if (
        $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    ) {
        $encoding = [Text.UTF8Encoding]::new($true, $true)
        $offset = 3
    } elseif ($bytes.Length -ge 4 -and (
        ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) -or
        ($bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF)
    )) {
        continue
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true)
        $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true)
        $offset = 2
    }

    try {
        $content = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    } catch {
        if ($processedFiles % 50 -eq 0) {
            Write-Host "Checked $processedFiles of $($files.Count) files..."
        }
        continue
    }
    if ($content.Contains([char]0)) {
        if ($processedFiles % 50 -eq 0) {
            Write-Host "Checked $processedFiles of $($files.Count) files..."
        }
        continue
    }

    $updated = $content
    foreach ($renameMapping in $renameMappings) {
        $updated = $updated.Replace($renameMapping.Old, $renameMapping.New)
    }

    if ($updated -cne $content) {
        $newBytes = $encoding.GetBytes($updated)
        if ($offset -gt 0) {
            $preamble = $encoding.GetPreamble()
            $newBytes = $preamble + $newBytes
        }
        [IO.File]::WriteAllBytes($file.FullName, $newBytes)
        $updatedFiles++
    }

    if ($processedFiles % 50 -eq 0 -or $processedFiles -eq $files.Count) {
        Write-Host "Checked $processedFiles of $($files.Count) files..."
    }
}

$renamedPaths = 0
Write-Host 'Renaming matching files and folders...'
$processedPaths = 0
foreach ($item in $paths) {
    $processedPaths++
    $newName = $item.Name
    foreach ($renameMapping in $renameMappings) {
        $newName = $newName.Replace($renameMapping.Old, $renameMapping.New)
    }

    if ($newName -cne $item.Name) {
        $parentPath = if ($item.PSIsContainer) { $item.Parent.FullName } else { $item.DirectoryName }
        $destination = Join-Path $parentPath $newName
        if (Test-Path -LiteralPath $destination) {
            throw "Cannot rename '$($item.FullName)': destination already exists: $destination"
        }

        Rename-Item -LiteralPath $item.FullName -NewName $newName
        $renamedPaths++
    }

    if ($processedPaths % 50 -eq 0 -or $processedPaths -eq $paths.Count) {
        Write-Host "Checked $processedPaths of $($paths.Count) paths..."
    }
}

Write-Output "Upper-case mapping: $upperMapping"
Write-Output "Lower-case mapping: $lowerMapping"
Write-Output "Updated text files: $updatedFiles"
Write-Output "Renamed files/folders: $renamedPaths"
