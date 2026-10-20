<#
======================================================================
  Sourin - screenshot CONTENT verifier (verify_shots)
======================================================================

WHY THIS FILE EXISTS
--------------------
`tools/e2e_shots.ps1` proves a screenshot EXISTS, is NON-EMPTY, and has the
expected PNG size. It does NOT prove the picture is of the page you asked for.
On 2026-10-19 that gap produced a false green:

    settings.png = 142,778 B, 1280x800, distinct from the other five images,
                   every automatic check in e2e_shots.ps1 passed.
    ...and it was a full-screen "发现新版本 1.3.0" dialog, not the settings page.

It was caught only because a human opened the file. That is exactly the
class of failure this repo forbids: a check that cannot go red.

Same day, second instance of the same shape:
  flutter_test's default font has no CJK glyphs, so a `toImage()` PNG renders
  every Chinese character as a tofu box. The file was 12,736 B -- a plausible
  size for a real screenshot -- and proved nothing.

=> "a screenshot exists" is not evidence. "the screenshot shows the page"
   is the claim, and it needs its own check.

WHAT THIS SCRIPT CHECKS (three criteria, all must pass)
-------------------------------------------------------
  1. non-empty + expected dimensions            (already in e2e_shots.ps1,
                                                 repeated here so this file is
                                                 usable stand-alone)
  2. content differs across the requested tabs  (same reason)
  3. *** the picture is NOT a full-screen modal overlay ***

CRITERION 3 -- what it measures, and why this statistic
-------------------------------------------------------
A full-screen modal draws a SCRIM (semi-opaque dark layer) over the entire
page and then a bright card in the middle. So the picture becomes
    perimeter -> pushed toward the scrim colour (darker)
    centre    -> stays / becomes bright
Measured centre/perimeter mean-luminance ratio on this machine:

    settings-BAD-dialog.png                 1.746   <- modal, the false green
    settings-GOOD.png                       1.042
    home / live / follow / search / cached  1.011 .. 1.029
    six tabs under a dark(er) theme         1.092 .. 1.125

Two thresholds, deliberately BOTH required:
  a) ratio  >= 1.35   (absolute: the modal is far above anything normal)
  b) ratio  >= 1.25 AND >= 2.5x the MINIMUM ratio seen in this same batch
     (relative: catches a modal on a theme where absolute numbers are
      different, without firing on ordinary cross-page variation)

WHY NOT A PIXEL-PERFECT APPROACH
--------------------------------
There is no DOM in a `.probe/tabshot_*.png`. The app renders through
RenderRepaintBoundary, so this script only has pixels. Three alternatives
were considered and rejected:
  · brightness threshold alone -- the repo ships 9 theme packs and the
    effective brightness follows the SYSTEM setting, so absolute luminance
    is not stable (measured: normal pages 233..253 across two themes).
  · "bright card bounded away from both window edges" (row scan) --
    measured to be fragile: the real modal's scan window missed the card at
    some rows and reported "ok" on the known-bad image.
  · asking the app to report which widgets are on screen -- that would need
    a change to lib/ (adding a text dump to the SOURIN_TABS probe). Out of
    scope for a verifier, and it would still not prove the picture matches
    the report. Kept as the documented upgrade path if criterion 3 ever
    needs to be stricter.

LIMITS (say them out loud)
--------------------------
  · A modal whose card fills nearly the whole window (ratio -> 1) would slip
    through. No such dialog exists in this app today (max width 820 of 1280).
  · This does not verify WHICH page it is -- only that it is not a modal.
    Two different pages that both pass can still be swapped with each other.
    Criterion 2 catches exact duplicates only.
  · Deep pages (player, settings sub-pages) are not reachable by the tab
    probe at all, so they are outside this script's remit.

USAGE
-----
  .\tools\verify_shots.ps1 -InDir .probe\e2e-t66
  .\tools\verify_shots.ps1 -InDir .probe\e2e-t66 -Tabs home,live,settings
  .\tools\verify_shots.ps1 -InDir .probe\e2e-t66 -ExpectWidth 1280 -ExpectHeight 800
  .\tools\verify_shots.ps1 -InDir .probe\e2e-t66 -Json

  # fault injection (proves it is not a constant-zero green):
  .\tools\verify_shots.ps1 -InDir .probe\e2e-bad    # dir holding the modal shot

EXIT CODES
----------
  0  every image passed all three criteria
  1  any criterion failed (the failing image + the number is printed)
  2  setup problem (dir missing, no PNGs, bad arguments)

