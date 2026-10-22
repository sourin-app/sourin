# Agent Note: 恒真断言要删，不是放宽 —— 以及正则尾部锚 `;` 的脆性

Status: implemented

Independent: 与 [four-shapes-of-always-green-assertions](../testing/2026-10-19-four-shapes-of-always-green-assertions.md)
**是同一纪律的延续**：那篇列举了恒绿断言的**四种形态**，
本篇处理其中一种当时**没被列出来**的形态 ——
**断言本身是对的，但它守的对象不是它以为的那个**。

## Problem

`test/zz_t66_sheettimer_dispose_test.dart` 有一条断言：

```dart
expect(RegExp(r'_sheetGuardTimer\?\.cancel\(\);').hasMatch(src), isTrue)
```

它的意图（从它所在的用例名与上下文看）是**守 `dispose()` 里那处定时器取消**。
★ 但它扫的是**整个文件**，而该调用在源码里有 **2 处**：

```text
lib/ui/player_page.dart
  _holdSheetGuard() 里   一处
  dispose() 里          一处
```

⇒ 删掉 `dispose` 里那处，全局 `hasMatch` **仍为 true**（还剩一处）
⇒ 它根本不是「守 dispose」的判据，而是「文件里至少有一处」⇒ **恒真**。

真正守住 `dispose` 的是**下一条**（`:200`）——它把扫描范围限制在
`dispose` 那一段的 2600 字符窗口里。

复核做了**双向反证**（从两个方向各删一次）：

```text
删 dispose 那处 ⇒ 全局 true，局部 false
删 _holdSheetGuard 那处 ⇒ 全局 true，局部 true（dispose 那处还在）
⇒ 只要两处中任何一处还在，全局就是 true
```

## Decision

### 删掉那条全局断言，只保留局部窗口判据

理由三条，按重要性：

```text
① 恒真的断言比没有断言更糟 —— 它提供**虚假的安全感**
   （读全量读数的人会以为「dispose 有守卫」）
② 改成局部窗口**会与下面那条完全重复** ⇒ 违反「同一纪律只能有一个实现」
   ⇒ 所以正解是**删**，不是改
③ 它还会给人「已覆盖 dispose」的错觉，而实际没有
```

### 顺带去掉两处正则的尾部 `;` 锚

```dart
- r'_sheetGuardTimer\?\.cancel\(\);'          // 多空格 / 改 ?.→!. 都会假红
+ r'_sheetGuardTimer[?!]?\cancel\('             // 认 ?. / !. / .

- r'\n\s*cur\.paint\(canvas, curRect\.topLeft\);'
+ r'\n\s*cur\.paint\(canvas, curRect\.topLeft\)'
```

★ 判别力**未丢**（逐条注入）：

```text
sheettimer  删掉 dispose 那处调用   ⇒ 红 ✔
            改 ?. → !.             ⇒ 绿 ✔（旧正则必红）
            多一个空格              ⇒ 绿 ✔（旧正则必红）
t466        删掉 cur.paint 整行    ⇒ 红 ✔
```

★ 顺带一条**反证**：旧版**局部**判据（带分号）在删掉调用后**也是** false
⇒ 分号对「判倒缺失」毫无贡献，它**只贡献假红**。

## Alternatives considered

**A. 把全局断言改成局部窗口（与 `:200` 那条合并成一条）。**
最强理由：保留「文件里必须有这个调用」这条信息。
否决理由：它与 `:200` **完全重复**（后者已在 dispose 窗口里做了同样的检查）
⇒ 两条断言守同一件事，正是铁律 170 要消除的情况。

**B. 放宽全局断言，让它在「只有一处时仍通过」。**
最强理由：改动最小。
否决理由：**它本来就在通过**（恒真），「放宽」没有意义 ——
问题不是它太严，是它**根本没在守 dispose**。

**C. 7 条全改。**
最强理由：一次性统一。
否决理由：**另外 5 条是计数/配对判据**，去掉 `;` 会改计数基数或破坏配对：
```text
login_prompt:204/205  expect(nKind, nStr) 是**配对相等**
                     ⇒ 必须成对改，单改一条会恒红
计数类（如 ≥13）      ⇒ 去掉 ; 后基数变大，阈值必须同步重算 —— 那是判据变更
```
⇒ 已把 5 条登记进 `plan-round-66.md`，每条注明「去掉 `;` 后必须重算什么」。

## Consequences

**验证（全部实跑）**

```text
两个改动的测试文件 + login_prompt 三文件合跑 ⇒ +22 All tests passed!
sheettimer / t466 单独跑                  ⇒ +13 All tests passed!
analyze 0 error，U+FFFD 0，YAML OK
```

**★ 登记的 5 条待办，每条都带「重算什么」**

这是本篇的**关键交付物** —— 若只写「这里脆，建议改」，
下一个人会照改并踩到阈值变化：

```text
| 文件:行 | 断言形态 | 当前命中 | 去掉 ; 后必须重算 |
| login_prompt:204/205 | 配对相等 | 6（剥注释后） | ⚠️ 必须成对改，单改恒红 |
| 计数类 | greaterThanOrEqualTo | 逐条记录 | 去掉 ; 后基数变大，阈值要重算 |
```

**★ 一条我自己的误报被复核纠正**

```text
我上轮报「login_prompt 的 nStr=7 / nKind=6 不相等」
★ 错：我 grep 了**原始源码**，而那条测试用的是 `codeOnly(player)`（**剥注释后**）
⇒ 剥注释后是 6/6，**配对成立**，那条测试现在是绿的。
⇒ 教训：核一条判据的输入，必须先看**它实际读的是哪一份**（剥没剥注释）。
```

**已知上限**

```text
· `sheettimer:200` 的局部窗口是**固定 2600 字符** —— 若 dispose 函数体
  将来变长超过这个窗口，检查会漏。
  ⇒ 未改成按大括号配对截取（超出本次范围），已登记。
· 那 5 条待办**没做**，所以「7 条里还有 5 条会在语义等价的重写后假红」这个
  事实仍然成立。
```

**何时该翻案**

```text
· 若 dispose 函数体增长，建议把 2600 字符窗口改成按大括号配对截取
  （与 `zz_t66_r3_dns_hijack_test.dart` 里那处 `_addressOf` 的做法一致）。
· 若将来全仓改用某个 lint 框架做源码结构检查，这 7 条正则判据可整体退役 ——
  在那之前，本篇的「只登记不改」比「全改」更安全。
```