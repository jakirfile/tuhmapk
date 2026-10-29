param(
    [Parameter(Mandatory = $true)]
    [string]$MetadataPath,
    [Parameter(Mandatory = $true)]
    [string]$StringsPath
)

$ErrorActionPreference = 'Stop'

try {
    $metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
    $apkElement = @($metadata.elements | Where-Object { $_.outputFile -eq 'app-debug.apk' })
    if ($apkElement.Count -ne 1) {
        throw 'Could not identify app-debug.apk in the build metadata.'
    }

    $applicationId = [string]$metadata.applicationId
    $versionName = [string]$apkElement[0].versionName
    $versionCode = [string]$apkElement[0].versionCode
    if (
        $applicationId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$' -or
        [string]::IsNullOrWhiteSpace($versionName) -or
        [string]::IsNullOrWhiteSpace($versionCode)
    ) {
        throw 'The APK build metadata is missing a valid package name or version.'
    }

    [xml]$strings = Get-Content -LiteralPath $StringsPath -Raw
    $appNameNode = $strings.SelectSingleNode('/resources/string[@name="app_name"]')
    if ($null -eq $appNameNode -or [string]::IsNullOrWhiteSpace($appNameNode.InnerText)) {
        throw 'Could not find the app_name resource.'
    }
    $appUrlNode = $strings.SelectSingleNode('/resources/string[@name="app_url"]')
    if ($null -eq $appUrlNode -or [string]::IsNullOrWhiteSpace($appUrlNode.InnerText)) {
        throw 'Could not find the app_url resource.'
    }
    $updateManifestUrlNode = $strings.SelectSingleNode('/resources/string[@name="update_manifest_url"]')
    if ($null -eq $updateManifestUrlNode -or [string]::IsNullOrWhiteSpace($updateManifestUrlNode.InnerText)) {
        throw 'Could not find the update_manifest_url resource.'
    }

    $appName = $appNameNode.InnerText.Trim()
    $appUrl = $appUrlNode.InnerText.Trim()
    $updateManifestUrl = $updateManifestUrlNode.InnerText.Trim()
    foreach ($urlSetting in @(
        [pscustomobject]@{ Name = 'app_url'; Value = $appUrl },
        [pscustomobject]@{ Name = 'update_manifest_url'; Value = $updateManifestUrl }
    )) {
        $uri = $null
        if (
            -not [Uri]::TryCreate($urlSetting.Value, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or
            $uri.UserInfo -or
            $uri.Fragment
        ) {
            throw "$($urlSetting.Name) must be a valid HTTPS URL without credentials or a fragment."
        }
    }

    foreach ($value in @($applicationId, $versionName, $versionCode, $appName, $appUrl, $updateManifestUrl)) {
        if ($value.Contains('|') -or $value.Contains("`r") -or $value.Contains("`n")) {
            throw 'APK information contains characters that cannot be displayed safely.'
        }
    }

    [Console]::Out.WriteLine("$applicationId|$versionName|$versionCode|$appName|$appUrl|$updateManifestUrl")
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
