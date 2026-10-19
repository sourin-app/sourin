# Agent Note: 源码扫描判据不该用固定字符窗口

Status: implemented

Independent: 与本仓其它 testing 笔记不同 —— 那几篇讲
[恒绿断言的四种形态](../testing/2026-10-19-four-shapes-of-always-green-assertions.md)、
[作废数字要 grep 全部位置](../testing/2026-10-19-invalidating-a-number-means-grepping-all-its-sites.md)、
[删恒真断言而非放宽](2026-10-19-delete-the-constant-true-assertion.md)、
[阈值按实测](../testing/2026-10-19-thresholds-from-measurement-not-from-myth.md)。
它们讲的是**判据对不对**；本篇讲**判据怎么取输入** ——
判据本身没错，取的输入却让它**看似有效**。

## Problem

`test/zz_t66_sheettimer_dispose_test.dart` 要确认
`PlayerPageState.dispose()` 里清理了 `_sheetGuardTimer`，写法是：

```dart
final disposeIdx = src.indexOf('void dispose() {');
final disposeBody = src.substring(disposeIdx, disposeIdx + 2600);
```

★ 复核实测：

```text
dispose 的真实函数体 = **6813 字符**
2600 窗口 ⇒ 只覆盖 **38.2%**
_window 外有 24 个清理调用，含 _player.dispose() / _danmakuClient?.close()
_sheetGuardTimer?.cancel() 在偏移 **1871（27.5%）** ⇒ 落进窗口
⇒ 这条断言目前是**侥幸正确**的
```

⇒ 它没有红，不是因为判据对，而是因为**目标恰好在前 38%**。
  前面多一行注释就可能失效 —— 而这类「运气型正确」最难查：
  读起来完全正常，只有某天突然假红。

## Decision

改成**按大括号配对**取整个函数体：

```dart
String _balancedBody(String src, String signature) {
  final i = src.indexOf(signature);
  if (i < 0) return '';
  final open = src.indexOf('{', i);
  if (open < 0) return '';
  var depth = 0;
  for (var k = open; k < src.length; k++) {
    if (src[k] == '{') depth++;
    if (src[k] == '}') {
      depth--;
      if (depth == 0) return src.substring(open, k + 1);
    }
  }
  return src.substring(open);
}
```

### 连带三条断言（配对截断改变了判据的性质，必须跟着改）

```dart
// ① 自检：**配对成功的直接证据**（不是 length）
expect(disposeBody, isNotEmpty, ...);
expect(disposeBody.startsWith('{'), isTrue, ...);
expect(disposeBody.endsWith('}'), isTrue, ...);    // ★ 这条才真的挡得住截断
expect(disposeBody.length, greaterThan(2600), ...); // 只抓「恰好改回 2600」

// ② ★「恰好 1 处」，而不只是「至少 1 处」
expect(RegExp(r'_sheetGuardTimer[?!]?\.cancel\(').allMatches(disposeBody).length, 1);

// ③ 三条关键释放调用 —— ★★ 必须**剥注释后**判，且**带分号**
for (final call in const ['_player.dispose();', '_danmakuClient?.close();', 'super.dispose();'])
  expect(_codeOnly(disposeBody).contains(call), isTrue);
```

★ **① 的教训**：`length > 2600` 只是**间接代理**，只对恰好 2600 这个魔数敏感
（复核实测：2700 的截断窗口、半个函数 3406 字符，**都能通过它**）
⇒ 必须断 `endsWith('}')` —— 那才是「配对成功」的直接证据。

★ **② 是最关键的一条**：修好之前 `hasMatch(disposeBody)` 在 dispose 里
出现 1 处或 2 处都通过；现在「只该有一处」本身成为一个**被断言的事实**。
复核三种形态实测：

```text
原样              ⇒ <1>  绿
删掉 dispose 那处   ⇒ <0>  红 ✅
★ 再加一处         ⇒ <2>  红 ✅   ← 这正是「判据变宽」的风险
```

★★ **③ 的教训（本篇最有价值的一条）：我第一版写的是假绿**

```text
第一版：expect(disposeBody.contains('_player.dispose()'), isTrue)
★ 实测：`_player.dispose()` 在 dispose 里出现 **3 次**，
      但只有 **1 次是真实代码**，另 2 次在**注释里**
      （那段注释解释为什么要放在 `_biliApi?.close()` 之后）
⇒ 删掉真实那一行后 contains 仍为 true ⇒ 测试**仍全绿**（复核端到端实测）
⇒ ★ 我自己写的注释，恰好满足了我自己写的判据。
```

⇒ 这与本仓 AGENTS §8 记的「命中注释」是同一个病，
**也与那条被删掉的全局 `hasMatch` 恒真是同一个病** ——
我以为换个扫描范围就治好了，实际只是把它从「全局」挪到了「函数体」。

