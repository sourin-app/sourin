# Agent Note: 登记「仪器失效」要用 tag，并给登记本身加门禁

Status: implemented

Independent: 与 [three-causes-of-a-red-test](2026-10-19-three-causes-of-a-red-test.md)
**是同一件事的两半**：那篇把红分成「漂移 / 仪器失效 / 真缺陷」三类，
并说「仪器失效**不该留在红里**」；本篇给出**具体怎么登记**，
以及一个那篇没展开的副作用 —— **登记即豁免，豁免会悄悄消失**。

## Problem

`test/t36_cache_refresh_test.dart` 有 4 条红（①切tab ×2 / ②pop回 / ②失败重试），
实测全是 `Expected: greaterThan(0) / Actual: 0`。

**根因是仪器失效，不是产品缺陷**：

```text
仪器（t36:95）  shelfLoads = [SHELF] 行数 ~/ 3
产品（my_shelf.dart:550 注释原文）
  「成功的 load() **什么都不打印**（只有失败路径有 `[SHELF] ...失败`）」
[SHELF] 的 6 个打印点：557 切 tab / 662 668 674 取各类失败
                     / 792 加载失败 / 1121 清空历史失败
⇒ **没有一处在 load() 的成功路径** ⇒ 计数恒 0 ⇒ 阳性对照必然失败
```

★ 而且 `my_shelf.dart:721` 的注释还写着「÷3 = load() 调用次数」
  ⇒ **注释与实现已经不符**（本轮第 N 次）。

⇒ 它们继续红着，会让读全量红数的人以为**产品坏了**。

## Decision

### ① 用 tag 登记，沿用仓里已有的 5 个同类 tag

```yaml
# dart_test.yaml
instrument-broken:
  skip: "仪器失效（非产品缺陷）：[SHELF] 只在失败路径打印，成功 load() 数不到
        ⇒ 阳性对照必然失败。手动跑：flutter test
        test/t36_cache_refresh_test.dart --run-skipped --tags instrument-broken --concurrency=1"
```

**★ 为什么叫 `instrument-broken` 而不是 `known-failure`**（队友写的注释，我采纳）：

```text
坏的是**尺子**，不是被测产品，也不是用例写错了。
叫 known-failure 会让人以为「产品有已知缺陷」—— 那是误导。
```

**逐用例打 tag 的正确写法**（队友踩过坑）：

```dart
// ★ @Tags 是**文件级注解**，写在函数体内会编译失败：
//     "Variables must be declared using the keywords..."
//     "testWidgets is already declared in this scope"
// ⇒ 正确写法是 flutter_test 签名里的 tags 参数（widget_tester.dart:155）
testWidgets('…', (tester) async { … }, tags: ['instrument-broken']);
```

**语义：默认 skip，可手动跑**（沿用仓里 `native-media` 的做法）

```text
默认跑    ⇒ +9 ~4  All tests passed!   ← 不再红，但读数里可见「跳过 4」
手动跑    ⇒ +0 -4  Some tests failed.   ← 真读数仍可复现
```

★ 用 `skip:` 而不是 `exclude_tags:` ——
  `exclude_tags` 发生在**选择之前**，排除了就无法再 `--tags` 放行。

### ② ★★ 登记本身必须有门禁（本篇最有价值的一条）

默认 skip 的副作用是**它们不再红了**。于是：

```text
若有人删文件 / 删用例 / 去掉 tags
⇒ 全量读数会「变干净」，而登记凭空消失
⇒ ★★ 看起来像「问题解决了」—— 这是「登记即豁免」的通病
```

加了 **3 条元断言**：

```dart
group('⑥ 元断言：instrument-broken 登记必须仍在', () {
  test('★ 本文件的 instrument-broken 标记必须恰好 4 处');
  test('★ dart_test.yaml 里必须有 instrument-broken 档（否则 tag 失效）');
  test('★ 手动跑的命令必须写在 skip 文案里（否则没人知道怎么复现）');
});
```

**双向注入验证**：