OUTPUT LANGUAGE
---------------
English + pure ASCII, same rule as the other tools here: a `.ps1` that gets
re-encoded to ANSI turns Chinese text into runs of question marks and the
error message is destroyed while the exit code still looks fine.
======================================================================
#>
[CmdletBinding()]
param(
    # Directory holding the PNGs to verify (non-recursive).
    [string]$InDir = '.probe/e2e',

    # Optional subset; default = every *.png in -InDir.
    [string]$Tabs = '',

    # Expected dimensions (0 = do not check).
    [int]$ExpectWidth = 0,
    [int]$ExpectHeight = 0,

    # Absolute modal ratio threshold.
    [double]$ModalRatioAbs = 1.35,

    # Relative threshold: ratio must also be >= this multiple of the batch min.
    [double]$ModalRatioRel = 2.5,
    [double]$ModalRatioFloor = 1.25,

    # Freshness: compare the lib/ fingerprint recorded in run-manifest.txt
    # against the CURRENT lib/ tree. If they differ, the screenshots were made
    # from different product code and must not be trusted as evidence.
    [switch]$CheckFresh,

    # Machine-readable output.
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "  ..   $m" -ForegroundColor DarkGray }
function Ok($m) { Write-Host "  OK   $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL $m" -ForegroundColor Red }

# ----------------------------------------------------------------------
#  PNG decoding
# ----------------------------------------------------------------------
# System.Drawing handles the IDAT/zlib/filter work for us and ships with
# Windows PowerShell. It is used ONLY to read pixels of files the product
# itself rendered (never to capture the screen).
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

function Get-PngStats([string]$path) {
    $bmp = $null
    try {
        $bmp = [System.Drawing.Bitmap]::FromFile($path)
    } catch {
        return $null
    }
    try {
        $w = $bmp.Width; $h = $bmp.Height
        $step = 4
        $cSum = 0.0; $cN = 0
        $pSum = 0.0; $pN = 0
        for ($y = 0; $y -lt $h; $y += $step) {
            for ($x = 0; $x -lt $w; $x += $step) {
                $c = $bmp.GetPixel($x, $y)
                $l = 0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B
                $isPerim = ($x -lt $w * 0.08) -or ($x -gt $w * 0.92) -or
                           ($y -lt $h * 0.08) -or ($y -gt $h * 0.92)
                if ($isPerim) {
                    $pSum += $l; $pN++
                } elseif (($x -gt $w * 0.30) -and ($x -lt $w * 0.70) -and
                          ($y -gt $h * 0.25) -and ($y -lt $h * 0.75)) {
                    $cSum += $l; $cN++
                }
            }
        }
        if ($cN -eq 0 -or $pN -eq 0) { return $null }
        $cm = $cSum / $cN
        $pm = $pSum / $pN
        $ratio = if ($pm -gt 0) { $cm / $pm } else { 999.0 }
        return [pscustomobject]@{
            Width = $w; Height = $h; CentreLum = $cm; PerimLum = $pm; Ratio = $ratio
        }
    } finally {
        $bmp.Dispose()
    }
}

# ----------------------------------------------------------------------
#  collect inputs
# ----------------------------------------------------------------------
if (-not (Test-Path $InDir)) {
    Write-Host "FAIL: -InDir '$InDir' does not exist" -ForegroundColor Red
    exit 2
}
$dirAbs = (Resolve-Path $InDir).Path

$files = @(Get-ChildItem -LiteralPath $dirAbs -Filter '*.png' -File |
        Sort-Object Name)
if ($Tabs.Trim() -ne '') {
    $want = @($Tabs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $skip = @($files | Where-Object { $want -notcontains [System.IO.Path]::GetFileNameWithoutExtension($_.Name) })
    $files = @($files | Where-Object { $want -contains [System.IO.Path]::GetFileNameWithoutExtension($_.Name) })
    foreach ($s in $skip) {
        Info ("not requested, skipped: " + $s.Name)
    }
    foreach ($w in $want) {
        if (-not ($files | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $w })) {
            Write-Host "FAIL: requested tab '$w' has no PNG in $dirAbs" -ForegroundColor Red
            exit 1
        }
    }
}
# Ignore deliberately-kept reference images (the -GOOD / -BAD fixtures used
# to calibrate the thresholds); they are not page screenshots.
$files = @($files | Where-Object { $_.Name -notmatch '-(GOOD|BAD[^.]*)\.png$' })
if ($files.Count -eq 0) {
    Write-Host "FAIL: no PNG files in $dirAbs" -ForegroundColor Red
    exit 2
}

# ----------------------------------------------------------------------
#  criterion 1 + 3 : per image
# ----------------------------------------------------------------------
$rows = New-Object System.Collections.Generic.List[object]
$fail = New-Object System.Collections.Generic.List[string]

