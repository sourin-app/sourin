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

# ★ 输出统一 UTF-8。
#
# 为什么（2026-10-16 CI 实测）：`Write-Host` 默认按**控制台代码页**编码输出。
# 中文 Windows（本机）是 936，读回来对得上；英文 runner 是 437/1252，
# 中文直接变成 `?` ⇒ 测试里「失败要给出人话」那条断言在 CI 上必红，
# 而本机永远绿。两边都显式钉成 UTF-8 才跨机器一致。
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

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
if ($dstFull.StartsWith($srcFull + $sep, [StringComparison]::OrdinalIgnoreCase) -or $srcFull.StartsWith($dstFull + $sep, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "[seed] ✗ 拒绝执行：源与目标互相包含" -ForegroundColor Red
    Write-Host "       源   = $srcFull" -ForegroundColor Red
    Write-Host "       目标 = $dstFull" -ForegroundColor Red
    exit 2
}

# ── ★★ 护栏二：按**真实指向**拒绝源目录别名（junction / 符号链接）──
#
# 上面只比了字符串。但 `-Target` 可以是源目录的一个 **junction**：
# 字符串看起来毫无关系，实际写进去的还是真实目录。
# ⇒ 比对「解析后的真实路径」（.NET 6+ 的 ResolveLinkTarget；PS 5.1 没有时退回字符串比较）。
# 另外**目标里已存在的 ui-prefs.json 也可能是源文件的硬/软链**，所以文件级也要查。
function Resolve-RealPath([string]$p) {
    try {
        $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if ($item.PSObject.Methods.Name -contains "ResolveLinkTarget") {
            $t = $item.ResolveLinkTarget($true)
            if ($t) { return [IO.Path]::GetFullPath($t.FullName) }
        }
    } catch { }
    return [IO.Path]::GetFullPath($p)
}
$srcReal = Resolve-RealPath $srcFull
$dstReal = Resolve-RealPath $dstFull
if ($dstReal -eq $srcReal -or
    $dstReal.StartsWith($srcReal + $sep, [StringComparison]::OrdinalIgnoreCase) -or
    $srcReal.StartsWith($dstReal + $sep, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "[seed] ✗ 拒绝执行：目标**实际指向**源目录（junction / 符号链接）" -ForegroundColor Red
    Write-Host "       源   字符串 = $srcFull" -ForegroundColor Red
    Write-Host "       源   真实   = $srcReal" -ForegroundColor Red
    Write-Host "       目标 字符串 = $dstFull" -ForegroundColor Red
    Write-Host "       目标 真实   = $dstReal" -ForegroundColor Red
    exit 2
}

# ── ★★ 护栏三：目标里**已存在**的 ui-prefs.json 若是指向源文件的链接 ⇒ 拒绝 ──
#
# 目标目录本身安全也不够：`-Force` 下会 WriteAllText 覆盖它，
# 而它可能是源文件的链接 ⇒ 等于改写用户真实偏好。
$dstPrefsLink = Join-Path $Target "ui-prefs.json"
if (Test-Path -LiteralPath $dstPrefsLink) {
    $prefsReal = Resolve-RealPath $dstPrefsLink
    if ($prefsReal.StartsWith($srcReal + $sep, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "[seed] ✗ 拒绝执行：目标里的 ui-prefs.json 指向源目录（$prefsReal）" -ForegroundColor Red
        exit 2
    }
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
# ⇒ 两边都先 [IO.Path]::GetFullPath 规范化，再按长度切。
#
# ⚠️ 别用 [Uri]::MakeRelativeUri：它在 **macOS 上对无 scheme 的路径直接抛**
#    "This operation is not supported"（2026-10-16 CI 的 macOS 7 条全红就是
#    这么来的）。教训：「Windows 上能跑」不等于「跨平台能跑」。
function Get-RelPath([string]$Full) {
    $base = [IO.Path]::GetFullPath($Source).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath($Full)
    # 规范化后 $full 必在 $base 这棵树里 ⇒ 前缀比对后再切
    $prefix = $base + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($prefix.Length)
    }
    # 兜底：万一规范化后仍对不上（短名 / 符号链接），退回文件名 —— 至少不静默丢件
    return [IO.Path]::GetFileName($full)
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

# ── ★★ 已有开发偏好里若残留 dsh.download.dir ⇒ 必须**删掉**（安全，不是整洁）──
#
# # 为什么（CR #29 指出，属实）
# ```text
# 上面那条只在「目标还没有 ui-prefs.json」时才重建（或 -Force 时）。
# 但开发目录**用过一次**之后就已经有了 —— 之后不带 -Force 就直接跳过。
# 而 dsh.download.dir 决定「从哪读下载路径」，它**不校验**那个路径是否真实：
# 若它指向用户的真实视频目录，开发实例的下载/缓存就写进真实目录。
# 这违反 docs/AGENTS.md §3「绝不在 <用户目录>\Videos\源影 里建/改/删」。
# ```
# ⇒ 每次播种都扫一遍已有文件，把这个键摘掉；**摘不掉就非零退出**，
#   由 run_client.ps1 挡住启动（宁可起不来，也不能拿用户真实目录当下载目标）。
elseif (Test-Path -LiteralPath $dstPrefs) {
    try {
        $existing = Get-Content -LiteralPath $dstPrefs -Raw -Encoding UTF8 | ConvertFrom-Json
        $hasDir = $null -ne $existing.PSObject.Properties["dsh.download.dir"]
        if ($hasDir) {
            $existing.PSObject.Properties.Remove("dsh.download.dir")
            $json2 = $existing | ConvertTo-Json -Depth 8
            [IO.File]::WriteAllText($dstPrefs, $json2, (New-Object Text.UTF8Encoding($false)))
            Write-Host "  ★ 已从开发偏好里摘掉 dsh.download.dir（不校验真实路径，会写进真实目录）" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "[seed] ✗ 清理 dsh.download.dir 失败：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "       不清掉它就可能把下载写进真实目录 ⇒ 拒绝继续。" -ForegroundColor Red
        exit 3
    }
}

# ── ★★ 已有开发偏好里若残留 dsh.download.dir ⇒ 必须**删掉**（安全，不是整洁）──
#
# # 为什么（CR #29 指出，属实）
# ```text
# 上面那条只在「目标还没有 ui-prefs.json」时才重建（或 -Force 时）。
# 但开发目录**用过一次**之后就已经有了 —— 之后不带 -Force 就直接跳过。
# 而 dsh.download.dir 决定「从哪读下载路径」，它**不校验**那个路径是否真实：
# 若它指向用户的真实视频目录，开发实例的下载/缓存就写进真实目录。
# 这违反 docs/AGENTS.md §3「绝不在 <用户目录>\Videos\源影 里建/改/删」。
# ```
# ⇒ 每次播种都扫一遍已有文件，把这个键摘掉；**摘不掉就非零退出**，
#   由 run_client.ps1 挡住启动（宁可起不来，也不能拿用户真实目录当下载目标）。




# ── ★★ 播完的库要能过 PRAGMA integrity_check（CR #29）──
#
# # 为什么（属实）
# ```text
# 本脚本允许真实 App 在跑时播种，而 dsh-media.db / -wal / -shm 是**逐个文件**拷的。
# 若源库在拷贝期间写入或 checkpoint，三个文件可能来自**不同状态** ——
# SQLite 官方明确说这样拷运行中的库可能得到损坏的副本。
# 损坏的副本不会报错，只会让开发环境出现「收藏/进度莫名消失」这类假象。
# ```
#
# ⚠️ 这里**不**改用 VACUUM INTO / 在线备份 API：那需要 SQLite 客户端，
#   而本脚本是开发者本机的一次性播种，不该为此引入新依赖。
#   改为**拷完就验**：能验就验（python 在就用它的 sqlite3），
#   验不过就硬失败（宁可重播一次，也不要一个悄悄坏掉的库）；
#   验不了就**明说验不了**，不许假装通过。
$dstDb = Join-Path $Target 'dsh-media.db'
if (Test-Path -LiteralPath $dstDb) {
    # 先看魔数：不是 SQLite 文件就没什么可校验的（测试夹具会写随机字节）。
    # 真用户的 dsh-media.db 一定有这个魔数；有魔数才谈得上「拷坏了」。
    # 用 FileStream 读前 16 字节 —— PS7 没有 -Encoding Byte，别用 Get-Content。
    $head = ''
    try {
        $fs = [IO.File]::OpenRead($dstDb)
        try {
            $buf = New-Object byte[] 16
            [void]$fs.Read($buf, 0, 16)
            $head = [Text.Encoding]::ASCII.GetString($buf)
        } finally { $fs.Dispose() }
    } catch { $head = '' }
    if (-not $head.StartsWith('SQLite format 3', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host '  [!] 目标 dsh-media.db 不是 SQLite 文件 => 跳过完整性校验（未验证，不是通过）' -ForegroundColor Yellow
    } else {
        $pyExe = $null
        foreach ($cand in @('python', 'python3', 'py')) {
            $cmd = Get-Command $cand -ErrorAction SilentlyContinue
            if ($cmd) { $pyExe = $cmd.Source; break }
        }
        if (-not $pyExe) {
            Write-Host '[seed] [!] 本机没有 python => 跳过完整性校验（未验证，不是通过）' -ForegroundColor Yellow
        } else {
            $check = 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); r=c.execute("PRAGMA integrity_check").fetchone()[0]; print(r); sys.exit(0 if r=="ok" else 1)'
            $out = & $pyExe '-c' $check $dstDb 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[seed] X 播种后的 dsh-media.db 没通过 integrity_check：$out" -ForegroundColor Red
                Write-Host '       多半是拷贝期间源库被写入/checkpoint => 关掉 App 重播一次。' -ForegroundColor Red
                exit 4
            }
            Write-Host '  * dsh-media.db 通过 PRAGMA integrity_check' -ForegroundColor DarkGray
        }
    }
}

foreach ($w in $script:warn) { Write-Host "  [!] $w" -ForegroundColor Red }

if ($script:copied -eq 0 -and $script:kept -gt 0) {
    Write-Host "[seed] 开发目录里已有 $($script:kept) 个文件，一个都没动（要覆盖加 -Force）" -ForegroundColor DarkGray
} else {
    Write-Host "[seed] 播种完成：新拷 $($script:copied) 个，保留已有 $($script:kept) 个" -ForegroundColor Green
}

exit 0
