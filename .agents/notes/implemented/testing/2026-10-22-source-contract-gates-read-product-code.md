# Agent Note: 「读产品源码」的契约门禁，写坏了比没有更糟

Status: implemented

> 同域：[2026-10-21-skipped-test-hides-constant-red.md](2026-10-21-skipped-test-hides-constant-red.md)
> （判据失效后没人看得见）；本篇管的是**判据自己能不能编译、能不能红**。

## Problem

PR #32 复核线程 1/9 与 8/9 补了两条「不模拟、直接读产品源码」的契约门禁：

```text
test/zz_t66_danmaku_startup_gate_test.dart  ② 启动期不许 await dan-api
test/zz_t66_scroll_behavior_gate_test.dart  ② ScrollConfiguration 挂载点
```

补得对，但没真跑。事实上：

```text
$ dart analyze test/zz_t66_danmaku_startup_gate_test.dart
41 issues found.   ← 全是 error，文件根本编译不了
$ flutter test test/zz_t66_scroll_behavior_gate_test.dart
+5: 全绿          ← 但它是假绿
```

### 三个真问题

**① 转义写坏：`\n` 变成了真实换行**

上一轮用 heredoc / `printf` 往 Dart 文件里写代码，`'\\n'` 落盘成了真换行，
字符串字面量被截断 ⇒ 41 个 error。**从此本仓往 Dart 源码写代码禁用 shell heredoc。**

**② scroll 那条断言被「类声明」满足**

```text
旧断言：shell.contains('_SourinScrollBehavior()')
文件里 const _SourinScrollBehavior();  ← 类体里的构造函数声明就满足它
⇒ 把 ScrollConfiguration(behavior: …) 换成框架默认，类还在，断言照样绿
```

**③ 首帧用例不经过真实启动路径（这才是补门禁的原因）**


`_simulateStartup` 不调 `main()`、不构建 shell，`debugSetDanmakuTransportForTest`
在那条路径上没有调用方 ⇒ 有人在 `main()` 里塞一句 `await DanmakuLocalService.probe()`
照样全绿。**假绿的形状：判据没经过被测对象。**

**④ 产品侧的真缺陷：`_SourinScrollBehavior` 从 2026-10-18 起就没挂上去过**

```text
lib/shell.dart:1941  M4 把 MaterialApp 换成 WidgetsApp 时 scrollBehavior: 参数被删了
                     ScrollConfiguration 却没补上 ⇒ 只剩一个类声明
⇒ arm64「内容区全空白」的 Clip.none 修复，从那天起其实是失效的
门禁 grep 的是 '_SourinScrollBehavior()' —— 正好被构造函数声明满足 ⇒ 假绿整整三天
```

## Decision

### ⑥ 产品侧：App 外层真的包一层 ScrollConfiguration

```text
lib/shell.dart:1941  child: WidgetsApp(  →  child: ScrollConfiguration(
                                          behavior: const _SourinScrollBehavior(),
                                          child: WidgetsApp(
```

★ 不整体缩进那 700 行：否则本次 diff 变成「全文件重排」，
而真正的语义只有一句「WidgetsApp 外面多包一层」。

### ① 先剥注释，再匹配

`lib/shell.dart` 的注释里大段引用了错误写法原文（「反例：await …」）。
不剥注释 ⇒ **代码改对了反而红**，而假红的下场是有人去删注释 —— 缺陷本体毫发无损。
`_stripDartComments` 剥 `//` 与 `/* */`，字符串字面量内容清空只留引号，
换行逐行保留以对齐行号。

### ② `await` 用 lookaround 词边界，不用 `\b`

```text
unawaited(DanmakuLocalService.probe());   ← 正确写法（后台异步）
字面量里含 await 子串（u-n-await-ed）⇒ 不带边界会把正确写法判红
_danApiAwaitRe = (?<![A-Za-z0-9_])await(?![A-Za-z0-9_])[^;{}]{0,160}(?:…)
```

★ 整条正则**零反斜杠**（lookaround 代 `\b`、`[.]` 代 `\.`）—— 就是为了不再被转义写坏一次。
`await` 与调用点跨行也必须认（间隔里允许换行）。

### ③ scroll 用真挂载点正则

```text
_scrollMountRe = ScrollConfiguration\(\s*behavior:\s*const\s+_SourinScrollBehavior\(\)
```

★ 判据：**断言要绑在「真的挂上去了」，不绑在「有这个类」。**

### ④ 每条门禁都带反空转前置

```text
initState() 扫到 0 处 ⇒ 红（判据失效，不是"没问题"）
shell.dart 里出现 ''' / """ ⇒ 红（剥注释器认不出边界 ⇒ 可能漏扫 ⇒ 假绿）
找不到 main() 签名 ⇒ 红（不许静默绿）
```

### ⑤ 行号要精确到 `await` 那一行

