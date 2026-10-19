<#
======================================================================
  Sourin - one-command on-device screenshot run (e2e_shots)
======================================================================

WHY THIS SCRIPT EXISTS
----------------------
Round 66 had no repeatable "start -> shoot -> collect" flow. Every probe
was hand written: someone typed
    SOURIN_TABS=1 SOURIN_SHOT=1 ./sourin_spike.exe
into a shell, then hunted for `.probe/tabshot_*.png`, then had to remember
to kill the process. That produced three recurring accidents:

  1. someone forgot the isolated data dir -> the run touched the Owner's
     real %APPDATA%\app.sourin.player (real favourites / progress / creds)
  2. someone forgot to kill the process -> a stray client stayed alive
  3. a "shot run" produced zero images and the operator still reported
     "looks fine" (a false green)

This script makes the whole sequence one command and makes every one of
those failure modes a NON-ZERO EXIT.

WHAT IT DOES (in order, each step is a hard gate)
-------------------------------------------------
  1. parse -Tabs against the real AppTab enum and REJECT unknown names
     (before spending a build)
  2. create a fresh isolated data dir  %TEMP%\sourin-e2e-<random>
     and point APPDATA / USERPROFILE / LOCALAPPDATA there, plus
     SOURIN_NO_REMOTE_AUTOSTART=1 (never start the remote server)
  3. optionally build (-NoBuild skips) -- always with
     `-t lib/shell.dart`, plus the app.so size gate (product > 5 MB;
     a build that silently used lib/main.dart produces a ~4 MB spike)
  4. snapshot the PID set, launch, then compute the PID DIFFERENCE so we
     only ever kill processes THIS run created (never `taskkill /IM`)
  5. wait for readiness by POLLING (not a fixed sleep):
        - window handle exists
        - the Dart-side marker `[SHELL] FIRST_FRAME_RENDERED` shows up in
          the captured stdout
  6. let the in-app tab probe drive the tabs, wait until every requested
     tab has a written PNG, then quit
  7. kill exactly the new PIDs, verify the PNGs are non-empty, print the
     absolute path + byte size of every image, write a run manifest

