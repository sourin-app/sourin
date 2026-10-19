# Agent Note: 门禁红了，先问「该改门禁还是该改代码」

Status: implemented

Independent: 与本轮其它笔记都不同 —— 那几篇分别讲
[断言钉机制不钉实现](../testing/2026-10-19-assertions-pin-mechanism-not-implementation.md)、
[恒绿断言的四种形态](../testing/2026-10-19-four-shapes-of-always-green-assertions.md)、
[判别式的唯一实现](../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md)。
那几篇讲**门禁本身该怎么写**；本篇讲**门禁红了之后该怎么判断**。

## Problem

批末全量跑报出两条**本轮新引入的红**，成因是我上一步的修复：

```text
zz_t66_prefetch_yield_test ④       红
zz_t66_seek_yield_coverage_test ④   红
```

它们共用一条正则：

```dart
RegExp(r'unawaited\(\s*SourinApi\.endYieldForSeek\(\)\s*\)')
```

它要求 `()` 之后**立刻**闭括号。而我为修「`SourinCoreException` 从
`dispose()` 逃逸」这个**真回归**，把那处改成了：

```dart
unawaited(SourinApi.endYieldForSeek().catchError((Object e) { … }));
```

⇒ `.catchError(` 让正则失配 ⇒ 门禁红。

★ 这是**修好了行为、修坏了断言**。而它有一个极易滑过去的默认反应：
**把门禁改回去，或者把修复改回去。**

## Decision

### 先读门禁自己的注释，判断它钉的是**意图**还是**字面形态**

`zz_t66_prefetch_yield_test:150-156` 的注释写得很清楚：

```text
本门禁第二版仍是恒绿（故障注入 case 4 又抓到）：
dispose 上方的注释里就写着「…调一次 endYieldForSeek()…」
⇒ body.contains('endYieldForSeek()') 命中的是**注释**，不是代码
```

⇒ 它要守的是「dispose 里有**实际调用**，不是注释里提一句」。
`.catchError` **没有改变这个意图**（调用仍在 `unawaited` 里），
所以该改的是**门禁**，不是我的修复。

### 只放宽**尾部**，锚点一个不减

```dart
// 改前
r'unawaited\(\s*SourinApi\.endYieldForSeek\(\)\s*\)'
// 改后
r'unawaited\(\s*SourinApi\.endYieldForSeek\(\)[^;]*?\)'
```

`unawaited(` 与 `SourinApi.` 两个锚点**全部保留**。

## Alternatives considered

**A. 把修复改回去（去掉 `.catchError`）。**
最强理由：门禁是既有的，改它需要理由；改修复只需一个字符。
否决理由：**那个修复是对的** —— `unawaited` 只是"不 await"，
**不等于**"异常被吃掉"；核心未启动时 `SourinCoreException`
会从 `dispose` 逃逸（实测咬红 `zz_cr_panel_double_enter` 与
`zz_cr_panel_notch A③`）。⇒ 改回去就是**为了让门禁绿而重新引入一个真缺陷**。

**B. 把门禁改成 `body.contains('endYieldForSeek')`。**
最强理由：一行搞定。
否决理由：**这正是该门禁第二版恒绿的形态** ——
`dispose` 上方那段注释里就写着「…调一次 endYieldForSeek()…」，
所以 `contains` 会命中注释，判据立刻退化成恒绿。
★ 它的注释里已经记着这个教训，再走一遍等于白读。

**C. 把门禁改成行为判据（注入会抛的 fetcher，dispose 后确认无异常逃逸）。**
最强理由：钉行为最稳，与实现形态完全解耦。
否决理由：**它换掉了门禁要守的东西** ——
原门禁守的是「dispose 里确实调了 endYieldForSeek」（漏了会让路窗口
在销毁时不释放，是资源问题），而行为判据测的是「dispose 不抛异常」
（那已经由 `zz_cr_panel_double_enter` 覆盖）。
⇒ 两条门禁守**不同的东西**，不能相互替代。

## Consequences

**验证（放宽后仍有判别力）**

```text
正则逐例实测：
  原形态 unawaited(...endYieldForSeek());     ⇒ MATCH
  带 catchError（当前）                       ⇒ MATCH
  ★ 只在注释里提一句                         ⇒ NO-MATCH  ✔
  ★ 完全没调用                               ⇒ NO-MATCH  ✔

故障注入：把 dispose 里那处调用整个删掉
⇒ 两条门禁都变红 ✔；还原 ⇒ +11 All tests passed!
```

★ **通则（本篇最该被记住的一句）**：

```text
放宽正则时，**锚点一个都不能少**。
少一个就从「钉意图」退化成「钉字面形态」，
而后者一改代码就红，最终必然被人加例外或注释掉。
```

**★ 这个坑的通用形态**

```text
「我刚修的代码让门禁红了」有三种可能，处理方式完全不同：
  ① 修复错了        ⇒ 改代码
  ② 门禁钉了字面形态 ⇒ 改门禁（但锚点不能减）
  ③ 门禁坏了         ⇒ 改门禁（且要留注入证明它新判据有判别力）
⇒ 判据：**先读门禁自己的注释**。写门禁时通常都写了「为什么这么写」，
  那是区分 ② 与 ③ 的唯一线索。
```

**何时该翻案**

```text
· 若将来这两处 dispose 被重构（例如加一层 `_safeEndYield()` 辅助），
  正则会再失配一次。届时**不要**再放宽一次 ——
  应把这两条判据改成找那个辅助函数的定义与调用点。
· 若 Dart 的 analyzer 将来能给出「这段 dispose 里有哪些未 await 调用」，
  应改用结构化手段，形态变化就不再影响判据。
```