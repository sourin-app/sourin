# ═══════════════════════════════════════════════════════════════════════
#  源影 · 开发数据目录播种（把真实目录的「内容」拷一份到开发目录）
# ═══════════════════════════════════════════════════════════════════════
#
# # 为什么有这个脚本（Owner 2026-10-15）
#
# `tools\run_client.ps1 -Dev` 起的是一间**空**数据目录：里面只有核心首次
# 启动释放的 demo.js。用户自己装的 31 个插件、收藏、历史、进度、偏好全都不在。
# Owner 原话：「你打开的时候没有之前的 js 插件和数据」—— 一个看不见真实内容
# 的开发环境，验不了任何真实场景（插件调试、追更、播放进度一条都跑不通）。
#
# # ★ 铁律：单向（只读真实目录）
#
# ```text
#   真实目录  %APPDATA%\app.sourin.player      ← **只读**，一个字节都不改
#   开发目录  -Target（-Dev 时 = %TEMP%\sourin-dev）  ← 只往这里写
# ```
#
# 本脚本没有任何一行以 $Source 为写入目标。对应的回归测试
# `test/zz_t1015_dev_seed_test.dart` 会按哈希逐文件核对「跑完种子后源目录一字未变」。
#
# # 播种什么（白名单，不是全量拷贝）
#
# ```text
#   拷   plugins\*.js         用户自己装的插件**源码**
#   拷   ui-prefs.json        按 key 过滤后的界面/外观/播放偏好（见白名单③）
#   拷   状态 json            收藏顺序 / 禁用的源 / 第三方源 / 书架缓存 / 首页缓存
#   拷   dsh-media.db 三件套  收藏/历史/进度/片头片尾（含 -wal、-shm）
#   不拷 logs\ backup-*\ mpv-cache\ clip-cache\ shots\ transcode\
#   不拷 device-id            ★ 让开发实例有**自己的**设备身份
# ```
#
# # ★★ 凭据类一律不带（仓库安全规矩：docs/AGENTS.md §3 点名的那三样）
#
# ```text
#   sync-settings.json   含 WebDAV 地址 + 账号，且会自动往**真实网盘**推数据
#   remote-pref.json     含端口 + auto_start=true，会占 8642 端口
#   plugins/.data/       插件私有存储，实测含真实凭据（token / 会话 cookie）
#   ui-prefs 的 dsh.bili.* / dsh.speedtest.* / dsh.srcpref.* / dsh.homeSource
#                        用户的分P绑定、测速历史、源级偏好（53 个 key 里占 35 个）
# ```
#
# ⚠️ 代价要说清楚：插件搬过去后是「未配置」状态，要自己重新填。这个代价必须付 ——
#    临时目录会被随手清空，凭据在那儿等于凭空多一份泄漏面。
#
# # 两条保护
#
# ```text
# ① 不覆盖：目标里已有的文件默认**跳过**（-Force 才盖）。
#    ⇒ 开发期自己写进去的测试数据不会被下一次启动冲掉，反复跑本脚本是幂等的。
# ② 拒绝「目标 = 源」：一句 -Target 指到真实目录就会被硬拒（exit 2）。
#    ⇒ 否则那等于拿用户数据当试验场，与本脚本「只读真实目录」的前提直接冲突。
# ```
#
# # 用法
#
# ```powershell
# .\tools\seed_dev_data.ps1 -Target "$env:TEMP\sourin-dev"
# .\tools\seed_dev_data.ps1 -Target D:\tmp\dev -Force      # 覆盖式重播
# .\tools\seed_dev_data.ps1 -Target D:\tmp\dev -Source X:\other
# ```
#
# ⚠️ 本脚本**不碰运行中的进程**，真实 App 开着也能跑（全程只读）。只是在真实
#    App 正写库的那一瞬间拷 dsh-media.db，可能拿到略旧的快照 —— 对本用途无妨。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$Source,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not $Source) { $Source = Join-Path $env:APPDATA "app.sourin.player" }
# 去掉尾部反斜杠，下面按长度切相对路径才不会多带一个分隔符
$Source = $Source.TrimEnd("\")
$Target = $Target.TrimEnd("\")

# ── 白名单①：源根目录下的文件（精确名 + 通配）──────────────────────
#
# ⚠️ 只有「不含凭据、不含登录态」的才配进来。逐条理由：
#   dsh-media.db 三件套  收藏/历史/进度/片头片尾 —— 正是开发要验的东西
#   shelf-cache.json     书架缓存（内容快照，无凭据）
#   home-cache-*.json    首页缓存。★ 用通配而不是写死文件名 ——
#                        文件名里带**用户配的源标识**，写死就等于把某个
#                        具体站名钉进仓库（仓库硬约束，见 CONTRIBUTING）
#   provider-order / disabled-providers / third-party-providers  源列表与顺序
#   ui-prefs.json        见白名单③ —— **按 key 过滤**，不整份拷
#
# ★★ 明确**不拷**（仓库安全规矩 docs/AGENTS.md §3 点名的那三样）：
#   sync-settings.json   含 WebDAV 地址 + 账号，且会自动往真实网盘推数据
#   remote-pref.json     含端口与 auto_start=true，会占 8642 端口
#   plugins/.data/ 整目录 插件私有存储，实测含真实凭据（token / 会话 cookie）
$seedFiles = @(
    'provider-order.json',
    'disabled-providers.json',
    'third-party-providers.json',
    'shelf-cache.json',
    'dsh-media.db',
    'dsh-media.db-wal',
    'dsh-media.db-shm'
)

# 通配（见上面 home-cache 那条的理由）
$seedFileGlob = @(
    'home-cache-*.json'
)

# ── 白名单②：插件源码（**只要 .js 本身，不要 plugins/.data/**）──
#
# 用户自己装的插件是开发时最需要的东西（Owner 报的「没有之前的 js 插件」）。
# 但 plugins/.data/ 是插件的私有存储，实测含真实凭据 ⇒ **一律不带**。
# 代价：插件起来后是「未配置」状态，要自己重新填。这个代价必须付 ——
# 凭据进临时目录就等于多了一份泄漏面，而临时目录是会被随手清空的。
$seedPluginGlob = @(
    'plugins/*.js',
    'plugins/.meta/*.json'   # 插件元信息（名称/来源），不含凭据
)

# ── 白名单③：ui-prefs.json 里**允许**搬过去的 key ──────────────────
#
# 为什么按 key 过滤而不是整份拷：实测真实文件 53 个 key，其中 28 个是
# `dsh.bili.*`（分P绑定 + 手动绑定 + 页码）。整份拷会把用户的观看痕迹
# 与登录绑定一起搬进临时目录。这里只搬「界面/外观/播放行为」那几类。
#
# ★ 键名是**照着真实文件核过的**，不是猜的前缀：
#   · 有的是**整键**（`dsh.theme` 没有结尾点，写成 `dsh.theme.` 会一个都匹配不到）
#   · 有的是**前缀**（`dsh.danmaku.` 底下 7 个）
#
# ★★ 刻意排除（都是「具体哪个源」的痕迹，不是界面偏好）：
#   dsh.bili.*        分P绑定 / 手动绑定 / 页码 —— 用户观看痕迹
#   dsh.speedtest.*   按源分组的测速历史
#   dsh.srcpref.*     源级偏好（键里带源标识）
#   dsh.homeSource    首页当前选中的源标识
$seedPrefExact = @(
    'dsh.theme',
    'dsh.themepack'
)
$seedPrefPrefixes = @(
    'dsh.danmaku.',
    'dsh.window.',
    'dsh.playprefs.',
    'appupdate.'
)

$script:copied = 0
$script:kept = 0
$script:warn = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $Source)) {
    Write-Host "[seed] 源目录不存在，跳过播种：$Source" -ForegroundColor DarkGray
    exit 0
}