```text
注入 A：删掉 1 个 tags（4 → 3）   ⇒ Expected <4> Actual <3>  红 ✔
注入 B：删掉 yaml 里的档          ⇒ 红 ✔（连带那 4 条重新参与默认跑）
```

★ 元断言自己踩过一个坑：第一版正则 `tags: \['instrument-broken'\]`
  把**元断言注释里那句举例**也数进去了 ⇒ 实测 5 处 ⇒ **假红**。
  改成行尾锚定 `^\s*\}, tags: \['instrument-broken'\]\);\s*$` 后正确。
  ⇒ **判据自身必须先被阳性/阴性各验一次**，否则它自己就是假绿。

## Alternatives considered

**A. 只在测试文件头加注释块（零配置）。**
最强理由：只碰一个文件。
否决理由：**只有打开那个文件的人才看得到** ——
  读全量红数的人仍会把 4 条红当产品缺陷，而那正是本篇要解决的问题。

**B. 逐个 `testWidgets(..., skip: '原因')`。**
最强理由：只碰测试文件，且真会 skip。
否决理由：4 处各写一遍、无法统一管理、skip 文案与 tag 分离。

**C. 把断言改掉让它绿。**
最强理由：红数归零。
否决理由：**那是把仪器失效伪装成「已修」** ——
  下一个人会以为那 4 个功能被验证过了，而它们其实根本没被验证。

## Consequences

**★ 可迁移的判据**

```text
凡是把用例从「红」改成「跳过」，都必须同时回答：
  ① 跳过的原因写在**读全量的人能看到的地方**（tag 的 skip 文案）
  ② 怎么手动跑它（命令要写在 skip 文案里，可复制）
  ③ ★ 谁保证这条登记**不会被悄悄删掉**（元断言）
缺任何一条 ⇒ 登记就只是「把红藏起来」。
```

**本轮全量的真实构成（真跑，不是静态推）**

```text
-25 ⇒ 修完这批应到 -23：
  · 4 条 仪器失效 ⇒ 已登记为 instrument-broken（默认 skip）
  · 1 条 白名单漂移 ⇒ 已更新行号（四条差值全部 = 741，硬证据）
  · 其余 20 条 基线既有（t75 ×9 / t74 ×3 / t80a ×2 / t526 ×1 /
                    t74_perf ×1 / t36_pill ×2 / t72_jank did-not-complete ×6 等）
★ 已核实：那 23 条里**没有一条是产品违规**。
```

**★ 顺带记一条方法论失败（同样有价值）**

队友尝试「静态扫描全仓找恒真断言」，静态判 227 条「已红」，
**抽样真跑发现全是绿的**：

```text
静态判「已红」：live_page_test / arrow_key_ownership
真跑： +29 全绿 / +6 全绿
```

⇒ 根因（他的原话，最值得记）：
> **静态推断「断言会不会红」本身不成立** ——
> 红不红取决于运行时（`setUpAll` 读了什么、`pump` 到第几帧、widget 树长什么样）。

⇒ **找假绿只能靠变异测试**（改坏产品符号 → 真跑 → 仍绿即假绿）。
第二批实测 3 条源码级门禁，**3/3 全红** ⇒ 那批无假绿。

**已知上限**

```text
· instrument-broken 目前只登记 1 个文件 4 条。
  若将来别的仪器也失效，应复用这个 tag 而不是新造一个 ——
  ★ 否则会出现 5 个语义相近的 tag，那比没有 tag 更糟。
· 元断言用的是 `File('test/xxx').readAsStringSync()` 读源码计数
  （沿用仓里 `search_all_test.dart:374` 的惯例）⇒ 它本身是**源码级**判据，
  不是运行时判据。若将来改用别的 tag 写法，这三条要同步改。
```

**何时该翻案**

```text
· 若本仓引入 AST 或统一的测试元数据机制（而非 dart_test.yaml + 源码计数），
  元断言可改为查那个元数据，而不是数文本。
· 若产品给 load() 成功路径补了可数信号 ⇒ 这 4 条应当**退出**该 tag
  （判据已恢复），这属于「档只该变短」而不是「档可以长期存在」。
```