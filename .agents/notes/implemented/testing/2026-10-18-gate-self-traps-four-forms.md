# Agent Note: 门禁自身的四个陷阱 —— 弱断言 / 注入静默失败 / 断言内部通知 / fake async 残留

Status: implemented

> 同域：[2026-10-18-skip-marker-write-path-lies.md](../bug-fix/2026-10-18-skip-marker-write-path-lies.md)
> 那篇是**被测对象**（写路径撒谎）；本篇是**量它的尺子**（门禁自身的四个陷阱）。
> 两者必须一起看：那篇的 7 条门禁里，第 ④ 条第一版就是本篇 Problem ① 的实例。

## Problem

为写路径写 7 条门禁时，**门禁本身**连续踩了四个坑。每一个单独出现都会让门禁
"看起来有效"而实际无效 —— 也就是本仓反复在打的「假绿」。

### ① `greaterThan` 太弱，能被无关变化满足

```dart
// 第一版（错）
expect(readCount, greaterThan(beforeClear),
    reason: '重置失败后必须重新读取');
```

```text
这条断言的意图是「失败后**因为重读**多了一次」
但 greaterThan 只要求 "比之前大" —— 任何**别的**读都能满足它：
  · 位置流触发的读
  · 别的页面/组件的读
  · 甚至测试装置自己的一次读
⇒ 当"重读"这段代码被删掉时，只要期间有别处读过一次，断言仍然绿
```

**实测**：把 `_reset` 两个失败分支里的 `await _loadExisting();` 整段删掉，
`greaterThan` 版本**仍然全绿** —— 这就是假绿。

### ② 注入脚本静默失败 —— 一个字节都没改

```python
# 第一版注入脚本（错）
s = open(p).read()
old = "..."
if old in s:                 # ← ★ 没匹配上就**什么都不做**，然后继续
    s = s.replace(old, new)
open(p, 'w').write(s)
print('injected')
```

```text
当时文件已被我 `cp` 还原过一次，old 字符串对不上
⇒ 脚本**没有任何改动**，但打印了 "injected"
⇒ 跑测试 → 仍然绿 → 我差点据此写成「门禁有效」

★ 这是「注入无效」的**第 6 种形态**，也是最阴险的一种：
  本仓 §8 已记的 5 种（行尾不同 / 命中注释 / 锚点漂移 / 写坏语法 / 忘还原）
  **至少都改了点什么**，能通过 analyze 或 diff 察觉；
  这一种是文件一个字节都没变 ⇒ 测试绿得完全合理 ⇒ **直接得出反结论**
```

### ③ 断言了"内部通知"，而它在测试环境里根本不发生

第一版 ①③⑤ 三条都断言 toast 文案：

```dart
expect(find.text('已重置'), findsWidgets);          // ⑤
expect(find.textContaining('重置失败'), findsWidgets);  // ③
```

**三条全红。** 原因：

```dart
// app_toast.dart:83
AppToaster.maybeOf(context)?.show(...);
//               ↑ findAncestorStateOfType<_AppToasterState>()

测试宿主（_host）里没有 ToastHost
⇒ maybeOf 返回 null
⇒ showAppToast 是**静默 no-op**（这正是它相对 ScaffoldMessenger.maybeOf 的改进：
  找不到宿主不抛异常，不会把调用方搞崩）
⇒ toast 文案**永远不会出现在树上**
```

**⇒ 用 toast 做断言，等于测一个在测试环境里必然不发生的事。**
产品在真机上有 ToastHost，所以这不是产品缺陷，是**断言选错了对象**。

### ④ fake async 下未走完的定时器 → "Pending timers"

```dart
// ⑦ 只测"保存进行中"，不推进时钟
await t.tap(find.text('确认设置'));
await t.pump();
expect(find.textContaining('区间不合法'), findsNothing);
expect(find.text('保存中…'), findsOneWidget);
// ← 测试在这里结束，但 .timeout(10s) 的定时器还在跑
```

```text
⇒ 测试以 "Pending timers: Timer (duration: 0:00:10.000000)" 失败
⇒ 但**所有断言都通过了** —— 失败原因不是断错，是 fake async 的卫生要求
★ 这很容易被误读成"断言有问题"，然后去改断言（越改越错）
```

## Decision

### ① 断言强度要"恰好"，不要"大于"

```dart
// 改后
expect(readCount, beforeClear + 1,
    reason: '重置失败后**必须恰好重新读取一次**');
```

```text
"恰好 +1" 同时排除了两种情况：
  · 少了（没重读）⇒ 失败
  · 多了（重读了两次 / 有别处的读混进来）⇒ 也失败
⇒ 它证明的是「**正是因为这次重置失败**，多发生了 1 次读」
★ 一般规则：能用等号的，不要用 greaterThan / isNotEmpty / contains
  —— 后者都是"只要有一个满足就行"，而"哪一个"往往正是要验证的
```

