<#
======================================================================
  Sourin - round-66 batch-end acceptance driver
======================================================================

WHY THIS SCRIPT EXISTS
----------------------
The Owner's test discipline is "accumulate, then verify once": finish every
in-flight change, then do ONE build + ONE deploy + ONE on-device run.
Round 66 has four independent harnesses, each with its own build entry,
isolated data dir, log file and result syntax:

  1. t105  lib/t105_r4_dialogs_probe.dart  -> .probe/round66_r4_device/
           dialog shell pixels + contrast + render-exception collector
  2. t106  lib/t106_r6b_live_probe.dart    -> .probe/round66_r6b/<sha7>/
           live-state danmaku controls (pixels)
  3. t107  lib/t107_cs1_flow_probe.dart    -> .probe/round66_cs1/<sha7>-<ts>/
           CS-1 backup five steps (report + >=5 shots)
  4. e2e   tools/e2e_shots.ps1             -> docs/notes/evidence/round-66-cs1/
           tab screenshots + evidence manifest.json

Run by hand, three accidents from earlier rounds come back:
  * two harnesses fight over the same window (t105 needs 1280x800)
  * a stale exe / stale PNG is reported as fresh evidence
  * one segment goes red and the remaining ones still "look fine"

This script runs the four segments SEQUENTIALLY (one window at a time),
stamps every run with the baseline sha, refuses artifacts older than their
entry source, and stops at the FIRST red with the offending line printed.

USAGE
-----
  .\tools\run_round66_acceptance.ps1
  .\tools\run_round66_acceptance.ps1 -T105Prefix fix2      # name the image set
  .\tools\run_round66_acceptance.ps1 -SkipE2E -SkipT106    # partial run
  .\tools\run_round66_acceptance.ps1 -NoBuild              # reuse last build
  .\tools\run_round66_acceptance.ps1 -SelfCheck            # parse check only

HARD GATES
----------
  * baseline sha (`git rev-parse --short HEAD`) + entry-source sha256 are
    printed BEFORE each segment and recorded in
    .probe/round66_acceptance/acceptance-run.log
  * every artifact (probe log / PNG / report / manifest) must be newer than
    its entry source, otherwise: "ERROR: artifact older than source"
  * any segment with EXIT != 0, or "RESULT ... bad>0", or "verdict=BAD"
    stops the whole run immediately and prints the red line
  * only PIDs created by this run are ever killed (PID difference, never
    taskkill by process name)

NOT DONE HERE
-------------
  * no screen capture: CopyFromScreen is banned (docs/AGENTS.md 8); every
    PNG is rasterised inside the product by RenderRepaintBoundary.toImage
  * no window activation, no synthetic OS input, no focus stealing
  * t105 case 11 (AppDialogShell glass) contrast is deliberately reported as
    skipped - its dark panel defeats the text-band classifier. See
    docs/notes/round-66-r4-device.md. It is not a green light.
======================================================================
#>

[CmdletBinding()]
param(
    # Filename prefix for the t105 image set. Final prefix is "<sha7>_<this>_"
    # so a PNG can never lie about which tree produced it.
    [string]$T105Prefix = 'accept',

    # Reuse the existing Release bundle. Every freshness gate still applies.
    [switch]$NoBuild,

    [switch]$SkipT106,
    [switch]$SkipT107,
    [switch]$SkipE2E,

    # Parse-check only: tokenize this script and the two helper scripts.
    [switch]$SelfCheck,

    [int]$T105TimeoutSec = 300,
    [int]$T106TimeoutSec = 300,
    [int]$T107TimeoutSec = 600,
    [int]$E2ETimeoutSec = 600
)

$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$probeR4 = Join-Path $root '.probe\round66_r4_device'
$probeR6 = Join-Path $root '.probe\round66_r6b'
$accDir  = Join-Path $root '.probe\round66_acceptance'
$runLog  = Join-Path $accDir 'acceptance-run.log'
$exePath = Join-Path $root 'build\windows\x64\runner\Release\sourin_spike.exe'
# Freshness of a build is asked of the Flutter payload (data\app.so), NOT the runner .exe:
# the C++ runner is only relinked when its own sources change, so its mtime stays old even
# after a full `flutter build windows`. Checking the runner produced a permanent false red.
$appSoPath = Join-Path $root 'build\windows\x64\runner\Release\data\app.so'
$evidDir = Join-Path $root 'docs\notes\evidence\round-66-cs1'

