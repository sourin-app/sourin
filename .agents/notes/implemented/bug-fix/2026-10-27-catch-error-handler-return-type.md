# Agent Note: `catchError` 的 handler 返回类型必须与 future 的元素类型一致

Status: implemented

## Problem

批末实机验收抓到 **10 条未捕获异常**，全部同一条：

```text
「Invalid argument(s) (onError): The error handler of Future.catchError
   must return a value of the future's type」
```

真凶（`lib/shell.dart` 的帧日志 flush）：

```dart
unawaited(
  f.writeAsString(chunk, mode: firstWrite ? FileMode.write : FileMode.append)
   .catchError((Object e) {
      /* 落盘失败不致命 */
   }),          // ← handler 返回 void
);
```

`File.writeAsString` 返回 **`Future<File>`**，而 handler 返回 `void`
⇒ **元素类型不符** ⇒ 运行期抛上述 `Invalid argument(s)`。
结果是**每次 flush 的失败路径都冒一条未捕获异常**。

★ **为什么它能藏这么久**：这条只在**失败路径**上抛，而正常跑不会走到；
且**生产默认不开帧日志仪器**（`SOURIN_FRAME_LOG=1` 才开）
⇒ **用户侧完全看不到**，只有跑验收仪器时才暴露。

## Decision

**修法：先把元素类型映射掉，再 `catchError` 返回该类型的值。**

```dart
unawaited(
  f.writeAsString(chunk, mode: firstWrite ? FileMode.write : FileMode.append)
   .then<Object?>((v) => v)
   .catchError((Object e) {
      /* 落盘失败不致命 —— 返回 null 与 Future<Object?> 的元素类型一致 */
      return null;
   }),
);
```

**排查结论（全仓逐个核过，只有这一处是真缺陷）**：

```text
app_log.dart:183/:389        _append / _flushBuffer 都是 `Future<void>` ⇒ void handler 合法
player_page.dart:1126/:13617/:15520    endYieldForSeek / setFullScreen 都是 `Future<void>` ⇒ 合法
my_shelf.dart ×3             `.then<Object?>((v) => v)` 后 handler 返回 null ⇒ 已是对的
live_groups_page.dart:859    本地 `unawaited(Future<void> f)` ⇒ 合法
⇒ **只有 shell.dart 那一处**（`Future<File>` + void handler）。
```

**一条通用判据（可直接拿去扫别的仓）**：

```text
`<Future<T>>.catchError(handler)` 的 handler **必须返回 T 类型的值**（或抛）。
· T == void   ⇒ `(e) {}` 合法（最常见，也是大多数处没问题的原因）
· T != void   ⇒ `(e) {}` **运行期抛**，且**编译期不报**（返回 void 的闭包可赋给任何
                 `Function(Object)` 形参）⇒ **静态分析抓不到，单测不走到失败路径也抓不到**
⇒ 自查口径：`grep catchError -B2` 看**链上那个 future 的元素类型**，不是看 handler 写得好不好。
```

## Alternatives considered

- **`ignore: unawaited_futures` / 直接 `unawaited(...)` 不挂 catchError** ——
  它最强的论据是**根本不会踩这个类型坑**（不写 handler 就没有 handler 返回值这回事）。
  否决理由：这条链是**仪器的后台落盘**，失败时若不吞，未捕获异常照样进日志、照样污染验收读数；
  且"不吞"会把一个**不致命的落盘失败**升格成异常噪声。⇒ 要吞，但**吞得类型正确**。
  （对照：`app_log.dart` 的 `unawaited(_append(line).catchError((Object _) {}))` 之所以对，
  是因为 `_append` 返回 `Future<void>` —— 差别在**元素类型**，不在写法。）

- **改成 `async/await` + `try/catch`** ——
  它最强的论据是**不用想类型**（`try/catch` 没有返回类型约束，也不会被遗漏）。
  否决理由：这是 `flush()` 同步返回路径里的**"发射后不管"**调用；
  改成 `await` 会把它变回同步等待（正是这段注释开头引以为戒的"原 `writeAsStringSync` 阻塞 UI isolate"）。
  若要 async 就得包一层 `async` 辅助函数 —— 收益不抵改动面。
  ⇒ 保留 `.then<Object?>` 的写法（与本仓 `my_shelf.dart` 三处**同款**，是一次**复用既有形状**）。

  ★ **补一条先例（复核者 tvbox-rust 核验时查到，我原先不知道）**：
  `grep -rn "then<Object?>((v) => v)" lib/` ⇒ `my_shelf.dart:661/667/673` **三处**，
  且**在 HEAD 里就已存在**（不是本批新增）⇒ **这个坑本仓早已有人踩过并留了正确先例**，
  我这次是**独立重新发现**了同一个修法。⇒ 结论：**修之前先 grep 一下仓内有没有同形状的正确写法可抄**，
  比从原理推导更快也更一致（本条已按此复核过）。