foreach ($f in $files) {
    $tab = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    $len = $f.Length
    $st = Get-PngStats $f.FullName

    $problems = @()
    # -- criterion 1a: non-empty
    if ($len -le 0) { $problems += 'zero bytes' }
    # -- criterion 1b: decodable
    if ($null -eq $st) { $problems += 'not a decodable PNG' }
    else {
        # -- criterion 1c: expected dimensions
        if ($ExpectWidth -gt 0 -and $st.Width -ne $ExpectWidth) {
            $problems += ("width {0} != expected {1}" -f $st.Width, $ExpectWidth)
        }
        if ($ExpectHeight -gt 0 -and $st.Height -ne $ExpectHeight) {
            $problems += ("height {0} != expected {1}" -f $st.Height, $ExpectHeight)
        }
    }
    $rows.Add([pscustomobject]@{
            Tab    = $tab
            Path   = $f.FullName
            Bytes  = $len
            Width  = if ($st) { $st.Width } else { 0 }
            Height = if ($st) { $st.Height } else { 0 }
            Ratio  = if ($st) { [math]::Round($st.Ratio, 3) } else { 0 }
            Sha    = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            Issues = ($problems -join '; ')
        })
}

foreach ($r in $rows) {
    if ($r.Issues -ne '') { $fail.Add("$($r.Tab): $($r.Issues)") }
}

# ----------------------------------------------------------------------
#  criterion 2 : distinct content
# ----------------------------------------------------------------------
$usable = @($rows | Where-Object { $_.Issues -eq '' })
$byHash = @{}
$dups = @()
foreach ($r in $usable) {
    if ($byHash.ContainsKey($r.Sha)) {
        $dups += ("{0} == {1}" -f $r.Tab, $byHash[$r.Sha])
    } else {
        $byHash[$r.Sha] = $r.Tab
    }
}
foreach ($d in $dups) { $fail.Add("duplicate content: $d") }

# ----------------------------------------------------------------------
#  criterion 3 : modal overlay
# ----------------------------------------------------------------------
$ratios = @($usable | ForEach-Object { [double]$_.Ratio })
$batchMin = if ($ratios.Count -gt 0) { ($ratios | Measure-Object -Minimum).Minimum } else { 0 }
$modal = @()
foreach ($r in $usable) {
    $ra = [double]$r.Ratio
    $byAbs = $ra -ge $ModalRatioAbs
    $byRel = ($ra -ge $ModalRatioFloor) -and ($batchMin -gt 0) -and
             ($ra -ge ($batchMin * $ModalRatioRel))
    if ($byAbs -or $byRel) {
        $why = if ($byAbs) { 'absolute' } else { 'relative-to-batch' }
        $modal += [pscustomobject]@{ Tab = $r.Tab; Ratio = $ra; Why = $why }
        # Build the message as plain concatenation: nested '...' inside a
        # double-quoted format string made the parser fail on the first try.
        $m = "modal overlay on '" + $r.Tab + "': centre/perimeter luminance ratio " +
             ("{0:N3}" -f $ra) + ' (threshold abs ' + ("{0:N2}" -f $ModalRatioAbs) +
             ', batch min ' + ("{0:N3}" -f $batchMin) + ' x ' +
             ("{0:N2}" -f $ModalRatioRel) + '); trigger=' + $why
        $fail.Add($m)
    }
}

