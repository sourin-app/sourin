# Resolve only an SDK launcher or a native command on PATH (not a PS alias/function).
function Resolve-SourinFlutter {
    [CmdletBinding()]
    param([switch]$PathFirst)

    $configuredLauncher = $null
    foreach ($sdkVar in 'SOURIN_FLUTTER_ROOT', 'FLUTTER_ROOT') {
        $sdk = [Environment]::GetEnvironmentVariable($sdkVar)
        if ([string]::IsNullOrEmpty($sdk)) { continue }

        $sdkDir = Get-Item -LiteralPath $sdk -ErrorAction SilentlyContinue
        if ($sdkDir -is [IO.DirectoryInfo]) {
            $launcher = [IO.Path]::Combine($sdkDir.FullName, 'bin', 'flutter.bat')
            if ([IO.File]::Exists($launcher)) {
                $configuredLauncher = $launcher
                break
            }
        }
        # An explicitly configured fallback must not silently pick a different SDK.
        throw "$sdkVar must point to a Flutter SDK containing bin\flutter.bat."
    }

    if ($PathFirst) {
        $command = Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue
        if ($command) { return $command.Path }
    }
    if ($configuredLauncher) { return $configuredLauncher }

    if (-not $PathFirst) {
        $command = Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue
        if ($command) { return $command.Path }
    }
    throw 'flutter not found on PATH; set SOURIN_FLUTTER_ROOT or FLUTTER_ROOT to the Flutter SDK directory.'
}