- **只在验收脚本里不设 `SOURIN_FRAME_LOG`（绕过现象）** ——
  它最强的论据是**零代码改动**，且生产本来就不开这个 env。
  否决理由：那等于**把一条真缺陷藏起来**，而且代价具体：验收就少了帧读数这一格
  （本批稳态帧读数正是靠 N7 专项探针补的）。⇒ 修根因，不修现象。

## Consequences

- **收益**：批末验收读数从 **unhandled=10 → 0**（有归因实验与两轮对比，见 Testing）。
- **收益**：留下一眼可判的自查口径 —— **看 future 的元素类型**，而不是看 handler 写得整不整齐。
  这类缺陷"**编译期不报、正常路径不抛、只在失败路径 + 仪器开启时暴露**"，
  正是最需要写成判据而不是靠记住的一类。
- **代价**：`.then<Object?>((v) => v)` 多一次 future 映射（分配开销可忽略，且在诊断仪器里）。
- **边界**：本条只管 `catchError` 的**返回类型**。
  "异常是否该在这个上下文被吞"是另一件事，见
  [2026-10-19-selfaudit-found-four-real-defects.md](2026-10-19-selfaudit-found-four-real-defects.md)
  （那篇讲的是"要盯异常真正逃逸的那个上下文"，与本节同源但不同层）。
- **重访条件**：若本仓给仪器日志换实现（例如统一走 `AppLog`），本节那条
  `shell.dart` 的修法可能被替代 —— 届时保留"类型必须一致"的判据即可。

## Testing

**归因实验**（`.probe/accept-attr-framelog.sh`，ON/OFF 对照，证明真凶就是这一处）：

| case | `SOURIN_FRAME_LOG` | unhandled |
| --- | --- | --- |
| frameLog_ON | `1` | **3** |
| frameLog_OFF | `0` | **0** |

**两轮验收对比**（`.probe/accept-run.sh`，产品入口 `lib/shell.dart` + 隔离数据目录）：

| 项 | 第 1 轮 | 第 2 轮（修后） |
| --- | --- | --- |
| 构建 | EXIT=0 | EXIT=0 |
| `app.so` | 12,108,680 B | 12,108,680 B |
| **未捕获异常** | **10** | **0** |
| 首帧标记 | 1 | 1 |
| 真实数据目录未写 | ✓（mtime 09:46 < 12:02） | ✓（< 12:13） |

产物：`.probe/accept-{20261027-120258,accept-20261027-121337}/`、`.probe/batch-end-acceptance.md`。

★ 修这处时我自己**二次踩了"块注释可嵌套"**（在注释里复现 `/* … */` 原文 ⇒
整份 `shell.dart` 报 `Unterminated multi-line comment` + 一串假的 undefined 错误 ⇒ 构建失败）。
同一个坑在本批 `settings_page.dart` 已踩过一次并写进
`.probe/t66-scanner-blockcomment-scope.md`。⇒ 实证：**写"改前长什么样"时不要复现 `/*` 与 `*/`**。

## 核验（复核者 tvbox-rust 独立只读复跑，记录在 `.probe/t7-catchError-claim-verify.md`）

本条三条主张**逐条独立成立**：
```text
① 归属既存        ⇒ `git show HEAD:lib/shell.dart` 该段逐字相同 ✓
② 修法正确        ⇒ 类型自洽；且查到上面那条仓内先例 ✓
③ 「全仓只有这一处」⇒ 复核者**按全称断言对待**：全仓 26 处 `.catchError(`，
                    逐个查 9 处 "void handler 作用在非 void future" 候选的**真被调函数签名**
                    （含从 `package_config.json` 的 rootUri 挖出 window_manager 真实路径
                     去读 `Future<void> setBackgroundColor`）⇒ **无第 4 处漏网** ✓
```
★ 复核者还自纠两次自己的核实失误并记录：`grep -A 3` 窗口太窄（原写法跨 5 行）导致误判"HEAD 里没这处"；
以及查外部包签名第一版走错目录（应走 `package_config.json` 的 `rootUri`，不是 `Pub/Cache/git/cache/`）。

Independent: 本篇记录 2026-10-27 批内一次具体改动的决策；已按标题关键词在 .agents/notes 全树检索（同日与相关主题），未发现记录同一决定的笔记，故不构成取代关系。正文未改，仅补声明。