# ── ★ 护栏：目标**绝不能**是源目录本身（或与它互相包含）──
#
# 没有这道闸时，一句 `-Target $env:APPDATA\app.sourin.player` 就会把真实目录
# 当成开发目录：下面「关掉云同步自动」那一步会**真的改写用户真实的
# sync-settings.json** —— 那是拿用户数据当试验场，与本脚本存在的理由
# （只读真实目录）直接冲突。宁可硬失败也不放行。
# ⚠️ 用 [char] 而不是字面量反斜杠：本文件是 PS 5.1 读的，字符串里的 `\` 极易被
#    上一层工具吃掉（实测过：写成 "\" 会变成 "\" 未闭合，脚本直接 ParserError）。
$sep = [IO.Path]::DirectorySeparatorChar
$srcFull = [IO.Path]::GetFullPath($Source).TrimEnd($sep)
$dstFull = [IO.Path]::GetFullPath($Target).TrimEnd($sep)
if ($dstFull -eq $srcFull) {
    Write-Host "[seed] ✗ 拒绝执行：目标目录就是源目录（$dstFull）" -ForegroundColor Red
    Write-Host "       本脚本只往开发目录写，绝不碰真实数据目录。" -ForegroundColor Red
    exit 2
}
if ($dstFull.StartsWith($srcFull + $sep) -or $srcFull.StartsWith($dstFull + $sep)) {
    Write-Host "[seed] ✗ 拒绝执行：源与目标互相包含" -ForegroundColor Red
    Write-Host "       源   = $srcFull" -ForegroundColor Red
    Write-Host "       目标 = $dstFull" -ForegroundColor Red
    exit 2
}

