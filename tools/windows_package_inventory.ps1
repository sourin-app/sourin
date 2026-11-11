# Shared runtime inventory for packaging and verification. CMake's install
# manifest excludes files created when someone ran an older build in Release.
function Get-WindowsPackageInventory([string]$BuildProject) {
    $project = (Resolve-Path -LiteralPath $BuildProject).Path
    $release = (Resolve-Path -LiteralPath (Join-Path $project 'build/windows/x64/runner/Release')).Path
    $prefix = $release.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $manifest = Join-Path $project 'build/windows/x64/install_manifest.txt'
    $installed = @(Get-Content -LiteralPath $manifest -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($installed.Count -eq 0) { throw 'Build install manifest is empty' }
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $installed) {
        $full = [IO.Path]::GetFullPath($entry)
        if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Build install manifest points outside the Release directory'
        }
        [void]$paths.Add($full.Substring($prefix.Length))
    }
    # These are produced by runner/plugin build commands, outside install().
    foreach ($name in @('sourin_spike.exe', 'WebView2Loader.dll')) {
        [void]$paths.Add($name)
    }
    foreach ($required in @('data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin', 'data/flutter_assets/NativeAssetsManifest.json', 'flutter_windows.dll', 'sourin_core.dll')) {
        $native = $required.Replace('/', [IO.Path]::DirectorySeparatorChar)
        if (-not $paths.Contains($native)) { throw "Build install manifest lacks required runtime file: $required" }
    }
    foreach ($relative in @($paths | Sort-Object)) {
        $normalized = $relative.Replace([IO.Path]::DirectorySeparatorChar, '/')
        if ($normalized -match '^(\.probe|app\.sourin\.player|webview_window_WebView2)(/|$)') {
            throw 'Build install manifest includes a runtime data directory'
        }
        $file = Join-Path $release $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Runtime file is missing: $relative" }
        [PSCustomObject]@{ Relative = $relative; FullName = $file }
    }
}
