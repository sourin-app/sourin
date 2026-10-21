# Agent Note: 只在 Windows 成立的判据，必须在别的平台上显式跳过；判据依赖的解释器要钉版本

Status: implemented

> 同域：[2026-10-21-skipped-test-hides-constant-red.md](../testing/2026-10-21-skipped-test-hides-constant-red.md)
> （那篇管「skip 吞掉了失败信号，恒红可以躺很久」；本篇管的是**反过来**——
> 该 skip 的没 skip，于是判据在别的平台上恒红，把 CI 拖成一个没人看的红灯）。
> Independent: 失效方向相反，结论也相反（一篇要求"别乱 skip"，一篇要求"该 skip 就 skip"）。

## Problem

CI run `39526450290` 的 macOS job：`4731 tests passed, 6 failed, 170 skipped`。
6 条失败**全部落在第 66 轮新增的 4 个测试文件里**，且**没有一条是产品缺陷**。

### 真原因（四类，前两类的机理是同一个）

**① 判据依赖的 PowerShell 版本变了 —— `pwsh` 是 7，不是 5.1**

`test/zz_t66_ps1_bom_gate_test.dart` 守的是「**PS 5.1 + 系统码页 936** 下，
无 BOM 的中文 `.ps1` 会解析崩」，所以判据③要**注入故障**：造一份无 BOM 副本，
断言它必须解析失败。原解析器是「PATH 上 `pwsh` 优先」：

```text
pwsh        = PowerShell 7，默认按 UTF-8 解码源文件
powershell  = Windows PowerShell 5.1，按系统 ANSI 码页（936）解码
```

⇒ 在 PS7 下切掉 BOM **不产生任何错误** ⇒ `expect(count, greaterThan(0))` 拿到
`Actual: 0` ⇒ 红。测试自己的报错文案已经猜到了半个原因：
「要么本机码页不是 936」——它猜的是码页，真因是**解释器版本**。

实测读数（macOS job）：

```text
Expected: a value greater than <0>
  Actual: <0>
  tools/e2e_checklist.ps1  →  切 BOM 后仍 0 错误
  tools/e2e_shots.ps1      →  切 BOM 后仍 0 错误
```

**② 顺带发现的 Windows 潜在红灯（这条才是重点）**

`windows-latest` **同样预装 PowerShell 7 且在 PATH 上**。所以这同一条判据在
Windows CI 上也会红 —— 只是上一轮 Windows job 卡在更早的「发布说明守卫」
（`python3` 不存在）**根本没跑到测试**，这个红一直没暴露。
本机没装 PS7 ⇒ 解析到 `powershell`(5.1) ⇒ **一直是"因为对了才绿"**。

⇒ 这次要是只修 macOS，下一轮 CI 会把红从 macOS 挪到 Windows。

**③ 真进程 + `taskkill` 是 Windows 专属**

`test/zz_t66_e2e_shots_survivor_test.dart` 的组③要起一个真进程
（`pwsh -Command Start-Sleep`）再用 `taskkill` 收尾。`_psExe()` 在非 Windows 上
回落到字面量 `'powershell.exe'` ⇒ `ProcessException: No such file or directory`。

**④ 三处站点全依赖 Windows 环境**

`test/zz_t66_danmaku_send_safety_gate_test.dart` 的组①要求「**至少查到一处**」
`danmakuSend` 声明，而三处站点是：私库源码、私库产物、`APPDATA` 下的用户数据目录。
前两处需要未公开的私库目录，第三处的 `APPDATA` **是 Windows 专有环境变量**
⇒ 三处全空 ⇒ `Expected: non-empty / Actual: []`。

**⑤ 证据图的失败已自行消失**

