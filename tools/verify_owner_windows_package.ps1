[CmdletBinding()]
param(
    [string]$PackageRoot,
    [string]$BuildProject,
    [string]$ExpectedCoreSha256,
    [switch]$SelfTest,
    [switch]$FaultIsolatedDataDirectory,
    [switch]$FaultMainEntrypoint
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_package_inventory.ps1')

function Assert-OwnerConfiguration([string]$Target, [string[]]$Defines) {
    if ($Target.Replace('\', '/') -ne 'lib/shell.dart') {
        throw 'Owner package must use the product entrypoint'
    }
    foreach ($define in $Defines) {
        if ($define.StartsWith('DATA_DIR_OVERRIDE=', [StringComparison]::Ordinal)) {
            throw 'Owner package must not contain a test data-directory override'
        }
    }
}

if ($SelfTest) {
    $target = if ($FaultMainEntrypoint) { 'lib/main.dart' } else { 'lib/shell.dart' }
    $defines = if ($FaultIsolatedDataDirectory) {
        @('DATA_DIR_OVERRIDE=D:\fixture\isolated-data')
    } else {
        @('FLUTTER_BUILD_NAME=1.0.0')
    }
    Assert-OwnerConfiguration $target $defines
    [PSCustomObject]@{ ownerConfigurationAccepted = $true; uiLaunched = $false } |
        ConvertTo-Json
    exit 0
}

if (-not $PackageRoot -or -not $BuildProject -or $ExpectedCoreSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
    throw 'Explicit package, build project and approved core hash are required'
}
$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$project = (Resolve-Path -LiteralPath $BuildProject).Path
$configFile = Join-Path $project 'windows\flutter\ephemeral\generated_config.cmake'
$config = Get-Content -LiteralPath $configFile -Raw
$targets = [regex]::Matches($config, '(?m)^\s*"FLUTTER_TARGET=([^"]+)"\s*$')
$encodedDefines = [regex]::Matches($config, '(?m)^\s*"DART_DEFINES=([^"]*)"\s*$')
if ($targets.Count -ne 1 -or $encodedDefines.Count -ne 1) {
    throw 'Generated build configuration must contain one target and define set'
}
$defines = @()
if ($encodedDefines[0].Groups[1].Value) {
    foreach ($value in $encodedDefines[0].Groups[1].Value.Split(',')) {
        try {
            $defines += [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value))
        } catch {
            throw 'Generated build configuration has malformed encoded defines'
        }
    }
}
Assert-OwnerConfiguration $targets[0].Groups[1].Value $defines

$builtFiles = @(Get-WindowsPackageInventory $project)
$packageFiles = @(Get-ChildItem -LiteralPath $package -File -Recurse -Force)
if ($builtFiles.Count -eq 0 -or $builtFiles.Count -ne $packageFiles.Count) {
    throw 'Package file inventory differs from the verified build output'
}
foreach ($file in $builtFiles) {
    $relative = $file.Relative
    $delivered = Join-Path $package $relative
    if (-not (Test-Path -LiteralPath $delivered -PathType Leaf) -or
        (Get-FileHash -LiteralPath $file.FullName).Hash -ne
        (Get-FileHash -LiteralPath $delivered).Hash) {
        throw 'Package content differs from the verified build output'
    }
}
$aot = Join-Path $package 'data\app.so'
$exe = Join-Path $package 'sourin_spike.exe'
$core = Join-Path $package 'sourin_core.dll'
if ((Get-Item -LiteralPath $aot).Length -lt 5MB -or
    -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw 'Package lacks the full product frontend'
}
if ((Get-FileHash -LiteralPath $core).Hash -ne $ExpectedCoreSha256.ToUpperInvariant()) {
    throw 'Package core differs from the approved playback core'
}
[PSCustomObject]@{
    ownerConfigurationAccepted = $true
    dataDirectoryMode = 'owner-default'
    dataDirectoryOverride = ''
    filesVerified = $builtFiles.Count
    inventory = 'cmake-install-manifest-and-runtime-build-outputs'
    executableSha256 = (Get-FileHash -LiteralPath $exe).Hash
    aotSha256 = (Get-FileHash -LiteralPath $aot).Hash
    coreSha256 = (Get-FileHash -LiteralPath $core).Hash
    uiLaunched = $false
    uiAccepted = $false
} | ConvertTo-Json
