# Agent Note: 框架断言不是 throw —— 第三种「仪器恒真」

Status: implemented

Independent: 与本仓其它 testing 笔记不同 —— 那几篇讲**判据本身**对不对
（[恒绿断言的四种形态](../testing/2026-10-19-four-shapes-of-always-green-assertions.md)、
[固定字符窗口](../testing/2026-10-19-source-scan-judge-should-not-use-fixed-window.md)、
[DLL 漂移静默测旧代码](../testing/2026-10-19-dll-drift-silently-tests-old-code.md)、
[红测试的三种成因](../testing/2026-10-19-three-causes-of-a-red-test.md)）。
本篇讲一个更基础的东西：**怎么判断「它报错了」** ——
而它在 Flutter 里有一个专门的陷阱。

## Problem

R4 排查中发现一条机制（已由复核真跑复现）：

```text
AppGlassDialog 里放 TextField ⇒ 抛：
  "No Material widget found.
   TextField widgets require a Material widget ancestor
   within the closest LookupBoundary."
```

队友的第一版探针这样写：

```dart
try {
  await t.pumpWidget(<无 Material 祖先的 TextField>);
  await t.pump();
} catch (e) {
  caught = e;
}
// ⇒ 实测 caught = null
```

★ **他差点据此判成「不抛异常」**，理由是「读数是 null，说明没异常」。

## Decision

### Flutter 的「错误」分两类，抓法不同

```dart
// ❶ 同步 throw（如 StateError）⇒ try/catch 抓得到
try { ... } catch (e) { caught = e; }        // ✅

// ❷ framework assertion（build/layout 阶段上报的 FlutterError）
//    ⇒ 它**不是 throw** ⇒ try/catch 抓不到
await t.pumpWidget(<同上>);
await t.pump();
final err = t.takeException();                 // ✅ FlutterError("No Material widget found.")
expect(err, isNotNull);                        // ★★★ 必须断言非空！
```

**四种方法的实测对照**（复核跑的）：

```text
① try/catch 抓到        = Null          ← 恒 null ⇒ 假绿
② takeException         = FlutterError
② 首行                  = No Material widget found.
③ 同步 throw 抓到       = StateError     ← 与 ① 对照，证明 ① 的写法本身没坏
④ 连续取到 1 个异常
```

### ★ 一次可能抛多个 ⇒ 循环取空

```dart
var n = 0;
Object? e;
while ((e = t.takeException()) != null) {
  n++;
  if (n > 5) break;   // ★ 别写成死循环
}
```

## Alternatives considered

**A. 读测试输出里的 `EXCEPTION CAUGHT BY WIDGETS LIBRARY` 段。**
最强理由：人眼能看见。
否决理由：**不能机器读**。门禁要判「有没有出错」，
靠读输出就退回了「人眼看日志」—— 而 CI 里没人看。

**B. 用 `expect(..., throwsA(...))`。**
最强理由：标准写法。
否决理由：**它只对 ❶ 同步 throw 有效**，对 framework assertion 无效
⇒ 用它反而会得到「通过」的假象。

## Consequences

**★ 这是本会话的第三种「仪器恒真」形态**

```text
① `b<32` 的 grep 查不到 U+FFFD（工具不支持那个码位）⇒ 安静地报「没有」
② 注释锚点误匹配（特征串不够唯一）⇒ 报了个不相干的位置，看着像对的
③ ★ framework assertion ⇒ try/catch 读数恒 null ⇒ 报「没异常」
⇒ 共同点：**探针会安静地报「没问题」**，而问题就在那儿。
```

★ 判据：**任何「没找到 / 没发生」的读数，都要先问一句
「我的工具**能**找到它吗」**，再问「它真的不在吗」。

**★⚠️ 另一半的陷阱（本条与 ❷ 同样重要）**

```dart
final err = t.takeException();
expect(err, isNotNull);   // ★★★ 这一行不能省
```

`takeException()` 在没有异常时返回 `null` —— 若只写
`if (err != null) fail(...)` 之外的用法、或干脆不消费返回值，
就会得到「没异常 ⇒ 通过」的结论
⇒ **恒真又回来了，只是换了个方向。**

**★ 顺带：这类错误会以测试输出的形式出现在 CI 日志里**

```text
EXCEPTION CAUGHT BY WIDGETS LIBRARY ……
⇒ 人眼在日志里能看见，但**程序里的 try/catch 看不见**
⇒ 判「有没有出错」必须机器读，不能靠读输出。
```

**已知上限**

```text
· `takeException()` 只捕获**最近一次**未消费异常 ⇒ 顺序敏感，
  所以上面给了「循环取空 + 上限」的写法。
· 有些错误两者都不报（例如断言在 `expect` 里失败时），
  那类要靠 `flutter test` 的退出码，不要指望异常对象。
```

**何时该翻案**

```text
· 若本仓引入集成测试框架（integration_test）或 golden 测试，
  错误的上报路径可能不同 ⇒ 重新核实这两个 API 是否仍适用。
· 若 Flutter 未来把 framework assertion 改成 throw，
  ❷ 会变成 ❶ ⇒ 那时 `try/catch` 就够了，但**两种写法都保留更安全**
  （因为 ❶/❷ 会共存于相当长一段时间）。