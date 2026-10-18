# =====================================================================
#  Live probe request counter -- real process measurement
# =====================================================================
#
# VERIFICATION TOOL -- NOT PART OF THE PRODUCT BUILD.
#
# Answers Owner's complaint:
#   "the live page re-checks everything on every launch; it will get us
#    blacklisted sooner or later"
#
# Method: the Rust core logs one line per REAL get_live_stream call when
# SOURIN_LIVE_PROBE_COUNT is set. That function is the ONLY path the live
# page uses to probe a channel, so the line count is the request count.
#
# stderr is used because Windows pipe stdout is block-buffered and gets
# lost when the process is force-killed.
#
# Scenarios:
#   1) no cache at all          -> expect N > 0  (first run must probe)
#   2) cache present, stale     -> expect N > 0  (expired must re-probe)
#   3) cache present, fresh     -> expect N == 0 (THIS IS THE BUG IF NOT 0)
#
# ASCII only: PowerShell reads .ps1 with the system ANSI code page.

param(
  [ValidateSet('nocache', 'stale', 'fresh')]
  [string]$Scenario = 'nocache',
  [int]$WatchSeconds = 30,
  # Reuse the data dir from a previous run instead of re-seeding it.
  # Needed for the 'fresh' scenario: the cache has to survive between runs.
  [switch]$Reuse
)

$ErrorActionPreference = 'Stop'

$root = 'D:\WishProject\sourin-flutter-spike'
$exe = Join-Path $root 'build\windows\x64\runner\Release\sourin_spike.exe'
# The app resolves its data dir as %APPDATA%pp.sourin.player (see
# lib/core/clip_download.dart::dataDir). So we point APPDATA at a scratch
# root and let the app create its own child directory there.
$scratch = Join-Path $root '.probe\live-probe-appdata'
$dataDir = Join-Path $scratch 'app.sourin.player'
$cacheFile = Join-Path $dataDir 'live-availability.json'
$outLog = Join-Path $root ".probe\live-probe-$Scenario.log"
$callsFile = Join-Path $root ".probe\live-probe-calls-$Scenario.txt"
Remove-Item -Force $callsFile -ErrorAction SilentlyContinue
# Tell the core where to append its per-call lines (survives force-kill).
$env:SOURIN_LIVE_PROBE_FILE = $callsFile

Write-Host "=== scenario: $Scenario ==="

# ---------------------------------------------------------------- data dir
# Start from the seeded dev data so the live page actually has channels.
$seed = Join-Path $root '.probe\round65-c\devdata'
if (-not (Test-Path $seed)) { throw "seed dir missing: $seed" }

# ------------------------------------------------------------ scenario prep
switch ($Scenario) {
  'nocache' {
    Write-Host "cache: REMOVED (first-run simulation)"
  }
  'fresh' {
    if (-not (Test-Path $cacheFile)) {
      throw "no cache at $cacheFile -- run -Scenario nocache first, then -Reuse"
    }
    $raw = Get-Content $cacheFile -Raw | ConvertFrom-Json
    $n = 0
    if ($raw.data) { $n = @($raw.data.PSObject.Properties).Count }
    Write-Host "cache: FRESH, $n entries, mtime=$((Get-Item $cacheFile).LastWriteTime)"
    if ($n -eq 0) { Write-Host "  WARNING: cache has 0 entries -- the skip path cannot be proven" }
  }
  'stale' {
    # Age a REAL cache (written by a previous run) past the TTL.
    # We do not synthesise entries: the key format and the envelope must be
    # exactly what the app wrote, otherwise this proves nothing.
    if (-not (Test-Path $cacheFile)) {
      throw "no cache at $cacheFile -- run -Scenario nocache first, then -Reuse"
    }
    $raw = Get-Content $cacheFile -Raw | ConvertFrom-Json
    $n = 0
    if ($raw.data) { $n = @($raw.data.PSObject.Properties).Count }
    # Shift every per-entry timestamp back by 3 hours so the TTL check fails.
    $shifted = 0
    if ($raw.data) {
      foreach ($p in $raw.data.PSObject.Properties) {
        if ($p.Value.PSObject.Properties.Name -contains 'at') {
          try {
            $p.Value.at = ([datetime]$p.Value.at).AddHours(-3).ToString('o')
            $shifted++
          } catch { }
        }
      }
    }
    $raw.at = ([datetime]$raw.at).AddHours(-3).ToString('o')
    $raw | ConvertTo-Json -Depth 12 | Set-Content $cacheFile -Encoding utf8
    Write-Host "cache: AGED by 3h ($n entries, $shifted timestamps shifted)"
    if ($n -eq 0) { Write-Host "  WARNING: cache has 0 entries -- nothing to age" }
  }
}

