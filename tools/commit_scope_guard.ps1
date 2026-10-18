# =====================================================================
#  Commit scope guard -- catch "whole-file add dragged in someone else's work"
# =====================================================================
#
# VERIFICATION TOOL -- NOT PART OF THE PRODUCT BUILD.
#
# # Why this exists (round 66, 2026-10-18)
#
# ```text
# FOUR independent people made the same mistake this round:
#   (1) lead      8e8be90  dragged in 125 lines of perf-player's work
#   (2) lead      dragged in a _mirrorProbeIntoHealth hunk from live-groups
#   (3) live-groups        dragged in someone else's hunk (self-reported)
#   (4) playback-fix c9061fe dragged in 334 lines of another track's rewrite
#
# Four people, one mistake => it is a PROCESS gap, not carelessness.
# "Be more careful next time" does not fix it. A mechanical check does.
# ```
#
# # What it does
#
# ```text
# For every staged file it prints how many lines you are adding/removing,
# and asks you to compare that against what you EXPECT to change.
#
# The rule: if the number does not match your expectation, STOP and use
#   git add -p
# ```
#
# # Usage
#
# ```powershell
#   # 1. stage what you think is yours
#   git add <files>
#
#   # 2. run this with your expectation
#   powershell -File tools/commit_scope_guard.ps1 -ExpectFile "path/to/f.dart" -ExpectAdded 19
#
#   # 3. only if it says OK, commit
# ```
#
# ASCII only: PowerShell reads .ps1 with the system ANSI code page (936),
# so any non-ASCII byte here would break tokenization.

param(
  # Files you believe are yours. Anything else staged is a red flag.
  [string[]]$ExpectFile = @(),
  # Optional: total added lines you expect (sum across files).
  [int]$ExpectAdded = -1,
  # Just report, never fail (useful for a quick look).
  [switch]$Report
)

$ErrorActionPreference = 'Stop'

$script:failed = $false

function Fail($msg) {
  Write-Host ""
  Write-Host "  [FAIL] $msg" -ForegroundColor Red
  $script:failed = $true
  # NOTE: do not `exit` here. `exit` inside a function still terminates the
  # script, but the exit code is easy to lose when the call is nested.
  # We set a flag and let the final block decide -- one exit point.
}

# ---------------------------------------------------------------- staged list
$nameStatus = & git diff --cached --name-status
if (-not $nameStatus) {
  Write-Host "  nothing staged -- nothing to check"
  exit 0
}

$rows = @()
foreach ($line in ($nameStatus -split "`n")) {
  if (-not $line.Trim()) { continue }
  $parts = $line -split "`t"
  if ($parts.Count -lt 2) { continue }
  $status = $parts[0]
  $path = $parts[-1]

  # Per-file added/removed line counts.
  $added = 0
  $removed = 0
  $d = & git diff --cached --numstat -- $path
  if ($d) {
    $f = ($d -split "`t")
    if ($f.Count -ge 2) {
      if ($f[0] -match '^\d+$') { $added = [int]$f[0] }
      if ($f[1] -match '^\d+$') { $removed = [int]$f[1] }
    }
  }
  $rows += [pscustomobject]@{
    Status  = $status
    Path    = $path
    Added   = $added
    Removed = $removed
  }
}

# ------------------------------------------------------------------- report
Write-Host ""
Write-Host "=== staged files ==="
$rows | ForEach-Object {
  Write-Host ("  {0,-12} +{1,-6} -{2,-6} {3}" -f $_.Status, $_.Added, $_.Removed, $_.Path)
}

$totalAdded = ($rows | Measure-Object -Property Added -Sum).Sum
$totalRemoved = ($rows | Measure-Object -Property Removed -Sum).Sum
Write-Host ""
Write-Host ("  TOTAL        +{0,-6} -{1,-6}  ({2} file(s))" -f $totalAdded, $totalRemoved, $rows.Count)

# ------------------------------------------------------------- expectation checks
Write-Host ""
Write-Host "=== expectation checks ==="

if ($ExpectFile.Count -gt 0) {
  $stagedPaths = $rows | ForEach-Object { $_.Path }
  foreach ($p in $stagedPaths) {
    $known = $false
    foreach ($e in $ExpectFile) {
      if ($p -eq $e -or $p.EndsWith($e.Replace('/', '\')) -or $p.EndsWith($e)) {
        $known = $true
        break
      }
    }
    if (-not $known) {
      Fail "staged but NOT in -ExpectFile: $p  (did you mean to add it?)"
    }
  }
  foreach ($e in $ExpectFile) {
    $found = $false
    foreach ($p in $stagedPaths) {
      if ($p -eq $e -or $p.EndsWith($e.Replace('/', '\')) -or $p.EndsWith($e)) {
        $found = $true
        break
      }
    }
    if (-not $found) {
      Write-Host "  [note] expected but not staged: $e"
    }
  }
  Write-Host "  [ok] every staged file is in -ExpectFile"
}

if ($ExpectAdded -ge 0) {
  if ($totalAdded -ne $ExpectAdded) {
    Fail ("added lines = {0}, but you expected {1}  => {2} line(s) are NOT yours" -f `
      $totalAdded, $ExpectAdded, [math]::Abs($totalAdded - $ExpectAdded))
  }
  Write-Host "  [ok] added lines == $ExpectAdded"
}

# --------------------------------------------------- heuristic size warnings
Write-Host ""
Write-Host "=== heuristic warnings ==="
$big = $rows | Where-Object { $_.Added -gt 80 }
if ($big) {
  foreach ($b in $big) {
    Write-Host ("  [WARN] {0} adds {1} lines -- large. Confirm every hunk is yours:" -f $b.Path, $b.Added) -ForegroundColor Yellow
    Write-Host ("         git diff --cached {0}" -f $b.Path)
    Write-Host ("         or: git add -p {0}" -f $b.Path)
  }
} else {
  Write-Host "  no file exceeds 80 added lines"
}

Write-Host ""
if ($Report) {
  Write-Host "  (report mode -- never fails)"
  exit 0
}
if ($script:failed) {
  Write-Host "  [STOP] scope does NOT match your expectation -- use: git add -p <file>" -ForegroundColor Red
  exit 1
}
Write-Host "  [PASS] scope looks consistent with your expectation"
exit 0
