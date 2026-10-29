$ErrorActionPreference = 'Stop'

try {
    $gradlePath = Join-Path $PSScriptRoot 'app\build.gradle.kts'
    $gradle = [IO.File]::ReadAllText($gradlePath)
    $defaultConfig = [regex]::Match(
        $gradle,
        '(?s)defaultConfig\s*\{(?<body>.*?)^\s{4}\}',
        [Text.RegularExpressions.RegexOptions]::Multiline
    )
    $match = [regex]::Match(
        $defaultConfig.Groups['body'].Value,
        '(?m)^\s*applicationId\s*=\s*"(?<value>[^"]+)"\s*$'
    )
    if (-not $defaultConfig.Success -or -not $match.Success) {
        throw 'Could not read applicationId from app/build.gradle.kts.'
    }

    $applicationId = $match.Groups['value'].Value
    if ($applicationId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
        throw "The Android application ID is invalid: $applicationId"
    }

    [Console]::Out.WriteLine($applicationId)
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