### ② 注入必须三重保险

```text
① 脚本里 **assert 匹配成功**，不匹配立即报错退出，不许静默 continue
     assert s.count(old) == 1, ('not found', s.count(old))
② 注入后**立刻验 git diff --stat <file> 有改动**
     —— 这是区分「注入无效」与「门禁抓不到」的**唯一手段**
③ 注入后先 `dart analyze <file>` 必须 0 error，再看测试红不红
     —— 防止"测试红是因为编译失败"
```

★ 本轮第二次注入时我照着做了 ①③，④④ 条立刻变红；如果只做 ①，
匹配成功但替换目标写错（比如替换了注释而不是代码）仍会静默失效。

### ③ 断言用户**看得见**的东西，不是内部通知

```dart
// 改后 —— 底栏 _saveError 是持久可见的
expect(find.textContaining('无响应'), findsWidgets,
    reason: '超时必须如实说（底栏 _saveError）');

// ⑤ 改用"四值清空后的可见结果"
expect(find.textContaining('片头未设'), findsWidgets,
    reason: '重置成功后四值必须清空');
```

```text
★ 判据：**这条断言在测试宿主里能不能真的成立？**
  · 依赖 ToastHost / Overlay / 键盘焦点 / 真实窗口的，测试宿主要么没有、
    要么行为不同 ⇒ 断言它们等于测"测试环境"，不是测产品
  · 优先选：组件自己渲染出来的文本（底栏、四行、错误面板）
★ 顺带的好处：底栏文案是**持久**的，toast 是 2.6 秒后消失的 ——
  断言持久的东西，不依赖 pump 时序
```

### ④ fake async：测试结束前把定时器走完

```dart
// ⑦ 结尾
await t.pump(const Duration(seconds: 11));   // 把 10 秒超时走完
await t.pump(const Duration(milliseconds: 100));
```

★ 判据：**凡测试里触发过 `.timeout(...)` / `Timer(...)` 而没等它结束，
结尾都要补 pump 把它走完**，否则 "Pending timers" 会让测试红 ——
而那与断言无关。

### ⑤ 源码级断言兜住"复制品测不到产品代码"

⑥ 是一条**源码级**门禁：

```dart
expect(RegExp(r'setSkipMarker\([\s\S]{0,400}?\.timeout\(_kLoadTimeout\)').hasMatch(src), isTrue);
expect(RegExp(r'clearSkipMarker\([^)]*\)\s*\n?\s*\.timeout\(_kLoadTimeout\)').hasMatch(src), isTrue);
expect(RegExp(r'重置失败[\s\S]{0,700}?_loadExisting\(\)').hasMatch(src), isTrue);
```

```text
为什么行为门禁不够：
  · 行为门禁用的是 fake（debugSkipMarkerWriter/Clearer），
    它顶替的是**核心层传输**，不是产品逻辑
  · 如果有人在产品代码里把 `.timeout()` 删了、但 fake 路径仍能跑通，
    行为门禁看到的还是绿
  · 源码级断言直接读产品文件文本 ⇒ 兜住这个盲区
★ 代价：正则脆（改个写法就失效）。所以它只用来守**"有没有接线"**，
  不用来守语义 —— 语义归行为门禁管。
```

### ⑥ ⑥ 这条本身也踩过坑：命中注释

```dart
// 第一版（错）
expect(RegExp(r"catch \(e\) \{[\s\S]{0,200}?_toast\('已重置'\)").hasMatch(src), isFalse);
```

**实测红了** —— 因为它命中的是文件里**注释**的一段示例代码：

```dart
///   _toast('已重置')          ← ★ 失败也报"已重置"
```

```text
⇒ 源码级断言必须先剥注释行，否则会把文档当代码
   （这正是 §8 已记的"命中注释"那条，只是这次发生在测试里而不是注入脚本里）
```

改后：

```dart
final codeOnly = src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');
expect(RegExp(r"catch \(e\) \{[\s\S]{0,200}?_toast\('已重置'\)").hasMatch(codeOnly), isFalse);
```

## Alternatives considered

### ① 「保留 `greaterThan`，靠 reason 说清意图」

**最强论据**：`greaterThan` 语义更宽松，不会因为"多读了一次"这种无害情况就红，
更不容易误伤。

**为什么否决**：**它的"宽松"正好落在要验证的那个维度上。**

```text
这条门禁要证明的正是「因为重置失败而多了一次读」
⇒ "多了一次"就是被测对象本身
⇒ 用 greaterThan 等于「只要比之前多就行，多几次、为什么多都不用管」
⇒ 它恰好把被测对象糊掉了
★ 不是说 greaterThan 一律不好 —— 是当"增量"本身是被测对象时，必须用等号。
```

