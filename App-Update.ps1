$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$gradlePath = Join-Path $projectRoot 'app\build.gradle.kts'
$manifestPath = Join-Path $projectRoot 'update.json'
$stringsPath = Join-Path $projectRoot 'app\src\main\res\values\strings.xml'

function Read-VersionFiles {
    $gradle = [IO.File]::ReadAllText($gradlePath)
    $defaultConfigMatch = [regex]::Match(
        $gradle,
        '(?s)defaultConfig\s*\{(?<body>.*?)^\s{4}\}',
        [Text.RegularExpressions.RegexOptions]::Multiline
    )
    if (-not $defaultConfigMatch.Success) {
        throw 'Could not find the android.defaultConfig block in app/build.gradle.kts.'
    }

    $codeMatch = [regex]::Match($defaultConfigMatch.Groups['body'].Value, '(?m)^\s*versionCode\s*=\s*(?<value>\d+)\s*$')
    $nameMatch = [regex]::Match($defaultConfigMatch.Groups['body'].Value, '(?m)^\s*versionName\s*=\s*"(?<value>[^"]+)"\s*$')
    $applicationIdMatch = [regex]::Match($defaultConfigMatch.Groups['body'].Value, '(?m)^\s*applicationId\s*=\s*"(?<value>[^"]+)"\s*$')
    if (-not $codeMatch.Success -or -not $nameMatch.Success -or -not $applicationIdMatch.Success) {
        throw 'Could not read applicationId, versionCode, and versionName from app/build.gradle.kts.'
    }

    $applicationId = $applicationIdMatch.Groups['value'].Value
    if ($applicationId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
        throw "The Android application ID is invalid: $applicationId"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.apkFileName -ne 'app-debug.apk') {
        throw 'update.json does not target app-debug.apk.'
    }

    [xml]$strings = [IO.File]::ReadAllText($stringsPath)
    $appNameNode = $strings.SelectSingleNode('/resources/string[@name="app_name"]')
    if ($null -eq $appNameNode -or [string]::IsNullOrWhiteSpace($appNameNode.InnerText)) {
        throw 'Could not find a valid app_name in app/src/main/res/values/strings.xml.'
    }
    $appUrlNode = $strings.SelectSingleNode('/resources/string[@name="app_url"]')
    if ($null -eq $appUrlNode -or [string]::IsNullOrWhiteSpace($appUrlNode.InnerText)) {
        throw 'Could not find a valid app_url in app/src/main/res/values/strings.xml.'
    }
    $updateManifestUrlNode = $strings.SelectSingleNode('/resources/string[@name="update_manifest_url"]')
    if ($null -eq $updateManifestUrlNode -or [string]::IsNullOrWhiteSpace($updateManifestUrlNode.InnerText)) {
        throw 'Could not find a valid update_manifest_url in app/src/main/res/values/strings.xml.'
    }

    foreach ($urlSetting in @(
        [pscustomobject]@{ Name = 'app_url'; Value = $appUrlNode.InnerText.Trim() },
        [pscustomobject]@{ Name = 'update_manifest_url'; Value = $updateManifestUrlNode.InnerText.Trim() }
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

    $deviceVersion = Get-InstalledAppVersion $applicationId
    $versionCode = [int]$codeMatch.Groups['value'].Value

    [pscustomobject]@{
        Gradle              = $gradle
        DefaultBlock        = $defaultConfigMatch
        ApplicationId       = $applicationId
        AppName             = $appNameNode.InnerText.Trim()
        Strings             = [IO.File]::ReadAllText($stringsPath)
        VersionCode         = $versionCode
        VersionName         = $nameMatch.Groups['value'].Value
        Manifest            = $manifest
        ManifestApplicationId = [string]$manifest.applicationId
        AppUrl              = $appUrlNode.InnerText.Trim()
        UpdateManifestUrl   = $updateManifestUrlNode.InnerText.Trim()
        MinimumVersionCode  = [Math]::Max(
            [Math]::Max($versionCode, [int]$manifest.versionCode),
            $deviceVersion.VersionCode
        )
        DeviceVersionCode   = $deviceVersion.VersionCode
        DeviceVersionName   = $deviceVersion.VersionName
    }
}

function Get-InstalledAppVersion([string]$ApplicationId) {
    $sdk = $env:ANDROID_SDK_ROOT
    if ([string]::IsNullOrWhiteSpace($sdk)) { $sdk = $env:ANDROID_HOME }
    if ([string]::IsNullOrWhiteSpace($sdk)) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $adb = Join-Path $sdk 'platform-tools\adb.exe'
    if (-not (Test-Path $adb)) {
        return [pscustomobject]@{ VersionCode = 0; VersionName = '' }
    }

    $devices = @(& $adb devices)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list connected Android devices using $adb."
    }
    $serials = @(
        $devices |
            Select-Object -Skip 1 |
            ForEach-Object {
                if ($_ -match '^\s*(\S+)\s+device\s*$') { $Matches[1] }
            }
    )

    $highest = [pscustomobject]@{ VersionCode = 0; VersionName = '' }
    foreach ($serial in $serials) {
        $packageInfo = @(& $adb -s $serial shell dumpsys package $ApplicationId 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not read the installed $ApplicationId version from Android device $serial."
        }
        $packageText = $packageInfo -join "`n"
        $installedCode = [regex]::Match($packageText, '(?m)^\s*versionCode=(\d+)')
        $installedName = [regex]::Match($packageText, '(?m)^\s*versionName=(\S+)')
        if ($installedCode.Success -and [int]$installedCode.Groups[1].Value -gt $highest.VersionCode) {
            $highest.VersionCode = [int]$installedCode.Groups[1].Value
            if ($installedName.Success) {
                $highest.VersionName = $installedName.Groups[1].Value
            }
        }
    }

    return $highest
}

function Set-ManifestApplicationId($Manifest, [string]$ApplicationId) {
    if ($Manifest.PSObject.Properties['applicationId']) {
        $Manifest.applicationId = $ApplicationId
    } else {
        $Manifest | Add-Member -NotePropertyName applicationId -NotePropertyValue $ApplicationId
    }
}

function Set-StringResource([string]$Content, [string]$Name, [string]$Value) {
    $escapedName = [regex]::Escape($Name)
    $pattern = '(?m)^(\s*<string\s+name="' + $escapedName + '"[^>]*>).*?(</string>\s*)$'
    if (-not [regex]::IsMatch($Content, $pattern)) {
        throw "Could not find the $Name resource in app/src/main/res/values/strings.xml."
    }

    $escapedValue = [System.Security.SecurityElement]::Escape($Value)
    return [regex]::Replace(
        $Content,
        $pattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $match.Groups[1].Value + $escapedValue + $match.Groups[2].Value
        },
        1
    )
}