`test/zz_t66_cs1_evidence_manifest_test.dart` 的②③报 sha256 / 尺寸不符。
查证：CI 跑的 `fc666cdb` 上 `docs/notes/evidence/round-66-cs1/` **只有 README.md**，
PNG 与 manifest 是之后的 `e48d923`、`3bfbfde` 才入库的。
HEAD 上三者一致（`git blob` 的 sha256 == manifest == 工作区）⇒ **不需要改代码**。

## Decision

### ① 解释器钉版本：只接受 `Major == 5`

```dart
for (final exe in <String>['powershell', 'pwsh']) {
  final r = Process.runSync(exe, [...'$PSVersionTable.PSVersion.Major']);
  if (r.exitCode != 0) continue;
  if ('${r.stdout}'.trim() == '5') return exe;   // ← 版本号说了算，名字不算
}
...
return null;   // 找不到 ⇒ 调用方 markTestSkipped（**不**降低断言）
```

原有的两处 `if (psExe == null) { markTestSkipped(...); return; }` **一字未改** ——
它们本来就是对的，只是从来没被触发过（因为 `pwsh` 总能被解析到）。

### ② 按平台显式跳过，且**只跳 Windows 专属的那几组**

```text
survivor  组③   skip: Platform.isWindows ? false : '本组要起真进程 + taskkill（Windows 专属）…'
danmaku   组①   skip: Platform.isWindows ? false : '本组站点依赖 APPDATA / 私库目录（Windows 专属）…'
```

**不跳**的部分（macOS 上照跑，覆盖率不损失）：

```text
ps1_bom_gate  判据①      纯字节读 tools/*.ps1 的 BOM          ← 平台无关
danmaku       组②③      扫仓内 lib/ui、扫仓内能力位与闸门证据  ← 平台无关
survivor      组①②      纯静态读 tools/e2e_shots.ps1 原文      ← 平台无关
cs1_evidence_manifest   全文件                                ← 平台无关
```

### ③ 跳过要带**具体理由**，不许写 `skip: true`

理由字符串会原样出现在 `flutter test` 输出里，且会被 `~N` 计数器记到。
这是「跳过」与「假装通过」的唯一可见差别。

## Alternatives considered

### ① 去掉 danmaku 组① 的「至少一处」断言

**最强论据**：这样它就能在所有平台跑 —— 只要有站点就比，没站点就跳过比较，
覆盖面看起来最大。

**为什么否决**：那条断言**就是本门禁的防空转判据**，它的 `reason` 原文写着
「一处都没查到 ⇒ 扫描器失效（不能把"没查"当成"没问题"）」。
去掉它，门禁在任何平台上都恒绿 —— 一个只要不工作就一定通过的判据，
不是判据。★ 而且这正是 `禁止假绿门禁` 明令要修的那一类。

### ② 把 macOS job 摘掉 / 设 `continue-on-error`

**最强论据**：立刻解除发版阻塞，且 macOS 不是产品目标平台（产品只出 Windows 包，
`ffi.dart:316` 写明 macOS 没有 `libsourin_core.dylib`）。

**为什么否决**：Owner 已明确否决「先摘掉 macOS job 发版」。
且从本次证据看，摘掉会**直接掩埋第②条那个 Windows 潜在红灯**——
它是被"Windows job 卡在更早门禁"挡住的，不是不存在。
★ 判据：**一个 job 红了，先问"它红得对不对"，再问"要不要摘"。**

### ③ 保留 `pwsh` 优先，改成「0 错误也算过」

**最强论据**：改动最小，一行断言的事，两个平台都能绿。

**为什么否决**：判据③的存在意义就是**证明判据①承重**（元判据）。
放宽成"0 错误也算过"⇒ ① 失去保护 ⇒ 下次谁把 BOM 弄丢都不会有人知道。
★ 宁可让它在 PS7 上**跳过**，也不要让它**恒真**。

### ④ 用 `@Tags(['windows-only'])` + CI 传 `--exclude-tags` 代替 `skip:`

**最强论据**：语义更准 —— 这正是"只在某个平台有意义"的既有表达方式，
本仓已有 `native-media` 标签的先例，且标签能在 CI 里集中管理。