**修复（两处都要，缺一仍会假绿）**

```dart
// ① 剥掉整行注释
String _codeOnly(String body) => body
    .split('\n').where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    }).join('\n');

// ② ★ 被扫的调用**带上分号**：`_player.dispose();`
//    注释里那两处是 `_player.dispose()`（不带分号）⇒ 多一层保险
```

★ 用 `String.contains` 而不是正则这一点仍然成立：`?` 在正则里是量词，
  `_danmakuClient?.close()` 得写成 `\?` —— 容易错，而这些调用
  不含可变空白，用 `contains` 更稳。

### 刻意**不**断言其余 21 条（复核的判断，我采纳）

```text
`_xxxTimer?.cancel()` 一类（12 条）
  ⇒ 删掉只是定时器多活几百 ms，由各自的功能测试覆盖
    （本文件 ①② 就在测这个）⇒ 重复断言违反「同一纪律只能有一个实现」
`_xxx.dispose()` 的 ValueNotifier 一类（8 条）
  ⇒ 删掉会被 flutter_test 的**泄漏检测**直接抓到 ⇒ **框架已经在守了**
```

★ ③ 的缺口依据（复核实测）：`t73_bili_wiring_test.dart:552` 提到了
`_player.dispose()`，但只拿它当**位置基准**（比较与 `_biliApi?.close()`
的先后）⇒ 实测**把它移出 dispose，它仍然绿**。

## Alternatives considered

**A. 只把窗口从 2600 调大到 8000。**
最强理由：一行改动，问题立刻消失。
否决理由：**仍然是运气型正确** —— 下次函数体长到 8001 就复发，
而且没人会想到去查那个数字。**它把一个结构问题变成了另一个结构问题。**

**B. 用「从 `dispose` 到文件末尾」截取。**
最强理由：不需要配对逻辑。
否决理由：会把**后面所有函数**都算进来 ⇒ 判据变宽 ⇒ 恒真
（这正是刚删掉那条全局断言的教训）。

**C. 24 条清理调用全部断言。**
最强理由：全覆盖。
否决理由：**过度** —— 其中 20 条已被功能测试或框架泄漏检测覆盖
⇒ 重复断言违反铁律 170，且增加维护面。
⇒ 只挑「用户可感知且无其它守卫」的 3 条。

## Consequences

**★ 这条判据是可迁移的**

```text
凡是用 `src.substring(idx, idx + N)` 取源码片段的判据，
都要问一句：**目标代码落在前 N 个字符里吗？**
若答案只是「目前是」，那它是运气型正确。

⇒ 优先用：正则定位到函数边界 / 大括号配对 / AST
⇒ 若必须用固定窗口（很长的函数体），把窗口值与
  「目标代码的偏移」一起写进注释，并说明余量。
```

**顺带：新发现的一条恒真断言**

`test/provider_layout_test.dart:91` 用**全文件**扫
`maxLines: 1 + ellipsis`，而该 pattern 在 `settings_page.dart`
全文件命中 **6 处**、`_nameRow` 方法体内只有 **1 处**
⇒ 删掉名称行那处后断言**仍绿** ⇒ 它守不住它声称要守的东西。

⇒ 改成 `_nameRow` 局部窗口 + 恰好 1 处（注入验证：删掉名称行 ⇒ `<0>` 红）。
★ 独立实现了 `_balancedBody`，**没有 import 那个测试文件**（铁律 170）。

**★ 复核的一次自我披露值得记**

```text
他第一版写注入脚本时用了全角 `①` 做 Python 注释 ⇒ SyntaxError
⇒ 计数断言**根本没加上**，但测试仍显示 `+3 All tests passed!`
⇒ 差点把「注入没生效」读成「加了也没问题」。
★ 判据：注入后**必须确认 diff 真的有改动**，再看测试红不绿。
  「测试通过」在「注入没生效」与「注入生效且判据有效」两种情形下
  长得一模一样。
```

**已知上限**

```text
· `_balancedBody` 不处理字符串字面量里的 `{`/`}`
  （如 `const Text('{')`）。当前三个签名下没触发，
  但若将来目标函数里有含花括号的字符串，会提前闭合。
  ⇒ 若真的触发，改为「跳过字符串字面量与注释」再配对。
· `_holdSheetGuard()` 函数体内那处 cancel **无人守** ——
  这**不是**本轮造成的（原来那条全局断言对它也是恒真），
  是现存缺口。待补一条针对它的局部窗口判据。
```

**何时该翻案**

```text
· 若本仓引入 Dart analyzer 的 AST 访问（本仓已在别处做过），
  这两条正则判据可改为 AST 判据 —— 那才真正与写法无关。
· 若 `_balancedBody` 的字符串字面量问题真的触发，按上面「已知上限」处理。
```