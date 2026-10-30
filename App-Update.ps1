param(
    [string]$BatchPath,
    [switch]$FormMode
)

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

function Get-LastQrTargetUrl([string]$IndexHtml) {
    $match = [regex]::Match(
        $IndexHtml,
        '(?is)<img\b(?=[^>]*\bdata-qr-target="(?<url>[^"]*)")[^>]*>'
    )
    if (-not $match.Success) {
        return Get-QrDownloadUrl $IndexHtml
    }

    $targetUrl = [System.Net.WebUtility]::HtmlDecode($match.Groups['url'].Value)
    if (-not (Test-HttpsUrl $targetUrl)) {
        throw 'The saved QR target URL in index.html is invalid.'
    }
    return $targetUrl
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

function Set-IndexQrCacheKey([string]$IndexHtml, [string]$CacheKey, [string]$QrTargetUrl) {
    $expectedQr = '<img(?<attributes>[^>]*\bsrc="\./qr\.png(?:\?[^"]*)?"[^>]*)>'
    if ($IndexHtml -notmatch $expectedQr) {
        throw 'Could not find the QR image element in index.html.'
    }

    $qrSource = 'src="./qr.png?v=' + $CacheKey + '"'
    $encodedTargetUrl = [System.Net.WebUtility]::HtmlEncode($QrTargetUrl)
    return [regex]::Replace(
        $IndexHtml,
        $expectedQr,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $imageTag = [regex]::Replace($match.Value, '\bsrc="\./qr\.png(?:\?[^"]*)?"', $qrSource, 1)
            $targetAttribute = 'data-qr-target="' + $encodedTargetUrl + '"'
            if ($imageTag -match '\bdata-qr-target="[^"]*"') {
                return [regex]::Replace($imageTag, '\bdata-qr-target="[^"]*"', $targetAttribute, 1)
            }

            $insertIndex = $imageTag.Length - 1
            if ($imageTag.EndsWith('/>')) {
                $insertIndex--
            }
            return $imageTag.Insert($insertIndex, ' ' + $targetAttribute)
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
    $downloadUrl = Get-LastQrTargetUrl $indexHtml
    Write-Host 'Refreshing the saved QR target image...' -ForegroundColor Cyan
    Write-ValidatedQrImage $downloadUrl $stagedQr
    $indexHtml = Set-IndexQrCacheKey $indexHtml $VersionCode $downloadUrl
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
    [string]$UpdateManifestUrl,
    [string]$LogoSourcePath = ''
) {
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

    $logoSource = $LogoSourcePath
    $logoDestination = $null
    $originalLogoBytes = $null
    $copyLogoRequired = $false
    $logoDestination = Join-Path $projectRoot 'app\src\main\res\drawable\logo.png'
    if ([string]::IsNullOrWhiteSpace($logoSource) -and -not (Test-Path -LiteralPath $logoDestination -PathType Leaf)) {
        $currentLogoPath = Join-Path $projectRoot ("app\src\main\res\drawable\$($current.ApplicationId.Split('.')[-1]).png")
        if (Test-Path -LiteralPath $currentLogoPath -PathType Leaf) {
            $logoSource = $currentLogoPath
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($logoSource)) {
        if ([IO.Path]::GetExtension($logoSource) -ine '.png' -or -not (Test-Path -LiteralPath $logoSource -PathType Leaf)) {
            throw 'The selected logo must be an existing PNG file.'
        }
        $copyLogoRequired = -not [string]::Equals(
            [IO.Path]::GetFullPath($logoSource),
            [IO.Path]::GetFullPath($logoDestination),
            [StringComparison]::OrdinalIgnoreCase
        )
        if (Test-Path -LiteralPath $logoDestination -PathType Leaf) {
            $originalLogoBytes = [IO.File]::ReadAllBytes($logoDestination)
        }
    }

    $originalManifest = [IO.File]::ReadAllText($manifestPath)
    try {
        if ($logoDestination -and $copyLogoRequired) {
            Copy-Item -LiteralPath $logoSource -Destination $logoDestination -Force
        }
        [IO.File]::WriteAllText($gradlePath, $newGradle, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stringsPath, $newStrings, [Text.UTF8Encoding]::new($false))
        Build-DebugApk $VersionCode $VersionName $ApplicationId
    } catch {
        [IO.File]::WriteAllText($gradlePath, $current.Gradle, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stringsPath, $current.Strings, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($manifestPath, $originalManifest, [Text.UTF8Encoding]::new($false))
        if ($logoDestination -and $copyLogoRequired) {
            if ($null -eq $originalLogoBytes) {
                if (Test-Path -LiteralPath $logoDestination -PathType Leaf) {
                    Remove-Item -LiteralPath $logoDestination -Force
                }
            } else {
                [IO.File]::WriteAllBytes($logoDestination, $originalLogoBytes)
            }
        }
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

function Save-GradleVersionValue([string]$Property, [string]$Value) {
    $gradle = [IO.File]::ReadAllText($gradlePath)
    $defaultConfigMatch = [regex]::Match(
        $gradle,
        '(?s)defaultConfig\s*\{(?<body>.*?)^\s{4}\}',
        [Text.RegularExpressions.RegexOptions]::Multiline
    )
    if (-not $defaultConfigMatch.Success) {
        throw 'Could not find the android.defaultConfig block in app/build.gradle.kts.'
    }

    $body = $defaultConfigMatch.Groups['body'].Value
    if ($Property -eq 'versionName') {
        $pattern = '(?m)^(?<prefix>\s*versionName\s*=\s*")[^"]+(?<suffix>"\s*)$'
        $escapedValue = $Value.Replace('\', '\\').Replace('"', '\"')
        $matches = [regex]::Matches($body, $pattern)
        if ($matches.Count -ne 1) {
            throw 'Could not uniquely locate versionName in app/build.gradle.kts.'
        }
        $body = [regex]::Replace(
            $body,
            $pattern,
            [System.Text.RegularExpressions.MatchEvaluator]{
                param($match)
                $match.Groups['prefix'].Value + $escapedValue + $match.Groups['suffix'].Value
            },
            1
        )
    } elseif ($Property -eq 'versionCode') {
        $pattern = '(?m)^(\s*versionCode\s*=\s*)\d+(\s*)$'
        if ([regex]::Matches($body, $pattern).Count -ne 1) {
            throw 'Could not uniquely locate versionCode in app/build.gradle.kts.'
        }
        $body = [regex]::Replace($body, $pattern, "`${1}$Value`$2", 1)
    } else {
        throw "Unsupported Gradle version property: $Property"
    }

    $newGradle = $gradle.Substring(0, $defaultConfigMatch.Groups['body'].Index) +
        $body +
        $gradle.Substring($defaultConfigMatch.Groups['body'].Index + $defaultConfigMatch.Groups['body'].Length)
    [IO.File]::WriteAllText($gradlePath, $newGradle, [Text.UTF8Encoding]::new($false))
    return Read-VersionFiles
}

if ($FormMode) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -Namespace AllAppUpdate -Name NativeWindow -MemberDefinition @'
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool ShowWindow(System.IntPtr handle, int command);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool ReleaseCapture();

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern System.IntPtr SendMessage(System.IntPtr handle, int message, int wParam, int lParam);
'@
}
try {
    $current = Read-VersionFiles
    $qrPath = Join-Path $projectRoot 'qr.png'
    $indexPath = Join-Path $projectRoot 'index.html'
    $currentQrTarget = Get-LastQrTargetUrl ([IO.File]::ReadAllText($indexPath))
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
} catch {
    if (-not $FormMode) { throw }
    [System.Windows.Forms.MessageBox]::Show(
        $_.Exception.Message,
        'Could not load update settings',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

if ($FormMode) {
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:currentQrTarget = $currentQrTarget
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AllApp - Version Update'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'None'
    $form.ClientSize = New-Object System.Drawing.Size(900, 540)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 540)
    $form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font = New-Object System.Drawing.Font('Arial', 10)
    $form.ForeColor = [System.Drawing.Color]::Black
    $form.Add_Shown({
        [void][AllAppUpdate.NativeWindow]::ShowWindow($form.Handle, 5)
        $form.Activate()
    })

    function New-UpdateCard {
        param([string]$Title, [int]$X, [int]$Y, [int]$Width, [int]$Height)
        $card = New-Object System.Windows.Forms.Panel
        $card.Location = New-Object System.Drawing.Point($X, $Y)
        $card.Size = New-Object System.Drawing.Size($Width, $Height)
        $card.BackColor = [System.Drawing.Color]::White
        $card.BorderStyle = 'FixedSingle'
        $form.Controls.Add($card)
        return $card
    }

    function Add-UpdateLabel {
        param($Card, [string]$Text, [int]$X, [int]$Y, [int]$Width = 350, [int]$Height = 20)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Location = New-Object System.Drawing.Point($X, $Y)
        $label.Size = New-Object System.Drawing.Size($Width, $Height)
        $label.Font = New-Object System.Drawing.Font('Arial', 10)
        $label.ForeColor = [System.Drawing.Color]::Black
        $Card.Controls.Add($label)
        return $label
    }

    function Add-UpdateTextBox {
        param($Card, [string]$Text, [int]$X, [int]$Y, [int]$Width)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Text = $Text
        $box.Location = New-Object System.Drawing.Point($X, $Y)
        $box.Size = New-Object System.Drawing.Size($Width, 27)
        $box.Font = New-Object System.Drawing.Font('Arial', 10)
        $box.ForeColor = [System.Drawing.Color]::Black
        $box.BorderStyle = 'FixedSingle'
        $Card.Controls.Add($box)
        return $box
    }

    function Add-UpdateButton {
        param($Card, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 30)
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Location = New-Object System.Drawing.Point($X, $Y)
        $button.Size = New-Object System.Drawing.Size($Width, $Height)
        $button.Font = New-Object System.Drawing.Font('Arial', 10)
        $button.ForeColor = [System.Drawing.Color]::Black
        $button.FlatStyle = 'System'
        $Card.Controls.Add($button)
        return $button
    }

    $versionCard = New-UpdateCard 'Version details' 20 18 420 180
    $versionCurrentLabel = Add-UpdateLabel $versionCard `
        "Current: Version Name $($current.VersionName)  |  Version Code $($current.VersionCode)" 16 12 388 22
    $null = Add-UpdateLabel $versionCard 'Pending Version Name' 16 42 175
    $versionNameBox = Add-UpdateTextBox $versionCard $pendingName 16 65 255
    $increaseNameButton = Add-UpdateButton $versionCard ([char]0xE710) 280 65 34 27
    $decreaseNameButton = Add-UpdateButton $versionCard ([char]0xE738) 318 65 34 27
    $applyVersionNameButton = Add-UpdateButton $versionCard ([char]0xE73E) 356 65 34 27
    $null = Add-UpdateLabel $versionCard 'Pending Version Code (positive whole number)' 16 107 300
    $versionCodeBox = Add-UpdateTextBox $versionCard ([string]$pendingCode) 16 130 255
    $increaseCodeButton = Add-UpdateButton $versionCard ([char]0xE710) 280 130 34 27
    $decreaseCodeButton = Add-UpdateButton $versionCard ([char]0xE738) 318 130 34 27
    $applyVersionCodeButton = Add-UpdateButton $versionCard ([char]0xE73E) 356 130 34 27
    $versionToolTip = New-Object System.Windows.Forms.ToolTip
    foreach ($button in @($increaseNameButton, $increaseCodeButton)) {
        $button.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 11)
        $versionToolTip.SetToolTip($button, 'Increase')
    }
    foreach ($button in @($decreaseNameButton, $decreaseCodeButton)) {
        $button.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 11)
        $versionToolTip.SetToolTip($button, 'Decrease')
    }
    foreach ($button in @($applyVersionNameButton, $applyVersionCodeButton)) {
        $button.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)
        $versionToolTip.SetToolTip($button, 'Save this version value without building')
    }
    function Format-UpdateUrlForDisplay([string]$Url) {
        if ([string]::IsNullOrEmpty($Url)) { return $Url }
        $middle = [int][Math]::Floor($Url.Length / 2)
        $breakAt = $Url.LastIndexOf('/', $middle)
        if ($breakAt -lt [int][Math]::Floor($Url.Length / 3)) {
            $breakAt = $Url.IndexOf('/', $middle)
            if ($breakAt -lt 0) { $breakAt = $middle }
        }
        return $Url.Substring(0, $breakAt + 1) + "`r`n" + $Url.Substring($breakAt + 1)
    }

    function ConvertFrom-UpdateUrlDisplay([string]$Text) {
        return $Text -replace '[\r\n]', ''
    }

    $appCard = New-UpdateCard 'App and update settings' 460 18 420 420
    $null = Add-UpdateLabel $appCard 'Android package name (applicationId)' 16 12 380
    $applicationIdBox = Add-UpdateTextBox $appCard $pendingApplicationId 16 34 340
    $copyApplicationIdButton = Add-UpdateButton $appCard ([char]0xE8C8) 362 34 32 27
    $newApplicationIdBox = Add-UpdateTextBox $appCard '' 16 66 340
    $applyApplicationIdButton = Add-UpdateButton $appCard ([char]0xE73E) 362 66 32 27
    $null = Add-UpdateLabel $appCard 'App name' 16 98 380
    $appNameBox = Add-UpdateTextBox $appCard $pendingAppName 16 120 340
    $copyAppNameButton = Add-UpdateButton $appCard ([char]0xE8C8) 362 120 32 27
    $newAppNameBox = Add-UpdateTextBox $appCard '' 16 152 340
    $applyAppNameButton = Add-UpdateButton $appCard ([char]0xE73E) 362 152 32 27
    $null = Add-UpdateLabel $appCard 'App website (app_url; HTTPS)' 16 184 380
    $appUrlBox = Add-UpdateTextBox $appCard $pendingAppUrl 16 206 340
    $copyAppUrlButton = Add-UpdateButton $appCard ([char]0xE8C8) 362 206 32 27
    $newAppUrlBox = Add-UpdateTextBox $appCard '' 16 238 340
    $applyAppUrlButton = Add-UpdateButton $appCard ([char]0xE73E) 362 238 32 27
    $null = Add-UpdateLabel $appCard 'Update manifest URL (HTTPS)' 16 270 380
    $manifestUrlBox = Add-UpdateTextBox $appCard $pendingUpdateManifestUrl 16 292 340
    $manifestUrlBox.Text = Format-UpdateUrlForDisplay $pendingUpdateManifestUrl
    $manifestUrlBox.Multiline = $true
    $manifestUrlBox.WordWrap = $true
    $manifestUrlBox.BorderStyle = 'None'
    $manifestUrlBox.Size = New-Object System.Drawing.Size(340, 40)
    $copyManifestUrlButton = Add-UpdateButton $appCard ([char]0xE8C8) 362 298 32 27
    $newManifestUrlBox = Add-UpdateTextBox $appCard '' 16 338 340
    $applyManifestUrlButton = Add-UpdateButton $appCard ([char]0xE73E) 362 338 32 27
    $copySettingButtons = @(
        $copyApplicationIdButton,
        $copyAppNameButton,
        $copyAppUrlButton,
        $copyManifestUrlButton
    )
    foreach ($button in $copySettingButtons) {
        $button.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)
        $versionToolTip.SetToolTip($button, 'Copy current value')
    }
    $applySettingButtons = @(
        $applyApplicationIdButton,
        $applyAppNameButton,
        $applyAppUrlButton,
        $applyManifestUrlButton
    )
    foreach ($button in $applySettingButtons) {
        $button.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)
        $versionToolTip.SetToolTip($button, 'Apply value to the field above')
    }
    function Format-UpdateQrTargetLabel([string]$TargetUrl) {
        return Format-UpdateUrlForDisplay $TargetUrl
    }

    $qrCard = New-UpdateCard 'QR code target' 20 204 420 152
    $null = Add-UpdateLabel $qrCard 'Last generated QR target URL' 16 12 385
    $qrTargetLabel = New-Object System.Windows.Forms.TextBox
    $qrTargetLabel.Text = Format-UpdateQrTargetLabel $currentQrTarget
    $qrTargetLabel.Location = New-Object System.Drawing.Point(16, 34)
    $qrTargetLabel.Size = New-Object System.Drawing.Size(340, 38)
    $qrTargetLabel.Font = New-Object System.Drawing.Font('Arial', 10)
    $qrTargetLabel.ForeColor = [System.Drawing.Color]::Black
    $qrTargetLabel.BackColor = [System.Drawing.Color]::White
    $qrTargetLabel.Multiline = $true
    $qrTargetLabel.ReadOnly = $true
    $qrTargetLabel.BorderStyle = 'None'
    $qrTargetLabel.TabStop = $true
    $qrTargetLabel.Cursor = [System.Windows.Forms.Cursors]::IBeam
    $qrCard.Controls.Add($qrTargetLabel)
    $copyQrTargetButton = Add-UpdateButton $qrCard ([char]0xE8C8) 362 36 32 27
    $copyQrTargetButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)
    $versionToolTip.SetToolTip($copyQrTargetButton, 'Copy QR target URL')
    $null = Add-UpdateLabel $qrCard 'New HTTPS target (leave blank to keep current)' 16 71 385
    $qrTargetBox = Add-UpdateTextBox $qrCard '' 16 93 338
    $refreshQrButton = Add-UpdateButton $qrCard ([char]0xE72C) 362 93 40 27
    $refreshQrButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)
    $versionToolTip.SetToolTip($refreshQrButton, 'Refresh QR image')
    $null = Add-UpdateLabel $qrCard "Image file: $qrPath" 16 123 385 18

    $script:selectedLogoPath = ''
    $script:pendingLogoPath = ''
    $previousLogoLabel = New-Object System.Windows.Forms.Label
    $previousLogoLabel.Text = 'Current logo'
    $previousLogoLabel.Location = New-Object System.Drawing.Point(22, 368)
    $previousLogoLabel.Size = New-Object System.Drawing.Size(130, 18)
    $previousLogoLabel.Font = New-Object System.Drawing.Font('Arial', 10)
    $previousLogoLabel.ForeColor = [System.Drawing.Color]::Black
    $form.Controls.Add($previousLogoLabel)

    $previousLogoPreview = New-Object System.Windows.Forms.PictureBox
    $previousLogoPreview.Location = New-Object System.Drawing.Point(22, 387)
    $previousLogoPreview.Size = New-Object System.Drawing.Size(64, 64)
    $previousLogoPreview.BorderStyle = 'FixedSingle'
    $previousLogoPreview.SizeMode = 'Zoom'
    $previousLogoPreview.BackColor = [System.Drawing.Color]::White
    $form.Controls.Add($previousLogoPreview)

    $newLogoLabel = New-Object System.Windows.Forms.Label
    $newLogoLabel.Text = 'New logo (PNG)'
    $newLogoLabel.Location = New-Object System.Drawing.Point(164, 368)
    $newLogoLabel.Size = New-Object System.Drawing.Size(145, 18)
    $newLogoLabel.Font = New-Object System.Drawing.Font('Arial', 10)
    $newLogoLabel.ForeColor = [System.Drawing.Color]::Black
    $form.Controls.Add($newLogoLabel)

    $newLogoPreview = New-Object System.Windows.Forms.PictureBox
    $newLogoPreview.Location = New-Object System.Drawing.Point(164, 387)
    $newLogoPreview.Size = New-Object System.Drawing.Size(64, 64)
    $newLogoPreview.BorderStyle = 'FixedSingle'
    $newLogoPreview.SizeMode = 'Zoom'
    $newLogoPreview.BackColor = [System.Drawing.Color]::White
    $newLogoPreview.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($newLogoPreview)

    $uploadLogoButton = New-Object System.Windows.Forms.Button
    $uploadLogoButton.Text = 'Choose PNG...'
    $uploadLogoButton.Location = New-Object System.Drawing.Point(164, 387)
    $uploadLogoButton.Size = New-Object System.Drawing.Size(64, 64)
    $uploadLogoButton.Font = New-Object System.Drawing.Font('Arial', 8)
    $uploadLogoButton.ForeColor = [System.Drawing.Color]::Black
    $uploadLogoButton.FlatStyle = 'Flat'
    $uploadLogoButton.BackColor = [System.Drawing.Color]::White
    $form.Controls.Add($uploadLogoButton)

    $applyLogoButton = New-Object System.Windows.Forms.Button
    $applyLogoButton.Text = [char]0xE73E
    $applyLogoButton.Location = New-Object System.Drawing.Point(238, 404)
    $applyLogoButton.Size = New-Object System.Drawing.Size(40, 30)
    $applyLogoButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)
    $applyLogoButton.FlatStyle = 'System'
    $applyLogoButton.Enabled = $false
    $versionToolTip.SetToolTip($applyLogoButton, 'Save as drawable/logo.png and use in the build')
    $form.Controls.Add($applyLogoButton)

    $previousLogoPath = Join-Path $projectRoot 'app\src\main\res\drawable\logo.png'
    if (-not (Test-Path -LiteralPath $previousLogoPath -PathType Leaf)) {
        $previousLogoPath = Join-Path $projectRoot ("app\src\main\res\drawable\$($current.ApplicationId.Split('.')[-1]).png")
    }
    if (Test-Path -LiteralPath $previousLogoPath -PathType Leaf) {
        $previousImage = [System.Drawing.Image]::FromFile($previousLogoPath)
        try {
            $previousLogoPreview.Image = [System.Drawing.Bitmap]::new($previousImage)
        } finally {
            $previousImage.Dispose()
        }
    } else {
        $previousLogoLabel.Text = 'Previous logo not found'
    }

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = ''
    $statusLabel.Location = New-Object System.Drawing.Point(16, 370)
    $statusLabel.Size = New-Object System.Drawing.Size(218, 42)
    $statusLabel.Font = New-Object System.Drawing.Font('Arial', 9)
    $statusLabel.ForeColor = [System.Drawing.Color]::Black
    $appCard.Controls.Add($statusLabel)

    function Copy-UpdateFieldValue([string]$Text, [string]$FieldName) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            $statusLabel.Text = "$FieldName copied to clipboard."
        } catch {
            $statusLabel.Text = "Could not copy $FieldName."
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Could not copy $FieldName.`r`n$($_.Exception.Message)",
                'Copy failed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    }

    function Apply-UpdateFieldValue($SourceBox, $TargetBox, [string]$FieldType, [string]$FieldName) {
        $value = $SourceBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            $statusLabel.Text = "Enter a new $FieldName in the empty field first."
            return
        }

        switch ($FieldType) {
            'applicationId' {
                if ($value -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
                    $statusLabel.Text = 'Enter a valid Android package name with at least two dot-separated segments.'
                    return
                }
            }
            'appName' {
                if ($value -match '[\r\n]') {
                    $statusLabel.Text = 'App Name cannot contain line breaks.'
                    return
                }
            }
            'httpsUrl' {
                if (-not (Test-HttpsUrl $value)) {
                    $statusLabel.Text = "Enter a valid HTTPS $FieldName without credentials or a fragment."
                    return
                }
            }
        }

        if ($FieldName -eq 'update manifest URL') {
            $TargetBox.Text = Format-UpdateUrlForDisplay $value
        } else {
            $TargetBox.Text = $value
        }
        $SourceBox.Clear()
        $statusLabel.Text = "$FieldName updated in the main field. Save & Build to save the settings."
    }

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = 'Save & Build'
    $saveButton.UseMnemonic = $false
    $saveButton.Location = New-Object System.Drawing.Point(242, 370)
    $saveButton.Size = New-Object System.Drawing.Size(160, 38)
    $saveButton.Font = New-Object System.Drawing.Font('Arial', 10, [System.Drawing.FontStyle]::Bold)
    $saveButton.BackColor = [System.Drawing.Color]::FromArgb(35, 105, 177)
    $saveButton.ForeColor = [System.Drawing.Color]::Black
    $saveButton.FlatStyle = 'Flat'
    $appCard.Controls.Add($saveButton)

    foreach ($control in @($form.Controls)) {
        $control.Top += 34
    }

    $titleBar = New-Object System.Windows.Forms.Panel
    $titleBar.Location = New-Object System.Drawing.Point(0, 0)
    $titleBar.Size = New-Object System.Drawing.Size(900, 34)
    $titleBar.BackColor = [System.Drawing.SystemColors]::Control
    $titleBar.ForeColor = [System.Drawing.Color]::Black
    $form.Controls.Add($titleBar)
    $titleBar.BringToFront()

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'AllApp - Version Update'
    $titleLabel.Location = New-Object System.Drawing.Point(10, 7)
    $titleLabel.Size = New-Object System.Drawing.Size(650, 20)
    $titleLabel.Font = New-Object System.Drawing.Font('Arial', 10, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::Black
    $titleBar.Controls.Add($titleLabel)

    $restartButton = New-Object System.Windows.Forms.Button
    $restartButton.Text = [char]0xE72C
    $restartButton.Location = New-Object System.Drawing.Point(716, 0)
    $restartButton.Size = New-Object System.Drawing.Size(46, 34)
    $restartButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)
    $restartButton.FlatStyle = 'Flat'
    $restartButton.FlatAppearance.BorderSize = 0
    $restartButton.BackColor = [System.Drawing.SystemColors]::Control
    $restartButton.ForeColor = [System.Drawing.Color]::Black
    $titleBar.Controls.Add($restartButton)

    $minimizeButton = New-Object System.Windows.Forms.Button
    $minimizeButton.Text = [char]0xE921
    $minimizeButton.Location = New-Object System.Drawing.Point(762, 0)
    $minimizeButton.Size = New-Object System.Drawing.Size(46, 34)
    $minimizeButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 9)
    $minimizeButton.FlatStyle = 'Flat'
    $minimizeButton.FlatAppearance.BorderSize = 0
    $minimizeButton.BackColor = [System.Drawing.SystemColors]::Control
    $minimizeButton.ForeColor = [System.Drawing.Color]::Black
    $titleBar.Controls.Add($minimizeButton)

    $maximizeButton = New-Object System.Windows.Forms.Button
    $maximizeButton.Text = [char]0xE922
    $maximizeButton.Location = New-Object System.Drawing.Point(808, 0)
    $maximizeButton.Size = New-Object System.Drawing.Size(46, 34)
    $maximizeButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 9)
    $maximizeButton.FlatStyle = 'Flat'
    $maximizeButton.FlatAppearance.BorderSize = 0
    $maximizeButton.BackColor = [System.Drawing.SystemColors]::Control
    $maximizeButton.ForeColor = [System.Drawing.Color]::Black
    $titleBar.Controls.Add($maximizeButton)

    $closeWindowButton = New-Object System.Windows.Forms.Button
    $closeWindowButton.Text = [char]0xE8BB
    $closeWindowButton.Location = New-Object System.Drawing.Point(854, 0)
    $closeWindowButton.Size = New-Object System.Drawing.Size(46, 34)
    $closeWindowButton.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 9)
    $closeWindowButton.FlatStyle = 'Flat'
    $closeWindowButton.FlatAppearance.BorderSize = 0
    $closeWindowButton.BackColor = [System.Drawing.SystemColors]::Control
    $closeWindowButton.ForeColor = [System.Drawing.Color]::Black
    $titleBar.Controls.Add($closeWindowButton)

    $restartToolTip = New-Object System.Windows.Forms.ToolTip
    $restartToolTip.SetToolTip($restartButton, 'Restart this form')
    $titleBar.Add_MouseDown({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            [void][AllAppUpdate.NativeWindow]::ReleaseCapture()
            [void][AllAppUpdate.NativeWindow]::SendMessage($form.Handle, 0xA1, 2, 0)
        }
    })
    $titleLabel.Add_MouseDown({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            [void][AllAppUpdate.NativeWindow]::ReleaseCapture()
            [void][AllAppUpdate.NativeWindow]::SendMessage($form.Handle, 0xA1, 2, 0)
        }
    })
    $restartButton.Add_Click({
        try {
            $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -BatchPath "{1}" -FormMode' -f $PSCommandPath, $BatchPath
            Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Hidden
            $form.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Could not restart the form.`r`n$($_.Exception.Message)",
                'Restart failed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })
    $minimizeButton.Add_Click({ $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized })
    $maximizeButton.Add_Click({
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized) {
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $maximizeButton.Text = [char]0xE922
        } else {
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
            $maximizeButton.Text = [char]0xE923
        }
    })
    $closeWindowButton.Add_Click({ $form.Close() })
    $form.Add_FormClosed({
        $restartToolTip.Dispose()
        $versionToolTip.Dispose()
        if ($previousLogoPreview.Image) { $previousLogoPreview.Image.Dispose() }
        if ($newLogoPreview.Image) { $newLogoPreview.Image.Dispose() }
    })

    $selectNewLogo = {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select the new app logo'
        $dialog.Filter = 'PNG images (*.png)|*.png'
        $dialog.Multiselect = $false
        try {
            if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
                return
            }
            if ([IO.Path]::GetExtension($dialog.FileName) -ine '.png') {
                throw 'Select a PNG image for the app logo.'
            }

            $loadedImage = [System.Drawing.Image]::FromFile($dialog.FileName)
            try {
                if ($loadedImage.RawFormat.Guid -ne [System.Drawing.Imaging.ImageFormat]::Png.Guid) {
                    throw 'The selected file is not a valid PNG image.'
                }
                if ($newLogoPreview.Image) { $newLogoPreview.Image.Dispose() }
                $newLogoPreview.Image = [System.Drawing.Bitmap]::new($loadedImage)
            } finally {
                $loadedImage.Dispose()
            }

            $script:selectedLogoPath = $dialog.FileName
            $uploadLogoButton.Visible = $false
            $applyLogoButton.Enabled = $true
            $statusLabel.Text = 'New logo selected. Click the check icon to stage it for Save & Build.'
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Could not load the selected logo.`r`n$($_.Exception.Message)",
                'Logo selection failed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        } finally {
            $dialog.Dispose()
        }
    }
    $uploadLogoButton.Add_Click($selectNewLogo)
    $newLogoPreview.Add_Click($selectNewLogo)
    $applyLogoButton.Add_Click({
        if (
            [string]::IsNullOrWhiteSpace($script:selectedLogoPath) -or
            -not (Test-Path -LiteralPath $script:selectedLogoPath -PathType Leaf)
        ) {
            $statusLabel.Text = 'Choose a PNG logo first.'
            return
        }
        $logoDestination = Join-Path $projectRoot 'app\src\main\res\drawable\logo.png'
        $stagedLogoPath = Join-Path (Split-Path -Parent $logoDestination) ("logo-" + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $selectedPath = [IO.Path]::GetFullPath($script:selectedLogoPath)
            if (-not [string]::Equals(
                $selectedPath,
                [IO.Path]::GetFullPath($logoDestination),
                [StringComparison]::OrdinalIgnoreCase
            )) {
                Copy-Item -LiteralPath $selectedPath -Destination $stagedLogoPath
                Move-Item -LiteralPath $stagedLogoPath -Destination $logoDestination -Force
            }

            $savedImage = [System.Drawing.Image]::FromFile($logoDestination)
            try {
                $updatedPreview = [System.Drawing.Bitmap]::new($savedImage)
            } finally {
                $savedImage.Dispose()
            }
            if ($previousLogoPreview.Image) { $previousLogoPreview.Image.Dispose() }
            $previousLogoPreview.Image = $updatedPreview
            $previousLogoLabel.Text = 'Current logo'

            if ($newLogoPreview.Image) {
                $newLogoPreview.Image.Dispose()
                $newLogoPreview.Image = $null
            }
            $uploadLogoButton.Visible = $true
            $applyLogoButton.Enabled = $false
            $script:pendingLogoPath = $logoDestination
            $script:selectedLogoPath = ''
            $statusLabel.Text = 'Logo saved to drawable/logo.png and shown on the left.'
        } catch {
            if (Test-Path -LiteralPath $stagedLogoPath -PathType Leaf) {
                Remove-Item -LiteralPath $stagedLogoPath -Force
            }
            $statusLabel.Text = 'Could not save the selected logo.'
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Could not save the selected logo to drawable/logo.png.`r`n$($_.Exception.Message)",
                'Logo save failed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })

    $copyApplicationIdButton.Add_Click({
        Copy-UpdateFieldValue $applicationIdBox.Text 'Application ID'
    })
    $copyAppNameButton.Add_Click({
        Copy-UpdateFieldValue $appNameBox.Text 'App name'
    })
    $copyAppUrlButton.Add_Click({
        Copy-UpdateFieldValue $appUrlBox.Text 'App website'
    })
    $copyManifestUrlButton.Add_Click({
        Copy-UpdateFieldValue (ConvertFrom-UpdateUrlDisplay $manifestUrlBox.Text) 'Update manifest URL'
    })
    $applyApplicationIdButton.Add_Click({
        Apply-UpdateFieldValue $newApplicationIdBox $applicationIdBox 'applicationId' 'Application ID'
    })
    $applyAppNameButton.Add_Click({
        Apply-UpdateFieldValue $newAppNameBox $appNameBox 'appName' 'App name'
    })
    $applyAppUrlButton.Add_Click({
        Apply-UpdateFieldValue $newAppUrlBox $appUrlBox 'httpsUrl' 'app website'
    })
    $applyManifestUrlButton.Add_Click({
        Apply-UpdateFieldValue $newManifestUrlBox $manifestUrlBox 'httpsUrl' 'update manifest URL'
    })

    $increaseNameButton.Add_Click({
        try {
            $versionNameBox.Text = Adjust-VersionName $versionNameBox.Text 1
        } catch {
            $statusLabel.Text = $_.Exception.Message
        }
    })
    $decreaseNameButton.Add_Click({
        try {
            $versionNameBox.Text = Adjust-VersionName $versionNameBox.Text -1
        } catch {
            $statusLabel.Text = $_.Exception.Message
        }
    })
    $increaseCodeButton.Add_Click({
        $code = 0
        if (-not [int]::TryParse($versionCodeBox.Text, [ref]$code) -or $code -lt 1) {
            $statusLabel.Text = 'Version Code must be a positive whole number before it can be adjusted.'
        } elseif ($code -eq [int]::MaxValue) {
            $statusLabel.Text = 'Version Code cannot exceed the Android integer limit.'
        } else {
            $versionCodeBox.Text = [string]($code + 1)
        }
    })
    $applyVersionNameButton.Add_Click({
        $name = $versionNameBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or $name -match '["\r\n]') {
            $statusLabel.Text = 'Version Name cannot be blank or contain quotes/newlines.'
            return
        }
        try {
            $current = Save-GradleVersionValue 'versionName' $name
            $pendingName = $name
            $versionCurrentLabel.Text = "Current: Version Name $($current.VersionName)  |  Version Code $($current.VersionCode)"
            $statusLabel.Text = "Version Name $name saved to Gradle. No APK was built."
        } catch {
            $statusLabel.Text = 'Could not save Version Name to Gradle.'
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Could not save Version Name to Gradle.`r`n$($_.Exception.Message)",
                'Version Name save failed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })
    $applyVersionCodeButton.Add_Click({
        $code = 0
        if (-not [int]::TryParse($versionCodeBox.Text.Trim(), [ref]$code) -or $code -lt 1) {
            $statusLabel.Text = 'Version Code must be a positive whole number.'
            return
        }
        try {
            $current = Save-GradleVersionValue 'versionCode' ([string]$code)
            $pendingCode = $code
            $versionCurrentLabel.Text = "Current: Version Name $($current.VersionName)  |  Version Code $($current.VersionCode)"
            $statusLabel.Text = "Version Code $code saved to Gradle. No APK was built."
        } catch {
            $statusLabel.Text = 'Could not save Version Code to Gradle.'
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Could not save Version Code to Gradle.`r`n$($_.Exception.Message)",
                'Version Code save failed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })
    $decreaseCodeButton.Add_Click({
        $code = 0
        if (-not [int]::TryParse($versionCodeBox.Text, [ref]$code) -or $code -le 1) {
            $statusLabel.Text = 'Version Code must remain a positive whole number.'
        } else {
            $versionCodeBox.Text = [string]($code - 1)
        }
    })
    $copyQrTargetButton.Add_Click({
        try {
            [System.Windows.Forms.Clipboard]::SetText($script:currentQrTarget)
            $statusLabel.Text = 'QR target URL copied to clipboard.'
        } catch {
            $statusLabel.Text = 'Could not copy the QR target URL.'
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Could not copy the QR target URL.`r`n$($_.Exception.Message)",
                'Copy failed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })
    $refreshQrButton.Add_Click({
        $newQrTarget = $qrTargetBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($newQrTarget)) {
            $newQrTarget = $script:currentQrTarget
        } elseif (-not (Test-HttpsUrl $newQrTarget)) {
            $statusLabel.Text = 'Enter a valid HTTPS QR target without credentials or a fragment.'
            return
        }

        $refreshQrButton.Enabled = $false
        $statusLabel.Text = 'Refreshing QR image...'
        $form.Refresh()
        try {
            $indexHtml = [IO.File]::ReadAllText($indexPath)
            Write-ValidatedQrImage $newQrTarget $qrPath
            $cacheVersionCode = $current.VersionCode
            $enteredVersionCode = 0
            if ([int]::TryParse($versionCodeBox.Text.Trim(), [ref]$enteredVersionCode) -and $enteredVersionCode -gt 0) {
                $cacheVersionCode = $enteredVersionCode
            }
            $cacheKey = "$cacheVersionCode-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
            $indexHtml = Set-IndexQrCacheKey $indexHtml $cacheKey $newQrTarget
            [IO.File]::WriteAllText($indexPath, $indexHtml, [Text.UTF8Encoding]::new($false))
            $script:currentQrTarget = $newQrTarget
            $qrTargetLabel.Text = Format-UpdateQrTargetLabel $script:currentQrTarget
            $qrTargetBox.Clear()
            $statusLabel.Text = 'QR image and saved target updated. No APK build was started.'
        } catch {
            $statusLabel.Text = 'Could not refresh the QR image.'
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Could not refresh the QR image.`r`n$($_.Exception.Message)",
                'QR refresh failed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        } finally {
            $refreshQrButton.Enabled = $true
        }
    })
    $saveButton.Add_Click({
        $name = $versionNameBox.Text.Trim()
        $code = 0
        $applicationId = $applicationIdBox.Text.Trim()
        $appName = $appNameBox.Text.Trim()
        $appUrl = $appUrlBox.Text.Trim()
        $updateUrl = (ConvertFrom-UpdateUrlDisplay $manifestUrlBox.Text).Trim()

        if ([string]::IsNullOrWhiteSpace($name) -or $name -match '["\r\n]') {
            $statusLabel.Text = 'Version Name cannot be blank or contain quotes/newlines.'
            return
        }
        if (-not [int]::TryParse($versionCodeBox.Text.Trim(), [ref]$code) -or $code -lt 1) {
            $statusLabel.Text = 'Version Code must be a positive whole number.'
            return
        }
        if ($applicationId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
            $statusLabel.Text = 'Enter a valid Android package name with at least two dot-separated segments.'
            return
        }
        if ([string]::IsNullOrWhiteSpace($appName) -or $appName -match '[\r\n]') {
            $statusLabel.Text = 'App Name cannot be blank or contain line breaks.'
            return
        }
        if (-not (Test-HttpsUrl $appUrl)) {
            $statusLabel.Text = 'Enter a valid HTTPS app website without credentials or a fragment.'
            return
        }
        if (-not (Test-HttpsUrl $updateUrl)) {
            $statusLabel.Text = 'Enter a valid HTTPS update manifest URL without credentials or a fragment.'
            return
        }
        if ($applicationId -cne $current.ApplicationId) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Changing the package name creates a separate app and does not transfer existing app data.`r`n`r`nThe current logo will be reused unless you selected a new logo. Continue?",
                'Package name changed',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $saveButton.Enabled = $false
        $refreshQrButton.Enabled = $false
        $statusLabel.Text = 'Saving and building the APK... This may take several minutes.'
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        try {
            Save-VersionAndBuild $code $name $applicationId $appName $appUrl $updateUrl $script:pendingLogoPath | Out-Null
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "The debug APK was built and verified successfully.`r`n`r`nApp Name: $appName`r`nVersion Name: $name`r`nVersion Code: $code`r`nApp Website: $appUrl",
                'Update prepared',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            $versionCurrentLabel.Text = "Current: Version Name $($current.VersionName)  |  Version Code $($current.VersionCode)"
            $statusLabel.Text = 'Build completed successfully. Close the form when you are ready.'
            $saveButton.Enabled = $true
            $refreshQrButton.Enabled = $true
        } catch {
            $saveButton.Enabled = $true
            $refreshQrButton.Enabled = $true
            $statusLabel.Text = 'Build failed. Pending values remain in the form.'
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Version update/build failed.`r`n$($_.Exception.Message)",
                'Build failed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })

    [void]$form.ShowDialog()
    exit 0
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
    Write-Host "Last QR image link: $currentQrTarget"
    Write-Host "Current: Version Name $($current.VersionName)  |  Version Code $($current.VersionCode)"
    Write-Host "Pending: Version Name $pendingName  |  Version Code $pendingCode" -ForegroundColor Green
    if ($current.ManifestApplicationId -cne $current.ApplicationId) {
        Write-Host "update.json package name is stale ($($current.ManifestApplicationId)); saving/building will sync it to $($current.ApplicationId)." -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '1. Increase Version Name (last number)'
    Write-Host '2. Decrease Version Name (last number)'
    Write-Host '3. Increase Version Code (+1)'
    Write-Host 'Save builds exactly the Pending Version Name and Version Code; values are never auto-incremented.' -ForegroundColor DarkGray
    Write-Host '4. Decrease Version Code (-1; not below 1)'
    Write-Host '5. Set Version Name manually (custom text is allowed)'
    Write-Host '6. Set Version Code manually (any positive whole number)'
    Write-Host '7. Set Android package name (applicationId; changing it creates a separate app)'
    Write-Host '8. Set App Name'
    Write-Host '9. Set app_url (HTTPS website opened by the app)'
    Write-Host '10. Set update_manifest_url (HTTPS update manifest)'
    Write-Host '11. Set QR target URL and refresh qr.png (no APK build)'
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
            $currentQrTarget = Get-LastQrTargetUrl $indexHtml
            $newQrTarget = (Read-Host 'Enter QR target URL (blank keeps current)').Trim()
            if (-not [string]::IsNullOrWhiteSpace($newQrTarget)) {
                if (-not (Test-HttpsUrl $newQrTarget)) {
                    Write-Host 'Enter a valid HTTPS URL without credentials or a fragment.' -ForegroundColor Yellow
                    break
                }
                $currentQrTarget = $newQrTarget
            }

            Write-Host "Refreshing QR image: $qrPath" -ForegroundColor Cyan
            Write-ValidatedQrImage $currentQrTarget $qrPath
            $cacheKey = "$pendingCode-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
            $indexHtml = Set-IndexQrCacheKey $indexHtml $cacheKey $currentQrTarget
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
