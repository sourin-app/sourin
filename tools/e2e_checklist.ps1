<#
======================================================================
  Sourin - round checklist runner (e2e_checklist)
======================================================================

WHAT THIS IS FOR
----------------
`docs/notes/round-66-e2e-verify.md` is a human checklist. This script runs
the machine-checkable half of it and PRINTS the rest as explicit MANUAL
work. It exists so the end-of-batch pass is one command instead of a
person re-reading a markdown table and hoping they covered everything.

DESIGN RULES (each exists because of a failure in this repo)
------------------------------------------------------------
  1. NO SILENT SKIPS. Every item either runs its checks or prints
     `MANUAL: <what a human must do>`. An item that quietly does nothing
     would be indistinguishable from a passing one.
  2. An unknown check type is a hard ERROR, not a skip. A typo in the JSON
     must not turn a check into a pass.
  3. Expected counts are EXACT for `tests` items when `passed` is given.
     "0 failed" alone is satisfied by a suite that ran nothing, which is
     how a skipped file looks.
  4. Negative-control items exist on purpose (`expectResult: fail`): the
     runner itself must reproduce a red result for the known-bad fixture,
     otherwise the verifier might be blind.

CHECK TYPES
-----------
  tests       run `flutter test <files> --concurrency=1`, require +N -M
  source      literal / regex present-or-absent in a source file
  log         count a regex over a log file, compare to an expected count
  file        existence / absence of a path
  screenshot  delegate to tools/verify_shots.ps1 (non-empty, size,
              distinct, and no full-screen modal overlay)

EXIT CODES
----------
  0  every auto item passed AND every manual item was reported
  1  at least one blocking auto item failed
  2  setup problem (checklist missing/unparseable, bad check type,
     flutter not found when a tests item needed it)

USAGE
-----
  .\tools\e2e_checklist.ps1
  .\tools\e2e_checklist.ps1 -Only R2-1,R2-2,DM-1
  .\tools\e2e_checklist.ps1 -SkipTests          # fast: source/log/file/screenshot only
  .\tools\e2e_checklist.ps1 -List                # show ids + modes, run nothing
  .\tools\e2e_checklist.ps1 -Json

OUTPUT LANGUAGE
---------------
English + pure ASCII. See the header of tools/e2e_shots.ps1 for why.
======================================================================
#>
[CmdletBinding()]
param(
    [string]$ChecklistPath = '',
    [string]$Only = '',
    [switch]$SkipTests,
    [switch]$List,
    [switch]$Json,
    # 留空 = 走 PATH（或 $env:FLUTTER_BIN）。
    # ⚠️ 不要在这里填某台开发机的绝对路径：提交前隐私清理要扫全树，
    #    换机器的人也会直接踩坑。见下方 Resolve-Flutter。
    [string]$FlutterBin = ''
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "  ..   $m" -ForegroundColor DarkGray }
function Ok($m) { Write-Host "  OK   $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL $m" -ForegroundColor Red }
# Do NOT name this `Man`: `man` is a built-in alias for Get-Help, and
# PowerShell resolves ALIAS before FUNCTION, so a function called Man is
# unreachable and every call silently invokes Get-Help instead.
function Show-Manual($m) { Write-Host "  MANUAL $m" -ForegroundColor Yellow }

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if ($ChecklistPath -eq '') { $ChecklistPath = Join-Path $root 'tools\e2e_checklist.json' }
if (-not (Test-Path $ChecklistPath)) {
    Write-Host "FAIL: checklist not found at $ChecklistPath" -ForegroundColor Red
    exit 2
}

try {
    $raw = Get-Content -LiteralPath $ChecklistPath -Raw -Encoding UTF8
    $doc = $raw | ConvertFrom-Json
} catch {
    Write-Host "FAIL: checklist is not valid JSON: $_" -ForegroundColor Red
    exit 2
}
if (-not $doc.items -or $doc.items.Count -eq 0) {
    Write-Host 'FAIL: checklist has no items' -ForegroundColor Red
    exit 2
}

# ---- selection --------------------------------------------------------
$items = @($doc.items)
if ($Only.Trim() -ne '') {
    $want = @($Only -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $missing = @($want | Where-Object { -not ($items | Where-Object { $_.id -eq $_ }) })
    if ($missing.Count -gt 0) {
        # A requested id that does not exist must not silently reduce coverage.
        Write-Host ("FAIL: -Only named id(s) that are not in the checklist: " + ($missing -join ', ')) -ForegroundColor Red
        exit 2
    }
    $items = @($items | Where-Object { $want -contains $_.id })
}

if ($List) {
    Write-Host ''
    Write-Host ("  {0,-10} {1,-8} {2,-10} {3}" -f 'id', 'mode', 'severity', 'title') -ForegroundColor Cyan
    foreach ($it in $items) {
        Write-Host ("  {0,-10} {1,-8} {2,-10} {3}" -f $it.id, $it.mode, $it.severity, $it.title)
    }
    $auto = @($items | Where-Object { $_.mode -eq 'auto' }).Count
    Write-Host ''
    Write-Host ("  total {0}: auto {1}, manual {2}" -f $items.Count, $auto, ($items.Count - $auto))
    Write-Host ''
    exit 0
}

# ---- helpers ----------------------------------------------------------
$script:Failures = New-Object System.Collections.Generic.List[object]
$script:Ran = 0

function Add-Failure($id, $msg) {
    $script:Failures.Add([pscustomobject]@{ id = $id; message = $msg })
}

function Resolve-Flutter {
    # 显式 -FlutterBin 优先，其次 $env:FLUTTER_BIN，最后 PATH。
    # ⚠️ 三条都要真的存在才认；都找不到就返回 $null，让调用方**报错退出**，
    #    不许静默回退到某个猜的路径（那会让"没跑"长得像"跑过了"）。
    if ($FlutterBin -and (Test-Path $FlutterBin)) { return $FlutterBin }
    if ($env:FLUTTER_BIN -and (Test-Path $env:FLUTTER_BIN)) { return $env:FLUTTER_BIN }
    $c = Get-Command flutter -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

# Count occurrences of a regex in a text file.
function Count-Regex([string]$path, [string]$pattern) {
    if (-not (Test-Path $path)) { return $null }
    $txt = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $txt) { return 0 }
    return ([regex]::Matches($txt, $pattern)).Count
}

# Run one `tests` check and parse the trailing "+N -M" the runner prints.
function Invoke-TestsCheck($id, $chk) {
    $fl = Resolve-Flutter
    if (-not $fl) { throw 'flutter not found (needed by a tests check)' }
    $files = @($chk.files)
    # NOTE: do NOT name this $args -- $args is a PowerShell automatic variable
    # and splatting it re-enters parameter binding (observed as
    # "Cannot find drive. A drive with the name 'R2-1' does not exist").
    $flutterArgs = @('test') + $files + @('--concurrency=1')
    $out = & $fl @flutterArgs 2>&1
    $rc = $LASTEXITCODE
    $text = ($out | Out-String)
    # last "+N -M" / "+N" on the tail
    $m = [regex]::Matches($text, '\+(\d+)(?:\s+-(\d+))?')
    $passed = $null; $failed = 0
    if ($m.Count -gt 0) {
        $last = $m[$m.Count - 1]
        $passed = [int]$last.Groups[1].Value
        if ($last.Groups[2].Success) { $failed = [int]$last.Groups[2].Value }
    }
    $expP = $null
    $expF = 0
    if ($chk.expect) {
        if ($null -ne $chk.expect.passed) { $expP = [int]$chk.expect.passed }
        if ($null -ne $chk.expect.failed) { $expF = [int]$chk.expect.failed }
    }
    $problems = @()
    if ($null -eq $passed) { $problems += "could not read a +N/-M summary (exit $rc)" }
    else {
        # exact passed-count when declared: "0 failed" alone is satisfied by a
        # run that executed nothing.
        if ($null -ne $expP -and $passed -ne $expP) {
            $problems += "passed $passed, expected exactly $expP"
        }
        if ($failed -ne $expF) { $problems += "failed $failed, expected exactly $expF" }
    }
    if ($rc -ne 0 -and $expF -eq 0) { $problems += "exit code $rc" }
    return [pscustomobject]@{
        passed   = $passed
        failed   = $failed
        exit     = $rc
        detail   = ("+{0} -{1} (exit {2}) over {3} file(s)" -f $passed, $failed, $rc, $files.Count)
        problems = $problems
    }
}

function Invoke-SourceCheck($id, $chk) {
    $path = Join-Path $root $chk.file
    if (-not (Test-Path $path)) {
        return [pscustomobject]@{ detail = "file missing: $($chk.file)"; problems = @('file missing') }
    }
    $txt = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    # Optional: strip comment lines before matching.
    #
    # WHY: on 2026-10-19 this check reported "lower.contains('内置代理') is
    # still present" against code where it had been REMOVED. Both hits were
    # in comments that explain why it was removed. That is the repo's known
    # "anchor matches a comment" trap: a bare substring search cannot tell
    # code from prose about the code.
    # With -IgnoreComments the matcher drops lines whose trimmed form starts
    # with //, ///, #, or * (JSDoc continuation).
    if ($chk.ignoreComments) {
        $kept = @()
        foreach ($ln in ($txt -split "`r?`n")) {
            $t = $ln.TrimStart()
            if ($t.StartsWith('//')) { continue }
            if ($t.StartsWith('#')) { continue }
            if ($t.StartsWith('*')) { continue }
            if ($t.StartsWith('/*')) { continue }
            $kept += $ln
        }
        $txt = ($kept -join "`n")
    }
    $pat = $chk.pattern
    $expect = $chk.expect
    $isRegex = ($expect -eq 'regex-present') -or ($expect -eq 'regex-absent')
    if ($isRegex) {
        $hit = [regex]::IsMatch($txt, $pat, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    } else {
        $hit = $txt.Contains($pat)
    }
    $wantPresent = -not ($expect -eq 'absent' -or $expect -eq 'regex-absent')
    $ok = ($hit -eq $wantPresent)
    $problems = @()
    if (-not $ok) {
        $problems += ("expected {0} but found {1}: {2}" -f $(if ($wantPresent) { 'present' } else { 'absent' }), $(if ($hit) { 'present' } else { 'absent' }), $pat)
    }
    return [pscustomobject]@{
        detail   = ("{0}: {1} {2}{3}" -f $chk.file, $(if ($hit) { 'contains' } else { 'lacks' }), $pat, $(if ($chk.ignoreComments) { ' [comments ignored]' } else { '' }))
        problems = $problems
    }
}

function Invoke-LogCheck($id, $chk) {
    $path = Join-Path $root $chk.file
    if (-not (Test-Path $path)) {
        return [pscustomobject]@{ detail = "log missing: $($chk.file)"; problems = @('log file missing (run e2e_shots.ps1 first)') }
    }
    $n = Count-Regex $path $chk.pattern
    $exp = $null
    if ($chk.expect -and $null -ne $chk.expect.count) { $exp = [int]$chk.expect.count }
    $problems = @()
    if ($null -ne $exp -and $n -ne $exp) {
        $problems += "count $n, expected exactly $exp for /$($chk.pattern)/"
    }
    return [pscustomobject]@{ detail = ("count={0} for /{1}/" -f $n, $chk.pattern); problems = $problems }
}

function Invoke-FileCheck($id, $chk) {
    $path = Join-Path $root $chk.path
    $exists = Test-Path $path
    $want = if ($chk.expect) { $chk.expect } else { 'exists' }
    $ok = if ($want -eq 'absent') { -not $exists } else { $exists }
    $problems = @()
    if (-not $ok) { $problems += "expected $want but exists=$exists" }
    return [pscustomobject]@{ detail = ("$($chk.path): exists=$exists, expected $want"); problems = $problems }
}

function Invoke-ScreenshotCheck($id, $chk) {
    $dirAbs = Join-Path $root $chk.dir
    if (-not (Test-Path $dirAbs)) {
        return [pscustomobject]@{ detail = "dir missing: $($chk.dir)"; problems = @('screenshot dir missing (run e2e_shots.ps1 first)') }
    }
    $verifier = Join-Path $root 'tools\verify_shots.ps1'
    if (-not (Test-Path $verifier)) {
        return [pscustomobject]@{ detail = 'tools/verify_shots.ps1 missing'; problems = @('verifier missing') }
    }
    $vArgs = @('-NoProfile', '-File', $verifier, '-InDir', $dirAbs)
    if ($chk.tabs) { $vArgs += @('-Tabs', (($chk.tabs) -join ',')) }
    if ($chk.expectWidth) { $vArgs += @('-ExpectWidth', $chk.expectWidth) }
    if ($chk.expectHeight) { $vArgs += @('-ExpectHeight', $chk.expectHeight) }
    $out = & pwsh @vArgs 2>&1
    $rc = $LASTEXITCODE
    $tail = ($out | Select-Object -Last 6) -join ' | '
    $wantFail = ($chk.expectResult -eq 'fail')
    $problems = @()
    if ($wantFail -and $rc -eq 0) {
        $problems += 'negative control did NOT fail -- the verifier is blind to this case'
    } elseif (-not $wantFail -and $rc -ne 0) {
        $problems += "verifier exited $rc"
    }
    return [pscustomobject]@{
        detail   = ("verify_shots exit={0} (expected {1}); {2}" -f $rc, $(if ($wantFail) { 'fail' } else { 'pass' }), $tail)
        problems = $problems
    }
}

# ---- run --------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]

foreach ($it in $items) {
    $mode = if ($it.mode) { $it.mode } else { 'manual' }
    Write-Host ''
    Write-Host ("[{0}] {1}" -f $it.id, $it.title) -ForegroundColor Cyan

    if ($mode -eq 'manual') {
        $why = if ($it.manual_note) { $it.manual_note } else { '(no reason recorded -- treat as a defect in the checklist)' }
        Show-Manual ("{0}  {1}" -f $it.id, $why)
        $results.Add([pscustomobject]@{ id = $it.id; mode = 'manual'; status = 'MANUAL'; detail = $why })
        continue
    }
    if ($mode -ne 'auto') {
        # A typo in "mode" must not quietly reduce coverage.
        Bad ("{0}: unknown mode '{1}' (must be auto|manual)" -f $it.id, $mode)
        Add-Failure $it.id "unknown mode '$mode'"
        $results.Add([pscustomobject]@{ id = $it.id; mode = $mode; status = 'ERROR'; detail = 'unknown mode' })
        continue
    }
    if (-not $it.checks -or @($it.checks).Count -eq 0) {
        Bad ("{0}: mode=auto but no checks -- that is a silent pass" -f $it.id)
        Add-Failure $it.id 'mode=auto with zero checks'
        $results.Add([pscustomobject]@{ id = $it.id; mode = 'auto'; status = 'ERROR'; detail = 'no checks' })
        continue
    }

    $itemProblems = @()
    $details = @()
    foreach ($chk in @($it.checks)) {
        $type = "$($chk.type)"
        if ($SkipTests -and $type -eq 'tests') {
            Show-Manual ("{0}: tests check skipped by -SkipTests" -f $it.id)
            $details += 'tests SKIPPED (-SkipTests)'
            continue
        }
        try {
            $r = switch ($type) {
                'tests' { Invoke-TestsCheck $it.id $chk }
                'source' { Invoke-SourceCheck $it.id $chk }
                'log' { Invoke-LogCheck $it.id $chk }
                'file' { Invoke-FileCheck $it.id $chk }
                'screenshot' { Invoke-ScreenshotCheck $it.id $chk }
                default { throw "unknown check type '$type' -- refusing to treat it as a pass" }
            }
        } catch {
            # setup-level problems (flutter missing) and unknown types both land
            # here; both must be loud.
            Bad ("{0}: {1}" -f $it.id, $_)
            $script:Failures.Add([pscustomobject]@{ id = $it.id; message = "$_" })
            $itemProblems += "$_"
            continue
        }
        if ($r) {
            $details += $r.detail
            foreach ($p in @($r.problems)) {
                if ($p) { $itemProblems += $p }
            }
        }
    }

    if ($itemProblems.Count -eq 0) {
        Ok ("{0}: {1}" -f $it.id, (($details -join '; ')))
        $results.Add([pscustomobject]@{ id = $it.id; mode = 'auto'; status = 'PASS'; detail = ($details -join '; ') })
    } else {
        foreach ($p in $itemProblems) { Bad ("{0}: {1}" -f $it.id, $p) }
        if ($it.severity -ne 'info') { Add-Failure $it.id ($itemProblems -join ' | ') }
        $results.Add([pscustomobject]@{ id = $it.id; mode = 'auto'; status = 'FAIL'; detail = ($itemProblems -join ' | ') })
    }
}

# ---- summary ----------------------------------------------------------
$auto = @($results | Where-Object { $_.mode -eq 'auto' })
$pass = @($auto | Where-Object { $_.status -eq 'PASS' }).Count
$failc = @($auto | Where-Object { $_.status -eq 'FAIL' -or $_.status -eq 'ERROR' }).Count
$manual = @($results | Where-Object { $_.status -eq 'MANUAL' })

if ($Json) {
    [pscustomobject]@{
        checklist = $ChecklistPath
        auto      = $auto.Count
        passed    = $pass
        failed    = $failc
        manual    = $manual.Count
        results   = $results
        failures  = $script:Failures
    } | ConvertTo-Json -Depth 6
} else {
    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host ("  auto   {0}  (pass {1}, fail {2})" -f $auto.Count, $pass, $failc)
    Write-Host ("  manual {0}" -f $manual.Count)
    if ($manual.Count -gt 0) {
        Write-Host ''
        Write-Host '  MANUAL items still owed (these are NOT verified):' -ForegroundColor Yellow
        foreach ($m in $manual) { Write-Host ("    - {0}" -f $m.id) -ForegroundColor Yellow }
    }
    Write-Host ''
    if ($failc -eq 0) {
        Write-Host '  PASS  every automated check passed; manual items listed above' -ForegroundColor Green
    } else {
        Write-Host '  FAIL  automated checks failed:' -ForegroundColor Red
        foreach ($f in $script:Failures) { Write-Host ("    - {0}: {1}" -f $f.id, $f.message) -ForegroundColor Red }
    }
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host ''
}

if ($failc -gt 0 -or $script:Failures.Count -gt 0) { exit 1 }
exit 0
