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
# The core appends each call to a FILE (SOURIN_LIVE_PROBE_FILE) rather than
# writing to stderr: on Windows a redirected stdout/stderr pipe is block
# buffered and the whole buffer is lost when the process is force-killed.
#
# ---------------------------------------------------------------------
# FIXED 2026-10-18 -- this tool used to print "0 calls" for FOUR different
# reasons, and three of them meant it had measured NOTHING. "0" is the
# best-looking number possible, so each one was a silent false negative:
#
#   (1) $seed was declared but never copied into the data dir.
#       -> data dir empty -> no channels -> live page never probes -> 0
#
#   (2) build was not given -t lib/shell.dart.
#       lib/main.dart is an early HEVC spike that does NOT mount the live
#       page -> 0. A wrong entry point does NOT fail the build; you only
#       notice by the app.so size.
#
#   (3) default watch was 30-45s, but "30s delayed probe + 1268 channels"
#       needs ~2 minutes -> killed mid-probe -> the cache was never
#       written, which then ALSO looked like a persistence bug.
#
#   (4) 'stale' edited fields that DO NOT EXIST.
#       A cache entry is {h, t}; the old code touched a per-entry 'at'
#       (absent) and then rewrote the outer envelope's 'at' -- which is
#       epoch MILLISECONDS -- via [datetime], turning 1792307003521 into
#       year 0001. DiskCache.read() then rejects the envelope, so the
#       "aged" cache was silently discarded and the run proved nothing
#       about the TTL path.
#
# Guard added: an explicit VERDICT at the end. 0 calls is only reported as
# SUCCESS when a populated cache file exists. 0 calls with no cache prints
# "cannot decide" and exits non-zero.
#
# Scenarios:
#   1) nocache -> expect N > 0  (first run must probe AND persist)
#   2) stale   -> expect N > 0  (expired cache must re-probe)
#   3) fresh   -> expect N ~ 0  (THIS IS THE BUG IF NOT)
#
# ENCODING: this file is UTF-8 **with BOM**. Windows PowerShell 5.1 reads a
# BOM-less .ps1 using the system ANSI code page, which mangles non-ASCII
# text. The verdict lines are Chinese on purpose (they are user-facing),
# so the BOM is required, not decoration.

