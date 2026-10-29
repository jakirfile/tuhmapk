param(
    [Parameter(Mandatory = $true)]
    [string]$Root,
    [Parameter(Mandatory = $true)]
    [string]$UpperMapping,
    [Parameter(Mandatory = $true)]
    [string]$LowerMapping
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
$upper = ConvertFrom-RenameMapping $UpperMapping 'upper-case'
$lower = ConvertFrom-RenameMapping $LowerMapping 'lower-case'
$mappings = @($upper, $lower)

foreach ($mapping in $mappings) {
    if ([string]::IsNullOrWhiteSpace($mapping.Old) -or [string]::IsNullOrWhiteSpace($mapping.New)) {
        throw "The $($mapping.Label) source and replacement values must not be blank."
    }
    if ($mapping.Old -ceq $mapping.New) {
        throw "The $($mapping.Label) source and replacement values are identical."
    }
}

$rootPath = [IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
    throw "Project folder does not exist: $rootPath"
}

$protectedScriptPaths = @(
    [IO.Path]::GetFullPath((Join-Path $rootPath 'Rename.bat')),
    [IO.Path]::GetFullPath((Join-Path $rootPath 'Rename-Project.ps1'))
)

function Test-InScope([string]$Path) {
    $relativePath = $Path.Substring($rootPath.Length).TrimStart('\', '/')
    $segments = $relativePath -split '[\\/]'
    -not ($segments | Where-Object { $_ -ieq '.git' })
}

$files = @(
    Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force |
        Where-Object { Test-InScope $_.FullName }
)

$updatedFiles = 0
foreach ($file in $files) {
    if ($protectedScriptPaths -contains [IO.Path]::GetFullPath($file.FullName)) {
        continue
    }

    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -eq 0) {
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
        continue
    }
    if ($content.Contains([char]0)) {
        continue
    }

    $updated = $content
    foreach ($mapping in $mappings) {
        $updated = $updated.Replace($mapping.Old, $mapping.New)
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
}

$renamedPaths = 0
$paths = @( 
    Get-ChildItem -LiteralPath $rootPath -Recurse -Force |
        Where-Object { Test-InScope $_.FullName } |
        Sort-Object { $_.FullName.Length } -Descending
)

foreach ($item in $paths) {
    if ($protectedScriptPaths -contains [IO.Path]::GetFullPath($item.FullName)) {
        continue
    }

    $newName = $item.Name
    foreach ($mapping in $mappings) {
        $newName = $newName.Replace($mapping.Old, $mapping.New)
    }

    if ($newName -ceq $item.Name) {
        continue
    }

    $parentPath = if ($item.PSIsContainer) { $item.Parent.FullName } else { $item.DirectoryName }
    $destination = Join-Path $parentPath $newName
    if (Test-Path -LiteralPath $destination) {
        throw "Cannot rename '$($item.FullName)': destination already exists: $destination"
    }

    Rename-Item -LiteralPath $item.FullName -NewName $newName
    $renamedPaths++
}

Write-Output "Upper-case mapping: $UpperMapping"
Write-Output "Lower-case mapping: $LowerMapping"
Write-Output "Updated text files: $updatedFiles"
Write-Output "Renamed files/folders: $renamedPaths"