New-Item -ItemType Directory -Force -Path $Target | Out-Null

function Copy-One([string]$Rel) {
    $src = Join-Path $Source $Rel
    $dst = Join-Path $Target $Rel
    if (-not (Test-Path -LiteralPath $src)) { return }
    if ((Test-Path -LiteralPath $dst) -and (-not $Force)) { $script:kept++; return }
    $parent = Split-Path -Parent $dst
    if ($parent -and (-not (Test-Path -LiteralPath $parent))) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    try {
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $script:copied++
    } catch {
        $script:warn.Add("$Rel —— $($_.Exception.Message)")
    }
}

foreach ($rel in $seedFiles) { Copy-One $rel }

# ★ 从「绝对路径」求「相对 Source 的路径」——**不能**用 $f.FullName.Substring($Source.Length + 1)。
#
# # 为什么（2026-10-16 CI 实测踩到）
# ```text
# Get-ChildItem 回的是**长名**绝对路径，而 -Source 可能传进来的是**8.3 短名**
# （CI runner 的 TEMP 就是 `C:\Users\RUNNER~1\AppData\Local\Temp\...`）。
# 两者长度不同 ⇒ Substring 切出来的「相对路径」是错的 ⇒ 拷贝静默变成 0 个。
#
# 实测（本机复现）：Source=C:\...\T1015_~2、FullName=C:\...\t1015_shortname_probe\plugins\mine.js
#   ⇒ 切出来的相对路径指向不存在的文件 ⇒ 日志「新拷 0 个」，插件没带过去。
# ```
# ⇒ 用 Uri 规范化后取相对段：短名/长名、大小写、分隔符差异都被吃掉。
function Get-RelPath([string]$Full) {
    $base = [IO.Path]::GetFullPath($Source).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath($Full)
    $baseUri = [Uri]($base + [IO.Path]::DirectorySeparatorChar)
    $fullUri = [Uri]$full
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fullUri).ToString())
}

foreach ($pattern in $seedFileGlob) {
    foreach ($f in (Get-ChildItem -Path (Join-Path $Source $pattern) -File -Force -ErrorAction SilentlyContinue)) {
        Copy-One (Get-RelPath $f.FullName)
    }
}

foreach ($pattern in $seedPluginGlob) {
    foreach ($f in (Get-ChildItem -Path (Join-Path $Source $pattern) -File -Force -ErrorAction SilentlyContinue)) {
        Copy-One (Get-RelPath $f.FullName)
    }
}

# ── ui-prefs.json：按前缀过滤后**重建**（不整份拷，见上面白名单③）──
$srcPrefs = Join-Path $Source 'ui-prefs.json'
$dstPrefs = Join-Path $Target 'ui-prefs.json'
if ((Test-Path -LiteralPath $srcPrefs) -and ($Force -or (-not (Test-Path -LiteralPath $dstPrefs)))) {
    try {
        $p = Get-Content -LiteralPath $srcPrefs -Raw -Encoding UTF8 | ConvertFrom-Json
        $keep = @{}
        foreach ($prop in $p.PSObject.Properties) {
            # 整键优先（`dsh.theme` 这种没有结尾点的）
            if ($seedPrefExact -contains $prop.Name) { $keep[$prop.Name] = $prop.Value; continue }
            foreach ($pre in $seedPrefPrefixes) {
                if ($prop.Name.StartsWith($pre)) { $keep[$prop.Name] = $prop.Value; break }
            }
        }
        # ⚠️ 不带 BOM 写回（同 sync-settings 的理由：Dart 的 jsonDecode 见到 U+FEFF 直接抛）
        $json = $keep | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($dstPrefs, $json, (New-Object Text.UTF8Encoding($false)))
        $script:copied++
        Write-Host "  ★ ui-prefs.json 只搬了 $($keep.Count) 个界面/播放偏好（凭据与登录绑定一律不带）" -ForegroundColor DarkGray
    } catch {
        $script:warn.Add("ui-prefs.json 过滤失败 —— $($_.Exception.Message)")
    }
}


foreach ($w in $script:warn) { Write-Host "  [!] $w" -ForegroundColor Red }

if ($script:copied -eq 0 -and $script:kept -gt 0) {
    Write-Host "[seed] 开发目录里已有 $($script:kept) 个文件，一个都没动（要覆盖加 -Force）" -ForegroundColor DarkGray
} else {
    Write-Host "[seed] 播种完成：新拷 $($script:copied) 个，保留已有 $($script:kept) 个" -ForegroundColor Green
}

exit 0
