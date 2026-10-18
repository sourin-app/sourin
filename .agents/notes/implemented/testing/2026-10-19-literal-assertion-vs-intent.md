# Agent Note: 用字面量包含去断言「行为还在」，改一行写法就红 —— 而它守的意图其实仍然成立

Status: implemented

> 同域：[2026-10-18-gate-self-traps-four-forms.md](./2026-10-18-gate-self-traps-four-forms.md)
> 那篇讲门禁自身的四个陷阱（弱断言 / 注入静默失败 / 断言内部通知 / fake async 残留）。
> 本篇是**第五个形态**的另一面：断言**太强**（绑死字面量），于是把「实现改写」
> 误报成「功能丢失」。两者都源于同一件事 —— **断言的对象选错了**。

## Problem

R3-④ 修「弹窗遮罩双击透传」时，把播放区的
`onTap: _togglePlay,`
改成了
`onTap: (_anySheetOpen || _sheetGuardHold) ? null : _togglePlay,`

**功能没变**（面板关着时单击画面照样播放/暂停），但三条测试同时变红：

```text
test/player_click_seek_removed_test.dart:114
  expect(noComments.contains('onTap: _togglePlay'), isTrue, ...)
test/player_gestures_test.dart:257
  expect(noComments.contains('onTap: _togglePlay'), isTrue, ...)
test/player_gestures_test.dart:386
  expect(noComments.contains('onTap: _togglePlay'), isTrue, ...)
```

```text
实测：flutter test test/player_click_seek_removed_test.dart test/player_gestures_test.dart
  ⇒ +26 -3
```

三条的 `reason` 都写得很清楚：

```text
「用户说的是『不要单击快进快退』，**没有**说去掉『单击画面播放/暂停』
  —— 那是所有播放器（含原版）的通行习惯。」
```

**这条意图仍然为真。** 坏的只是它的表达方式：`contains('onTap: _togglePlay')`
把「意图」编码成了「这一行必须长这样」。

### 为什么这个错误特别难发现

```text
· 它不会假绿 —— 它假红。而假红会被当成「我改坏了」去修产品代码，
  最坏的结果是把 R3-④ 的守卫**撤掉**去迁就断言（那就是用测试反向破坏产品）
· 它的 reason 写得很对，所以看起来「这条断言是有理由的」
  —— 理由对、**判据错**，是这个形态最迷惑人的地方
· 它是**源码级断言**，而源码级断言天然要和「写法」耦合
  （本仓 2026-10-18 那篇记录里，源码级断言正是被接受的一种手段：
   用来兜住「行为门禁走 fake、看不到产品代码里有没有 .timeout()」的盲区）
  ⇒ 不能因为这次踩坑就否定源码级断言，要否定的是「用字面量代替语义」
```

## Decision

### 字面量断言 → 意图判据（正则允许合法变异，但卡死落点）

```dart
// 改前（绑死写法）
expect(noComments.contains('onTap: _togglePlay'), isTrue, ...);

// 改后（允许守卫前缀，但落点必须是 _togglePlay）
expect(
  RegExp(r'onTap:\s*[^,\n]*_togglePlay\s*,').hasMatch(noComments),
  isTrue,
  reason: '...允许守卫前缀（如 `(_anySheetOpen || _sheetGuardHold) ? null : `），'
      '但落点必须仍是 _togglePlay。',
);
```

```text
正则的两处刻意设计：
  `[^,\n]*`   —— 守卫前缀里可以有 `||`、`?`、`:`、空格，但**不能跨行**、
                 **不能含逗号** ⇒ 不会把隔壁那个 onTap 的条件吃进来
  `\s*,$`     —— 要求这行以逗号结束 ⇒ 锚定「它就是一个具名参数」
  ★ 尾部 `_togglePlay` 是硬要求：`onTap: null` / `onTap: () {}` 都必须红
```

### ★ 不许退回更弱的形式

```text
❌ contains('_togglePlay')      —— 文件里任何地方出现都算绿（函数定义里就有）
❌ contains('? null : ')        —— 只证明有守卫，不证明落点
❌ 只要有一个 onTap 带 _togglePlay 就绿 —— 播放区可能有多处 onTap
```

### 故障注入（这是本决策唯一的合法性来源）

```text
注入：lib/ui/player_page.dart 的 `onTap: (...) ? null : _togglePlay,` → `onTap: null,`
  → dart analyze lib/ui/player_page.dart ⇒ 0 error（注入有效，不是编译失败）
  → flutter test 上述两文件 ⇒ **+26 -3**，红的正是那三条
还原：git status --porcelain lib/ui/player_page.dart ⇒ 空
  → dart analyze ⇒ 0 error
  → flutter test ⇒ **+29 All tests passed**
```