# ----------------------------------------------------------------------
#  criterion 4 (opt-in) : are these images still current?
# ----------------------------------------------------------------------
# WHY a content hash and NOT a timestamp
# ----------------------------------------------------------------------
# The obvious rule "every PNG must be newer than HEAD's commit time" is a
# FALSE GREEN on CI. Measured on this machine:
#     git clone + git checkout  =>  all 1133 files get mtime inside a 1.8 s
#     window, and that window is LATER than the commit timestamp
#   (files 23:26:07.771..23:26:09.574, commit 23:24:35)
# So on any fresh checkout the PNGs would look "newer than the code" even if
# they were generated from completely different code. A timestamp check
# cannot distinguish "regenerated just now" from "checked out just now".
#
# The lib/ fingerprint recorded in the manifest CAN: it is stable across
# checkouts and changes exactly when the product code changes.
if ($CheckFresh) {
    $manifestPath = Join-Path $dirAbs 'run-manifest.txt'
    if (-not (Test-Path $manifestPath)) {
        $fail.Add("freshness: no run-manifest.txt in $dirAbs -- cannot tell which code produced these images. Re-run tools/e2e_shots.ps1.")
    } else {
        $mf = Get-Content -LiteralPath $manifestPath -Raw
        $m = [regex]::Match($mf, '(?m)^inputHash\s*=\s*([0-9a-f]{64})\s*$')
        if (-not $m.Success) {
            $fail.Add("freshness: run-manifest.txt has no inputHash line -- the manifest predates the fingerprint. Re-run tools/e2e_shots.ps1.")
        } else {
            $recorded = $m.Groups[1].Value
            # Recompute with EXACTLY the algorithm documented in
            # tools/e2e_shots.ps1 step 5 (same roots, same normalisation,
            # same ordinal sort, same line format). If the two ever diverge
            # this check silently reports STALE forever -- so keep them in sync.
            $repoRoot = Split-Path -Parent $PSScriptRoot
            $roots = @('lib', 'rust/sourin_core/src', 'windows', 'assets')
            $singleFiles = @('pubspec.yaml', 'pubspec.lock')
            $inputs2 = New-Object System.Collections.Generic.List[object]
            foreach ($r in $roots) {
                $abs = Join-Path $repoRoot $r
                if (-not (Test-Path $abs)) { continue }
                foreach ($f in @(Get-ChildItem -LiteralPath $abs -Recurse -File -ErrorAction SilentlyContinue)) {
                    $inputs2.Add($f)
                }
            }
            foreach ($f in $singleFiles) {
                $abs = Join-Path $repoRoot $f
                if (-not (Test-Path $abs)) { continue }
                $inputs2.Add((Get-Item -LiteralPath $abs))
            }
            if ($inputs2.Count -eq 0) {
                $fail.Add("freshness: recomputed zero input files -- cannot compare")
            } else {
                $entries2 = New-Object System.Collections.Generic.List[string]
                foreach ($f in $inputs2) {
                    $relPath = $f.FullName.Substring($repoRoot.Length).Replace('\', '/')
                    if ($relPath.StartsWith('/')) { $relPath = $relPath.Substring(1) }
                    $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    $entries2.Add($relPath + ':' + $h)
                }
                $entries2.Sort([System.StringComparer]::Ordinal)
                $sb2 = New-Object System.Text.StringBuilder
                foreach ($e in $entries2) { [void]$sb2.Append($e).Append("`n") }
                $sha2 = [System.Security.Cryptography.SHA256]::Create()
                $current = -join ($sha2.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb2.ToString())) |
                        ForEach-Object { $_.ToString('x2') })
                $sha2.Dispose()
                if ($current -ne $recorded) {
                    $fail.Add(("freshness: screenshots were made from build inputs " + $recorded.Substring(0,16) +
                            "... but the tree is now " + $current.Substring(0,16) +
                            "... -- STALE. Re-run tools/e2e_shots.ps1."))
                } else {
                    Info ("freshness OK: build-input fingerprint matches the manifest (" + $recorded.Substring(0,16) +
                          "...; " + $inputs2.Count + " files)")
                }
            }
        }
    }
}

# ----------------------------------------------------------------------
#  report
# ----------------------------------------------------------------------
if ($Json) {
    [pscustomobject]@{
        dir        = $dirAbs
        batchMin   = $batchMin
        thresholds = [pscustomobject]@{ abs = $ModalRatioAbs; rel = $ModalRatioRel; floor = $ModalRatioFloor }
        images     = $rows
        failures   = $fail
        pass       = ($fail.Count -eq 0)
    } | ConvertTo-Json -Depth 6
} else {
    Write-Host ''
    Write-Host '  -- verify_shots ---------------------------------------------' -ForegroundColor Cyan
    Write-Host ("  {0,-12} {1,10} {2,11} {3,8}  {4}" -f 'tab', 'bytes', 'png', 'ratio', 'verdict')
    foreach ($r in $rows) {
        $verdict = if ($r.Issues -ne '') { 'BAD' }
        elseif ($modal | Where-Object { $_.Tab -eq $r.Tab }) { 'MODAL!' }
        else { 'ok' }
        Write-Host ("  {0,-12} {1,10:N0} {2,11} {3,8:N3}  {4}" -f `
                $r.Tab, $r.Bytes, ("{0}x{1}" -f $r.Width, $r.Height), $r.Ratio, $verdict)
    }
    Write-Host '  ------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ("  batch min ratio = {0:N3}   (modal thresholds: abs {1:N2}, or >= batch min x {2:N2} and >= {3:N2})" -f `
            $batchMin, $ModalRatioAbs, $ModalRatioRel, $ModalRatioFloor)
    Write-Host ''
    if ($fail.Count -eq 0) {
        Write-Host ("  PASS  {0} image(s): non-empty, expected size, distinct, no modal overlay" -f $rows.Count) -ForegroundColor Green
    } else {
        foreach ($m in $fail) { Bad $m }
        Write-Host ''
        Write-Host ("  FAIL  {0} problem(s) across {1} image(s)" -f $fail.Count, $rows.Count) -ForegroundColor Red
    }
    Write-Host ''
}

if ($fail.Count -gt 0) { exit 1 }
exit 0