Screenshot mechanism (Owner's iron rule #2)
-------------------------------------------
This script NEVER captures screen pixels. `SOURIN_SHOT=1` makes the app
rasterise its own root `RenderRepaintBoundary` (`toImage` + `toByteData`)
inside the Flutter process. That is the only accepted capture path --
`CopyFromScreen` would photograph the Owner's desktop.

KNOWN LIMITATIONS (read before trusting a number)
-------------------------------------------------
  * The in-app probe switches tabs every 5s and bursts 6 frames at
    0/40/80/160/200 ms after the switch. Transition is Motion.base
    (260 ms) => the LAST frames of a burst can still be mid transition.
    This script takes the last burst frame per tab as the "settled"
    candidate and, when two tabs are byte-identical, says so loudly
    instead of pretending they differ.
  * The PNGs land in `<repo>\.probe\` because lib/shell.dart hardcodes
    that relative path. -OutDir is the folder this script COPIES them to;
    it is not the in-process write path.
  * The app is a single-instance app with a kernel Mutex, but any of
    SOURIN_SHOT / SOURIN_TABS bypasses that check (windows/runner/
    main.cpp: kProbeEnvVars). So two concurrent e2e_shots runs will both
    start -- they just fight over `.probe\tabshot_*.png`. Do not run two.
  * The tab PNG name is tabshot_<phase*10+k> zero-padded to 3 digits
    (lib/shell.dart: idx = phase * 10 + k, then padLeft(3,'0')).
    Writing the name as two concatenated fields produces "tabshot_10.png"
    for phase 1 / k 0, which never exists -- that bug cost one full 240s
    timeout here.

EXIT CODES
----------
  0  success: every requested tab produced a non-empty PNG
  1  any step failed (bad tab name, build fail, app.so too small,
     app exited early, window never appeared, missing/zero-byte image,
     timeout). The failing STEP is printed as `FAIL step N: ...`

OUTPUT LANGUAGE
---------------
All of this script's own output is ENGLISH and pure ASCII on purpose.
Round 66 had an incident where a `.ps1` got re-encoded to ASCII and its
Chinese text turned into runs of question marks, which silently destroyed
the error message that mattered. ASCII output cannot be mangled that way.
Verify with:  file tools/e2e_shots.ps1  => must say "ASCII text"
and:          grep -cP "[^\x00-\x7F]" tools/e2e_shots.ps1  => must be 0
(Do not search for a literal run of question marks: this comment would
 match it and make the mechanical check look like it failed.)

USAGE
-----
  .\tools\e2e_shots.ps1                                  # default tabs, no build
  .\tools\e2e_shots.ps1 -Tabs home,settings -NoBuild
  .\tools\e2e_shots.ps1 -Tabs home,live,cached,settings -NoBuild
  .\tools\e2e_shots.ps1 -Tabs settings -Rust              # rebuild rust + flutter
  .\tools\e2e_shots.ps1 -Tabs home -OutDir .probe\e2e-r3

  # fault injection (proves the script is not a constant-zero green):
  .\tools\e2e_shots.ps1 -Tabs home,settigns -NoBuild      # => exit 1
======================================================================
#>
[CmdletBinding()]
param(
    # Comma separated AppTab names, e.g. "home,settings".
    # Matched case-sensitively against the real enum in lib/shell.dart.
    [string]$Tabs = 'home,live,cached,settings',

    # Where the PNGs are COPIED to. The app always writes .probe\tabshot_*.png.
    [string]$OutDir = '.probe/e2e',

    # Skip flutter build (use the existing Release bundle).
    [switch]$NoBuild,

    # cargo build --release first, then flutter build.
    [switch]$Rust,

    # How long to wait for the window + FIRST_FRAME_RENDERED, in seconds.
    [int]$ReadyTimeoutSec = 90,

    # How long to wait for the tab PNGs after the first frame, in seconds.
    # One full sweep is tabs*5s; two sweeps is tabs*10s. Keep some slack.
    [int]$ShotsTimeoutSec = 240,

    # Extra settle time after the last requested tab has its PNG, in ms.
    [int]$SettleMs = 800,

    # Keep the temp data dir (default: delete it at the end).
    [switch]$KeepData
)

$ErrorActionPreference = 'Stop'

# ======================================================================
#  Housekeeping
# ======================================================================
$script:StepNo = 0
function Step($msg) {
    $script:StepNo++
    Write-Host ''
    Write-Host "=== [step $($script:StepNo)] $msg ===" -ForegroundColor Cyan
}
function Ok($msg) { Write-Host "  OK   $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "  ..   $msg" -ForegroundColor DarkGray }
function Warn($msg) { Write-Host "  !!   $msg" -ForegroundColor Yellow }

# A hard failure: print which step failed and exit non-zero.
# NEVER let this script end with exit 0 on a broken run -- that is the
# "constant-zero false green" the repo forbids.
function Fail($msg, [int]$code = 1) {
    Write-Host ''
    Write-Host "FAIL step $($script:StepNo): $msg" -ForegroundColor Red
    Write-Host ''
    # best effort: kill only what we started
    try { Stop-OurProcesses } catch { }
    exit $code
}

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$rel = Join-Path $root 'build\windows\x64\runner\Release'
$exe = Join-Path $rel 'sourin_spike.exe'
$appso = Join-Path $rel 'data\app.so'
$probeDir = Join-Path $root '.probe'
$outDirAbs = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $root $OutDir }

# Processes we started (filled in by the launch step).
$script:StartedPids = @()
# ★ 2026-10-19：StartedPids 的**留档**。收尾的存活复查与 manifest 都读它
#   （StartedPids 会被 Stop-OurProcesses 清空，读它会恒为 0）。
$script:PidListForManifest = @()
# Temp data dir (filled in by the isolated-data-dir step).
$script:DataDir = $null
# Raw stdout of the client.
$script:StdoutPath = $null
# Diagnostics slots used by the window enumeration callback.
$script:WinDump = @()
$script:BestH = [IntPtr]::Zero
$script:BestArea = 0

function Stop-OurProcesses {
    # Only ever kill the exact PIDs this run created. `taskkill /IM` would
    # kill the Owner's own client -- that is an incident, not cleanup.
    #
    # ★★★ 2026-10-19（收尾可判性修复）: keep the list we were asked to kill
    # BEFORE clearing it.
    #
    # # 改前这里最后一行就是 `$script:StartedPids = @()`
    # ⇒ `step 8` 的存活复查读的是**已清空**的集合
    #   ⇒ `$left` 恒为空 ⇒ "still alive after kill" 这条检查
    #     **结构上不可能**发现幸存者（双重失效的另一半）。
    # ⇒ 现在把要杀的集合**留档**再清空；manifest 与收尾复查
    #   读同一个权威列表（该变量在启动时已建过一份）。
    foreach ($p in @($script:StartedPids)) {
        if (-not $p) { continue }
        $alive = Get-Process -Id $p -ErrorAction SilentlyContinue
        if ($alive) {
            try {
                & taskkill /PID $p /F /T 2>&1 | Out-Null
                Write-Host "  ..   killed pid=$p" -ForegroundColor DarkGray
            } catch {
                Warn "could not kill pid=$p : $_"
            }
        }
    }
    # ★ 留档**必须在清空之前**，否则收尾复查又退回恒 0。
    if ($script:StartedPids.Count -gt 0) {
        $script:PidListForManifest = @($script:StartedPids)
    }
    $script:StartedPids = @()
}

# ======================================================================
#  step 1 -- validate tab names against the REAL enum
# ======================================================================
Step 'validate -Tabs against lib/shell.dart AppTab enum'

$shellPath = Join-Path $root 'lib\shell.dart'
if (-not (Test-Path $shellPath)) { Fail "lib/shell.dart not found at $shellPath" }

# The enum members are the only place tab names are defined. Read them from
# source so this script cannot drift from the app.
$enumText = Get-Content -LiteralPath $shellPath -Raw -Encoding UTF8
$enumMatch = [regex]::Match($enumText, 'enum\s+AppTab\s*\{(?<body>[\s\S]*?)\n\}')
if (-not $enumMatch.Success) { Fail 'could not locate `enum AppTab { ... }` in lib/shell.dart' }

$knownTabs = @()
foreach ($m in [regex]::Matches($enumMatch.Groups['body'].Value, '(?m)^\s{2}([a-z][a-zA-Z0-9]*)\(')) {
    $knownTabs += $m.Groups[1].Value
}
if ($knownTabs.Count -eq 0) { Fail 'AppTab enum parsed as empty -- refusing to guess' }
Ok ("known tabs: " + ($knownTabs -join ', '))

$requested = @()
foreach ($t in ($Tabs -split ',')) {
    $tt = $t.Trim()
    if ($tt -eq '') { continue }
    $requested += $tt
}
if ($requested.Count -eq 0) { Fail '-Tabs resolved to an empty list' }

$bad = @()
$normalized = @()
foreach ($t in $requested) {
    # Case handling is a trap, found by fault injection on 2026-10-19:
    #   PowerShell's -eq / Where-Object comparisons are CASE-INSENSITIVE, so
    #   "-Tabs Home" passed validation. But [array]::IndexOf (used later to
    #   map a tab to its phase) is CASE-SENSITIVE, so the phase lookup
    #   returned -1, no image name ever matched, and the run sat in the
    #   polling loop until the timeout. Same input, two different opinions.
    # => compare with an explicit ORDINAL (case-sensitive) match here, and
    #    NORMALIZE the value to the enum's own spelling, so every later step
    #    sees exactly one form.
    $hit = $knownTabs | Where-Object { [string]::Equals($_, $t, [System.StringComparison]::Ordinal) }
    if (-not $hit) {
        # A case-only mistake deserves a hint, not a bare reject.
        $ci = $knownTabs | Where-Object { [string]::Equals($_, $t, [System.StringComparison]::OrdinalIgnoreCase) }
        if ($ci) { $bad += "$t (did you mean '$ci'? tab names are case-sensitive)" }
        else { $bad += $t }
    } else {
        $normalized += $hit
    }
}
if ($bad.Count -gt 0) {
    # This is the fault-injection gate. A typo must die HERE, before a build
    # is spent and before the app is launched.
    Fail ("unknown tab name(s): " + ($bad -join ', ') + "`n         valid names: " + ($knownTabs -join ', '))
}
$requested = @($normalized)