`_extractBlockFrom` 初版把行号算到签名行（`lib/shell.dart:1716`），
Owner 还得自己再翻一遍。抽出 `_blockOpen(code, at)` 用「块的 `{` 绝对偏移 + 块内 start」
→ 读数变成 `lib/shell.dart:1719 `await DanmakuLocalService.probe(``。

## 同批：三处被本次改动撞红的旧门禁（全量跑才现形）

产品代码一动，三条**早就存在**的读源码门禁同时假红 —— 它们守的语义都对，
但都用「今天的文本形状」当锚。逐条修，并且**每条都保留原来的语义**：

```text
zz_t66_prefetch_yield_test.dart:90   窗口 [\s\S]{0,200}? → 700
  ↑ 给回调接上 .catchError 后，Timer 到 endYieldForSeek 之间多了 6 行说明注释
  ★ 这条对「有没有 catchError」是宽容的（见 2026-10-19-selfaudit 的更正）：
    别指望它守住"异常被接住"，它只守"到点会调 end"

zz_t66_r7_material_audit_test.dart:68  删掉「1941 行必须是 WidgetsApp(」这个行号锚
  ↑ 包一层 ScrollConfiguration 后 1941 变成 `child: ScrollConfiguration(`
  → 改成按内容锚：找到 `child: ScrollConfiguration(`，断言下一行是
    `behavior: const _SourinScrollBehavior()`，且往下 40 行内出现 `WidgetsApp(`
  ★ 顺带删掉只被它调用的 lineAt()，不留诱导下一个人再写行号锚的样板

zz_t66_raw_deflate_test.dart:211  `[^}]*` → `[\s\S]{0,2000}?`
  ↑ Err 分支里先放了 `if !is_real_decompress_failure(&e) { … }` 这个带 `}` 的闸门
    ⇒ `[^}]*` 一遇到闸门的 `}` 就停住
```

★ 判据：**读源码的门禁，锚要绑在「结构/语义」上，不绑在「第几行」「窗口正好多长」。**
三条都是同一个病：锚写成了当天的字面形状，改产品的人一动就假红，
而假红的下场永远是「有人去把门禁改松」，直到它守不住任何东西。

## Alternatives considered

### ① 用 analyzer 包做 AST 判断，不做文本匹配

**最强论据**：语义等价。能抓 `final f = DanmakuLocalService.probe(); await f;`
这种「先存变量再 await」的形状 —— 文本正则对此是**已知盲区**（见代价），
而且不用手写剥注释器，三引号 / raw string / 插值全都不用操心。

**为什么否决**：`package:analyzer` 目前不在 dev_dependencies，为两个断言引入
一整套前端依赖（含版本约束与升级负担），而本仓门禁的定位是**廉价的守夜人**，
不是编译器。且文本版已用硬断言把「剥注释器覆盖不到」的形态转成**红**而非静默漏扫
（三引号那条），失效可见。若将来这类契约门禁超过三五条，AST 方案的成本就被摊平 —— 那时换。

### ② 不剥注释，只改注释措辞

**最强论据**：省一个剥注释器，少一处可能自己出错的地方。

**为什么否决**：注释里引用错误写法**是好事**（它记录了"为什么不能这么写"），
为迁就判据去删它，等于让下一个人重新踩一次。而且剥注释器出错时有三引号硬断言托底。

### ③ scroll 沿用 `contains('_SourinScrollBehavior()')`

**最强论据**：一行断言，简单。

**为什么否决**：实测证明它被类声明满足 —— 注入「类还在但没挂上去」
（`behavior: const ScrollBehavior(),`）时它**不红**。这正是要抓的形态。

## Consequences

### 收益

```text
· 两个文件从「编译不了 / 假绿」变成三向可证：
    dart analyze 两个文件 ⇒ No issues found!
    flutter test  ⇒ +16 全绿（danmaku 10 + scroll 6），EXIT=0
· 三次红注入全部打红，且都指向目标那条用例：
    A main() 里 await → +6 -1，Actual: <true>，analyze 零 error（能编译的真实缺陷）
    B initState 里 await → +7 -1，Actual: ['lib/shell.dart:1719 `await …`']
    C 挂载点失效（类还在）→ +5 -1，Actual: <false>，同跑的判据自检仍绿
· lib/shell.dart 一字节没留：sha256 773ed665…b995b3，
  git diff --stat 17/1，git diff 与基线备份逐字节一致
```

### 代价 / 已知盲区（都写在文件注释里）

```text
· 文本匹配抓的是「await 后 160 字符内出现 dan-api 调用」。
  `final f = probe(); await f;` 漏判 —— 启动路径上同样是缺陷，但形态太多，抓语义要 AST。
· 剥注释器不认三引号字符串 ⇒ 出现即红（当前 shell.dart 为 0 处）。
  ★ 触发时红在那条断言上，不是静默失效 —— 这是有意的取舍。
· 剥注释器把字符串字面量内容清空 ⇒ 若有人把 dan-api 调用写进字符串（不该有），漏判。
· 门禁只读 lib/shell.dart 一个文件；启动路径若迁到别的文件，需同步扩扫描范围。
```

### 何时该翻案

```text
① 若这类「读源码契约」门禁超过三五条 ⇒ 换 analyzer AST，一次解决盲区①②
② 若 lib/shell.dart 出现三引号字符串 ⇒ 必须先扩剥注释器，那条断言会先红提醒
③ 若启动路径改成 build 里起请求（不再是 initState）⇒ 扫描目标要跟着变，
   否则 scanned 会掉到 0 —— 已被反空转断言拦住
```

## 给下一个人的提醒

```text
★ 本次最值得记的形态：**「补了门禁」不等于「门禁在工作」。**

  三个层次一次踩全：
    编译不了（转义写坏）→ 41 error，最响，最容易被发现
    假绿（断言被类声明满足）→ 全绿，最危险
    假红风险（注释里引用错误写法）→ 会逼人去删注释，缺陷毫发无损

  ⇒ 判据：**新门禁先做故障注入证明它会红，才承认它是绿的。**
     红注入必须是「真能编译的缺陷形态」，不是语法垃圾 —— 所以 analyze 要零 error。
```
