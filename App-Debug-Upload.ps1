param(
    [Parameter(Mandatory = $true)]
    [string]$TargetDirectory,
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,
    [Parameter(Mandatory = $true)]
    [string]$ApkMetadataPath,
    [Parameter(Mandatory = $true)]
    [string]$StringsPath,
    [Parameter(Mandatory = $true)]
    [string]$IndexPath,
    [Parameter(Mandatory = $true)]
    [string]$RawApkUrl
)

$ErrorActionPreference = 'Stop'

$stagedManifestPath = Join-Path $TargetDirectory 'update.json'
$stagedApkPath = Join-Path $TargetDirectory 'app-debug.apk'
$stagedIndexPath = Join-Path $TargetDirectory 'index.html'
$metadata = Get-Content -LiteralPath $ApkMetadataPath -Raw | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $stagedManifestPath -Raw | ConvertFrom-Json
$applicationId = [string]$metadata.applicationId
$strings = [xml](Get-Content -LiteralPath $StringsPath -Raw)
$appNameNode = $strings.SelectSingleNode('/resources/string[@name="app_name"]')
if ($null -eq $appNameNode -or [string]::IsNullOrWhiteSpace($appNameNode.InnerText)) {
    throw 'Could not find a valid app_name in strings.xml.'
}
$appName = $appNameNode.InnerText.Trim()

if ($applicationId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
    throw "Invalid applicationId in APK metadata: $applicationId"
}
if ($metadata.elements.Count -lt 1) {
    throw 'APK metadata does not contain a build artifact.'
}
if (
    [long]$manifest.versionCode -ne [long]$metadata.elements[0].versionCode -or
    [string]$manifest.versionName -cne [string]$metadata.elements[0].versionName
) {
    throw "update.json version $($manifest.versionName) ($($manifest.versionCode)) does not match the APK version $($metadata.elements[0].versionName) ($($metadata.elements[0].versionCode)). Run App-Update.bat first."
}

if ($manifest.PSObject.Properties['applicationId']) {
    $manifest.applicationId = $applicationId
} else {
    $manifest | Add-Member -NotePropertyName applicationId -NotePropertyValue $applicationId
}

$html = [IO.File]::ReadAllText($stagedIndexPath, [Text.Encoding]::UTF8)
$escapedAppName = [System.Security.SecurityElement]::Escape($appName)
foreach ($elementId in @('app-name-heading')) {
    $appNamePattern = '(<span\s+id="' + [regex]::Escape($elementId) + '">).*?(</span>)'
    if (-not [regex]::IsMatch($html, $appNamePattern)) {
        throw "Could not find the $elementId app-name element in index.html."
    }
    $html = [regex]::Replace(
        $html,
        $appNamePattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $match.Groups[1].Value + $escapedAppName + $match.Groups[2].Value
        },
        1
    )
}
$versionId = 'id="version"'
$versionIdIndex = $html.IndexOf($versionId, [StringComparison]::Ordinal)
$versionStart = if ($versionIdIndex -ge 0) {
    $html.LastIndexOf('<p', $versionIdIndex, [StringComparison]::Ordinal)
} else {
    -1
}
$versionContentStart = if ($versionStart -ge 0) {
    $html.IndexOf('>', $versionIdIndex, [StringComparison]::Ordinal) + 1
} else {
    -1
}
$versionEnd = if ($versionContentStart -gt 0) {
    $html.IndexOf('</p>', $versionContentStart, [StringComparison]::Ordinal)
} else {
    -1
}
$imageStart = if ($versionEnd -ge 0) {
    $html.IndexOf('<img', $versionEnd + 4, [StringComparison]::OrdinalIgnoreCase)
} else {
    -1
}
if ($versionEnd -lt 0 -or $imageStart -lt 0) {
    throw 'Could not find the version and QR image sections in index.html.'
}

$packageElement = "`r`n      <p class=`"package-name`" id=`"package-name`">Package name: $applicationId</p>`r`n      "
$html = $html.Substring(0, $versionEnd + 4) +
    $packageElement +
    $html.Substring($imageStart)
[IO.File]::WriteAllText($stagedIndexPath, $html, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($IndexPath, $html, [Text.UTF8Encoding]::new($false))

$manifest.apkFileName = 'app-debug.apk'
$manifest.sha256 = (Get-FileHash -LiteralPath $stagedApkPath -Algorithm SHA256).Hash.ToLowerInvariant()
$versionedName = 'app-debug-' + $manifest.sha256 + '.apk'
Copy-Item -LiteralPath $stagedApkPath -Destination (Join-Path $TargetDirectory $versionedName) -Force
$manifest.apkUrl = $RawApkUrl -replace 'app-debug\.apk$', $versionedName
$manifestJson = (ConvertTo-Json -InputObject $manifest -Depth 10) + [Environment]::NewLine
[IO.File]::WriteAllText($stagedManifestPath, $manifestJson, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($ManifestPath, $manifestJson, [Text.UTF8Encoding]::new($false))

Write-Output "Version $($manifest.versionName) (code $($manifest.versionCode))  Package: $applicationId  SHA-256: $($manifest.sha256)"
Write-Output "Cache-safe APK URL: $($manifest.apkUrl)"
Write-Output ''
Write-Output 'Upload details:'
Write-Output "Package Name: $applicationId"
Write-Output "Version Name: $($manifest.versionName)"
Write-Output "Version Code: $($manifest.versionCode)"
Write-Output 'Files to upload:'
Get-ChildItem -LiteralPath $TargetDirectory -File -Recurse |
    Sort-Object FullName |
    ForEach-Object {
        $relativePath = $_.FullName.Substring($TargetDirectory.TrimEnd('\', '/').Length).TrimStart('\', '/')
        Write-Output "  $relativePath"
    }
