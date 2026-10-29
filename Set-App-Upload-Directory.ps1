param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [string]$RepositoryUrl = 'https://github.com/jakirfile/allapp.git',
    [string]$ResultPath,
    [switch]$SaveRepositoryPreference,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($env:APP_UPLOAD_REPOSITORY_URL)) {
    $RepositoryUrl = $env:APP_UPLOAD_REPOSITORY_URL
}
$repositoryUri = $null
if (-not [Uri]::TryCreate($RepositoryUrl.Trim(), [UriKind]::Absolute, [ref]$repositoryUri)) {
    throw 'Enter a valid HTTPS GitHub repository URL.'
}
if (
    $repositoryUri.Scheme -ne 'https' -or
    $repositoryUri.Host -ine 'github.com' -or
    $repositoryUri.UserInfo -or
    $repositoryUri.Query -or
    $repositoryUri.Fragment
) {
    throw 'Use an HTTPS GitHub repository URL such as https://github.com/owner/repository.git.'
}

$repositorySegments = @($repositoryUri.AbsolutePath.Trim('/').Split('/'))
if ($repositorySegments.Count -ne 2) {
    throw 'The GitHub repository URL must contain exactly an owner and repository name.'
}
$repositoryOwner = $repositorySegments[0]
$repositoryName = $repositorySegments[1]
if ($repositoryName.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
    $repositoryName = $repositoryName.Substring(0, $repositoryName.Length - 4)
}
if (
    $repositoryOwner -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$' -or
    $repositoryName -notmatch '^[A-Za-z0-9._-]{1,100}$' -or
    $repositoryName -in @('.', '..') -or
    $repositoryName.EndsWith('.')
) {
    throw 'The GitHub owner or repository name is invalid.'
}
$repositorySlug = "$repositoryOwner/$repositoryName"
$repositoryPage = "https://github.com/$repositorySlug"

$directory = [string]$env:UPLOAD_DIRECTORY
if ([string]::IsNullOrWhiteSpace($directory)) {
    $directory = '.'
}

$directory = $directory.Trim().Replace('\', '/')
if ($directory -eq '.') {
    $normalizedDirectory = '.'
    $urlDirectory = ''
} else {
    $segments = $directory.Split('/')
    if (
        $directory.StartsWith('/') -or
        $directory -match '^[A-Za-z]:' -or
        @(
            $segments | Where-Object {
                $_ -notmatch '^[A-Za-z0-9._ -]+$' -or
                $_ -eq '.' -or
                $_ -eq '..' -or
                $_ -match '^\s|\s$|\.$'
            }
        ).Count -gt 0
    ) {
        throw 'Use a relative directory path with letters, numbers, spaces, dot, underscore, or hyphen only. Do not use . or .. path segments.'
    }

    $normalizedDirectory = $segments -join '/'
    $encodedSegments = @($segments | ForEach-Object { [Uri]::EscapeDataString($_) })
    $urlDirectory = '/' + ($encodedSegments -join '/')
}

$projectPath = [IO.Path]::GetFullPath($ProjectRoot)
$stringsPath = Join-Path $projectPath 'app\src\main\res\values\strings.xml'
$indexPath = Join-Path $projectPath 'index.html'
$qrPath = Join-Path $projectPath 'qr.png'
$repositoryPreferencePath = Join-Path $env:LOCALAPPDATA 'AllApp\App-Debug-Upload.repository'
$rawBaseUrl = "https://raw.githubusercontent.com/$repositorySlug/main$urlDirectory"
$manifestUrl = $rawBaseUrl + '/update.json'
$apkUrl = $rawBaseUrl + '/app-debug.apk'

if ($SaveRepositoryPreference) {
    $preferenceDirectory = Split-Path -Parent $repositoryPreferencePath
    New-Item -ItemType Directory -Path $preferenceDirectory -Force | Out-Null
    [IO.File]::WriteAllText(
        $repositoryPreferencePath,
        "$repositoryPage.git$([Environment]::NewLine)",
        [Text.UTF8Encoding]::new($false)
    )
}

if ($Apply) {
    $strings = [IO.File]::ReadAllText($stringsPath)
    $manifestPattern = '(<string\s+name="update_manifest_url"[^>]*>)[^<]*(</string>)'
    if (-not [regex]::IsMatch($strings, $manifestPattern)) {
        throw "Could not find update_manifest_url in $stringsPath."
    }
    $html = [IO.File]::ReadAllText($indexPath, [Text.Encoding]::UTF8)
    $downloadPattern = '(?s)(<a\b(?=[^>]*\bclass="download")[^>]*\bhref=")[^"]*(")'
    $repositoryPattern = '(?s)(<a\b(?=[^>]*\bclass="fallback-link")[^>]*\bhref=")[^"]*(")'
    if (-not [regex]::IsMatch($html, $downloadPattern)) {
        throw "Could not find the download link in $indexPath."
    }
    if (-not [regex]::IsMatch($html, $repositoryPattern)) {
        throw "Could not find the GitHub repository link in $indexPath."
    }

    if ($apkUrl -cne 'https://raw.githubusercontent.com/jakirfile/allapp/main/app-debug.apk') {
        $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
        if (-not $curl) {
            throw 'curl.exe is required to refresh qr.png for the selected repository.'
        }
        $qrTempPath = "$qrPath.$([Guid]::NewGuid().ToString('N')).tmp"
        try {
            $qrUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=600x600&format=png&data=' +
                [Uri]::EscapeDataString($apkUrl)
            & $curl.Source '--fail' '--location' '--silent' '--show-error' '--max-time' '30' '--output' $qrTempPath $qrUrl
            if ($LASTEXITCODE -ne 0) {
                throw "Could not refresh qr.png (curl exit code $LASTEXITCODE)."
            }
            $qrBytes = [IO.File]::ReadAllBytes($qrTempPath)
            if (
                $qrBytes.Length -lt 100 -or
                $qrBytes[0] -ne 137 -or $qrBytes[1] -ne 80 -or
                $qrBytes[2] -ne 78 -or $qrBytes[3] -ne 71
            ) {
                throw 'The refreshed QR image is not a valid PNG.'
            }
            Move-Item -LiteralPath $qrTempPath -Destination $qrPath -Force
        } finally {
            if (Test-Path -LiteralPath $qrTempPath) {
                Remove-Item -LiteralPath $qrTempPath -Force
            }
        }
    }

    $strings = [regex]::Replace(
        $strings,
        $manifestPattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $match.Groups[1].Value + $manifestUrl + $match.Groups[2].Value
        },
        1
    )
    $html = [regex]::Replace(
        $html,
        $downloadPattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $match.Groups[1].Value + $apkUrl + $match.Groups[2].Value
        },
        1
    )
    $html = [regex]::Replace(
        $html,
        $repositoryPattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $match.Groups[1].Value + $repositoryPage + $match.Groups[2].Value
        },
        1
    )
    [IO.File]::WriteAllText($stringsPath, $strings, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($indexPath, $html, [Text.UTF8Encoding]::new($false))
}

$resultUrlDirectory = if ([string]::IsNullOrEmpty($urlDirectory)) {
    '.'
} else {
    $urlDirectory.TrimStart('/')
}
$result = "$normalizedDirectory|$resultUrlDirectory|$repositorySlug|$repositoryOwner|$repositoryName"
if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    Write-Output $result
} else {
    [IO.File]::WriteAllText($ResultPath, "$result$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
}