**为什么否决**：标签与 `build.yml` 的 `--exclude-tags` 是**两处**要同步的事实，
任一处漏改就是静默失效；`skip:` 写在文件里，**没法与判据脱节**。
★ 承认这是**可辩护的替代方案**：若将来平台专属判据多到十几个，
集中管理的收益会超过脱节风险，那时应该翻案。

## Consequences

### 收益

```text
· macOS job 的 6 条红里，5 条有明确处置（3 组按平台跳过、1 处解释器钉版本、
  1 组纯数据问题已在 HEAD 自愈）
· 第②条那个 Windows 潜在红灯在它咬人之前就被修掉
· 判据③在 PS 5.1 上**仍然真的注入故障**（本机 +3 全绿，说明它没变成恒真）
· 每处跳过都带原因字符串，`~N` 里能看见，不会被读成"通过"
```

### 读数

```text
修前（macOS，CI）：4731 passed / 6 failed
修前（本机 Windows）：4 个文件 +3 / +6 / +6 / +8 全绿
                      ——但本机没装 PS7，这个"绿"证明不了 CI 能绿

故障注入 A（把 _resolvePowerShell 的 '5' 改成 '7'，即只认 PS7）：
  本机 PS5.1 被拒 ⇒ +1 ~2
  ②③ 跳过并打印「本机没有 PowerShell ⇒ 无法注入故障」
  ⇒ 证明版本过滤是**承重的**，不是只看 exitCode==0

故障注入 B（danmaku 组① 强制 skip）：
  +4 ~2  ⇒ 只有组①的两条被跳，②③ 照跑

故障注入 C（survivor 组③ 强制 skip）：
  +4 ~2  ⇒ 跳过理由原样打印

还原后：+3 / +6 / +6 全绿，git status 干净，`false && Platform` 计数 = 0
```

### 代价

```text
· macOS 上这 3 组从「跑但红」变成「不跑」——覆盖率归零，只剩 Windows job 兜。
  若 Windows job 哪天也挂了，这 3 组就完全没人守。
· 真进程巡检（survivor 组③）在读"全量测试"的人眼里从此是 `~2`，
  容易被当成"本来就不跑"。缓解：只有带 `skip:` 理由的那 2 条会这样。
· `dart format` 会把这个仓手写的长注释块整片重排（实测 3 个文件多出 350 行无关改动）
  ⇒ 本次**没有**跑 `dart format`，改动手写保持原格式（CI 不查格式）。
```

### 何时该翻案

```text
① 若 GitHub runner 不再预装 PowerShell 7（或把 `pwsh` 从 PATH 摘掉）⇒
   版本钉死就不再是必须的，但留着也无害
② 若平台专属判据多到十几个 ⇒ 改用 tag + `--exclude-tags` 集中管理（见替代方案④）
③ 若哪天有了 macOS/Linux 测试机跑产品本体 ⇒ 这些组应该改造成**真的双平台断言**
   （比如给 `.ps1` 判据配一份等价的 sh 判据），而不是继续 skip
```

## 给下一个人的提醒

```text
★ 本次最值得记的不是"加了 3 个 skip"，而是这个形态：

  **同一条判据可以在两个平台上因为同一个原因红，但只有一个平台看得见。**

  机理：CI 的 job 之间是**独立失败**的。Windows job 卡在更早的门禁（第 9 步），
  它根本没机会跑到测试 ⇒ 「Windows 上是绿的」这个印象是错误的，
  只是**没测**。真正暴露问题的是那个"一直在红、已经没人看"的 macOS job。

  ⇒ 判据：看到某 job 从绿变红，先 bisect 区间（对），
    但**同时要查"判据依赖的外部物在区间里有没有换版本"**——
    本次换的不是仓里的代码，是 runner 上的 PowerShell 版本。
    只 bisect 仓内提交会一无所获。
```