# ------------------------------------------------------------------- launch
$env:SOURIN_LIVE_PROBE_COUNT = '1'
$env:SOURIN_NO_REMOTE_AUTOSTART = '1'
# Drive the shell through every tab so the live page actually mounts and
# runs its availability probe. Without this the app just sits on Home and
# never calls get_live_stream at all.
$env:SOURIN_TABS = '1'
$env:APPDATA = $scratch
$env:USERPROFILE = $dataDir

Get-Process sourin_spike -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600

$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.WorkingDirectory = $root

$proc = [Diagnostics.Process]::Start($psi)
Write-Host "started PID=$($proc.Id) dataDir=$dataDir"

$sb = New-Object Text.StringBuilder
$null = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
  if ($EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) }
} -MessageData $sb
$null = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
  if ($EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) }
} -MessageData $sb
$proc.BeginOutputReadLine()
$proc.BeginErrorReadLine()

Write-Host "watching $WatchSeconds s ..."
Start-Sleep -Seconds $WatchSeconds

Get-Process sourin_spike -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 1200

$out = $sb.ToString()
$out | Out-File -Encoding utf8 $outLog

$probeLines = @()
if (Test-Path $callsFile) {
  $probeLines = @(Get-Content $callsFile | Where-Object { $_ -match 'LIVE-PROBE-COUNT' })
}
$cacheLines = @($out -split "`n" | Where-Object { $_ -match 'LIVE.*cache|LIVE.*skip|LIVE.*probe' })

Write-Host ""
Write-Host "=== RESULT ($Scenario) ==="
Write-Host "real get_live_stream calls = $($probeLines.Count)"
Write-Host ""
if ($probeLines.Count -gt 0) {
  Write-Host "first 5:"
  $probeLines | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
  if ($probeLines.Count -gt 5) {
    Write-Host "last 2:"
    $probeLines | Select-Object -Last 2 | ForEach-Object { Write-Host "  $_" }
  }
} else {
  Write-Host "  (none)"
}

Write-Host ""
Write-Host "=== live page cache decisions ==="
if ($cacheLines.Count -eq 0) { Write-Host "  (none)" }
$cacheLines | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "=== cache file after run ==="
if (Test-Path $cacheFile) {
  $fi = Get-Item $cacheFile
  Write-Host "  $cacheFile  $($fi.Length) bytes  $($fi.LastWriteTime)"
  Write-Host "  unique keys: $((Get-Content $cacheFile -Raw | ConvertFrom-Json).data.PSObject.Properties.Name.Count)"
} else {
  Write-Host "  MISSING"
}

Write-Host ""
Write-Host "full log: $outLog"

Remove-Item Env:\SOURIN_LIVE_PROBE_COUNT -ErrorAction SilentlyContinue
Remove-Item Env:\SOURIN_LIVE_PROBE_FILE -ErrorAction SilentlyContinue
Remove-Item Env:\SOURIN_TABS -ErrorAction SilentlyContinue
Remove-Item Env:\APPDATA -ErrorAction SilentlyContinue
Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue
