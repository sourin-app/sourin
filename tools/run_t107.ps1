# ═══════════════════════════════════════════════════════════════════════
#  源影 · CS-1 备份五步真机驱动（Windows）
# ═══════════════════════════════════════════════════════════════════════
#
# # 为什么要有这个脚本
#
# ```text
# docs/notes/round-66-e2e-verify.md 自报过「CS-1 真机 56 ✓ / 7 张截图」，
# 但全盘 `t66-cs1*` = 0、`.probe/e2e/` 只剩 3 张弹幕代理图 ⇒ 那 7 张从来没
# 落在自报路径上。根因之一不是"忘记跑"，而是 `tools/e2e_shots.ps1` 只到页签级
# —— CS-1 的「导出 → 设口令 → 导入 → 错口令 → 对口令」这 5 步，
# 没有任何工具驱动得了，所以"跑过"只能靠人嘴说。
#
# ⇒ 这个脚本把那条路做成一条命令：编探针入口 → 跑真窗口 → 读探针自己落的
#   报告文件 → 打印机器可读行。判据不在本脚本里，探针自己算 OK/BAD。
# ```
#
# # 用法
#
# ```powershell
# .\tools\run_t107.ps1                  # 编 + 跑（默认 Release），产物在 .probe\round66_cs1\<时间戳>\
# .\tools\run_t107.ps1 -Run r6b-cs1     # 指定本次运行目录名（可复现路径）
# .\tools\run_t107.ps1 -NoBuild         # 只跑，不编（复用上次编进去的数据目录）
# ```
#
# # ⚠️ 三个硬闸（都是真实事故换来的）
#
# ```text
# ① 数据目录必须解析到 .probe\round66_cs1\ 下，否则立刻退出 —— 探针会**写**
#    （导出包、删/放一份假凭据文件），指到真实数据目录就是把用户的收藏/进度
#    拿去陪跑。探针自己也有一道同样的闸（DATA_DIR_OVERRIDE 不含 round66_cs1 ⇒ exit(3)）。
# ② 产物必须比源码新。2026-10-20 现场就踩过：build\ 里躺着 10-18 的 exe，
#    跑起来一切"正常"，出的是两天前的像素 ⇒ 证据全废，且不会报错。
# ③ GUI 子系统的 exe **没有 stdout**。日志可能一个字都重定向不出来，
#    所以判据只认探针自己写的三个文件：
#      <数据目录>\cs1-report.txt  逐条 ✓/✗ + `---- 结果：OK=n BAD=m`
#      <数据目录>\cs1-lines.txt   CS1|step|file=…|bytes=…|sha256=…|ui=…|verdict=OK|BAD
#      <数据目录>\cs1-trace.txt   时间戳追踪（异常/看门狗/落盘路径）
#    本脚本只负责把它们打出来，不改写、不二次判定。
# ```
#
# # 与 git 的关系
#
# ```text
# 探针 `lib/t107_cs1_flow_probe.dart` 是**未提交**资产（untracked），
# `-NoBuild` 时若找不到它或产物过期，本脚本直接退出 —— 不给"看起来跑过了"的机会。
# ```

[CmdletBinding()]
param(
    [string]$Run = (Get-Date -Format 'yyyyMMdd-HHmmss'),
    [switch]$NoBuild,
    [int]$TimeoutSec = 480
)

$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent $PSScriptRoot
$probeSrc = Join-Path $root 'lib\t107_cs1_flow_probe.dart'
$exe      = Join-Path $root 'build\windows\x64\runner\Release\sourin_spike.exe'
$probeRoot = Join-Path $root '.probe\round66_cs1'
$dataDir  = Join-Path $probeRoot $Run
$stamp    = Join-Path $probeRoot 'last_build_dir.txt'

function Die([string]$msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 2
}

# ── 硬闸 ①：路径必须是隔离目录 ─────────────────────────────────────────
if ($dataDir -notmatch 'round66_cs1') {
    Die "数据目录不在 .probe\round66_cs1 下：$dataDir"
}
if ($dataDir -match 'app\.sourin\.player' -or $dataDir -match [regex]::Escape($env:APPDATA)) {
    Die "数据目录像是真实用户数据目录，拒绝运行：$dataDir"
}
if (-not (Test-Path $probeSrc)) {
    Die "找不到探针源码：$probeSrc（未提交资产，确认它在盘上）"
}

New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null

# ── 编（可跳过）─────────────────────────────────────────────────────────
if (-not $NoBuild) {
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    Set-Content -Path $stamp -Value $dataDir -Encoding UTF8
    # flutter 可执行：优先 PATH，其次本机固定位置（直接在 pwsh 里跑时 PATH 未必有）
    $flutter = $null
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd -ne $null) { $flutter = $cmd.Source }
    if ($flutter -eq $null) {
        $cand = 'C:\Users\iuuuuuuuu\flutter\bin\flutter.bat'
        if (Test-Path $cand) { $flutter = $cand }
    }
    if ($flutter -eq $null) { Die "找不到 flutter：PATH 里没有，也没有 C:\Users\iuuuuuuuu\flutter\bin\flutter.bat" }
    Write-Host "== 构建探针入口（-t lib/t107_cs1_flow_probe.dart）==" -ForegroundColor Cyan
    Write-Host "   flutter=$flutter"
    Write-Host "   DATA_DIR_OVERRIDE=$dataDir"
    Push-Location $root
    try {
        & $flutter build windows --release `
            -t lib/t107_cs1_flow_probe.dart `
            --dart-define=DATA_DIR_OVERRIDE="$dataDir"
        $buildExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($buildExit -ne 0) { Die "flutter build 失败（exit=$buildExit）" }
} else {
    if (-not (Test-Path $stamp)) { Die "-NoBuild 需要先跑过一次带构建的运行（缺 $stamp）" }
    $dataDir = (Get-Content $stamp -Raw).Trim()
    if ($dataDir -notmatch 'round66_cs1') { Die "记录的数据目录不合法：$dataDir" }
    if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }
    Write-Host "== 复用上次构建的数据目录：$dataDir" -ForegroundColor Yellow
}

# ── 硬闸 ②：产物必须存在且比源码新 ──────────────────────────────────────
if (-not (Test-Path $exe)) { Die "找不到产物：$exe" }
$exeTime   = (Get-Item $exe).LastWriteTime
$srcTime   = (Get-Item $probeSrc).LastWriteTime
if ($exeTime -lt $srcTime) {
    Die ("产物比源码旧 ⇒ 跑出来的是旧代码，证据无效。`n" +
         "  exe : $exeTime`n  源码: $srcTime`n  去掉 -NoBuild 重新编。")
}
Write-Host "== 产物 $exe" -ForegroundColor Cyan
Write-Host "   exe=$exeTime  源码=$srcTime  (exe 不旧于源码 ✓)"

# ── 跑 ──────────────────────────────────────────────────────────────────
$outLog = Join-Path $dataDir 'stdout.txt'
$errLog = Join-Path $dataDir 'stderr.txt'
Write-Host "== 启动真窗口（$TimeoutSec s 超时；本脚本不夺焦点、不注入输入）==" -ForegroundColor Cyan
$proc = Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) `
    -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
$exited = $proc.WaitForExit($TimeoutSec * 1000)
if (-not $exited) {
    try { $proc.Kill() } catch { }
    Write-Host "TIMEOUT: 超过 $TimeoutSec s 未退出（看 cs1-trace.txt 的最后一个阶段）" -ForegroundColor Red
    $code = 124
} else {
    $code = $proc.ExitCode
}

# ── 读探针自己落的报告（判据只认这三个文件）─────────────────────────────
$report = Join-Path $dataDir 'cs1-report.txt'
$lines  = Join-Path $dataDir 'cs1-lines.txt'
$traceF = Join-Path $dataDir 'cs1-trace.txt'
$shotDir = Join-Path $dataDir 'shots'

Write-Host ""
Write-Host "======== 机器可读行（cs1-lines.txt）========" -ForegroundColor Green
if (Test-Path $lines) { Get-Content $lines } else { Write-Host "（缺失）" -ForegroundColor Red }

Write-Host ""
Write-Host "======== 逐条读数（cs1-report.txt）========" -ForegroundColor Green
if (Test-Path $report) {
    Get-Content $report | Select-Object -Last 80
} else {
    Write-Host "（缺失 —— 说明探针没走到收尾，看下面的 trace）" -ForegroundColor Red
}

Write-Host ""
Write-Host "======== 截图（shots\cs1_*.png）========" -ForegroundColor Green
if (Test-Path $shotDir) {
    Get-ChildItem $shotDir -Filter 'cs1_*.png' |
        Sort-Object Name |
        ForEach-Object { "{0,-28} {1,8} B" -f $_.Name, $_.Length }
} else {
    Write-Host "（没有 shots 目录）" -ForegroundColor Red
}

if (Test-Path $traceF) {
    Write-Host ""
    Write-Host "======== trace 尾部（cs1-trace.txt）========" -ForegroundColor Green
    Get-Content $traceF | Select-Object -Last 25
}

# ── 汇总 ────────────────────────────────────────────────────────────────
$bad = 0
if (Test-Path $report) {
    $bad = (Select-String -Path $report -Pattern '^\s*✗' -AllMatches).Count
}
$pngCount = 0
if (Test-Path $shotDir) { $pngCount = (Get-ChildItem $shotDir -Filter 'cs1_*.png').Count }

Write-Host ""
Write-Host "======== 汇总 ========" -ForegroundColor Cyan
Write-Host "  探针退出码 : $code"
Write-Host "  BAD 行数   : $bad"
Write-Host "  截图张数   : $pngCount  (约定 ≥ 5)"
Write-Host "  产物目录   : $dataDir"
Write-Host ""
Write-Host "★ 判据以 cs1-report.txt 的逐条 ✓/✗ 为准；本脚本只打印，不改判。"

if ($code -ne 0 -or $bad -gt 0 -or $pngCount -lt 5) { exit 1 }
exit 0
