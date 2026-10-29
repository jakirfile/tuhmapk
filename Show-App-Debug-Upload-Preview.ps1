param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,
    [Parameter(Mandatory = $true)]
    [string]$ApkMetadataPath,
    [Parameter(Mandatory = $true)]
    [string]$StringsPath,
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [Parameter(Mandatory = $true)]
    [string]$IndexPath,
    [Parameter(Mandatory = $true)]
    [string]$QrPath,
    [Parameter(Mandatory = $true)]
    [string]$UploadDirectory
)

$ErrorActionPreference = 'Stop'

foreach ($path in @($ApkPath, $ApkMetadataPath, $StringsPath, $ManifestPath, $IndexPath, $QrPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required upload file is missing: $path"
    }
}

$metadata = Get-Content -LiteralPath $ApkMetadataPath -Raw | ConvertFrom-Json
if ($metadata.elements.Count -lt 1) {
    throw 'APK metadata does not contain a build artifact.'
}

$applicationId = [string]$metadata.applicationId
$versionName = [string]$metadata.elements[0].versionName
$versionCode = [long]$metadata.elements[0].versionCode
$strings = [xml](Get-Content -LiteralPath $StringsPath -Raw)
$appNameNode = $strings.SelectSingleNode('/resources/string[@name="app_name"]')
if ($null -eq $appNameNode -or [string]::IsNullOrWhiteSpace($appNameNode.InnerText)) {
    throw 'Could not find a valid app_name in strings.xml.'
}
$appName = $appNameNode.InnerText.Trim()
$appUrlNode = $strings.SelectSingleNode('/resources/string[@name="app_url"]')
if ($null -eq $appUrlNode -or [string]::IsNullOrWhiteSpace($appUrlNode.InnerText)) {
    throw 'Could not find a valid app_url in strings.xml.'
}
$appUrl = $appUrlNode.InnerText.Trim()
$updateManifestUrlNode = $strings.SelectSingleNode('/resources/string[@name="update_manifest_url"]')
if ($null -eq $updateManifestUrlNode -or [string]::IsNullOrWhiteSpace($updateManifestUrlNode.InnerText)) {
    throw 'Could not find a valid update_manifest_url in strings.xml.'
}
$updateManifestUrl = $updateManifestUrlNode.InnerText.Trim()
if ($applicationId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
    throw "Invalid applicationId in APK metadata: $applicationId"
}
if ([string]::IsNullOrWhiteSpace($versionName) -or $versionCode -lt 1) {
    throw 'APK metadata contains an invalid version name or version code.'
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if (
    [long]$manifest.versionCode -ne $versionCode -or
    [string]$manifest.versionName -cne $versionName
) {
    throw "update.json version $($manifest.versionName) ($($manifest.versionCode)) does not match the APK version $versionName ($versionCode). Run App-Update.bat first."
}

$sha256 = (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash.ToLowerInvariant()
$versionedApkName = "app-debug-$sha256.apk"
$directoryPrefix = if ($UploadDirectory -eq '.') { '' } else { $UploadDirectory.TrimEnd('\', '/') + '\' }

Write-Output ''
Write-Output 'App details:'
Write-Output "App Name: $appName"
Write-Output "App URL: $appUrl"
Write-Output "Update Manifest URL: $updateManifestUrl"
Write-Output "Package Name: $applicationId"
Write-Output "Version Name: $versionName"
Write-Output "Version Code: $versionCode"
Write-Output 'Files to upload:'
Write-Output "  ${directoryPrefix}update.json"
Write-Output "  ${directoryPrefix}app-debug.apk"
Write-Output "  ${directoryPrefix}$versionedApkName (SHA-256: $sha256)"
Write-Output "  ${directoryPrefix}index.html"
Write-Output "  ${directoryPrefix}qr.png"
