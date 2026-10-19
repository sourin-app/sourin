# Agent Note: 断言要钉机制，不钉实现 —— 以及负对照变异点必须真实存在

Status: implemented

Independent: 与本轮其它笔记都不同 —— 那几篇分别讲
[判别式的唯一实现](../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md)、
[弹窗收拢](../feature/2026-10-19-dialog-shell-unification-and-hover-sticky-bit.md)、
[强调用中文引号](../simplification/2026-10-19-emphasis-uses-chinese-quotes-not-markdown.md)。
本篇专门讲**测试自身与产品漂移**时的处置。

## Problem

第 66 轮改产品，同轮有 9 条断言红了。红的原因**不是产品缺陷** ——
是产品**有意改了**，断言还认旧东西：

```text
① settings_panels_test        断言 N12 **有意移除**的字面量
② zz_cr_nit_shell_theme_gate  硬编码 `MaterialApp(`，
                              而产品 10-18 已迁 `WidgetsApp`
③ zz_cr_nit_theme_gate_not_false
                              负对照变异的是一个**已不存在**的行
④ zz_t66_toast_call_sites     断言 `TextButton(onPressed: _reset,`，
                              实际是 `_busy ? null : _reset`
⑤ t486 / zz_t66_r8 / t3b 等   跟本轮改动相关的锚点
```

★ 第 ③ 条最危险，它是**假绿**而非假红：

```text
负对照的职责 = 证明"这条门禁能变红"
它变异的是一行**已不存在**的代码 ⇒ 变异不命中 ⇒ 断言仍绿
⇒ 它证明不了任何事，却让人以为"已验证这条门禁有效"
```

## Decision

### 原则：钉机制，不钉实现

逐条改法：

**① `settings_panels_test`** —— ⚠️ **不能**改成"必须不存在"：

```text
那条字面量（N12 的报错文案）在 N12 之后被接上了一档**真实的**
「网络异常，重试中…」⇒ 断言"必须不存在"会诱导后人把那档删掉。

改为：断言走 `QrPollErrorText.of(e)` 这个**入口**，
且**断成对**（该在的在 + 不该在的不在）。
```

**② `zz_cr_nit_shell_theme_gate`** —— 改前 `src.contains('MaterialApp(')`。

实测 `shell.dart` 里这个字面量 **2 次、两次都在注释里**，
代码里 **0 次** —— 而旧断言**照样绿** ⇒ 它守的是注释文本，不是代码。

改为：认 `WidgetsApp` / `MaterialApp` 两种绑定形态。

**③ 负对照** —— 变异点换成**真实存在**的那一行。

**④ `zz_t66_toast_call_sites`** —— 我第一反应是**删掉断言**让它绿。
那是错的：那条断言在钉「提交按钮在忙时禁用」这个**真实意图**。
改为加宽正则以钉意图，保留约束。

## Alternatives considered

**A. 把红着的断言全部删掉（"它已经不适用了"）。**
最强理由：最快，且没有"假绿"风险（没了就不会误报绿）。
否决理由：**删掉的门禁会静默失去覆盖面**。
本轮 ④ 就是活例子：如果我删了它，将来有人把
`_busy ? null : _reset` 改成 `_reset`（忙时也能点），
**没有任何门禁会红** —— 而那是用户能直接感知的缺陷（重复提交）。

**A'. 把断言改成"注释行不算"。**
最强理由：② 那种情况一劳永逸。
否决理由：它要求每个门禁都实现一遍剥注释逻辑 ——
而 `stripComments` 已经踩过坑（本仓 `cache_page.dart:1097` 的
`r'\'` 让整个文件 374 行被当字符串保留）。**判据分散到各处必漂开。**

**B. 让负对照变异一行**已被产品删除**的代码，并把它当作"防回退"用。**
最强理由：它看起来在防"删了再改回来"。
否决理由：它**变不红**，所以它什么也防不了。
负对照的价值**完全来自"它能红"**；一个不会红的负对照
比没有负对照更糟 —— 它提供虚假的安全感。

## Consequences

**验证（每条都做故障注入）**

```text
settings_panels_test      注入改回旧断言 ⇒ 复现 -1 ⇒ 有判别力
zz_cr_nit_*（经 importer）+21 全绿
本批其余 11 个           +125 All tests passed!
t3b_selfhosted_panel      探针 tab '弹幕来源' → '高级'
                         （_selfHostedSection() 只在 advanced 分支被调用 :1574，
                           按钮在 :2141 ⇒ 原 tab 名取不到）
```

★ 一条**跑法教训**（我自己的仪器用错了）：

```text
zz_cr_nit_shell_theme_gate.dart **没有 `main`** ——
它是共享门禁，被 theme_regression_test.dart 与
zz_cr_nit_theme_gate_not_false_test.dart import。
⇒ `flutter test <该文件>` 报 "Missing definition of `main`" 是**预期**行为。
我第一轮把它当缺陷查了一段才反应过来。
★ 判据：报"缺 main"先看它是不是 `no main` 的共享文件，别急着改。
```

**已知上限**

```text
· ⑤ 那几条我只改了锚点，没有逐条做注入。
  `fulltest` 的读数显示它们在基线 worktree 上也是红的
  ⇒ 归属是"基线既有"，但**本轮没解决**。

  ★★★ 2026-10-19（批末自审报告纠正，Lead 采纳）：
  这个说法**口径不准**，必须改。它容易被读成
  「全量基线有 23 条红」，而实际是：
    `baseline16_fails.txt` 恰好 23 行，但那是**16 个定向文件**的跑
    （读数 +91 -23），**不是全量基线**。
  ⇒ 准确说法：「这 16 个文件里的 23 条红是本轮之前就有的」。
  ★ 教训：「恰好 23」与「全量 23」是两回事 ——
    数字对上了不等于**口径**对上了。
    引用一个数字时必须同时说清它的**取样范围**。
· `zz_cr_nit_theme_gate_not_false` 的负对照现在变异真实行，
  但它只覆盖**一处**变异点；一条门禁通常有多个失败模式。
```

**何时该翻案**

```text
· 若有人为"让它绿"而删断言，这条笔记的 A 条就是判据：
  删除前必须问「这条门禁原本防的缺陷现在还有谁防？」
· 若 `stripComments` 的实现再变（加新语法），
  所有依赖它的门禁要一起重验 —— 它们现在的行为依赖它。
```