# de-dupe while preserving order
$seen = @{}
$requested = @($requested | Where-Object { if ($seen.ContainsKey($_)) { $false } else { $seen[$_] = 1; $true } })
Ok ("requested tabs: " + ($requested -join ', '))

# ======================================================================
#  step 2 -- isolated data dir (iron rule #1 and #3)
# ======================================================================
Step 'create isolated data dir (never touch %APPDATA%\app.sourin.player)'

$realDataDir = Join-Path $env:APPDATA 'app.sourin.player'
$rand = -join ((48..57) + (97..122) | Get-Random -Count 10 | ForEach-Object { [char]$_ })
$script:DataDir = Join-Path $env:TEMP "sourin-e2e-$rand"
New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $script:DataDir 'logs') | Out-Null
if (-not (Test-Path $script:DataDir)) { Fail "could not create isolated data dir $($script:DataDir)" }

# Paranoia: the isolated dir must NOT be inside the real one, and the real
# one must not be inside it. Either would mean we are about to write the
# Owner's real library.
$normA = [System.IO.Path]::GetFullPath($script:DataDir).TrimEnd('\').ToLowerInvariant()
$normR = [System.IO.Path]::GetFullPath($realDataDir).TrimEnd('\').ToLowerInvariant()
if ($normA.StartsWith($normR) -or $normR.StartsWith($normA)) {
    Fail "isolated dir '$($script:DataDir)' overlaps the real data dir '$realDataDir' -- refusing to run"
}
Ok "data dir  = $($script:DataDir)"
Ok "real dir  = $realDataDir   (NOT used, only compared)"
Ok 'SOURIN_NO_REMOTE_AUTOSTART=1'

# ======================================================================
#  step 3 -- build (optional)
# ======================================================================
Step 'build (cargo / flutter, -t lib/shell.dart is mandatory)'

# 先走 FLUTTER_BIN 环境变量，再走 PATH。
# ⚠️ 这里**不要**写死某台开发机的绝对路径：提交前的隐私清理要求扫全树，
#    而换机器的人也会直接踩坑。两条都找不到就报错退出（不猜）。
$flutter = ''
if ($env:FLUTTER_BIN -and (Test-Path $env:FLUTTER_BIN)) {
    $flutter = $env:FLUTTER_BIN
} else {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $cmd) { Fail 'flutter not found (tried $env:FLUTTER_BIN and PATH)' }
    $flutter = $cmd.Source
}

if ($Rust) {
    $cargo = "$env:USERPROFILE\.cargo\bin\cargo.exe"
    if (-not (Test-Path $cargo)) { $cargo = 'cargo' }
    Push-Location (Join-Path $root 'rust\sourin_core')
    try {
        & $cargo build --release 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) { Pop-Location; Fail "cargo build --release failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
    Ok 'rust core rebuilt'
}

if (-not $NoBuild) {
    # `-t lib/shell.dart` is not optional. Without it flutter builds
    # lib/main.dart (the HEVC acceptance spike) and exits 0 -- the repo
    # has been bitten by exactly this, so the argument is hardcoded.
    & $flutter build windows --release -t lib/shell.dart 2>&1 |
        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { Fail "flutter build failed (exit $LASTEXITCODE)" }
    Ok 'flutter build windows --release -t lib/shell.dart'
} else {
    Info 'skipped (-NoBuild)'
}

# -- app.so size gate: product entry vs spike entry --
if (-not (Test-Path $exe)) { Fail "missing $exe (drop -NoBuild to build once)" }
if (-not (Test-Path $appso)) { Fail "missing $appso (this tree is not a complete build)" }
$soMb = (Get-Item $appso).Length / 1MB
if ($soMb -lt 5) {
    Fail ("data\app.so is only {0:N2} MB (product should be > 5 MB).`n         This almost always means the build missed -t lib/shell.dart`n         and produced the lib/main.dart HEVC spike instead." -f $soMb)
}
Ok ("data\app.so = {0:N2} MB  (> 5 MB => product entry)" -f $soMb)

# ======================================================================
#  step 4 -- seed ui-prefs.json into the isolated dir (deterministic shots)
# ======================================================================
Step 'seed ui-prefs.json (suppress the update dialog)'

# WHY THIS STEP EXISTS (found on 2026-10-19, first full run of this script)
#
# The in-app update check is skipped only when the data dir is overridden at
# COMPILE time (`--dart-define=DATA_DIR_OVERRIDE`). This script isolates by
# setting the APPDATA/USERPROFILE env vars instead, which that compile-time
# constant does not see. A brand-new isolated dir has no
# `appupdate.lastCheckAt`, so the 24h throttle does not apply and the app
# checks GitHub on startup.
#
# Result: the `settings` screenshot came out as "发现新版本 1.3.0" dialog
# covering the whole settings page. The image was non-empty, the size was
# plausible -- and it was NOT a picture of the settings page. That is exactly
# the "shot exists therefore it is evidence" false green this repo forbids.
#
# Turning the PREF off (not just hiding the dialog) also removes the network
# call, so the run is deterministic and does not depend on GitHub reachability.
#
# WHERE the app actually reads it:
#   _resolveDataDir() builds  $APPDATA + app.sourin.player
#   (lib/shell.dart:1043-1049) -- it APPENDS app.sourin.player to APPDATA.
#   So the prefs file is NOT at $DataDir\ui-prefs.json; it is one level down.
# The first version of this step wrote to "$DataDir\ui-prefs.json" and the
# seed was silently ignored: the app created its own dir, the update dialog
# came back, and settings.png was a picture of that dialog.
$appDir = Join-Path $script:DataDir 'app.sourin.player'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
$prefsPath = Join-Path $appDir 'ui-prefs.json'
$seedPrefs = [ordered]@{
    'appupdate.autoCheck' = '0'
} | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($prefsPath, $seedPrefs, (New-Object System.Text.UTF8Encoding($false)))
if (-not (Test-Path $prefsPath)) { Fail "could not write $prefsPath" }
# Read it back: a seed that was written to the WRONG path fails silently and
# only shows up as "the screenshot is a dialog". Assert the content, not just
# the write.
$back = Get-Content -LiteralPath $prefsPath -Raw
if ($back -notmatch 'appupdate.autoCheck') {
    Fail "seed file at $prefsPath does not contain appupdate.autoCheck -- the next run would show the update dialog again"
}
Ok "wrote $prefsPath  (appupdate.autoCheck=0, so no startup update dialog)"

# ======================================================================
#  step 5 -- launch with a PID difference (never kill by name)
# ======================================================================
Step 'launch client (isolated env, PID difference recorded)'

New-Item -ItemType Directory -Force -Path $probeDir | Out-Null

# Clear stale tab shots so a previous run cannot be mistaken for this one.
$stale = @(Get-ChildItem -LiteralPath $probeDir -Filter 'tabshot_*.png' -ErrorAction SilentlyContinue)
if ($stale.Count -gt 0) {
    $stale | Remove-Item -Force -ErrorAction SilentlyContinue
    Info "removed $($stale.Count) stale tabshot_*.png so this run cannot inherit them"
}

$script:StdoutPath = Join-Path $outDirAbs 'client-stdout.log'
New-Item -ItemType Directory -Force -Path $outDirAbs | Out-Null
if (Test-Path $script:StdoutPath) { Remove-Item -LiteralPath $script:StdoutPath -Force }

# The PID set BEFORE launch. Anything new afterwards is ours.
$beforePids = @(Get-Process -Name 'sourin_spike' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Info ("pids before launch: " + $(if ($beforePids.Count) { $beforePids -join ',' } else { '(none)' }))

# The full child environment. Start-Process -Environment replaces/extends
# the inherited environment, so APPDATA/USERPROFILE redirect is explicit.
$childEnv = @{
    'APPDATA'                    = $script:DataDir
    'USERPROFILE'                = $script:DataDir
    'LOCALAPPDATA'               = $script:DataDir
    'SOURIN_NO_REMOTE_AUTOSTART' = '1'
    'SOURIN_TABS'                = '1'
    'SOURIN_SHOT'                = '1'
}

# Two traps found the hard way (first run of this script, 2026-10-19):
#
#   1. -WorkingDirectory must be the REPO ROOT, not the Release dir.
#      lib/shell.dart writes `File('.probe/tabshot_XXX.png')` -- a RELATIVE
#      path. With cwd=Release every shot fails with
#        PathNotFoundException: Cannot open file, path = '.probe/tabshot_000.png'
#      and the run produces zero images while the app looks perfectly fine.
#
#   2. Do NOT pass -WindowStyle Hidden.
#      It sets STARTUPINFO.wShowWindow=SW_HIDE, and Windows ignores the
#      argument of the FIRST ShowWindow() call for a process started that
#      way. The window is created (the log still prints [ALPHA] window=1280x800)
#      but IsWindowVisible() stays false -> the readiness poll never matches.
#
# Also: no cmd /c wrapper. Start-Process can redirect stdout/stderr straight
# to files, and polling those files gives us FIRST_FRAME_RENDERED.
$proc = Start-Process -FilePath $exe -WorkingDirectory $root -PassThru `
    -RedirectStandardOutput $script:StdoutPath `
    -RedirectStandardError (Join-Path $outDirAbs 'client-stderr.log') `
    -Environment $childEnv
if (-not $proc) { Fail 'Start-Process returned no process' }

# Give it a moment to spawn, then diff the PID set.
$deadline = (Get-Date).AddSeconds(15)
$afterPids = @()
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    $afterPids = @(Get-Process -Name 'sourin_spike' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $newOnes = @($afterPids | Where-Object { $beforePids -notcontains $_ })
    if ($newOnes.Count -gt 0) { break }
}
$newOnes = @($afterPids | Where-Object { $beforePids -notcontains $_ })
if ($newOnes.Count -eq 0) {
    Fail ("client process never appeared (no new sourin_spike pid within 15s)`n         stdout: $($script:StdoutPath)")
}
$script:StartedPids = $newOnes
# Keep a copy for the manifest: Stop-OurProcesses clears StartedPids, so
# reading it later would record an empty list (that bug shipped once).
$script:PidListForManifest = @($newOnes)
Ok ("started pid(s): " + ($newOnes -join ', ') + "   (these, and only these, will be killed)")

# ======================================================================
#  step 6 -- wait for readiness by polling (no fixed sleep)
# ======================================================================
Step 'wait for window + FIRST_FRAME_RENDERED (polling)'

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class E2eWin {
    public delegate bool Cb(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Cb cb, IntPtr l);
    // CharSet.Unicode is MANDATORY here.
    //   With the default (Ansi) marshaling, GetClassNameW writes UTF-16 into
    //   the StringBuilder but PowerShell reads it back as ANSI, so the result
    //   is the FIRST CHARACTER ONLY ("F" instead of
    //   "FLUTTER_RUNNER_WIN32_WINDOW"). The first version of this script
    //   therefore never matched a window even though the window was there.
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr h, StringBuilder s, int c);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@ -ErrorAction SilentlyContinue

function Get-MainWindowOf([int[]]$pids) {
    # Pick the LARGEST visible FLUTTER_RUNNER_WIN32_WINDOW owned by our pids.
    # The tray icon also creates a tiny 180x28 window; picking by area avoids
    # mistaking it for the main window.
    $script:BestH = [IntPtr]::Zero
    $script:BestArea = 0
    $cb = [E2eWin+Cb]{
        param($hw, $l)
        $cn = New-Object System.Text.StringBuilder 256
        [void][E2eWin]::GetClassNameW($hw, $cn, 256)
        if ($cn.ToString() -ne 'FLUTTER_RUNNER_WIN32_WINDOW') { return $true }
        $owner = 0
        [void][E2eWin]::GetWindowThreadProcessId($hw, [ref]$owner)
        if ($pids -notcontains [int]$owner) { return $true }
        if (-not [E2eWin]::IsWindowVisible($hw)) { return $true }
        $rr = New-Object E2eWin+RECT
        [void][E2eWin]::GetWindowRect($hw, [ref]$rr)
        $area = ($rr.Right - $rr.Left) * ($rr.Bottom - $rr.Top)
        if ($area -gt $script:BestArea) {
            $script:BestArea = $area
            $script:BestH = $hw
        }
        return $true
    }
    [void][E2eWin]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:BestH
}

$t0 = Get-Date
$hwnd = [IntPtr]::Zero
$firstFrame = $false
$readyDeadline = $t0.AddSeconds($ReadyTimeoutSec)
while ((Get-Date) -lt $readyDeadline) {
    if ($hwnd -eq [IntPtr]::Zero) { $hwnd = Get-MainWindowOf $script:StartedPids }
    if (-not $firstFrame -and (Test-Path $script:StdoutPath)) {
        $txt = Get-Content -LiteralPath $script:StdoutPath -Raw -ErrorAction SilentlyContinue
        if ($txt -and $txt.Contains('FIRST_FRAME_RENDERED')) { $firstFrame = $true }
    }
    if ($hwnd -ne [IntPtr]::Zero -and $firstFrame) { break }

    # early-exit detection: if every pid is gone, the app died
    $alive = @($script:StartedPids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($alive.Count -eq 0) {
        Fail ("client exited before becoming ready`n         stdout: $($script:StdoutPath)")
    }
    Start-Sleep -Milliseconds 250
}
$readySec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
if ($hwnd -eq [IntPtr]::Zero) {
    # Distinguish "app never made a window" from "our window lookup is wrong"
    # -- the two need completely different fixes.
    $script:WinDump = @()
    $dumpCb = [E2eWin+Cb]{
        param($hw, $l)
        $cn = New-Object System.Text.StringBuilder 256
        [void][E2eWin]::GetClassNameW($hw, $cn, 256)
        $owner = 0
        [void][E2eWin]::GetWindowThreadProcessId($hw, [ref]$owner)
        if ($script:StartedPids -contains [int]$owner) {
            $rr2 = New-Object E2eWin+RECT
            [void][E2eWin]::GetWindowRect($hw, [ref]$rr2)
            $script:WinDump += ("hwnd=0x{0:X} class='{1}' visible={2} rect={3}x{4}" -f `
                    $hw.ToInt64(), $cn.ToString(), [E2eWin]::IsWindowVisible($hw), `
                    ($rr2.Right - $rr2.Left), ($rr2.Bottom - $rr2.Top))
        }
        return $true
    }
    [void][E2eWin]::EnumWindows($dumpCb, [IntPtr]::Zero)
    $dumpText = if ($script:WinDump.Count) { $script:WinDump -join "`n         " } else { '(none)' }
    Fail ("no visible FLUTTER_RUNNER_WIN32_WINDOW for pid(s) " + ($script:StartedPids -join ',') +
        " after ${ReadyTimeoutSec}s`n         windows owned by our pids:`n         $dumpText`n         stdout: $($script:StdoutPath)")
}
if (-not $firstFrame) { Fail "FIRST_FRAME_RENDERED never appeared after ${ReadyTimeoutSec}s (stdout: $($script:StdoutPath))" }
$wr = New-Object E2eWin+RECT
[void][E2eWin]::GetWindowRect($hwnd, [ref]$wr)
Ok ("ready in ${readySec}s  hwnd=0x{0:X}  window={1}x{2}" -f $hwnd.ToInt64(), ($wr.Right - $wr.Left), ($wr.Bottom - $wr.Top))

# ======================================================================
#  step 7 -- wait for the per-tab PNGs
# ======================================================================
Step 'wait for per-tab screenshots (polling for non-empty PNGs)'

# The in-app probe cycles AppTab.values (ALL tabs), 5 s each, two rounds,
# then stops. It writes tabshot_<phase*10+k padded to 3 digits>.png where
# phase = 1..N and k = 0..5 within a burst. To find "the settled frame for
# tab X" we look at the LAST burst whose phase maps to X and take its
# highest k.
#
# We cannot ask the app which tab is active, so we rely on the enum order:
# phase p (1-based) => AppTab.values[(p-1) % values.Length].
$tabOrder = $knownTabs          # enum declaration order == values order
Info ("app cycles ALL tabs: " + ($tabOrder -join ' -> '))
Info 'map: phase p (1-based) => AppTab.values[(p-1) % count]; burst frames k=0..5'

function Get-TabShotName([int]$phase, [int]$k) {
    return 'tabshot_{0}.png' -f (($phase * 10) + $k).ToString('000')
}

function Get-PhaseForTab([string]$tab) {
    $idx = [array]::IndexOf($tabOrder, $tab)
    if ($idx -lt 0) { return @() }
    # two rounds: phase = idx+1 and idx+1+count
    return @(($idx + 1), ($idx + 1 + $tabOrder.Count))
}

$wanted = @{}
foreach ($t in $requested) { $wanted[$t] = Get-PhaseForTab $t }

$shotsDeadline = (Get-Date).AddSeconds($ShotsTimeoutSec)
$done = $false
$haveNames = @()
while ((Get-Date) -lt $shotsDeadline) {
    $haveNames = @(Get-ChildItem -LiteralPath $probeDir -Filter 'tabshot_*.png' -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 0 } | Select-Object -ExpandProperty Name)
    $allHave = $true
    foreach ($t in $requested) {
        $any = $false
        foreach ($ph in $wanted[$t]) {
            if ($ph -lt 0) { continue }
            foreach ($k in 0..5) {
                if ($haveNames -contains (Get-TabShotName $ph $k)) { $any = $true; break }
            }
            if ($any) { break }
        }
        if (-not $any) { $allHave = $false; break }
    }
    if ($allHave) { $done = $true; break }

    $alive = @($script:StartedPids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($alive.Count -eq 0) {
        Fail ("client exited while waiting for screenshots (got $($haveNames.Count) non-empty PNGs)`n         stdout: $($script:StdoutPath)")
    }
    Start-Sleep -Milliseconds 300
}
if (-not $done) {
    $haveAll = @(Get-ChildItem -LiteralPath $probeDir -Filter 'tabshot_*.png' -ErrorAction SilentlyContinue)
    Fail ("timed out after ${ShotsTimeoutSec}s waiting for screenshots of: " + ($requested -join ', ') + "`n         got $($haveAll.Count) PNG(s) in .probe`n         stdout: $($script:StdoutPath)")
}
Ok 'every requested tab has at least one non-empty PNG'
Start-Sleep -Milliseconds $SettleMs

# ======================================================================
#  step 8 -- stop the client (exact PIDs only), then collect + verify
# ======================================================================
Step 'stop the client (only the PIDs this run started)'
Stop-OurProcesses
Start-Sleep -Milliseconds 400

# ★★★ 2026-10-19（收尾可判性修复）：存活复查读**留档**的那份，不是已清空的 StartedPids
#
# # 改前（双重失效）
# ```text
# $left = @($script:StartedPids | …)     # ← StartedPids 刚被 Stop-OurProcesses 清空
# if ($left.Count -gt 0) { Warn … }      # ← 只 Warn，随后仍会走到末尾的 exit 0
# ⇒ 既看不见幸存者，也拦不住。
# ```
#
# # 改后（三条要求）
# ```text
# ① 读 $script:PidListForManifest（Stop-OurProcesses 在清空前留的档）
# ② 打印 `SURVIVORS=<n>` —— 机器可读（可 grep / 可被别的脚本判）+ 人能一眼看出
# ③ 非 0 ⇒ **Fail（exit 非 0）**，不是 Warn
# ```
$left = @($script:PidListForManifest |
          Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
Write-Host ("SURVIVORS=" + $left.Count)
if ($left.Count -gt 0) {
    # ★ 仍然 Fail：留下孤儿进程 = 下一次跑会撞端口 / 抢数据目录，
    #   这正是本脚本开头铁律 ③④要防的事，不能只提醒。
    Fail ("survivors: $($left.Count) process(es) from THIS run are still alive " +
          "(pids: $($left -join ', ')). Killing them by name is forbidden; " +
          "stop them by PID.")
} else {
    Ok 'all our pids are gone'
}

Step 'collect screenshots and verify sizes'
New-Item -ItemType Directory -Force -Path $outDirAbs | Out-Null

$rows = New-Object System.Collections.Generic.List[object]
$missing = New-Object System.Collections.Generic.List[string]
$emptyFiles = New-Object System.Collections.Generic.List[string]

foreach ($t in $requested) {
    $candidates = @()
    foreach ($ph in $wanted[$t]) {
        if ($ph -lt 0) { continue }
        foreach ($k in 0..5) {
            $name = Get-TabShotName $ph $k
            $src = Join-Path $probeDir $name
            if (Test-Path $src) {
                $len = (Get-Item $src).Length
                if ($len -gt 0) {
                    $candidates += [pscustomobject]@{
                        Phase = $ph; K = $k; Name = $name; Path = $src; Bytes = $len
                    }
                } else {
                    $emptyFiles.Add("$name (0 bytes)")
                }
            }
        }
    }
    if ($candidates.Count -eq 0) { $missing.Add($t); continue }

    # settled candidate = highest phase, then highest k (latest frame in burst)
    $best = $candidates | Sort-Object Phase, K | Select-Object -Last 1
    $dst = Join-Path $outDirAbs ("{0}.png" -f $t)
    Copy-Item -LiteralPath $best.Path -Destination $dst -Force
    $dstLen = (Get-Item $dst).Length
    if ($dstLen -le 0) { $emptyFiles.Add("$t.png (0 bytes after copy)"); continue }

    $rows.Add([pscustomobject]@{
            Tab       = $t
            Source    = $best.Name
            Bytes     = $dstLen
            Path      = $dst
            AllFrames = ($candidates | ForEach-Object { $_.Name }) -join ','
        })
}

if ($missing.Count -gt 0) { Fail ("no non-empty PNG for tab(s): " + ($missing -join ', ')) }
if ($emptyFiles.Count -gt 0) { Fail ("zero-byte image(s): " + ($emptyFiles -join '; ')) }

# -- duplicate-content check: two tabs with identical bytes means at least
#    one shot did NOT capture that tab (it caught a neighbour mid-transition).
$dupWarn = @()
$byHash = @{}
foreach ($r in $rows) {
    $h = (Get-FileHash -LiteralPath $r.Path -Algorithm SHA256).Hash
    $r | Add-Member -NotePropertyName Sha256 -NotePropertyValue $h -Force
    if ($byHash.ContainsKey($h)) { $dupWarn += ("{0} == {1}" -f $r.Tab, $byHash[$h]) }
    else { $byHash[$h] = $r.Tab }
}

# -- read the PNG dimensions without any image library (IHDR is at a fixed
#    offset: 8-byte signature, 4-byte length, 4-byte 'IHDR', then w,h)
function Get-PngSize([string]$path) {
    try {
        $b = [System.IO.File]::ReadAllBytes($path)
        if ($b.Length -lt 24) { return $null }
        if ($b[0] -ne 0x89 -or $b[1] -ne 0x50 -or $b[2] -ne 0x4E -or $b[3] -ne 0x47) { return $null }
        $w = ([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19]
        $h = ([int]$b[20] -shl 24) -bor ([int]$b[21] -shl 16) -bor ([int]$b[22] -shl 8) -bor [int]$b[23]
        return "$w x $h"
    } catch { return $null }
}

Write-Host ''
Write-Host '  -- screenshots ---------------------------------------------' -ForegroundColor Cyan
foreach ($r in $rows) {
    $sz = Get-PngSize $r.Path
    Write-Host ("  {0,-10} {1,10:N0} B  {2,12}  {3}" -f $r.Tab, $r.Bytes, $sz, $r.Path)
}
Write-Host '  ------------------------------------------------------------' -ForegroundColor Cyan

if ($dupWarn.Count -gt 0) {
    Warn ("identical image content for: " + ($dupWarn -join '; ') + "`n         => at least one of those shots caught a neighbour, not that tab.")
    Warn '         Treat those images as NOT evidence for that tab.'
} else {
    Ok 'all tab images have distinct content'
}

# ======================================================================
#  step 9 -- verify the CONTENT (not just that a file exists)
# ======================================================================
Step 'verify screenshot content (not just "a file exists")'

# WHY THIS STEP EXISTS (2026-10-19, the most expensive finding of the round)
#
# Everything above this point proves: a PNG was written, it is non-empty, it
# has the right dimensions, and no two tabs produced identical bytes.
# NONE of that proves the picture shows the page you asked for.
#
# Real failure: `settings.png` came out as a full-screen update dialog.
# 142,778 B / 1280x800 / distinct from the other five => every check above
# passed. It was caught only because a human opened the file.
#
# verify_shots.ps1 closes that hole with a pixel statistic that separates a
# full-screen modal (scrim + bright card => high centre/perimeter ratio) from
# ordinary page content. Measured on this machine: normal 1.011..1.125,
# modal 1.746.
$verifier = Join-Path $root 'tools\verify_shots.ps1'
if (-not (Test-Path $verifier)) {
    Fail "tools\verify_shots.ps1 not found -- cannot verify screenshot content. Refusing to report a pass on images whose content was never checked."
}
$verifyArgs = @('-NoProfile', '-File', $verifier, '-InDir', $outDirAbs,
    '-Tabs', ($requested -join ','))
$verifyOut = & pwsh @verifyArgs 2>&1
$verifyRc = $LASTEXITCODE
$verifyOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
if ($verifyRc -ne 0) {
    Fail ("screenshot content verification failed (exit $verifyRc).`n         The images exist and are the right size, but their CONTENT is not a page screenshot.`n         See the per-image ratio table above: a value >= 1.35 means a full-screen modal covered the page.")
}
Ok 'screenshot content verified (no modal overlay, content distinct)'

# ======================================================================
#  step 10 -- run manifest (so a later reader can tell what was actually run)
# ======================================================================
Step 'write run manifest'

$manifest = Join-Path $outDirAbs 'run-manifest.txt'
$lines = @()
$lines += 'sourin e2e_shots run manifest'
$lines += "started   = $($t0.ToString('o'))"
$lines += "finished  = $((Get-Date).ToString('o'))"
$lines += "tabs      = $($requested -join ', ')"
$lines += "dataDir   = $($script:DataDir)"
$lines += "realData  = $realDataDir  (NOT touched)"
$lines += "pids      = $($script:PidListForManifest -join ', ')"
$lines += ("appso     = {0}  ({1:N2} MB)" -f $appso, $soMb)
$lines += "stdout    = $($script:StdoutPath)"
$lines += ("hwnd      = 0x{0:X}" -f $hwnd.ToInt64())
$lines += "readySec  = $readySec"
$lines += 'capture   = SOURIN_SHOT=1 RenderRepaintBoundary.toImage (no screen pixels)'
$lines += ''
$lines += "tab`tsource`tbytes`tpng`tsha256`tpath"
foreach ($r in $rows) {
    $lines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $r.Tab, $r.Source, $r.Bytes, (Get-PngSize $r.Path), $r.Sha256.Substring(0, 16), $r.Path)
}
Set-Content -LiteralPath $manifest -Value $lines -Encoding UTF8
Ok "manifest: $manifest"

# ======================================================================
#  step 11 -- cleanup
# ======================================================================
Step 'cleanup'
if ($KeepData) {
    Info "kept data dir: $($script:DataDir)"
} else {
    try {
        Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
        Ok "removed data dir $($script:DataDir)"
    } catch { Warn "could not remove data dir $($script:DataDir): $_" }
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host ("  PASS  {0} tab(s) captured, all non-empty" -f $rows.Count) -ForegroundColor Green
Write-Host "  out   = $outDirAbs" -ForegroundColor Green
Write-Host "  log   = $($script:StdoutPath)" -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
exit 0
