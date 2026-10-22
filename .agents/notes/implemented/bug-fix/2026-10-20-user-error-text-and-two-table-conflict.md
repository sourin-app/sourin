# Agent Note: 异常原文不许进用户可见字段 —— 收口入口 + 债务预算

Status: implemented

> 同域：[../architecture/2026-10-18-cross-language-shape-must-run-against-real-parser.md](../architecture/2026-10-18-cross-language-shape-must-run-against-real-parser.md)
> （跨语言边界要读对方的真实定义）；本篇管的是**跨到用户眼前的最后一步**。
> 判据设计参考：[../testing/2026-10-12-gates-must-be-able-to-fail.md](../testing/2026-10-12-gates-must-be-able-to-fail.md)

## Problem

界面里到处是 `_err = '$e'` / `_toast('保存失败：$e')`。用户看到的是一串
**他自己看不懂、而排障需要的信息**：

```text
SourinCoreException(other): 口令不正确（或这个备份包已被改动），登录态没有导入
└──────────┬──────────────┘
      ①宿主类名（用户不知道这是什么）
```

`SourinCoreException.displayMessage` 早就剥掉了 ①，但**全仓零调用** ——
「accessor 写对了」不等于「界面用上了」。这是本仓记过的第 ① 条硬规矩
（写了 ≠ 接线了）的又一实例。

## Decision

### ① 唯一入口 `userErrorText()`（`lib/core/ffi.dart`）

```dart
String userErrorText(Object error, {String fallback = '操作没有完成，请稍后重试'})
```

契约：

```text
· SourinCoreException ⇒ displayMessage（只剩插件原文，用户能读懂）
· 其它异常（文件系统 / 解析 / 平台通道）⇒ 原始串**只进日志**，界面拿到 fallback
  用户看不懂 FileSystemException(..., errno = 2)，而排障需要它留在日志里
· fallback 按场景定制，不是一句话复用
  例：'读取备份信息失败，请稍后重试' / '导出失败，请稍后重试' / '预览无法启动'
```

### ② 收口范围：6 个文件，逐处替换 `$e`

```text
lib/ui/widgets/backup_panel.dart           4 处
lib/ui/widgets/provider_login_panel.dart   3 处
lib/ui/widgets/proxy_panel.dart            5 处
lib/ui/widgets/skip_marker_dialog.dart     6 处
lib/ui/player/player_bottom_bar.dart       1 处
lib/ui/player_page.dart                    1 处（:6214）
```

★ **前缀文案一律保留**（「发送失败：」这类），只替换 `$e` 那一段。
改前缀会改变用户看到的话，那不是本次任务。

### ③ 存量 82 处 / 18 个文件：记成**预算**，不硬清

```text
_debt = { 'lib/ui/settings_page.dart': 26, 'lib/ui/player_page.dart': 14, ... }
合计 82 处。判据是「不再变多」+「也不许悄悄变少」（降了就得把预算改小）。
```

理由：这些文件在别的写入边界内，本轮不碰；而「预算」比「全部清零」更诚实 ——
它明说「还没干净」，而不是把未完成伪装成已完成。

### ④ 门禁 `test/zz_t66_user_error_text_gate_test.dart`

```text
扫描器  区分「用户可见桶」与「仅日志桶」（debugPrint / AppLog.write 算日志）
断言①  收口文件：插值必须 0（**有 _debt 预算的除外**，见下）
断言②  收口文件：userErrorText 调用次数 == 期望值（少一次 = 退回去了）
断言③  预算文件：插值条数 == 预算（精确相等，涨了红了、降了也红）
断言④  两张表之外的文件一处都不许有
断言⑤  总数 == _debt 之和
自检    合成样本必须 2 红 / 1 日志 / 2 绿（防扫描器永远返回空）
```

## 本轮修掉的门禁自身缺陷

### 缺陷 1：两张表对同一维度提互斥要求（数学上不可能满足）

```text
_expectedCalls['lib/ui/player_page.dart'] = 1   ⇒ 断言① 要求 perFile == 0
_debt['lib/ui/player_page.dart']          = 14  ⇒ 断言③ 要求 perFile == 14
⇒ 0 == 14，**必然红**

★ 更狠：断言⑤「总数 == _debt 之和」把 14 计入总数
⇒ 真把那 14 处改掉，断言⑤ 又红 ⇒ **改不改代码都不可能绿**
```

修法：断言① 加 `if (_debt.containsKey(f)) continue;` —— 管辖转移。
并在两张表的**定义处**写死管辖规则（不只是改控制流）：

```text
· 在 _debt 里   ⇒ 插值条数由 ③ 判（== 预算）
· 不在 _debt 里 ⇒ 插值条数由 ① 判（== 0）
· 两张表都适用  ⇒ userErrorText 调用数始终由 ② 判
```

★ 精确表述：**一个文件可以被两张表登记，但每张表必须只对「自己管辖的那个维度」
提要求；同一维度只能有一张表说了算。**

### 缺陷 2：收口范围与预算表的口径原本靠人记，没写成数据

