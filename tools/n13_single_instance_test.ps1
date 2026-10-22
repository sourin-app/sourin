# =====================================================================
#  N13 real-machine verification: only one instance may exist
# =====================================================================
#
# VERIFICATION TOOL -- NOT PART OF THE PRODUCT BUILD.
# Nothing imports or invokes this script during a normal build or run; it is
# committed so the single-instance behaviour can be re-verified later.
# Usage: powershell -ExecutionPolicy Bypass -File tools/n13_single_instance_test.ps1
#
# # Criteria (all real process readings, never "should work")
# ```text
# 1) start #1        -> process count = 1, has a window
# 2) start #2        -> #2 exits IMMEDIATELY (count stays 1)
# 3) #1 window gets activated (GetForegroundWindow points at it)
# 4) minimize #1, start #2 -> #1 is SW_RESTORE'd (not minimized)
# 5) probe process not blocked: start with SOURIN_SHOT -> it keeps running
# 6) crash residue: hard-kill #1, then start again -> must come up normally
# ```
#
# # Why "process count did not grow" is not enough
# ```text
# The count also stays flat if #2 CRASHED (not blocked by the singleton).
# => must also check: #2 exit code == 0 (we return EXIT_SUCCESS)
#    and #1's window became foreground.
# ```
#
# NOTE: this file is intentionally ASCII-only. PowerShell reads .ps1 using
# the system ANSI code page (936 here), so UTF-8 Chinese text is mangled
# into invalid tokens and the script fails to parse.

$ErrorActionPreference = 'Stop'
$exe = 'D:\WishProject\sourin-flutter-spike\build\windows\x64\runner\Release\sourin_spike.exe'
$lines = New-Object System.Collections.Generic.List[string]
$fail = 0

function Say($s) {
  $lines.Add($s)
  Write-Host $s
}

function LiveProcs {
  @(Get-Process sourin_spike -ErrorAction SilentlyContinue)
}