function Test-HttpsUrl([string]$Value) {
    $uri = $null
    return (
        -not [string]::IsNullOrWhiteSpace($Value) -and
        [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -and
        $uri.Scheme -eq 'https' -and
        -not $uri.UserInfo -and
        -not $uri.Fragment
    )
}

function Adjust-VersionName([string]$VersionName, [int]$Amount) {
    $match = [regex]::Match($VersionName, '^(?<numbers>\d+(?:\.\d+)*)(?<suffix>.*)$')
    if (-not $match.Success) {
        throw 'Version Name must start with numeric segments (for example 1.0 or 1.2.3) to increase/decrease it.'
    }

    $segments = @($match.Groups['numbers'].Value.Split('.'))
    $lastIndex = $segments.Count - 1
    $segmentValue = [int]$segments[$lastIndex]
    if ($Amount -lt 0 -and $segmentValue -eq 0) {
        Write-Host 'The last Version Name segment is already 0; it cannot go lower.' -ForegroundColor Yellow
        return $VersionName
    }

    $segments[$lastIndex] = [string]($segmentValue + $Amount)
    return (($segments -join '.') + $match.Groups['suffix'].Value)
}

function Get-QrDownloadUrl([string]$IndexHtml) {
    $rawApkMatch = [regex]::Match(
        $IndexHtml,
        '(?is)<a\b(?=[^>]*\bclass="download")[^>]*\bhref="(?<url>https://raw\.githubusercontent\.com/[^/"\s]+/[^/"\s]+/main/app-debug\.apk)"'
    )
    $githubMatch = [regex]::Match(
        $IndexHtml,
        '(?is)<a\b(?=[^>]*\bclass="fallback-link")[^>]*\bhref="(?<url>https://github\.com/[^/"\s]+/[^/"\s]+)/*"'
    )
    if (-not $rawApkMatch.Success -or -not $githubMatch.Success) {
        throw 'index.html must contain GitHub download and fallback links in the standard repository URL format.'
    }

    $rawApkUri = [Uri]$rawApkMatch.Groups['url'].Value
    $githubUri = [Uri]$githubMatch.Groups['url'].Value
    $rawRepository = $rawApkUri.AbsolutePath.Trim('/').Split('/')
    $githubRepository = $githubUri.AbsolutePath.Trim('/').Split('/')
    if (
        $rawRepository.Count -ne 4 -or
        $githubRepository.Count -ne 2 -or
        $rawRepository[0] -ine $githubRepository[0] -or
        $rawRepository[1] -ine $githubRepository[1] -or
        $rawRepository[2] -cne 'main' -or
        $rawRepository[3] -cne 'app-debug.apk'
    ) {
        throw 'The APK download and GitHub fallback links in index.html must target the same repository.'
    }
    if ($IndexHtml -notmatch 'fetch\("\./update\.json"') {
        throw 'index.html is missing the configured update manifest link.'
    }

    return $rawApkUri.AbsoluteUri
}

function Write-ValidatedQrImage([string]$DownloadUrl, [string]$DestinationPath) {
    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if (-not $curl) {
        throw 'curl.exe is required to refresh the QR image.'
    }

    $temporaryPath = "$DestinationPath.$([Guid]::NewGuid().ToString('N')).tmp"
    $qrServiceUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=600x600&format=png&data=' +
        [Uri]::EscapeDataString($DownloadUrl)
    try {
        & $curl.Source '--fail' '--location' '--silent' '--show-error' '--max-time' '30' '--output' $temporaryPath $qrServiceUrl
        if ($LASTEXITCODE -ne 0) {
            throw "Could not refresh qr.png (curl exit code $LASTEXITCODE)."
        }
        $qrBytes = [IO.File]::ReadAllBytes($temporaryPath)
        if (
            $qrBytes.Length -lt 100 -or
            $qrBytes[0] -ne 137 -or $qrBytes[1] -ne 80 -or
            $qrBytes[2] -ne 78 -or $qrBytes[3] -ne 71
        ) {
            throw 'The refreshed QR image is not a valid PNG.'
        }

        Move-Item -LiteralPath $temporaryPath -Destination $DestinationPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Set-IndexQrCacheKey([string]$IndexHtml, [string]$CacheKey) {
    $expectedQr = '<img(?<attributes>[^>]*\bsrc="\./qr\.png(?:\?[^"]*)?"[^>]*)>'
    if ($IndexHtml -notmatch $expectedQr) {
        throw 'Could not find the QR image element in index.html.'
    }

    $qrSource = 'src="./qr.png?v=' + $CacheKey + '"'
    return [regex]::Replace(
        $IndexHtml,
        $expectedQr,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            [regex]::Replace($match.Value, '\bsrc="\./qr\.png(?:\?[^"]*)?"', $qrSource, 1)
        },
        1
    )
}

function Build-DebugApk([int]$VersionCode, [string]$VersionName, [string]$ApplicationId) {
    $sdk = $env:ANDROID_SDK_ROOT
    if ([string]::IsNullOrWhiteSpace($sdk)) { $sdk = $env:ANDROID_HOME }
    if ([string]::IsNullOrWhiteSpace($sdk)) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }

    $buildToolsRoot = Join-Path $sdk 'build-tools'
    $buildTools = Get-ChildItem -LiteralPath $buildToolsRoot -Directory |
        Sort-Object { [version]$_.Name } -Descending |
        Where-Object {
            (Test-Path (Join-Path $_.FullName 'apksigner.bat')) -and
            (Test-Path (Join-Path $_.FullName 'aapt.exe'))
        } |
        Select-Object -First 1
    if (-not $buildTools) {
        throw "Android SDK build-tools with apksigner and aapt were not found under $buildToolsRoot."
    }

    $gradleWrapper = Join-Path $projectRoot 'gradlew.bat'
    $debugApk = Join-Path $projectRoot 'app\build\outputs\apk\debug\app-debug.apk'
    $signedApk = Join-Path $projectRoot 'app\build\outputs\apk\debug\app-debug.apk'
    $stagedApk = Join-Path $projectRoot 'app\build\outputs\apk\debug\app-debug-version-update.apk'
    $qrPath = Join-Path $projectRoot 'qr.png'
    $stagedQr = Join-Path $projectRoot 'app\build\outputs\apk\debug\qr-version-update.png'
    $indexPath = Join-Path $projectRoot 'index.html'
    $keystore = Join-Path $env:USERPROFILE '.android\debug.keystore'
    $apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
    $aapt = Join-Path $buildTools.FullName 'aapt.exe'

    if (-not (Test-Path $gradleWrapper)) { throw 'gradlew.bat was not found.' }
    if (-not (Test-Path $keystore)) { throw "Android debug keystore was not found: $keystore" }

    Write-Host ''
    Write-Host 'Building the debug APK...' -ForegroundColor Cyan
    Push-Location $projectRoot
    try {
        & $gradleWrapper ':app:assembleDebug' '-PskipInstallAndRun=true' '--console=plain' '--no-configuration-cache'
        $buildExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($buildExitCode -ne 0) {
        throw "Debug APK build failed with exit code $buildExitCode."
    }
    if (-not (Test-Path $debugApk)) {
        throw "Debug build succeeded, but the APK was not found: $debugApk"
    }

    if (Test-Path $stagedApk) { Remove-Item -LiteralPath $stagedApk -Force }
    Write-Host 'Verifying the debug APK...' -ForegroundColor Cyan
    Copy-Item -LiteralPath $debugApk -Destination $stagedApk -Force
    & $apksigner verify $stagedApk
    if ($LASTEXITCODE -ne 0) { throw 'Debug APK signature verification failed.' }

    $badging = & $aapt dump badging $stagedApk
    if ($LASTEXITCODE -ne 0) { throw 'Could not read debug APK version metadata.' }
    $packageLine = $badging | Where-Object { $_ -match '^package:' } | Select-Object -First 1
    if (
        $packageLine -notmatch ("name='" + [regex]::Escape($ApplicationId) + "' versionCode='" + $VersionCode + "' versionName='([^']+)'") -or
        $Matches[1] -cne $VersionName
    ) {
        throw "Built APK version does not match Version Name $VersionName and Version Code $VersionCode."
    }

    $indexHtml = [IO.File]::ReadAllText($indexPath)
    $downloadUrl = Get-QrDownloadUrl $indexHtml
    Write-Host 'Refreshing the GitHub fallback QR image...' -ForegroundColor Cyan
    Write-ValidatedQrImage $downloadUrl $stagedQr
    $indexHtml = Set-IndexQrCacheKey $indexHtml $VersionCode
    $versionHtml = [regex]::Escape('<p class="version" id="version" aria-live="polite">') +
        '.*?' +
        [regex]::Escape('</p>')
    if ($indexHtml -notmatch $versionHtml) {
        throw 'Could not find the version display in index.html.'
    }
    $fallbackVersion = "Latest version $VersionName (Version code $VersionCode)"
    $indexHtml = [regex]::Replace(
        $indexHtml,
        $versionHtml,
        ('<p class="version" id="version" aria-live="polite">' + $fallbackVersion + '</p>'),
        1
    )
    $packageNameHtml = '(?<opening>' + [regex]::Escape('<p class="package-name" id="package-name">') + ')' +
        '(?<label>.*?: )[^<]*' +
        '(?<closing>' + [regex]::Escape('</p>') + ')'
    if ($indexHtml -notmatch $packageNameHtml) {
        throw 'Could not find the package name display in index.html.'
    }
    $indexHtml = [regex]::Replace(
        $indexHtml,
        $packageNameHtml,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $match.Groups['opening'].Value +
                $match.Groups['label'].Value +
                $ApplicationId +
                $match.Groups['closing'].Value
        },
        1
    )
    Move-Item -LiteralPath $stagedApk -Destination $signedApk -Force
    Move-Item -LiteralPath $stagedQr -Destination $qrPath -Force
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.versionCode = $VersionCode
    $manifest.versionName = $VersionName
    Set-ManifestApplicationId $manifest $ApplicationId
    $manifest.sha256 = (Get-FileHash -LiteralPath $signedApk -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        $manifestPath,
        (ConvertTo-Json -InputObject $manifest -Depth 10) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText($indexPath, $indexHtml, [Text.UTF8Encoding]::new($false))

    Write-Host "Debug APK built: $signedApk" -ForegroundColor Green
    Write-Host "Package full name: $ApplicationId"
    Write-Host "SHA-256: $($manifest.sha256)"
    Write-Host "Updated local files: update.json, index.html, and qr.png."
}

function Save-VersionAndBuild(
    [int]$VersionCode,
    [string]$VersionName,
    [string]$ApplicationId,
    [string]$AppName,
    [string]$AppUrl,
    [string]$UpdateManifestUrl
) {
    if ($VersionCode -le $current.MinimumVersionCode) {
        Write-Host "Warning: Version Code $VersionCode is not higher than the current/installed minimum $($current.MinimumVersionCode). Android will not install this as an update over a higher version; uninstall the existing app first." -ForegroundColor Yellow
    }

    $blockBody = $current.DefaultBlock.Groups['body'].Value
    $blockBody = [regex]::Replace(
        $blockBody,
        '(?m)^(\s*versionCode\s*=\s*)\d+(\s*)$',
        "`${1}$VersionCode`$2",
        1
    )
    $escapedName = $VersionName.Replace('\', '\\').Replace('"', '\"')
    $blockBody = [regex]::Replace(
        $blockBody,
        '(?m)^(\s*versionName\s*=\s*")[^"]+("\s*)$',
        "`${1}$escapedName`$2",
        1
    )
    $escapedApplicationId = $ApplicationId.Replace('\', '\\').Replace('"', '\"')
    $blockBody = [regex]::Replace(
        $blockBody,
        '(?m)^(\s*applicationId\s*=\s*")[^"]+("\s*)$',
        "`${1}$escapedApplicationId`$2",
        1
    )
    $newGradle = $current.Gradle.Substring(0, $current.DefaultBlock.Groups['body'].Index) +
        $blockBody +
        $current.Gradle.Substring($current.DefaultBlock.Groups['body'].Index + $current.DefaultBlock.Groups['body'].Length)

    if (-not (Test-HttpsUrl $AppUrl)) {
        throw 'app_url must be a valid HTTPS URL without credentials or a fragment.'
    }
    if (-not (Test-HttpsUrl $UpdateManifestUrl)) {
        throw 'update_manifest_url must be a valid HTTPS URL without credentials or a fragment.'
    }
    $newStrings = Set-StringResource $current.Strings 'app_name' $AppName
    $newStrings = Set-StringResource $newStrings 'app_url' $AppUrl
    $newStrings = Set-StringResource $newStrings 'update_manifest_url' $UpdateManifestUrl

    $originalManifest = [IO.File]::ReadAllText($manifestPath)
    try {
        [IO.File]::WriteAllText($gradlePath, $newGradle, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stringsPath, $newStrings, [Text.UTF8Encoding]::new($false))
        Build-DebugApk $VersionCode $VersionName $ApplicationId
    } catch {
        [IO.File]::WriteAllText($gradlePath, $current.Gradle, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stringsPath, $current.Strings, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($manifestPath, $originalManifest, [Text.UTF8Encoding]::new($false))
        throw
    }

    $current.Manifest.versionCode = $VersionCode
    $current.Manifest.versionName = $VersionName
    Set-ManifestApplicationId $current.Manifest $ApplicationId
    $current.ManifestApplicationId = $ApplicationId
    $current.ApplicationId = $ApplicationId
    $current.AppName = $AppName
    $current.AppUrl = $AppUrl
    $current.UpdateManifestUrl = $UpdateManifestUrl
    $current.Strings = $newStrings
    Write-Host ''
    Write-Host "Saved app name $AppName, application ID $ApplicationId, Version Name $VersionName, and Version Code $VersionCode." -ForegroundColor Green
    Write-Host "Saved app_url: $AppUrl" -ForegroundColor Green
    Write-Host "Saved update_manifest_url: $UpdateManifestUrl" -ForegroundColor Green
    return $true
}

$current = Read-VersionFiles
$qrPath = Join-Path $projectRoot 'qr.png'
$indexPath = Join-Path $projectRoot 'index.html'
$currentQrTarget = Get-QrDownloadUrl ([IO.File]::ReadAllText($indexPath))
$pendingCode = $current.VersionCode
$pendingName = $current.VersionName
$pendingApplicationId = $current.ApplicationId
$pendingAppName = $current.AppName
$pendingAppUrl = $current.AppUrl
$pendingUpdateManifestUrl = $current.UpdateManifestUrl
if (
    $current.DeviceVersionCode -gt $current.VersionCode -and
    -not [string]::IsNullOrWhiteSpace($current.DeviceVersionName)
) {
    $pendingName = $current.DeviceVersionName
}

while ($true) {
    Clear-Host
    Write-Host 'AllApp Version Update' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "Last App Name: $pendingAppName" -ForegroundColor Green
    Write-Host "Latest package full name: $pendingApplicationId" -ForegroundColor Green
    Write-Host "Current app_url: $($current.AppUrl)"
    Write-Host "Pending app_url: $pendingAppUrl" -ForegroundColor Green
    Write-Host "Current update_manifest_url: $($current.UpdateManifestUrl)"
    Write-Host "Pending update_manifest_url: $pendingUpdateManifestUrl" -ForegroundColor Green
    Write-Host "QR image: $qrPath"
    Write-Host "QR target URL: $currentQrTarget"
    Write-Host "Current: Version Name $($current.VersionName)  |  Version Code $($current.VersionCode)"
    Write-Host "Pending: Version Name $pendingName  |  Version Code $pendingCode" -ForegroundColor Green
    if ($current.ManifestApplicationId -cne $current.ApplicationId) {
        Write-Host "update.json package name is stale ($($current.ManifestApplicationId)); saving/building will sync it to $($current.ApplicationId)." -ForegroundColor Yellow
    }
    if ($current.DeviceVersionCode -gt 0) {
        Write-Host "Installed device minimum: Version Name $($current.DeviceVersionName)  |  Version Code $($current.DeviceVersionCode)" -ForegroundColor DarkGray
    } else {
        Write-Host 'No installed app version was detected by ADB; the version floor uses Gradle and update.json only.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '1. Increase Version Name (last number)'
    Write-Host '2. Decrease Version Name (last number)'
    Write-Host '3. Increase Version Code (+1)'
    Write-Host 'Save builds exactly the Pending Version Name and Version Code; values are never auto-incremented.' -ForegroundColor DarkGray
    Write-Host "For auto-update, the code must be greater than the installed code $($current.DeviceVersionCode)." -ForegroundColor DarkGray
    Write-Host '4. Decrease Version Code (-1; not below 1)'
    Write-Host '5. Set Version Name manually (custom text is allowed)'
    Write-Host '6. Set Version Code manually (any positive whole number)'
    Write-Host '7. Set Android package name (applicationId; changing it creates a separate app)'
    Write-Host '8. Set App Name'
    Write-Host '9. Set app_url (HTTPS website opened by the app)'
    Write-Host '10. Set update_manifest_url (HTTPS update manifest)'
    Write-Host '11. Refresh qr.png from the QR target URL above (no APK build)'
    Write-Host 'S. Save changes'
    Write-Host 'Q. Quit without saving'
    Write-Host 'After changing a value, choose S to save it and build the APK.' -ForegroundColor DarkGray
    Write-Host 'Or enter both on one line to save/build, e.g. Version Name 1.1, Version Code 3' -ForegroundColor DarkGray
    $choiceInput = Read-Host 'Choose 1-11, S, Q, or enter both versions'
    if ($null -eq $choiceInput) { break }
    $choice = $choiceInput.Trim()

    switch -Regex ($choice) {
        '^1$' { $pendingName = Adjust-VersionName $pendingName 1; break }
        '^2$' { $pendingName = Adjust-VersionName $pendingName -1; break }
        '^3$' {
            if ($pendingCode -eq [int]::MaxValue) {
                Write-Host 'Version Code cannot exceed the Android integer limit.' -ForegroundColor Yellow
            } else {
                $pendingCode++
            }
            break
        }
        '^4$' {
            if ($pendingCode -le 1) {
                Write-Host 'Version Code must be a positive whole number.' -ForegroundColor Yellow
            } else {
                $pendingCode--
            }
            break
        }
        '^5$' {
            $newName = (Read-Host 'Enter any Version Name text (for example 1.2-beta or AllApp Special)').Trim()
            if ([string]::IsNullOrWhiteSpace($newName) -or $newName -match '["\r\n]') {
                Write-Host 'Version Name cannot be blank or contain quotes/newlines.' -ForegroundColor Yellow
            } else {
                $pendingName = $newName
            }
            break
        }
        '^6$' {
            $newCodeText = (Read-Host 'Enter Version Code (positive whole number)').Trim()
            $newCode = 0
            if ([int]::TryParse($newCodeText, [ref]$newCode) -and $newCode -ge 1) {
                $pendingCode = $newCode
            } else {
                Write-Host 'Version Code must be a positive whole number.' -ForegroundColor Yellow
            }
            break
        }
        '^7$' {
            $newApplicationId = (Read-Host 'Enter Android package name').Trim()
            if ($newApplicationId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
                Write-Host 'Package name must contain at least two dot-separated identifier segments and use letters, digits, or underscores.' -ForegroundColor Yellow
            } else {
                $pendingApplicationId = $newApplicationId
                Write-Host 'Changing the package name creates a separate app; it will not update or transfer data from the old package.' -ForegroundColor Yellow
            }
            break
        }
        '^8$' {
            $newAppName = (Read-Host 'Enter the new App Name').Trim()
            if ([string]::IsNullOrWhiteSpace($newAppName) -or $newAppName -match '[\r\n]') {
                Write-Host 'App Name cannot be blank or contain line breaks.' -ForegroundColor Yellow
            } else {
                $pendingAppName = $newAppName
            }
            break
        }
        '^9$' {
            $newAppUrl = (Read-Host 'Enter app_url (HTTPS URL)').Trim()
            if (-not (Test-HttpsUrl $newAppUrl)) {
                Write-Host 'Enter a valid HTTPS URL without credentials or a fragment.' -ForegroundColor Yellow
            } else {
                $pendingAppUrl = $newAppUrl
            }
            break
        }
        '^10$' {
            $newUpdateManifestUrl = (Read-Host 'Enter update_manifest_url (HTTPS URL)').Trim()
            if (-not (Test-HttpsUrl $newUpdateManifestUrl)) {
                Write-Host 'Enter a valid HTTPS URL without credentials or a fragment.' -ForegroundColor Yellow
            } else {
                $pendingUpdateManifestUrl = $newUpdateManifestUrl
            }
            break
        }
        '^11$' {
            $indexHtml = [IO.File]::ReadAllText($indexPath)
            $currentQrTarget = Get-QrDownloadUrl $indexHtml
            Write-Host "Refreshing QR image: $qrPath" -ForegroundColor Cyan
            Write-ValidatedQrImage $currentQrTarget $qrPath
            $cacheKey = "$pendingCode-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
            $indexHtml = Set-IndexQrCacheKey $indexHtml $cacheKey
            [IO.File]::WriteAllText($indexPath, $indexHtml, [Text.UTF8Encoding]::new($false))
            Write-Host "Updated QR image: $qrPath" -ForegroundColor Green
            Write-Host "QR target URL: $currentQrTarget" -ForegroundColor Green
            break
        }
        '^Version\s+Name\s+([^,]+),\s*Version\s+Code\s+(\d+)$' {
            $newName = $Matches[1].Trim()
            $newCodeText = $Matches[2]
            $newCode = 0
            if (
                [string]::IsNullOrWhiteSpace($newName) -or
                $newName -match '["\r\n]' -or
                -not [int]::TryParse($newCodeText, [ref]$newCode) -or
                $newCode -lt 1
            ) {
                Write-Host 'Enter a valid Version Name and positive whole-number Version Code.' -ForegroundColor Yellow
            } else {
                $pendingName = $newName
                $pendingCode = $newCode
                Write-Host "Saving Version Name $pendingName and Version Code $pendingCode, then building the debug APK..." -ForegroundColor Cyan
                if (Save-VersionAndBuild $pendingCode $pendingName $pendingApplicationId $pendingAppName $pendingAppUrl $pendingUpdateManifestUrl) { exit 0 }
            }
            break
        }
        '^(S|SAVE)$' {
            if (Save-VersionAndBuild $pendingCode $pendingName $pendingApplicationId $pendingAppName $pendingAppUrl $pendingUpdateManifestUrl) { exit 0 }
            break
        }
        '^(Q|QUIT)$' { exit 0 }
        default { Write-Host 'Choose one of the listed options.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
}