原先「谁管辖插值条数」藏在 `for` 循环的 `continue` 里。改后写进表定义注释，
并要求后续把管辖规则提升为 `const _debtWins = {...}` 这样的**数据**
（`r1r8-ui` 正在做，见「还没覆盖的」）。

## 另一条线：`tools/run_t107.ps1`（CS-1 真机驱动）的两个真实缺陷

### 缺陷 3：BOM 丢失 ⇒ PS 5.1 下整个脚本语法错误

```text
某次改动（把 mtime 判据改成 sha256）弄掉了 UTF-8 BOM，而脚本里有中文。
PS 5.1 无 BOM 时按 ANSI(936/GBK) 读 ⇒ 中文字节被误读 ⇒ 字符串引号错配：

  At nobom.ps1:1 char:12 + Write-Host "涓枃娴嬭瘯锛氭暟鎹洰褰曞繀椤婚殧绂?
  ⇒ 整个脚本**根本跑不起来**（不是"中文变问号"那么轻）
```

★ 与已知的「`???` 现象」是**两个不同的坑**：`???` 是输出被 ASCII 化（脚本能跑），
丢 BOM 是**解析失败**（压根不能跑）。

★ 更隐蔽：这个坑在用 `pwsh` 7 复核时**看不出来**（pwsh 7 默认按 UTF-8 读）。
本机只有 PS 5.1，反而暴露了它。

### 缺陷 4（存量，HEAD 里就有）：安全闸判的是**未解析的字符串**

```powershell
if ($dataDir -notmatch 'round66_cs1') { Die }   # 改前
```

而 `$dataDir = Join-Path $probeRoot $Run`，`probeRoot` 里**本身就含** `round66_cs1`
⇒ 拼出来的串**必然**匹配 ⇒ **闸永远放行**。

实测：`-Run '..\..\..\evil-dir'` ⇒ `dataDir = ...\.probe\round66_cs1\..\..\..\evil-dir`
⇒ 含关键词 ⇒ 放行。穿越到真实数据目录时只被**另一条**关键词挡住。

修法：解析后判 + 边界判：

```powershell
$dataDir      = [System.IO.Path]::GetFullPath($dataDirRaw)
$probeRootAbs = [System.IO.Path]::GetFullPath($probeRoot)
if (-not $dataDir.StartsWith($probeRootAbs + [IO.Path]::DirectorySeparatorChar,
                             [StringComparison]::OrdinalIgnoreCase)) { Die }
```

★ 判据：**判「路径是否在某目录之下」，必须先 `realpath`/`GetFullPath` 解析成绝对路径，
再按分隔符边界比较** —— 不是 `contains`、不是前缀字符串匹配。

### 缺陷 5：`-NoBuild` 的「产物新鲜」判据从 mtime 改成 sha256

```text
为什么不用 mtime：
· runner .exe 只在 C++ 侧变化时重链，mtime 长期停在旧日期 ⇒ 假红
· data\app.so 走内容寻址增量编译，改注释后真编一次也是字节不变、mtime 不动
真事故（2026-10-20）：build\ 里躺着两天前的 exe，跑起来"正常"，出的却是两天前的像素
⇒ 由 sha 比对挡住：别的入口编过同一个 bundle 后 payload sha 会变，
   -NoBuild 直接拒绝跑，不拿别人的二进制冒充 CS-1 证据
```

## Alternatives considered

### ① 「一次性把 82 处存量全清掉，不留预算表」

**最强论据**：预算表是个「合法的欠债清单」，它会让人习惯于「反正有预算」；
一次清干净才是彻底解法，也不必维护两张表。

**为什么否决**：**这 82 处分散在 18 个文件，多数在别人的写入边界内。**

```text
· 本轮若全清，要动 settings_page（26 处）/ sync_panel（10 处）/
  playback_page（9 处）等 —— 这些文件同一时刻有别人在改
⇒ 撞车风险 + 无法逐项验证（每处都要判断"这真的是用户可见字段吗"）
★ 预算表的价值恰恰在于它**诚实**：明说"还没干净"，并给出准确数字（82）。
  没有预算表的话，门禁只能二选一：要么全绿（假装干净），要么全红（噪声到没人看）。
```

### ② 「收口文件也允许存量，只要不涨」—— 即取消断言①

**最强论据**：既然预算表能表达「还没干净」，为什么还要区分「收口文件必须 0」？
统一用预算表，判据更简单，也不会出现两张表打架。

**为什么否决**：**「本轮改过的文件」和「本轮没碰的文件」必须区别对待。**

```text
· 我改过的文件，我有能力也有责任把它改干净
· 我没碰的文件，我只能保证"别因为我变多"
⇒ 若统一用预算，收口文件就退化成"只要不涨就行"，
  而它本来是可以做到 0 的 —— 那是自我降级。
★ 判据：**预算的适用范围是"我改不动的地方"，不是"我不想改的地方"。**
```

### ③ 「门禁扫全仓，一处都不许有」—— 不留任何白名单

**最强论据**：白名单/预算表是假绿的温床；彻底的做法是「零容忍」，逼所有人一次改完。

**为什么否决**：**实测过它的后果 —— 噪声门禁会被绕过。**

```text
本仓已有先例（notes-coverage 的注释原文）：
「明确不要求，否则门禁会被噪音淹没，最后被 --no-verify 绕过」
⇒ 82 处、18 个文件同时红，人不会去逐个判断，而是直接绕过门禁
★ 判据：**一道会被绕过的门禁等于没有门禁。**
```

### ④ 「`userErrorText` 里对非 SourinCoreException 也返回原文」

**最强论据**：用户报障时能直接说出错误原文，比「请稍后重试」更有用；
而且省掉一个 `fallback` 参数。

**为什么否决**：**用户看不懂 `FileSystemException(..., errno = 2)`，而它留在日志里更有用。**

```text
· 界面职责：告诉用户「下一步该做什么」（重试 / 换个文件 / 去设置口令）
· 日志职责：保留类名、参数、errno，供排障
⇒ 两边各取所需。若界面也吐原文，用户得到一串看不懂的英文，
  真原因被挤到后面 —— 这正是改前的病。
★ 代价（诚实记账）：`fallback` 是按场景手写的，21 处就是 21 句文案。
  好处是每句都能指向具体行动；坏处是新增错误位时要记得写它
  （断言② 的「调用次数 == 期望值」正是为了逼人同批更新）。
```

## Consequences

### 收益

```text
· 用户不再看到宿主类名；21 处用户可见错误位改走唯一入口
· 存量 82 处 / 18 文件有了**准确预算**（实测值，非估值），涨了降了都红
· 门禁自身两处缺陷修好：① 两张表互斥要求（0 == 14 不可能满足）
  ② 收口文件与预算文件的口径打架
· run_t107.ps1：BOM 恢复（PS 5.1 可跑）、路径穿越闸修好（存量安全缺陷）
· 探针夹具对齐产品契约（补 .zip）⇒ CS-1 五步真跑从 OK=20 BAD=3 → **OK=45 BAD=0**
```

### 读数

```text
门禁（三条一起跑）：
  zz_t66_user_error_text_gate_test.dart    +8  All tests passed
    USERERROR|scope=lib/ui/**|userVisible=82|logOnly=133|files=97|filesWithDebt=18
  zz_t66_convergent_tile_gate_test.dart    +5  All tests passed
  zz_t66_r4_dialog_consistency_test.dart   +14 All tests passed
  合计 +27 All tests passed

dart analyze lib ⇒ 0 error

CS-1 五步真跑（改 .zip 前 / 后）：
  OK=20 BAD=3  →  OK=45 BAD=0
  机器可读行五步全 verdict=OK，bytes=3950 sha256=d462185cf0a01268（五步同一份产物）

run_t107.ps1 四条故障注入（全部 exit=2）：
  A 数据目录穿越   ERROR: 数据目录不在 .probe\round66_cs1 下：D:\...\evil-dir
  B 篡改 payload   ERROR: build\ 里的 payload 不是 CS-1 入口编的（内容已变）
  C 缺 app.so      ERROR: 找不到 payload：...（bundle 不完整）
  D 无 stamp       ERROR: -NoBuild 需要先有一次带构建的运行

编码：BOM=1 个（非双 BOM）/ ??? 计数=0 / bytes=15506 / CRLF 285 / PS 5.1 PARSE OK
```

### 代价

```text
· 21 处 fallback 文案是手写的，新增错误位必须记得写（断言② 逼着更新）
· 预算表需要人维护：真的清掉一处就必须改预算（断言③ 会红提示）
· `lib/t107_cs1_flow_probe.dart` 是**未提交资产**，改它不进仓库
  ⇒ 下游 clone 后没有这个探针，CS-1 五步真跑无法复现
```

### 还没覆盖的

```text
· `_debtWins` 那种「管辖规则写成数据」的自检还没落地（`r1r8-ui` 在做）
· 探针报告 `credentialsNote` 里出现 Markdown 星号「**」，界面会原样显示
  —— 真缺陷，但要动 Rust 构造方或 UI 渲染层，不在本轮边界
· 本机 `Start-Process` 因 NO_PROXY/no_proxy 大小写冲突不可用
  ⇒ 已记入脚本注释，不改（换机器不会有；改 cmd /c 会失去 PID 管理能力）
```

### 何时该翻案

```text
① 若 _debt 长期不降（预算变成"永久欠债"）
   ⇒ 排一个专项把 settings_page(26) / sync_panel(10) 清掉，并逐步删表
② 若新增错误位频繁忘记写 fallback（断言② 经常红）
   ⇒ 考虑让 userErrorText 的 fallback 变成必填参数（现在有默认值）
③ 若探针需要进仓库（下游要复现 CS-1 五步）
   ⇒ 把它从「未提交资产」转正，并加隐私检查（它读写隔离目录，不碰真实数据）
```