★ 注意：改前那三条**也是红的**（因为字面量变了）。所以「红」本身不能区分
「改前（假红）」与「注入后（真红）」—— 区分它们的是**产品的实际行为**：
改前产品是对的、注入后产品是坏的。这正是本仓「门禁读数不能单独作为判据」的又一例。

## Alternatives considered

### ① 「把 R3-④ 的守卫挪到别处，让 `onTap: _togglePlay` 字面量留着」

**最强论据**：三条既有断言零改动，风险最小；而且「单击画面 = 播放/暂停」这行
看起来更干净，守卫逻辑放到外层（比如包一层 `AbsorbPointer`）读起来也更清晰。

**为什么否决**：**为了迁就断言去改产品设计，方向反了。**

```text
· 守卫必须作用在**这一处 onTap** 上：面板关闭后第 2 击落到播放区，
  受害的正是这个 onTap；包 AbsorbPointer 会连**控制条显隐之外的其它交互**一起吞掉
  （控制条由 _showControls 驱动，与 onTap 无关 —— 已在代码注释里核实）
· 更根本：断言的职责是描述产品，不是规定产品怎么写
  ⇒ 若一条断言强迫实现保持某个字面量，那它测的是「写法」而不是「行为」
```

### ② 「三条断言直接删掉」

**最强论据**：它们守的东西（单击能播放/暂停）已经被别的测试覆盖了
（`player_gestures_test` 里另有行为级用例）。删掉最省事。

**为什么否决**：**它们守的是一个真实的回归风险，且没有替代品。**

```text
这三条是**源码级**断言，守着「有人把整屏单击改成没反应」这个历史事故
（用户曾明确要求删掉"单击快进快退"，很容易连"单击暂停"一起删）。
删掉它们 ⇒ 这类回归只能靠人工点。
★ 而且它们是在**没有行为门禁**的情况下唯一防线：
  在 flutter_test 里挂整个 player_page 拿不到真实播放器（libmpv），
  行为级断言只能测到复刻件。
```

### ③ 「用 `contains('_togglePlay')` 放宽，反正意图是它还在」

**最强论据**：最不容易误报，任何写法都能过。

**为什么否决**：**它把「有没有」和「在哪」混为一谈。**

```text
文件里 `void _togglePlay()` 的定义本身就让 contains 恒真
⇒ 把 onTap 整个删掉，断言照样绿
⇒ 这是标准的弱断言（本仓 2026-10-18 那篇的形态①），比假红危险得多
```

## Consequences

### 三条断言已改，读数

```text
flutter test test/player_click_seek_removed_test.dart test/player_gestures_test.dart --concurrency=1
  改前：+26 -3
  改后：+29 All tests passed
  注入 onTap→null：+26 -3（红的正是那三条）
  还原：+29 All tests passed，git status 干净，analyze 0 error
```

### 一条可迁移的判据

```text
写源码级断言之前问一句：**我断言的是「行为」还是「这一行长什么样」？**

· 若行为有别的办法测（挂组件、读渲染结果）⇒ 优先测行为
· 若只能读源码（因为真实依赖在测试环境里起不来）⇒ 那就用
  「正则 + 允许合法变异 + 卡死关键落点」，并在 reason 里写清
  **允许哪些变异、不许哪些**
· ★ 判据：**把产品改成一个「行为相同但写法不同」的版本，断言必须仍然绿。**
  做不到这一点，说明它绑死的是写法。
```

### 代价

```text
· 正则比 contains 脆：`_togglePlay` 若被重命名，这条会红（但那是**该红**的，
  重命名本身应当同步改断言）
· 正则 `[^,\n]*` 假设 onTap 是单行表达式。若将来写成多行 lambda，
  这条会误红 ⇒ 那时应改成「解析 widget 树」或直接写行为门禁，
  不许把正则放宽到跨行
```

### 还没覆盖的

```text
· 没有全仓扫「同类字面量断言」还剩多少条（本轮只修了被 R3-④ 撞红的三条）
· 没有做「故意写一个绑死字面量的断言」的故障注入，来证明这套判据能被发现
  （目前只证明了「改后的断言在行为不变时是绿的」）
```

### 何时该翻案

```text
① 若本仓能给 PlayerPage 挂上可测的播放器替身（让 onTap 行为可观测）
   ⇒ 这三条应改成行为断言，源码断言退为兜底
② 若 `onTap` 需要写成多行 lambda
   ⇒ 正则方案失效，改用 AST/树断言
③ 若出现第二次「因实现改写导致源码断言假红」
   ⇒ 说明这不是个案，应当规则化：源码级断言必须附「允许的变异」注释
```
