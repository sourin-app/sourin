# Agent Note: R5「音量恢复」在 flutter_tester 里不可判定 —— 门禁只能钉结构

Status: implemented

Independent: 与
[门禁的四种「范围形态」](2026-10-20-gate-scope-shapes-unrendered-inventory-replica-constant.md)
互补：那篇讲「断言是真的、注入会红，但钉的对象不是产品」；本篇讲
**被测对象在测试宿主里根本不可观测**——无论判据怎么写都不可能有行为层读数，
所以门禁只能退到结构层，且**必须把边界写进文件头**，不许用绿冒充行为成立。

## Problem

Owner 1009 的第三句：「再次点击 静音图标……必须拖音量条才恢复」。
期望行为是：再点一次静音图标，音量回到**静音前那个值**（快照 → 偏好 → 兜底三级瀑布）。

我先按行为层写了两条 `native-media` 用例：挂真 `LiveEmbeddedPlayer`，等播放器建出来，
`await state.toggleMute()`，然后读 `state.volume`。三轮实测全部失败，且失败原因不是断言：

```text
① 直接 await toggleMute()（fake-async）：两条用例各撞 **5 分钟**超时。
   日志停在 `[LIVE] 静音按钮被点击…` 之后不再前进 —— 卡在 `await p.setVolume(...)`。
② pumpWidget 放进 runAsync（AGENTS §8）+ 轮询改用 runAsync：
   红色变成 `MissingPluginException(No implementation found for method
   VideoOutputManager.Create on channel com.alexmercerind/media_kit_video)` ——
   `VideoController` 在 flutter_tester 里没有平台实现，异常走 Completer 变成
   zone 级 unhandled error，`takeException()` 都接不住。
③ 裸 `Player()`（真 libmpv 2.dll）+ `t.runAsync` 里 `setVolume(37)` / `setVolume(0)`：
   `done=false`（3 秒后仍未完成），`p.state.volume` **始终 100.0**。
   `Player.dispose()` 同样不完成，用例最后撞 90s 超时。
```

仓内既有门禁 `test/zz_t66_r5_live_mute_default_test.dart` 的文件头记录了同一结论
（它因此只钉 `muted` 标志）。⇒ 「音量真的变成 37」在 flutter_tester **结构性不可判定**，
不是判据写得好不好的问题。

## Decision

落一个**结构门禁** `test/zz_t66_r5_mute_restore_structure_test.dart`（+10），
钉 `toggleMute()` 实现的五条约束，并在文件头明写「行为层不可测、真音量归真机」：

```text
① 三级瀑布顺序：_volumeBeforeMute → dsh.playprefs.lastVolume → 兜底 100（顺序不能反）
② 取消静音**不得** `setVolume(100)` / `setVolume(0)`（Owner 的 bug 正是回到 100）
③ 先下发、后翻 _muted（setVolume 抛异常时 UI 不许显示「有声」）
④ 静音分支先抓 `p.state.volume` 快照、再 `setVolume(0)`
⑤ 快照用完即清，且清在下发之前（否则第二次静音拿过期值）
```

做法是「抠函数体 + 纯函数规则」：`codeOnly()` 先剥 `//`、`/* */`（本仓踩过
「匹配到注释里的示例代码 ⇒ 假通过」），`toggleMuteBody()` 按大括号配对（跳过字符串内括号）
抠出实现，`violationsIn(body)` 返回违规代码。**防空转靠夹具**：1 份 GOOD + 6 份各违反一条
的 BAD 样本，逐条断言「BAD 必须被点名、GOOD 必须干净」——规则或解析器坏掉立刻红，
不会恒绿。真源码那条最后跑，断言违规为空。

## Alternatives considered

**A. 保留行为层用例，标 `skip:` 并在理由里写「tester 不可测」。**
最强理由：终归留了一个就绪的骨架，真机环境接上就能跑。
否决理由：skipped 不产生读数，`flutter test` 一屏绿里夹一条 skip，下一个人只会看到绿；
本轮我已两次被「宣称 N 条 ✓」的台账伤到，不再制造同类计数噪声。用例删掉，结论写进文件头。

**B. 给 `LiveEmbeddedPlayerState` 加一个 `@visibleForTesting` 的音量注入缝（假 Player）。**
最强理由：能真正测「瀑布 + 顺序」，而且 UI 层完全可控。
否决理由：那是**产品代码改动**，本轮职责是门禁（且该文件归 r6b-live）。缝一旦存在，
测的就是「假 Player 的语义」；若没人保持缝与真 Player 一致，又会退化成同构副本。
→ 作为建议写进笔记，未实施。

**C. 只写「真机判据」文档，不落自动化门禁。**
最强理由：最诚实，不假装覆盖。
否决理由：降级路径（把 100 写回去、把顺序调反、删掉偏好一级）在 tester 里**恰恰是可判的**
——它们都是结构改动。结构门禁能在这三条上真红（已注入验证），比零门禁强得多。

**D. 断言 `player_page.dart` 的 VOD 侧瀑布（`_volumeBeforeMute` → `_lastVolume*100`）。**
最强理由：VOD 侧实现同构，测它就等于测了两处语义。
否决理由：Owner 报的是**直播页**；VOD 侧一直是好的，测对的代码不能替换坏的那处。

## Consequences

- 读数（主树）：`flutter test test/zz_t66_r5_mute_restore_structure_test.dart --concurrency=1`
  ⇒ `+10 All tests passed!`。
- 注入读数（worktree `/d/tmp/r66-r5` = HEAD `83e86e1`，注入后 `flutter analyze` 无 issue，
  还原后 `sha256[:16]=b5e2d9373d754f00` 回基线、`git status` 只剩 pub 生成的 registrant）：
  ```text
  INJ1 `setVolume(restore.clamp(1, 100))` → `setVolume(100)`        ⇒ +7 -3
       红：「不得下发写死的常量音量」「violations 为空」「覆盖边界（clamp 不在）」
  INJ2 unmute 分支 setState 提到 setVolume 之前                      ⇒ 红 2 条
       红：「先下发、后翻 _muted」「violations 为空」
  INJ3 删掉偏好一级（dsh.playprefs.lastVolume）                      ⇒ 红 2 条
       红：「三级瀑布顺序」「violations 为空」
  ```
- ⚠️ 覆盖边界（写进文件头 + 一条「覆盖边界」用例盯住）：
  本文件**不**覆盖运行时音量真值；默认静音那一半由
  `zz_t66_r5_live_mute_default_test.dart` 覆盖（用例断言它仍存在且仍记录 setVolume 不完成）。
- ✅ 真机判据（交给 Owner/设备侧，不属自动化）：
  `静音 → 音量条拖到 37 → 再点静音图标 ⇒ 底栏音量条回到 37`；
  `冷启动（默认静音）→ 第一次点图标 ⇒ 回到偏好 dsh.playprefs.lastVolume`（未设过则 100）；
  `再点第二次 ⇒ 回到上一个非零值，不是 0`。
  逐条看 `AppLog` 的 `静音按钮被点击：_muted=… volume=…` 与 `取消静音 ⇒ 音量还原到 N`。
