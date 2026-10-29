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

    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if (-not $curl) { throw 'curl.exe is required to refresh the QR image.' }
    $indexHtml = [IO.File]::ReadAllText($indexPath)
    $qrUrl = $null
    $rawApkMatch = [regex]::Match(
        $indexHtml,
        '(?is)<a\b(?=[^>]*\bclass="download")[^>]*\bhref="(?<url>https://raw\.githubusercontent\.com/[^/"\s]+/[^/"\s]+/main/app-debug\.apk)"'
    )
    $githubMatch = [regex]::Match(
        $indexHtml,
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

    if ($indexHtml -notmatch 'fetch\("\./update\.json"') {
        throw 'index.html is missing the configured update manifest link.'
    }
    $qrUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=600x600&format=png&data=' +
        [Uri]::EscapeDataString($rawApkUri.AbsoluteUri)
    if (Test-Path $stagedQr) { Remove-Item -LiteralPath $stagedQr -Force }
    Write-Host 'Refreshing the GitHub fallback QR image...' -ForegroundColor Cyan
    & $curl.Source '--fail' '--location' '--silent' '--show-error' '--max-time' '30' '--output' $stagedQr $qrUrl
    if ($LASTEXITCODE -ne 0) { throw "Could not refresh qr.png (curl exit code $LASTEXITCODE)." }
    $qrBytes = [IO.File]::ReadAllBytes($stagedQr)
    if (
        $qrBytes.Length -lt 100 -or
        $qrBytes[0] -ne 137 -or $qrBytes[1] -ne 80 -or
        $qrBytes[2] -ne 78 -or $qrBytes[3] -ne 71
    ) {
        throw 'The refreshed QR image is not a valid PNG.'
    }

    $expectedQr = '<img(?<attributes>[^>]*\bsrc="\./qr\.png(?:\?[^"]*)?"[^>]*)>'
    if ($indexHtml -notmatch $expectedQr) {
        throw 'Could not find the QR image element in index.html.'
    }
    $versionedQrSource = 'src="./qr.png?v=' + $VersionCode + '"'
    $indexHtml = [regex]::Replace(
        $indexHtml,
        $expectedQr,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            [regex]::Replace($match.Value, '\bsrc="\./qr\.png(?:\?[^"]*)?"', $versionedQrSource, 1)
        },
        1
    )
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

function Save-VersionAndBuild([int]$VersionCode, [string]$VersionName, [string]$ApplicationId, [string]$AppName) {
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

    $escapedAppName = [System.Security.SecurityElement]::Escape($AppName)
    $appNamePattern = '(?m)^(\s*<string\s+name="app_name"\s*>).*?(</string>\s*)$'
    if (-not [regex]::IsMatch($current.Strings, $appNamePattern)) {
        throw 'Could not find the app_name resource in strings.xml.'
    }
    $newStrings = [regex]::Replace(
        $current.Strings,
        $appNamePattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $match.Groups[1].Value + $escapedAppName + $match.Groups[2].Value
        },
        1
    )

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
    $current.Strings = $newStrings
    Write-Host ''
    Write-Host "Saved app name $AppName, application ID $ApplicationId, Version Name $VersionName, and Version Code $VersionCode." -ForegroundColor Green
    return $true
}

$current = Read-VersionFiles
$pendingCode = $current.VersionCode
$pendingName = $current.VersionName
$pendingApplicationId = $current.ApplicationId
$pendingAppName = $current.AppName
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
    Write-Host 'S. Save changes'
    Write-Host 'Q. Quit without saving'
    Write-Host 'After changing a value, choose S to save it and build the APK.' -ForegroundColor DarkGray
    Write-Host 'Or enter both on one line to save/build, e.g. Version Name 1.1, Version Code 3' -ForegroundColor DarkGray
    $choiceInput = Read-Host 'Choose 1-8, S, Q, or enter both versions'
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
                if (Save-VersionAndBuild $pendingCode $pendingName $pendingApplicationId $pendingAppName) { exit 0 }
            }
            break
        }
        '^(S|SAVE)$' {
            if (Save-VersionAndBuild $pendingCode $pendingName $pendingApplicationId $pendingAppName) { exit 0 }
            break
        }
        '^(Q|QUIT)$' { exit 0 }
        default { Write-Host 'Choose one of the listed options.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
}