# Find the app's main window by class + title (MainWindowHandle is 0 for
# Flutter windows during early startup, so it cannot be used as the probe).
Add-Type -Path (Join-Path $PSScriptRoot 'WinLister.cs')
function MainHwnd([int]$procId) {
  $list = [WinLister]::List([uint32]$procId)
  $hit = @($list | Where-Object { $_ -match 'FLUTTER_RUNNER_WIN32_WINDOW' -and $_ -match 'visible=True' })
  if ($hit.Count -eq 0) { return [IntPtr]::Zero }
  $m = [regex]::Match($hit[0], 'hwnd=(\d+)')
  if (-not $m.Success) { return [IntPtr]::Zero }
  return [IntPtr][int64]$m.Groups[1].Value
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class FG {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@

Say "=== N13 single-instance real-machine test ==="
Say "exe = $exe"
if (-not (Test-Path $exe)) {
  Say "FAIL exe not found"
  exit 1
}

# -- start clean --
Get-Process sourin_spike -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 700
Say "initial process count = $((LiveProcs).Count)  (expect 0)"

# -- (1) start #1 --
$p1 = Start-Process -FilePath $exe -PassThru
Say "start #1: PID=$($p1.Id)"
$ok = $false
$i = 0
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Milliseconds 500
  $procs = LiveProcs
  if ($procs.Count -ge 1) {
    $withWin = @($procs | Where-Object { (MainHwnd $_.Id) -ne [IntPtr]::Zero })
    if ($withWin.Count -ge 1) { $ok = $true; break }
  }
}
$procs = LiveProcs
Say "(1) after $($i*0.5)s: count=$($procs.Count) withWindow=$(@($procs | Where-Object {(MainHwnd $_.Id) -ne [IntPtr]::Zero}).Count)"
if (-not $ok) {
  Say "FAIL #1 never produced a window; cannot continue"
  $lines -join "`n" | Out-File -Encoding utf8 '.probe\n13-single-instance.log'
  exit 1
}
$first = ($procs | Where-Object { (MainHwnd $_.Id) -ne [IntPtr]::Zero } | Select-Object -First 1)
$firstHwnd = MainHwnd $first.Id
Say "    #1 PID=$($first.Id) hwnd=$firstHwnd title='$($first.MainWindowTitle)'"

# -- (2) start #2 -> must exit immediately --
Say ""
Say "(2) start #2 (must be blocked by singleton and exit)"
$sw = [Diagnostics.Stopwatch]::StartNew()
$p2 = Start-Process -FilePath $exe -PassThru
$exited = $p2.WaitForExit(15000)
$sw.Stop()
$nAfter = (LiveProcs).Count
Say "    #2 PID=$($p2.Id) exited=$exited elapsed=$($sw.ElapsedMilliseconds)ms"
Say "    process count now = $nAfter  (expect 1)"
if ($exited) {
  $code2 = $p2.ExitCode
  Say "    #2 exit code = $code2  (expect 0)"
  if ($code2 -ne 0) { Say "    FAIL exit code not 0 (crashed rather than blocked?)"; $fail++ }
} else {
  Say "    FAIL #2 did not exit -> singleton not working"
  $fail++
}
if ($nAfter -ne 1) { Say "    FAIL process count is $nAfter, expected 1"; $fail++ }

# -- (3) #1 window activated --
Start-Sleep -Milliseconds 900
$fg = [FG]::GetForegroundWindow()
Say ""
Say "(3) foreground hwnd = $fg , #1 hwnd = $firstHwnd"
Say "    same = $($fg -eq $firstHwnd)"
if ($fg -ne $firstHwnd) {
  Say "    WARN not foreground (SetForegroundWindow can be refused by the foreground lock)"
}

# -- (4) minimize then start #2 -> restore --
Say ""
Say "(4) minimize #1, start #2 (should SW_RESTORE it)"
[void][FG]::ShowWindow($firstHwnd, 6)  # SW_MINIMIZE
Start-Sleep -Milliseconds 1000
$iconicBefore = [FG]::IsIconic($firstHwnd)
Say "    after minimize: IsIconic = $iconicBefore  (expect True)"
if (-not $iconicBefore) { Say "    WARN could not minimize (already not minimized?)" }

$p3 = Start-Process -FilePath $exe -PassThru
$exited3 = $p3.WaitForExit(15000)
Start-Sleep -Milliseconds 1500
$iconicAfter = [FG]::IsIconic($firstHwnd)
Say "    #3 PID=$($p3.Id) exited=$exited3"
Say "    after restore: IsIconic = $iconicAfter  (expect False)"
if ($iconicAfter) { Say "    FAIL window still minimized -> SW_RESTORE did not run"; $fail++ }

# -- (5) probe exemption --
Say ""
Say "(5) probe process must NOT be blocked (SOURIN_SHOT=1)"
$env:SOURIN_SHOT = '1'
$p4 = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 4
$alive4 = -not $p4.HasExited
Say "    PID=$($p4.Id) still alive after 4s = $alive4  (expect True)"
if (-not $alive4) { Say "    FAIL probe was blocked by the singleton"; $fail++ }
Remove-Item Env:\SOURIN_SHOT -ErrorAction SilentlyContinue
if ($alive4) { Stop-Process -Id $p4.Id -Force -ErrorAction SilentlyContinue }

# -- (6) crash residue: hard kill then restart --
Say ""
Say "(6) crash residue: hard-kill everything, then start again"
Get-Process sourin_spike -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 1200
$n = (LiveProcs).Count
Say "    after hard kill: count=$n  (expect 0)"
$p5 = Start-Process -FilePath $exe -PassThru
$up = $false
for ($j = 0; $j -lt 40; $j++) {
  Start-Sleep -Milliseconds 500
  $pr = LiveProcs
  if (@($pr | Where-Object { (MainHwnd $_.Id) -ne [IntPtr]::Zero }).Count -ge 1) { $up = $true; break }
}
Say "    restart PID=$($p5.Id) produced a window = $up  (expect True)"
if (-not $up) { Say "    FAIL Mutex did not get released on crash -> app cannot restart"; $fail++ }

# -- cleanup --
Say ""
Get-Process sourin_spike -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600
Say "cleanup: count=$((LiveProcs).Count)"
Say ""
Say "=== RESULT: failures = $fail ==="

$lines -join "`n" | Out-File -Encoding utf8 '.probe\n13-single-instance.log'
Write-Host "`nwritten to .probe\n13-single-instance.log"