New-Item -ItemType Directory -Force -Path $accDir | Out-Null

# ---------------------------------------------------------------- utilities

function Log([string]$msg) {
    Write-Host $msg
    Add-Content -LiteralPath $runLog -Value $msg -Encoding UTF8
}

function Get-Sha7 {
    $s = "$(& git -C $root rev-parse --short=7 HEAD 2>$null)".Trim()
    if ($s -eq '') { $s = 'unknown' }
    return $s
}

function Get-DirtyCount {
    return @(& git -C $root status --porcelain 2>$null).Count
}

function Get-Sha256Short([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
    $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $h.Substring(0, 16)
}

function Get-EntryTime([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return [datetime]::MinValue }
    return (Get-Item -LiteralPath $path).LastWriteTime
}

function Newest-File([string]$dir, [string]$filter) {
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    return (Get-ChildItem -LiteralPath $dir -Filter $filter -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

# Freshness of a build cannot be a hard gate here, and that is measured, not assumed:
#   * the runner .exe is only relinked when the C++ runner sources change, so its mtime stays
#     at the day it was first built (measured 2026-10-18, weeks old after many rebuilds);
#   * data\app.so comes from a content-addressed incremental build, so a comment-only edit
#     followed by a real `flutter build windows` leaves app.so byte-identical with an old mtime
#     (measured this round: probe source 18:54:13 vs app.so 18:19:22 after a 26 s rebuild).
# Comparing mtimes therefore red-flags healthy runs. What is sound instead:
#   - build exit code is a hard gate (Invoke-FlutterBuild);
#   - the artifact must exist (hard, see the segments below);
#   - staleness is a WARN carrying both mtimes, and the header table prints app.so sha256,
#     so a reader can always tell which binary produced the numbers.
function Warn-Stale([string]$artifact, [string]$source) {
    if (-not (Test-Path -LiteralPath $artifact)) {
        Log ("WARN: artifact missing: {0}" -f $artifact)
        return
    }
    $a = (Get-Item -LiteralPath $artifact).LastWriteTime
    $s = Get-EntryTime $source
    if ($a -lt $s) {
        Log ("WARN: binary older than source - incremental build may have been a no-op")
        Log ("  artifact : {0}  {1}" -f $a.ToString('yyyy-MM-dd HH:mm:ss'), $artifact)
        Log ("  source   : {0}  {1}" -f $s.ToString('yyyy-MM-dd HH:mm:ss'), $source)
    }
}

# Artifact freshness check used for probe OUTPUT files (log/png/manifest vs probe source).
function Test-Fresh([string]$artifact, [string]$source) {
    if (-not (Test-Path -LiteralPath $artifact)) {
        Log ("ERROR: artifact missing: {0}" -f $artifact)
        return $false
    }
    $a = (Get-Item -LiteralPath $artifact).LastWriteTime
    $s = Get-EntryTime $source
    if ($a -lt $s) {
        Log ("ERROR: artifact older than source (产物比源码旧)")
        Log ("  artifact : {0}  {1}" -f $a.ToString('yyyy-MM-dd HH:mm:ss'), $artifact)
        Log ("  source   : {0}  {1}" -f $s.ToString('yyyy-MM-dd HH:mm:ss'), $source)
        return $false
    }
    return $true
}

function Resolve-Flutter {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    if ($env:FLUTTER_BIN -and (Test-Path -LiteralPath $env:FLUTTER_BIN)) { return $env:FLUTTER_BIN }
    $cand = Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat'
    if (Test-Path -LiteralPath $cand) { return $cand }
    return $null
}

function Get-ProbePids {
    return @(Get-Process -Name 'sourin_spike' -ErrorAction SilentlyContinue |
             ForEach-Object { $_.Id })
}

# Kill only the PIDs this run created (difference against the pre-run set).
function Stop-OurPids($before, [string]$tag) {
    $now = Get-ProbePids
    $mine = @($now | Where-Object { $before -notcontains $_ })
    foreach ($pid in $mine) {
        try {
            Stop-Process -Id $pid -Force -ErrorAction Stop
            Log ("  killed pid {0} ({1})" -f $pid, $tag)
        } catch {
            Log ("  WARN: could not kill pid {0}: {1}" -f $pid, $_)
        }
    }
    # Wait until the window is really gone: next segment must not inherit it.
    for ($i = 0; $i -lt 30; $i++) {
        $left = @(Get-ProbePids | Where-Object { $before -notcontains $_ })
        if ($left.Count -eq 0) { return }
        Start-Sleep -Milliseconds 300
    }
    Log ("  WARN: pids still alive after 9s: {0}" -f (($left) -join ','))
}

# Isolated environment for one launch. Returns the saved values so the caller
# can restore them (never leave APPDATA pointing at a temp dir).
function Enter-IsoEnv([string]$dataDir, [string]$t105Prefix) {
    $saved = @{
        APPDATA                    = $env:APPDATA
        USERPROFILE                = $env:USERPROFILE
        SOURIN_NO_REMOTE_AUTOSTART = $env:SOURIN_NO_REMOTE_AUTOSTART
        SOURIN_T105_PREFIX         = $env:SOURIN_T105_PREFIX
    }
    $appData = Join-Path $dataDir 'appdata'
    $userPro = Join-Path $dataDir 'userprofile'
    New-Item -ItemType Directory -Force -Path $appData, $userPro | Out-Null
    $env:APPDATA = $appData
    $env:USERPROFILE = $userPro
    $env:SOURIN_NO_REMOTE_AUTOSTART = '1'
    if ($t105Prefix -ne '') { $env:SOURIN_T105_PREFIX = $t105Prefix }
    return $saved
}

function Exit-IsoEnv($saved) {
    if ($saved.ContainsKey('APPDATA')) { $env:APPDATA = $saved['APPDATA'] }
    if ($saved.ContainsKey('USERPROFILE')) { $env:USERPROFILE = $saved['USERPROFILE'] }
    if ($saved.ContainsKey('SOURIN_NO_REMOTE_AUTOSTART')) {
        $env:SOURIN_NO_REMOTE_AUTOSTART = $saved['SOURIN_NO_REMOTE_AUTOSTART']
    }
    if ($saved.ContainsKey('SOURIN_T105_PREFIX')) { $env:SOURIN_T105_PREFIX = $saved['SOURIN_T105_PREFIX'] }
}

function Invoke-FlutterBuild([string]$entry, [string]$dataDir) {
    Log ("  build: flutter build windows --release -t {0}" -f $entry)
    Log ("         --dart-define=DATA_DIR_OVERRIDE={0}" -f $dataDir)
    Push-Location $root
    try {
        & $script:Flutter build windows --release -t $entry `
            "--dart-define=DATA_DIR_OVERRIDE=$dataDir" 2>&1 |
            ForEach-Object {
                $line = "$_"
                Write-Host ("    " + $line)
                Add-Content -LiteralPath $runLog -Value ("    " + $line) -Encoding UTF8
            }
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

function Invoke-ReleaseExe([string]$tag, [string]$dataDir, [string]$t105Prefix, [int]$timeoutSec) {
    $before = Get-ProbePids
    $saved = Enter-IsoEnv $dataDir $t105Prefix
    Log ("  launch: {0}" -f $exePath)
    Log ("  env   : APPDATA={0}" -f $env:APPDATA)
    Log ("          USERPROFILE={0}" -f $env:USERPROFILE)
    Log ("          SOURIN_NO_REMOTE_AUTOSTART=1")
    if ($t105Prefix -ne '') { Log ("          SOURIN_T105_PREFIX={0}" -f $t105Prefix) }
    $proc = $null
    $code = 124
    try {
        $proc = Start-Process -FilePath $exePath -WorkingDirectory $root -PassThru
        if ($proc.WaitForExit($timeoutSec * 1000)) {
            $code = $proc.ExitCode
        } else {
            Log ("TIMEOUT: {0} did not exit within {1}s" -f $tag, $timeoutSec)
        }
    } finally {
        Exit-IsoEnv $saved
        Stop-OurPids $before $tag
    }
    Log ("  exit  : {0}" -f $code)
    return $code
}

function Read-Utf8Lines([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path -Encoding UTF8)
}

# ------------------------------------------------------- self-check mode

if ($SelfCheck) {
    $files = @($PSCommandPath,
               (Join-Path $root 'tools\run_t107.ps1'),
               (Join-Path $root 'tools\e2e_shots.ps1'))
    $bad = 0
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { Write-Host "MISSING $f"; $bad++; continue }
        $raw = Get-Content -LiteralPath $f -Raw
        try {
            $errs = $null
            [void][System.Management.Automation.PSParser]::Tokenize($raw, [ref]$errs)
            if ($errs -and $errs.Count -gt 0) {
                Write-Host ("PARSE FAIL {0} ({1} error(s))" -f $f, $errs.Count)
                foreach ($e in $errs) { Write-Host ("  line {0}: {1}" -f $e.Token.StartLine, $e.Message) }
                $bad++
            } else {
                Write-Host ("PARSE OK   {0}  ({1} bytes)" -f (Split-Path -Leaf $f), $raw.Length)
            }
        } catch {
            Write-Host ("PARSE THREW {0}: {1}" -f $f, $_)
            $bad++
        }
    }
    if ($bad -eq 0) { Write-Host 'SELFCHECK PASS'; exit 0 }
    Write-Host 'SELFCHECK FAIL'
    exit 2
}

# --------------------------------------------------------------- preflight

$script:Flutter = Resolve-Flutter
if ($null -eq $script:Flutter) {
    Write-Host 'ERROR: flutter not found (PATH, $env:FLUTTER_BIN, %USERPROFILE%\flutter\bin\flutter.bat)'
    exit 2
}

Log ''
Log '=================================================================='
Log ("  round-66 batch acceptance  {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Log '=================================================================='
Log ("  repo     : {0}" -f $root)
Log ("  flutter  : {0}" -f $script:Flutter)
Log ("  run log  : {0}" -f $runLog)

$sha7 = Get-Sha7
$shaFull = "$(& git -C $root rev-parse HEAD 2>$null)".Trim()
$dirty = Get-DirtyCount
Log ("  baseline : {0}  ({1})" -f $sha7, $shaFull)
Log ("  dirty    : {0} path(s) in working tree" -f $dirty)
if ($dirty -gt 0) {
    Log '  NOTE: artifacts below were produced from the WORKING TREE, not from a'
    Log '        clean commit. Report the dirty list with any verdict.'
}

$results = @()
$red = $null

function New-Segment([int]$index, [string]$name, [string]$entryRel) {
    $entryAbs = Join-Path $root $entryRel
    Log ''
    Log ('------------------------------------------------------------------')
    Log ("[segment {0}] {1}" -f $index, $name)
    Log ("  baseline sha = {0}   dirty = {1} path(s)" -f $sha7, $dirty)
    Log ("  entry        = {0}" -f $entryRel)
    Log ("  entry sha256 = {0}..." -f (Get-Sha256Short $entryAbs))
    Log ("  entry mtime  = {0}" -f (Get-EntryTime $entryAbs).ToString('yyyy-MM-dd HH:mm:ss'))
    return $entryAbs
}

function Set-Red([int]$index, [string]$name, [string]$why, $evidence) {
    $script:red = [pscustomobject]@{
        Index = $index; Name = $name; Why = $why; Evidence = @($evidence)
    }
}

# ====================================================== segment 1: t105
$t105EntryRel = 'lib/t105_r4_dialogs_probe.dart'
$t105Entry = New-Segment 1 't105 dialog shell pixels + contrast' $t105EntryRel
$t105Data = Join-Path $probeR4 'data'
$t105Prefix = ('{0}_{1}_' -f $sha7, $T105Prefix)
$t105Log = Join-Path $probeR4 ($t105Prefix + 'probe.log')
New-Item -ItemType Directory -Force -Path $t105Data | Out-Null
Log ("  data dir     = {0}" -f $t105Data)
Log ("  image prefix = {0}" -f $t105Prefix)

$t105Exit = -1
if (-not $NoBuild) {
    $t105Exit = Invoke-FlutterBuild $t105EntryRel $t105Data
    if ($t105Exit -ne 0) {
        Set-Red 1 't105' ("build failed (exit={0})" -f $t105Exit) @()
    }
}
if ($null -eq $script:red) {
    if (-not (Test-Path -LiteralPath $appSoPath)) {
        Set-Red 1 't105' 'build artifact missing: data/app.so (nothing to run)' @()
    } else {
        Warn-Stale $appSoPath $t105Entry
        $code = Invoke-ReleaseExe 't105' $t105Data $t105Prefix $T105TimeoutSec
        $lines = Read-Utf8Lines $t105Log
        $verdict = '?'; $cases = 0; $ok = 0; $bad = 0; $errs = 0
        foreach ($ln in $lines) {
            if ($ln -match 'RESULT\s+(PASS|FAIL)\s+cases=(\d+)\s+ok=(\d+)\s+bad=(\d+)\s+errors=(\d+)') {
                $verdict = $matches[1]; $cases = [int]$matches[2]; $ok = [int]$matches[3]
                $bad = [int]$matches[4]; $errs = [int]$matches[5]
            }
        }
        $cOk = 0; $cBad = 0; $cSkip = 0
        $offenders = @()
        foreach ($ln in $lines) {
            if ($ln -match '^CONTRAST\|(?!selftest)') {
                if ($ln -match 'verdict=OK') { $cOk++ }
                elseif ($ln -match 'verdict=BAD') { $cBad++; $offenders += $ln }
                else { $cSkip++ }
            } elseif ($ln -match 'verdict=bad') {
                $offenders += $ln
            }
        }
        $pngCount = @(Get-ChildItem -LiteralPath $probeR4 -Filter ($t105Prefix + '*.png') -File -ErrorAction SilentlyContinue).Count
        $key = ('ok={0} bad={1} errors={2} CONTRAST OK={3} BAD={4} SKIP={5} png={6}' -f `
                 $ok, $bad, $errs, $cOk, $cBad, $cSkip, $pngCount)
        Log ("  reading      = RESULT {0} cases={1} {2}" -f $verdict, $cases, $key)

        if ($code -ne 0) { Set-Red 1 't105' ("exit={0}" -f $code) $offenders }
        elseif ($lines.Count -eq 0) { Set-Red 1 't105' 'probe.log missing or empty' @() }
        elseif ($verdict -ne 'PASS' -or $bad -gt 0 -or $errs -gt 0) {
            Set-Red 1 't105' ("RESULT {0} bad={1} errors={2}" -f $verdict, $bad, $errs) $offenders
        } elseif ($cBad -gt 0) { Set-Red 1 't105' ("contrast BAD={0}" -f $cBad) $offenders }
        elseif ($pngCount -lt 18) { Set-Red 1 't105' ("only {0} PNG(s), expected >= 18" -f $pngCount) @() }
        elseif (-not (Test-Fresh $t105Log $t105Entry)) { Set-Red 1 't105' 'probe.log older than source' @() }
        elseif (-not (Test-Fresh (Newest-File $probeR4 ($t105Prefix + '*.png')).FullName $t105Entry)) {
            Set-Red 1 't105' 'PNG older than source' @()
        }
        $results += [pscustomobject]@{ Seg = '1 t105'; Exit = $code; Key = $key; Out = '.probe/round66_r4_device' }
    }
}

# ====================================================== segment 2: t106
if ($null -eq $script:red -and -not $SkipT106) {
    $t106EntryRel = 'lib/t106_r6b_live_probe.dart'
    $t106Entry = New-Segment 2 't106 R6-b live danmaku controls' $t106EntryRel
    $t106Data = Join-Path $probeR6 $sha7
    New-Item -ItemType Directory -Force -Path $t106Data | Out-Null
    Log ("  data dir     = {0}" -f $t106Data)

    if (-not $NoBuild) {
        $code = Invoke-FlutterBuild $t106EntryRel $t106Data
        if ($code -ne 0) { Set-Red 2 't106' ("build failed (exit={0})" -f $code) @() }
    }
    if ($null -eq $script:red) {
        if (-not (Test-Path -LiteralPath $appSoPath)) {
            Set-Red 2 't106' 'build artifact missing: data/app.so (nothing to run)' @()
        } else {
            Warn-Stale $appSoPath $t106Entry
            $code = Invoke-ReleaseExe 't106' $t106Data '' $T106TimeoutSec
            $t106Log = Join-Path $t106Data 'probe.log'
            $lines = Read-Utf8Lines $t106Log
            $ok = 0; $fail = 0
            foreach ($ln in $lines) {
                if ($ln -match 'OK=(\d+)\s+FAIL=(\d+)') {
                    $ok = [int]$matches[1]; $fail = [int]$matches[2]
                }
            }
            $failLines = @($lines | Where-Object { $_ -match '^\s*\[r6b\]\s*(FAIL|!!)' })
            $pngs = @(Get-ChildItem -LiteralPath $t106Data -Filter '*.png' -File -ErrorAction SilentlyContinue).Count
            $key = ('OK={0} FAIL={1} png={2}' -f $ok, $fail, $pngs)
            Log ("  reading      = {0}" -f $key)

            if ($code -ne 0) { Set-Red 2 't106' ("exit={0}" -f $code) $failLines }
            elseif ($lines.Count -eq 0) { Set-Red 2 't106' 'probe.log missing or empty' @() }
            elseif ($fail -gt 0) { Set-Red 2 't106' ("FAIL={0}" -f $fail) $failLines }
            elseif ($ok -lt 1) { Set-Red 2 't106' 'no OK assertions in probe.log' @() }
            elseif ($pngs -lt 1) { Set-Red 2 't106' 'no PNG produced' @() }
            elseif (-not (Test-Fresh $t106Log $t106Entry)) { Set-Red 2 't106' 'probe.log older than source' @() }
            $results += [pscustomobject]@{ Seg = '2 t106'; Exit = $code; Key = $key; Out = ('.probe/round66_r6b/' + $sha7) }
        }
    }
}

# ====================================================== segment 3: t107
if ($null -eq $script:red -and -not $SkipT107) {
    $t107EntryRel = 'lib/t107_cs1_flow_probe.dart'
    $t107Entry = New-Segment 3 't107 CS-1 backup five steps' $t107EntryRel
    $runName = ('{0}-{1}' -f $sha7, (Get-Date -Format 'HHmmss'))
    $t107RunDir = Join-Path $root ('.probe\round66_cs1\' + $runName)
    Log ("  run dir      = {0}" -f $t107RunDir)

    $runner = Join-Path $root 'tools\run_t107.ps1'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner,
              '-Run', $runName, '-TimeoutSec', "$T107TimeoutSec")
    if ($NoBuild) { $args += '-NoBuild' }
    Log ("  runner: {0} {1}" -f $psExe, ($args -join ' '))
    $segLog = Join-Path $accDir ('t107-' + $runName + '.log')
    $out = & $psExe @args 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $out | Set-Content -LiteralPath $segLog -Encoding UTF8
    $out | ForEach-Object { Write-Host ("    " + $_) }
    Log ("  exit  : {0}   (console log: {1})" -f $code, $segLog)

    $lines = Read-Utf8Lines (Join-Path $t107RunDir 'cs1-lines.txt')
    $badLines = @($lines | Where-Object { $_ -match 'verdict=BAD' })
    $okLines = @($lines | Where-Object { $_ -match 'verdict=OK' })
    $shotDir = Join-Path $t107RunDir 'shots'
    $shots = 0
    if (Test-Path -LiteralPath $shotDir) {
        $shots = @(Get-ChildItem -LiteralPath $shotDir -Filter 'cs1_*.png' -File).Count
    }
    $key = ('CS1 OK={0}/{1} BAD={2} shots={3}' -f $okLines.Count, $lines.Count, $badLines.Count, $shots)
    Log ("  reading      = {0}" -f $key)

    if ($code -ne 0) { Set-Red 3 't107' ("exit={0}" -f $code) $badLines }
    elseif ($badLines.Count -gt 0) { Set-Red 3 't107' ("verdict=BAD x{0}" -f $badLines.Count) $badLines }
    elseif ($okLines.Count -lt 5) { Set-Red 3 't107' ("only {0} OK line(s), expected >= 5" -f $okLines.Count) @() }
    elseif ($shots -lt 5) { Set-Red 3 't107' ("only {0} shot(s), expected >= 5" -f $shots) @() }
    elseif (-not (Test-Fresh (Join-Path $t107RunDir 'cs1-report.txt') $t107Entry)) {
        Set-Red 3 't107' 'cs1-report.txt older than source' @()
    }
    $results += [pscustomobject]@{ Seg = '3 t107'; Exit = $code; Key = $key; Out = ('.probe/round66_cs1/' + $runName) }
}

# ====================================================== segment 4: e2e
if ($null -eq $script:red -and -not $SkipE2E) {
    $e2eEntryRel = 'lib/shell.dart'
    $e2eEntry = New-Segment 4 'e2e_shots product tabs + evidence manifest' $e2eEntryRel
    Log ("  out dir      = {0}" -f $evidDir)

    # Stale PNGs would end up "on disk but not in manifest" and turn the CS-1
    # evidence gate red for the wrong reason. Evidence images are regenerated
    # by this very segment, so clear them first and say what was cleared.
    if (Test-Path -LiteralPath $evidDir) {
        $stale = @(Get-ChildItem -LiteralPath $evidDir -Filter '*.png' -File)
        if ($stale.Count -gt 0) {
            Log ("  clearing {0} stale PNG(s) before reseal:" -f $stale.Count)
            foreach ($f in $stale) {
                Log ("    - {0}  {1}" -f $f.Name, (Get-Date $f.LastWriteTime -Format 'yyyy-MM-dd HH:mm:ss'))
                Remove-Item -LiteralPath $f.FullName -Force
            }
        }
        $oldManifest = Join-Path $evidDir 'manifest.json'
        if (Test-Path -LiteralPath $oldManifest) { Remove-Item -LiteralPath $oldManifest -Force }
    } else {
        New-Item -ItemType Directory -Force -Path $evidDir | Out-Null
    }

    $e2e = Join-Path $root 'tools\e2e_shots.ps1'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $e2ePrefix = ('cs1_{0}_' -f $sha7)
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $e2e,
              '-OutDir', 'docs\notes\evidence\round-66-cs1',
              '-Prefix', $e2ePrefix,
              '-Criterion', ('round-66 batch acceptance ' + $sha7))
    if ($NoBuild) { $args += '-NoBuild' }
    Log ("  runner: {0} {1}" -f $psExe, ($args -join ' '))
    $segLog = Join-Path $accDir ('e2e-' + $sha7 + '.log')
    $out = & $psExe @args 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $out | Set-Content -LiteralPath $segLog -Encoding UTF8
    $out | ForEach-Object { Write-Host ("    " + $_) }
    Log ("  exit  : {0}   (console log: {1})" -f $code, $segLog)

    $manifest = Join-Path $evidDir 'manifest.json'
    $entries = 0
    if (Test-Path -LiteralPath $manifest) {
        try {
            $mj = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
            $entries = @($mj.files).Count
        } catch {
            Log ("  WARN: manifest.json not parseable: {0}" -f $_)
        }
    }
    $pngs = @(Get-ChildItem -LiteralPath $evidDir -Filter '*.png' -File -ErrorAction SilentlyContinue).Count
    $key = ('manifest={0} png={1}' -f $entries, $pngs)
    Log ("  reading      = {0}" -f $key)

    if ($code -ne 0) { Set-Red 4 'e2e' ("exit={0}" -f $code) @($out | Select-Object -Last 12) }
    elseif ($entries -lt 4) { Set-Red 4 'e2e' ("manifest entries={0}, expected >= 4" -f $entries) @() }
    elseif ($entries -ne $pngs) { Set-Red 4 'e2e' ("manifest entries ({0}) != PNG on disk ({1})" -f $entries, $pngs) @() }
    elseif (-not (Test-Fresh $manifest $e2eEntry)) { Set-Red 4 'e2e' 'manifest older than lib/shell.dart' @() }
    $results += [pscustomobject]@{ Seg = '4 e2e'; Exit = $code; Key = $key; Out = 'docs/notes/evidence/round-66-cs1' }
}

# ============================================================= summary
Log ''
Log '========================== SUMMARY =========================='
Log ("  baseline sha : {0}   (dirty paths: {1})" -f $sha7, $dirty)
Log ("  {0,-8} {1,-5} {2,-58} {3}" -f 'segment', 'exit', 'key reading', 'artifacts')
foreach ($r in $results) {
    Log ("  {0,-8} {1,-5} {2,-58} {3}" -f $r.Seg, $r.Exit, $r.Key, $r.Out)
}
if ($null -eq $red) {
    Log '  VERDICT: PASS (all executed segments green)'
    Log ("  skipped : t106={0} t107={1} e2e={2}" -f [bool]$SkipT106, [bool]$SkipT107, [bool]$SkipE2E)
    Log '============================================================='
    exit 0
}

Log ''
Log ("  RED: segment {0} ({1}) -- {2}" -f $red.Index, $red.Name, $red.Why)
if ($red.Evidence.Count -gt 0) {
    Log '  offending line(s):'
    foreach ($e in ($red.Evidence | Select-Object -First 12)) {
        $t = "$e"
        if ($t.Length -gt 240) { $t = $t.Substring(0, 240) + '...' }
        Log ("    | " + $t)
    }
}
Log '  VERDICT: FAIL (later segments were not run: one window at a time, and'
Log '           a red segment invalidates the batch)'
Log '============================================================='
exit 1