### ② 「注入失败就跳过，继续跑测试」

**最强论据**：脚本更健壮，不会因为一次匹配失败就中断整轮流程。

**为什么否决**：**它会把"没测到"伪装成"测到了且通过"。**

```text
这正是本仓反复在打的那个形态（故障伪装成正常状态），只不过这次
发生在验证流程里：
  注入没做成 → 缺陷仍在 → 门禁绿 → 结论"门禁有效"
⇒ 比"脚本报错退出"危险得多。
★ 脚本失败时**必须响亮地失败**，哪怕打断流程。
```

### ③ 「断言 toast，因为用户实际看到的就是 toast」

**最强论据**：这是最贴近用户视角的断言 —— 用户确实看到「已重置」这四个字。

**为什么否决**：**在测试环境里它恒不成立，所以断言它测的是测试环境而不是产品。**

```text
测试宿主没有 ToastHost ⇒ showAppToast 静默 no-op
⇒ 断言必然红（或为了变绿而加 ToastHost，那又引入新的装置复杂度）
★ 正确做法：断言"用户看得见的另一面"——
  失败 ⇒ 底栏 _saveError；成功 ⇒ 四值清空后 UI 显示「片头未设」
  这些都是组件自己渲染的，不依赖宿主
★ 若将来真要断言 toast，应该给测试宿主配上 ToastHost，
  而不是把断言改弱
```

### ④ 「源码级断言（⑥）没用，正则太脆」

**最强论据**：正则遇到格式化/重命名就失效，维护成本高。

**为什么否决**：**它守的是行为门禁覆盖不到的盲区。**

```text
行为门禁全部走 fake（顶替核心层传输）
⇒ 产品代码里的 `.timeout()` 被删掉时，fake 路径仍能跑通
⇒ 行为门禁看不到
⇒ 必须有东西直接读产品文件
★ 折中：源码级断言**只守"有没有接线"**（.timeout 是否存在、
  catch 里是否还有那句 toast），不守语义 —— 语义归行为门禁
★ 代价是脆，但脆在"改了写法就红"，那是**可以修的误报**，
  比"缺陷在但门禁绿"的**漏报**好得多
```

## Consequences

### 四个陷阱的最终形态

| # | 陷阱 | 修法 |
|---|---|---|
| ① | `greaterThan` 假绿 | 改成 `beforeClear + 1`（恰好 +1） |
| ② | 注入静默失败 | `assert` 匹配 + 验 `git diff --stat` 有改动 + analyze 0 error |
| ③ | 断言内部通知 | 改用底栏 `_saveError` / 四值清空后的可见结果 |
| ④ | fake async 残留定时器 | 结尾补 `pump` 走完超时 |
| ⑤ | 源码级断言命中注释 | 先剥注释行再匹配 |

### 验证读数

```text
注入 A（删掉 _reset 的重读）：
  [DIAG4] readCount=1 beforeClear=1     ← 重读没发生
  ④ 变红 ✓                (+5 -2)

注入 B（删掉 _save 的 .timeout()）：
  ①⑥ 变红 ✓               (+5 -2)

还原核对：analyze 0 error / diff -q 一致 / grep INJECT = 0 / 全量 +7 绿
```

### 这套判据的适用范围

```text
不只用于 skip_marker：**任何"失败态"门禁**都该按这四条自查
  · 断言强度是否恰好（等号优先于 greaterThan）
  · 注入是否真的改动了文件（diff --stat）
  · 断言的对象在测试宿主里会不会真的出现（ToastHost / Overlay / 焦点）
  · 有没有未走完的定时器
```

### 还没覆盖的

```text
· 这四个陷阱是我**在同一个文件的门禁上**连续踩到的 ——
  没有做"故意再造一次"的验证（比如故意留一个 greaterThan 看它多久被抓到）
· ⑤ 源码级断言的正则没有做"改动写法"的鲁棒性测试
  （只知道它能抓"删掉 .timeout()"，不知道它对"换个写法接线"是否仍成立）
```

### 何时该翻案

```text
① 若本仓引入更强的断言库（如精确的调用计数 matcher）
   ⇒ `greaterThan` 那条可以用更语义化的写法替代
② 若测试框架支持"注入必须产物差异"的机械校验（脚本产物 diff）
   ⇒ 注入三重保险可简化为一条
③ 若测试宿主统一挂上 ToastHost
   ⇒ ③ 可以改回断言 toast（那更像用户视角），但仍建议**同时**断言持久文本
④ 若 Flutter 的 fake async 改成自动清理定时器
   ⇒ ④ 那条 pump 可以去掉（但目前不是）
```