param(
  [ValidateSet('nocache', 'stale', 'fresh')]
  [string]$Scenario = 'nocache',
  # Raised 30 -> 200: "30s delayed probe + 1268 channels" needs ~2 min.
  # The loop below exits early as soon as the evidence is in, so the
  # normal case finishes much sooner than this cap.
  [int]$WatchSeconds = 200,
  # Reuse the data dir from a previous run instead of re-seeding it.
  # Needed for 'fresh'/'stale': the cache must survive between runs.
  [switch]$Reuse,
  # Skip the build (assume the shipped exe is already the product build).
  [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'

$root = 'D:\WishProject\sourin-flutter-spike'
$exe = Join-Path $root 'build\windows\x64\runner\Release\sourin_spike.exe'
$appSo = Join-Path $root 'build\windows\x64\runner\Release\data\app.so'

# The app resolves its data dir as %APPDATA%\app.sourin.player (see
# lib/core/clip_download.dart::dataDir). So we point APPDATA at a scratch
# root and let the app create its own child directory there.
$scratch = Join-Path $root '.probe\live-probe-appdata'
$dataDir = Join-Path $scratch 'app.sourin.player'
$cacheFile = Join-Path $dataDir 'live-availability.json'
$outLog = Join-Path $root ".probe\live-probe-$Scenario.log"
$callsFile = Join-Path $root ".probe\live-probe-calls-$Scenario.txt"

# Seed data: a real dev snapshot (providers, plugins, live channels).
$seed = Join-Path $root '.probe\round65-c\devdata'

# ---------------------------------------------------------------- helpers
function Fail([string]$msg) {
  Write-Host ''
  Write-Host '=== VERDICT ===' -ForegroundColor Red
  Write-Host "  ERROR: $msg" -ForegroundColor Red
  Write-Host ''
  exit 2
}

function Get-CacheEntryCount {
  if (-not (Test-Path $cacheFile)) { return -1 }
  try {
    $raw = Get-Content $cacheFile -Raw | ConvertFrom-Json
    if ($null -eq $raw.data) { return 0 }
    return @($raw.data.PSObject.Properties).Count
  } catch {
    return -1
  }
}

# =================================================================== (2)
# PRODUCT ENTRY POINT GUARD
# ---------------------------------------------------------------------
# docs/AGENTS.md: the product entry point is lib/shell.dart. lib/main.dart
# is an early HEVC spike and does NOT mount the live page. Omitting
# -t lib/shell.dart does NOT fail the build, so this must be asserted.
#
# Judgement: data/app.so size. Spike ~4.7MB, product ~11.5MB.
$MinProductSoBytes = 8MB

if (-not $NoBuild) {
  Write-Host '=== build (product entry: lib/shell.dart) ==='
  $flutter = 'C:\Users\iuuuuuuuu\flutter\bin\flutter.bat'
  if (-not (Test-Path $flutter)) { Fail "flutter not found: $flutter" }

  # Kill any running instance first: it locks the exe and makes the
  # INSTALL step fail with a confusing MSB3073 message.
  Get-Process sourin_spike -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600

  & $flutter build windows --release -t lib/shell.dart
  if ($LASTEXITCODE -ne 0) { Fail "build failed (exit $LASTEXITCODE)" }
}

if (-not (Test-Path $exe)) { Fail "exe missing: $exe" }
if (-not (Test-Path $appSo)) { Fail "app.so missing: $appSo (wrong build?)" }

$soSize = (Get-Item $appSo).Length
$soMB = [math]::Round($soSize / 1MB, 2)
if ($soSize -lt $MinProductSoBytes) {
  Fail @"
app.so is only $soMB MB -- this is NOT the product build.

  Expected >= 8 MB. A ~4.7 MB app.so means you built lib/main.dart
  (the early HEVC spike) instead of the product entry point.

  Fix:  flutter build windows --release -t lib/shell.dart

  Why this matters: the spike never mounts the live page, so this tool
  would report 0 calls and that would look like a perfect fix.
"@
}
Write-Host "  app.so = $soMB MB (>= 8 MB => product entry, OK)"

Get-Process sourin_spike -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600

# Tell the core where to append its per-call lines (survives force-kill).
Remove-Item -Force $callsFile -ErrorAction SilentlyContinue
$env:SOURIN_LIVE_PROBE_FILE = $callsFile

Write-Host ''
Write-Host "=== scenario: $Scenario ==="

# ------------------------------------------------------------------ (1)
# SEED THE DATA DIR
# ---------------------------------------------------------------------
# Previously $seed was only *declared*. The data dir stayed empty, so the
# live page had zero channels and never called get_live_stream at all --
# producing "0 calls", the best-looking possible output.
if (-not (Test-Path $seed)) { Fail "seed dir missing: $seed" }

if (-not $Reuse) {
  Write-Host "seed: COPY $seed"
  Write-Host "        -> $dataDir"
  if (Test-Path $dataDir) { Remove-Item -Recurse -Force $dataDir }
  New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
  Copy-Item -Path (Join-Path $seed '*') -Destination $dataDir -Recurse -Force
  $seedCount = @(Get-ChildItem $dataDir).Count
  Write-Host "seed: $seedCount top-level entries copied"
  if ($seedCount -eq 0) { Fail 'seed copy produced an empty data dir' }
} else {
  if (-not (Test-Path $dataDir)) {
    Fail "no data dir at $dataDir -- run -Scenario nocache first, then -Reuse"
  }
  Write-Host 'seed: REUSED existing data dir'
}

# ----------------------------------------------------------- scenario prep
switch ($Scenario) {
  'nocache' {
    Remove-Item -Force $cacheFile -ErrorAction SilentlyContinue
    Write-Host 'cache: REMOVED (first-run simulation)'
  }
  'fresh' {
    if (-not (Test-Path $cacheFile)) {
      Fail "no cache at $cacheFile -- run -Scenario nocache first, then -Scenario fresh -Reuse"
    }
    $n = Get-CacheEntryCount
    Write-Host "cache: FRESH, $n entries, mtime=$((Get-Item $cacheFile).LastWriteTime)"
    if ($n -le 0) {
      Fail @"
cache file exists but has 0 entries.

  This is exactly the state that used to silently pass: the file is
  present and not corrupt, so a naive check calls it fixed, but a
  0-entry cache cannot make the live page skip anything.
"@
    }
  }
  'stale' {
    # (4) Age a REAL cache past the TTL using the ACTUAL on-disk shape.
    #
    # Written shape (LiveHealthCache.encode + DiskCache.write):
    #   { "v":1, "at":<epoch-ms>,
    #     "data": { "<key>": {"h": ..., "t": <epoch-ms>} } }
    #
    # The old version looked for a per-entry 'at' (entries only have 'h'
    # and 't'), then rewrote the outer 'at' with [datetime] -- but that
    # value is epoch ms, so the cast yields year 0001 and the envelope
    # stops parsing entirely.
    if (-not (Test-Path $cacheFile)) {
      Fail "no cache at $cacheFile -- run -Scenario nocache first, then -Scenario stale -Reuse"
    }

    $raw = Get-Content $cacheFile -Raw | ConvertFrom-Json
    $props = @($raw.data.PSObject.Properties)
    if ($props.Count -eq 0) { Fail 'cache has 0 entries -- nothing to age' }

    $shiftMs = [int64](3 * 60 * 60 * 1000)   # 3h in ms: clears the 10min TTL
    $shifted = 0
    foreach ($p in $props) {
      if ($null -ne $p.Value.t) {
        $p.Value.t = ([int64]$p.Value.t) - $shiftMs
        $shifted++
      }
    }
    $raw.at = ([int64]$raw.at) - $shiftMs

    # Rewrite as UTF-8 WITHOUT BOM: DiskCache jsonDecodes the raw string,
    # and a BOM would make that parse fail.
    $json = $raw | ConvertTo-Json -Depth 12 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($cacheFile, $json, $utf8NoBom)

    # Prove the aged file is still readable in the shape the app expects.
    $check = Get-Content $cacheFile -Raw | ConvertFrom-Json
    $checkN = @($check.data.PSObject.Properties).Count
    if ($checkN -ne $props.Count) { Fail "aged cache unreadable ($checkN entries)" }
    Write-Host "cache: AGED by 3h ($checkN entries, $shifted timestamps shifted)"
  }
}

# ------------------------------------------------------------------ launch
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

# --------------------------------------------------------------- (3) watch
# Poll instead of a blind sleep, so we stop as soon as evidence is in.
#
#   nocache/stale -> stop when the cache file is REWRITTEN with entries.
#                    ??? Must compare mtime, not just "file exists with
#                    entries": in the stale scenario a populated file is
#                    already there when the run starts (it is the aged
#                    one), so an existence check fires at t=8s and kills
#                    the app before it ever mounts the live page. That
#                    produced a "0 calls" false negative -- the very bug
#                    this rewrite is supposed to remove.
#   fresh         -> a warm cache never writes anything, so waiting for a
#                    cache write would always burn the whole timeout.
#                    25s of tab cycles is enough to see whether probing
#                    resumed.
$sw = [Diagnostics.Stopwatch]::StartNew()

# Baseline mtime captured BEFORE launch; a real persist bumps it.
$cacheMtimeBefore = if (Test-Path $cacheFile) {
  (Get-Item $cacheFile).LastWriteTimeUtc
} else {
  [datetime]::MinValue
}

Write-Host "watching up to $WatchSeconds s (early exit when evidence is in) ..."

while ($sw.Elapsed.TotalSeconds -lt $WatchSeconds) {
  Start-Sleep -Seconds 2

  if ($sw.Elapsed.TotalSeconds -lt 8) { continue }

  if ($Scenario -eq 'fresh') {
    if ($sw.Elapsed.TotalSeconds -ge 25) {
      Write-Host "  early exit: warm-cache window elapsed after $([int]$sw.Elapsed.TotalSeconds)s"
      break
    }
  } else {
    $cnt = Get-CacheEntryCount
    $mtimeNow = if (Test-Path $cacheFile) {
      (Get-Item $cacheFile).LastWriteTimeUtc
    } else {
      [datetime]::MinValue
    }
    # Rewritten (mtime advanced) AND populated => the probe ran and saved.
    if ($cnt -gt 0 -and $mtimeNow -gt $cacheMtimeBefore) {
      Write-Host "  early exit: cache REWRITTEN with $cnt entries after $([int]$sw.Elapsed.TotalSeconds)s"
      break
    }
  }
}

Get-Process sourin_spike -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 1500

$out = $sb.ToString()
$out | Out-File -Encoding utf8 $outLog

$probeLines = @()
if (Test-Path $callsFile) {
  $probeLines = @(Get-Content $callsFile | Where-Object { $_ -match 'LIVE-PROBE-COUNT' })
}
$cacheLines = @($out -split "`n" | Where-Object { $_ -match 'LIVE.*cache|LIVE.*skip|LIVE.*probe' })
$cacheCount = Get-CacheEntryCount
$cacheExists = Test-Path $cacheFile

Write-Host ''
Write-Host "=== RESULT ($Scenario) ==="
Write-Host "real get_live_stream calls = $($probeLines.Count)"
Write-Host ''
if ($probeLines.Count -gt 0) {
  Write-Host 'first 3:'
  $probeLines | Select-Object -First 3 | ForEach-Object { Write-Host "  $_" }
  if ($probeLines.Count -gt 3) {
    Write-Host 'last 2:'
    $probeLines | Select-Object -Last 2 | ForEach-Object { Write-Host "  $_" }
  }
} else {
  Write-Host '  (none)'
}

Write-Host ''
Write-Host '=== live page cache decisions ==='
if ($cacheLines.Count -eq 0) { Write-Host '  (none)' }
$cacheLines | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" }

Write-Host ''
Write-Host '=== cache file after run ==='
if ($cacheExists) {
  $fi = Get-Item $cacheFile
  $entries = if ($cacheCount -ge 0) { $cacheCount } else { 'unreadable' }
  Write-Host "  $cacheFile  $($fi.Length) bytes  $($fi.LastWriteTime)"
  Write-Host "  entries: $entries"
} else {
  Write-Host '  MISSING'
}

Write-Host ''
Write-Host "full log: $outLog"
Write-Host ''

# ----------------------------------------------------------------- VERDICT
# "0 calls" is only good news when the cache that should have suppressed
# probing actually exists and has entries. Otherwise 0 means the tool
# measured nothing -- the exact false negative this rewrite removes.
$exit = 0
$haveCache = ($cacheExists -and $cacheCount -gt 0)

Write-Host '=== VERDICT ===' -ForegroundColor Cyan

if ($Scenario -eq 'fresh') {
  if ($probeLines.Count -eq 0 -and $haveCache) {
    Write-Host '  ??? ?????????????????????????????????0 ????????????' -ForegroundColor Green
  }
  elseif ($probeLines.Count -le 2 -and $haveCache) {
    Write-Host "  ??? ???????????????????????????????????? $($probeLines.Count) ????????? = ???????????????????????????" -ForegroundColor Green
  }
  elseif (-not $haveCache) {
    Write-Host '  ?????? ????????????????????????????????????????????????????????????' -ForegroundColor Yellow
    Write-Host '     ???0 ????????? + ?????????????????? ??? ?????????????????????????????????' -ForegroundColor Yellow
    $exit = 3
  }
  else {
    Write-Host "  ??? ????????????????????????????????????????????? $($probeLines.Count) ?????????" -ForegroundColor Red
    $exit = 1
  }
}
elseif ($Scenario -eq 'stale') {
  # ??? The stale cache is AGED on purpose, so a hit here means the aging did
  #   not take effect -- i.e. the TTL path was never exercised. Reporting
  #   that as success would be the same class of false negative as the
  #   original "0 calls" bug.
  if ($probeLines.Count -gt 0 -and $haveCache) {
    Write-Host "  ??? ??????????????????????????????$($probeLines.Count) ?????????????????? $cacheCount ???" -ForegroundColor Green
  }
  elseif ($probeLines.Count -gt 0 -and -not $haveCache) {
    Write-Host "  ??? ????????? $($probeLines.Count) ????????????????????????" -ForegroundColor Red
    $exit = 1
  }
  elseif ($probeLines.Count -eq 0 -and $haveCache) {
    Write-Host "  ??? ????????????**??????**???????????????0 ????????????" -ForegroundColor Red
    Write-Host '     ????????????????????????????????? TTL ???????????? ?????? ?????????????????????' -ForegroundColor Red
    $exit = 1
  }
  else {
    Write-Host '  ?????? ????????????????????????????????????????????????????????????' -ForegroundColor Yellow
    Write-Host '     ???0 ????????? + ?????????????????? ??? ?????????????????????' -ForegroundColor Yellow
    $exit = 3
  }
}
else {
  if ($probeLines.Count -gt 0 -and $haveCache) {
    Write-Host "  ??? ??????????????????$($probeLines.Count) ?????????????????? $cacheCount ???" -ForegroundColor Green
  }
  elseif ($probeLines.Count -gt 0 -and -not $haveCache) {
    Write-Host "  ??? ????????? $($probeLines.Count) ????????????????????????" -ForegroundColor Red
    Write-Host '     ?????????????????? kill???????????????????????????' -ForegroundColor Red
    $exit = 1
  }
  elseif ($probeLines.Count -eq 0 -and $haveCache) {
    Write-Host "  ??? ???????????????????????? $cacheCount ??????" -ForegroundColor Green
  }
  else {
    Write-Host '  ?????? ????????????????????????????????????????????????????????????' -ForegroundColor Yellow
    Write-Host '     ???0 ????????? + ?????????????????? ??? ?????????????????????' -ForegroundColor Yellow
    $exit = 3
  }
}

Write-Host ''
Remove-Item Env:\SOURIN_LIVE_PROBE_COUNT -ErrorAction SilentlyContinue
Remove-Item Env:\SOURIN_LIVE_PROBE_FILE -ErrorAction SilentlyContinue
Remove-Item Env:\SOURIN_TABS -ErrorAction SilentlyContinue
Remove-Item Env:\APPDATA -ErrorAction SilentlyContinue
Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue

exit $exit
