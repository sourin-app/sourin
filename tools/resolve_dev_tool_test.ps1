# Offline Windows test: launches isolated PowerShell children and fixture .bat files.
[CmdletBinding()]
param(
    [switch]$Child,
    [switch]$PathFirst,
    [string]$ScratchParent = [IO.Path]::GetTempPath()
)
$ErrorActionPreference = 'Stop'

if ($Child) {
    . (Join-Path $PSScriptRoot 'resolve_dev_tool.ps1')
    try {
        $tool = Resolve-SourinFlutter -PathFirst:$PathFirst
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 2
    }
    & $tool
    exit $LASTEXITCODE
}

$fixture = Join-Path $ScratchParent ('portable tools ' + [guid]::NewGuid())
$sdkDir = Join-Path $fixture 'configured SDK'
$sdkBin = Join-Path $sdkDir 'bin'
$pathBin = Join-Path $fixture 'PATH bin'
$emptyBin = Join-Path $fixture 'empty bin'
$hostExe = (Get-Process -Id $PID).Path

function Test-Resolution($Case, $Override, $FlutterRoot, $PathDir, $First, $Exit, $Expected) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $hostExe
    $psi.Arguments = '-NoProfile -NonInteractive -File "' + $PSCommandPath + '" -Child'
    if ($First) { $psi.Arguments += ' -PathFirst' }
    $psi.WorkingDirectory = $fixture
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables.Clear()
    $psi.EnvironmentVariables['SystemRoot'] = $env:SystemRoot
    $psi.EnvironmentVariables['ComSpec'] = $env:ComSpec
    $psi.EnvironmentVariables['TEMP'] = $fixture
    $psi.EnvironmentVariables['TMP'] = $fixture
    $psi.EnvironmentVariables['PATH'] = $PathDir
    $psi.EnvironmentVariables['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'
    if ($Override) { $psi.EnvironmentVariables['SOURIN_FLUTTER_ROOT'] = $Override }
    if ($FlutterRoot) { $psi.EnvironmentVariables['FLUTTER_ROOT'] = $FlutterRoot }

    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(20000)) { $proc.Kill(); throw "$Case timed out" }
        $stdout = $outTask.Result.Trim()
        $stderr = $errTask.Result.Trim()
        $actual = $proc.ExitCode
        Write-Host "$Case exit=$actual stdout=[$stdout] stderr=[$stderr]"
        if ($actual -ne $Exit -or
            ($Exit -eq 0 -and ($stdout -cne $Expected -or $stderr)) -or
            ($Exit -ne 0 -and ($stdout -or $stderr -notlike $Expected))) {
            throw "$Case did not match the expected resolver/launcher result"
        }
    } finally {
        $proc.Dispose()
    }
}

[IO.Directory]::CreateDirectory($fixture) | Out-Null
try {
    foreach ($dir in $sdkBin, $pathBin, $emptyBin) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $sdkBin 'flutter.bat'), "@echo off`r`necho FIXTURE-SDK`r`nexit /b 0`r`n")
    [IO.File]::WriteAllText((Join-Path $pathBin 'flutter.bat'), "@echo off`r`necho FIXTURE-PATH`r`nexit /b 0`r`n")

    Test-Resolution 'bad explicit SDK despite available PATH' $emptyBin $sdkDir $pathBin $false 2 'SOURIN_FLUTTER_ROOT must point to*'
    Test-Resolution 'bad explicit SDK despite PATH-first mode' $emptyBin $sdkDir $pathBin $true 2 'SOURIN_FLUTTER_ROOT must point to*'
    Test-Resolution 'bad fallback SDK without PATH' $null $emptyBin $emptyBin $true 2 'FLUTTER_ROOT must point to*'
    Test-Resolution 'no SDK and no PATH command' $null $null $emptyBin $false 2 'flutter not found on PATH*'
    Test-Resolution 'SDK first when both present' $sdkDir $emptyBin $pathBin $false 0 'FIXTURE-SDK'
    Test-Resolution 'PATH first when both present' $sdkDir $null $pathBin $true 0 'FIXTURE-PATH'
    Test-Resolution 'default PATH fallback' $null $null $pathBin $false 0 'FIXTURE-PATH'
    Test-Resolution 'FLUTTER_ROOT fallback when PATH lacks flutter' $null $sdkDir $emptyBin $true 0 'FIXTURE-SDK'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
