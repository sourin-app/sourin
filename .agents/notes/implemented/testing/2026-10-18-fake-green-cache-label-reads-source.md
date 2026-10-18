# Agent Note: 缓存文案门禁读源码，分支写反仍全绿

Status: implemented

> 同域：本篇是「假绿」的一个实例。总原则见
> [2026-10-12-gates-must-be-able-to-fail.md](../process/2026-10-12-gates-must-be-able-to-fail.md)；
> 另外两种形态见
> [2026-10-18-gate-reads-worktree-not-blob.md](./2026-10-18-gate-reads-worktree-not-blob.md)（测错了对象）
> 与 [2026-10-18-gate-locked-api-name-not-invariant.md](./2026-10-18-gate-locked-api-name-not-invariant.md)（锁了实现细节）。

## Problem

`test/zz_t66_mpv_cache_ui_test.dart` 原有 9 条断言，**全是 `src.contains`**：

```dart
expect(src.contains('_mpvBytes > 0'), isTrue)
expect(src.contains("'0 B'"), isFalse)
expect(src.contains('humanBytes(_mpvBytes)'), isTrue)
```

这组断言能证明「这些字符出现在源码里」，**证明不了分支方向是对的**。

### 实证：注入后测试仍全绿

我把三元表达式的两个分支**写反**（真的改了代码、真的跑了测试）：

```dart
// 写反后
_mpvBytes > 0
  ? '不占磁盘…'
  : '${humanBytes(_mpvBytes)} · 仅不可 seek…'
```

后果：

```text
0 字节时   显示「0 B · 仅不可 seek 的流会落盘」
>0 字节时  显示「不占磁盘（网络流在内存里缓存）」
```

**用户看到的信息完全相反** —— 正是该测试文件开头自己描述的那个坑。

而注入后：

```text
dart analyze  ⇒ 0 error
flutter test  ⇒ +5 All tests passed
```

缺陷完整逃逸。`src.contains` 在这时全部为真，因为那些字符确实还在源码里，
只是位置换了。

## Decision

**把文案抽成顶层纯函数，断言读它的返回值。**

```dart
String mpvCacheLabel(int bytes) {
  if (bytes <= 0) return '不占磁盘（网络流在内存里缓存）';
  return '${ClipDownloader.humanBytes(bytes)} · 仅不可 seek 的流会落盘';
}
```

测试改成断言**真实结果**，并补上反向断言：

```dart
// 正向：有值时显示字节数
mpvCacheLabel(1536) 含 KB 且含「不可 seek」
// 反向①：0 字节时不许出现 '0 B'
mpvCacheLabel(0)    不含 '0 B'
// 反向②：有值时不许说「不占磁盘」   ← 改前漏掉的正是这条
mpvCacheLabel(4096) 不含 '不占磁盘'
```

**must**：反向断言必须成对存在。
只断言「0 字节时说对了」是不够的 —— 分支写反时那句话仍然「说对了」，
只是说在了错误的分支上。**必须有「有值时不许说不占磁盘」这一半**，
才能把方向锁死。

## Alternatives considered

- **保留 `src.contains`，再加几条检查字符顺序** — 不用抽函数，改动小。
  否掉：那是在用字符串位置猜控制流，任何格式化、提取变量、加注释都会
  让它失效或误报。而且它测的仍然不是「用户看到什么」。
- **把文案抽成函数，但只在测试里重建一份实现** — 不必改生产代码。
  否掉：那就是「测了一份复制品」，复制品与生产实现会各自漂移，
  典型的假绿温床。
- **用 golden test 截图比对** — 能覆盖真实渲染，最接近用户所见。
  否掉：为一句文案引入 golden 基础设施成本过高，且文案变化频繁时
  要不断更新基准图，噪音大于收益。纯函数返回值已经足够锁住语义。
- **只在 0 字节那条加反向断言** — 改动更少。否掉：单侧断言挡不住
  「分支互换」这个具体故障（互换后两个分支各自的文案都「正确」，
  只是挂错了条件）。必须两侧都断言。
- **不抽函数，改成 widget test 真渲染再断言文案** — 最真实。
  否掉：这条 UI 在设置页深处，起一个完整 widget 树需要大量桩；
  文案本身是纯函数级别的事实，用纯函数测最直接。

## Consequences

- **收益**：这条门禁第一次真正具备判别力。故障注入证明：分支写反后
  **+2 -3**（3 条红），还原后 **+5 全绿**。
- **收益**：`mpvCacheLabel` 成为可独立测试的纯函数，文案逻辑与 widget
  生命周期解耦。
- **收益**：确立了一条可复用的判据纪律 —— **门禁要读真实结果，
  不能读喂进去的那个值**。同仓其它 `src.contains` 型断言可照此改造。
- **代价**：生产代码多了一个顶层函数（`playback_page.dart` 内），
  需要它不依赖 BuildContext 才能保持纯函数性。
- **代价**：反向断言让测试对文案措辞更敏感 —— 以后想改「不占磁盘」的
  表述，必须同步改测试。这是**有意**的：措辞就是用户可见行为。
- **未做**：没有全仓排查其它 `src.contains` 型断言。
  重访信号：又出现「测试全绿但行为明显错」时，先查该测试是否只断言了源码文本。

## Verification

**撤销验证（证明新门禁真有判别力）**：

```text
注入：三元分支写反
  ⇒ dart analyze 0 error
  ⇒ flutter test **+2 -3**
      ① 0 字节时不许显示 "0 B"                     FAILED
      ② 0 字节时必须如实解释原因                     FAILED
      ③ 有值时必须显示字节数，且标签语义正确          FAILED

还原
  ⇒ 0 error
  ⇒ **+5 All tests passed**
```

关键是注入后 `dart analyze` **仍是 0 error** —— 说明这是纯逻辑错误，
编译器抓不到，只有断言能抓。而旧断言抓不到它。
