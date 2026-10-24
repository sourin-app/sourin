# Agent Note: 直播内嵌播放器的静音意图与播放页不变量收紧

Status: implemented

本篇与既有直播笔记的关系：接在 [Shell 直播播放快照交接](2026-10-23-live-shell-playback-handoff.md) 之后——那篇解决"路由返回时拿不到播放状态"，本篇解决"拿到状态后如何在内嵌播放器里保住用户意图，并让往返/释放各自可观测"。两篇为**部分重叠**：本篇新增静音意图分离与三条回执，未推翻快照交接的决定，故两篇都保留、不归档。

## Problem

直播内嵌播放器（`lib/ui/widgets/live_embedded_player.dart`）有三个互相牵连的问题：

**① 隐藏期间必须静默，但"用户想要的音量"不能丢。** 内嵌播放器在页面切走 / 全屏接管时保持存活但不可见。原实现把"不可见"直接等价成"音量压 0"，而静音快照 `_volumeBeforeMute` 与隐藏前的音量 `_volumeBeforeHide` 混在一起用，恢复时取到 0 或旧值。

**② 全屏往返要保住用户的暂停意图。** 原实现新建流即 `p.play()`，用户在直播页按了暂停、进全屏再回来，播放状态被重置成"播放中"。且内嵌播放器不向宿主上报"用户主动暂停"，宿主无从得知。

**③ 无法证明原生资源真的释放。** 内嵌 `dispose` 里是 `unawaited(p.dispose())`，State 卸载后看起来"没了"，但没有任何完成回执；路由返回只代表导航结束，不代表退场动画、LivePage 恢复或原生释放完成。

同时播放页有两条既有不变量被这批改动触及：`_onPositionTick` 里"每秒位置分支不得 setState"（防每 tick 重建整页），以及 `_seekBy` 的"用户 seek 必须紧跟预取让路 `_beginPrefetchYield()`"。

## Decision

**静音与音量分离成两个概念。** `desiredVolume` 表示"用户期望的音量"，与"当前是否因不可见而临时压 0"分开：隐藏时下发给原生的仍是 0，但 `_volumeBeforeMute` / `_volumeBeforeHide` 保留用户意图。`setVolume` 在 `next > 0` 时更新 `_volumeBeforeMute`，不可见时更新 `_volumeBeforeHide`，下发给原生的是 `_visibleNow ? next : 0`。`toggleMute` 取消静音时把恢复目标写回 `_volumeBeforeMute`（`restore.clamp(1,100)`），**不再置 null**。

这条取代了既有结构约束 V7「快照用完即清」：新不变量是"快照保留的是用户期望音量，不是一次性状态"，因为取消静音后用户可能再次静音，需要同一个期望值。

**用户暂停意图经共用入口上报。** 底栏 `onTogglePlay` 与探针调用同一个 `runLiveUserPlaybackToggle`：先 `await` 原生 `pause()`/`play()`，成功后才 `onUserPause`。命令失败则不发布意图（避免 UI 显示已暂停但原生仍在播）。

**新增三条只读回执（仅探针消费）：** `LiveRoundtripReceipt`（分别记录 `routeReturnedAt` 与 `restoredAt`，不合成单个布尔）、`LiveEmbeddedDisposalReceipt`（实例 id、`started`、`hadNativePlayer`、`completedAt`、`error`、`stackTrace`，保持 `State.dispose` 同步返回）、以及 `applyPlaybackSnapshot(..., restorePlaying:)` 让恢复播放与恢复音量/静音分开控制。

**播放页两条不变量的处理：**
- `_seekByUser(target)` 同步做 `_introSkipped = true`、`_pendingSeek = null`、`++_seekToken`，再返回原生 seek Future；`_seekBy` 里 `_seekByUser(clamped)` 之后**紧跟** `_beginPrefetchYield()`。该次序是不变量，测试锚点随之改为 `_seekByUser(clamped)`。
- `_onPositionTick` 的"每秒位置分支不得 setState"**保留**；新增的故障恢复清横幅是**受严格约束的例外**：需同时满足 `_playbackFailure != null`、`_sawFirstFrame`、`playing`、`!buffering`、`p > _position`、单次推进 ≤ 2 秒，且累加 `_recoveryProgress`（普通字段，不触发重建）满 3 秒才 `setState` 一次。清完即走 else 分支，不可能每 tick 重建。

## Alternatives considered

- **把 `_playbackFailure` 改成 `ValueNotifier` 以彻底避开 setState**：最"纯"，能让 `_onPositionTick` 完全不碰 setState。但 `_playbackFailure` 是页面级状态、一次性的 UI 变更，为它引入 notifier 会增加一层生命周期与监听管理；且本批范围是修缺陷不是重构播放页状态层。放弃，作为后续重构项保留。
- **直接删掉 V6/V7 两条结构约束**：迁移最省事。但 V6（静音分支必须先抓快照再压 0）守的是真实缺陷——顺序反了就抓不到原音量，静音再取消会恢复到 0。放弃。改为换锚点（`p.state.volume` → `desiredVolume`）并保留判定。
- **把 setState 提到 3 秒阈值判断之外**（每 tick 都 setState）：能让横幅更快消失，但直接违反"每秒位置分支不得 setState"，会造成整页每 tick 重建。放弃。
- **用 `Navigator.push` 的返回值当"往返完成"信号**：简单，但 pop 结果到达 ≠ 退场动画结束 ≠ LivePage 恢复完成 ≠ 原生释放。三件事必须分别可观测。放弃。
- **给内嵌 dispose 加超时兜底而非回执**：能防卡死，但仍无法证明"何时完成、是否报错"。放弃，改为回执 + 错误/堆栈保留。

## Consequences

隐藏期间静默且不丢用户音量；全屏往返保住暂停意图；原生释放与路由返回各自有完成回执可查。播放页两条不变量都还在，其中一条变成"不变量 + 一个双条件约束的例外"。

代价与边界：

- `_volumeBeforeMute` 不再清空，因此"同一字段承担两种职责"的风险由 `desiredVolume` 的取值链承担：`_volumeBeforeMute ?? _volumeBeforeHide ?? state.volume ?? UiPrefs 偏好`。⚠️ 实测该链条在 `_player` 非空时**终止于 `state.volume`**，`UiPrefs` 持久化音量实际几乎不生效——这是已知缺口，未在本批修（会改变默认音量语义），单独记录待办。
- `LiveEmbeddedDisposalReceipt.instanceId` 标识的是 **State 持有的回执实例**，不是底层原生句柄；同一 State 重建原生 Player 时无法区分。需要原生级标识才能覆盖该场景。
- `onUserPause` 的原生 `p.pause`/`p.play` 绑定只有**源码契约证据**；`State.dispose` 的行为用例走的是**无原生播放器**路径（`stream: null`）。这些都不是原生播放证据。
- 实际音频输出（WASAPI loopback 或等效）**没有任何采集入口**，属环境级缺口：即使三条回执齐备，也只能证明"状态与时间窗"，不能证明"声音真的停了"。批末实机验收必须如实区分这两件事。

## Verification

全部 `--run-skipped --concurrency=1`，先 `export PATH="/c/Users/iuuuuuuuu/flutter/bin:$PATH"`：

- 五文件串行：`+108: All tests passed!`，退出码 0（`.probe/regress-live-after.log`）。
- 五条故障注入**全部退出码 1**（`.probe/regress-live-inject.log`）：
  - `MUTE_ORDER_EXIT_CODE=1` —— 把 `await p?.setVolume(0)` 提到抓快照之前，V6 顺序 + 汇总同时失败；
  - `ESC_ORDER_EXIT_CODE=1` —— 把 `else if (_zoomOpen)` 移到 `_settingsOpen` 之前，`player_capability ★` 与 `t78 ③` 同时失败；
  - `PREFETCH_ANCHOR_EXIT_CODE=1` —— 打断 `_seekByUser(clamped)` 与 `_beginPrefetchYield()` 的紧邻关系；
  - `OVERLAY_THRESHOLD_EXIT_CODE=1` —— 把横幅恢复的 setState 移出阈值判断；
  - `DISPOSAL_UNAWAITED_EXIT_CODE=1` —— 把销毁回执的 `await disposeNative()` 改回 `unawaited(...)`。
  每条注入后均恢复原状并复跑绿。
- Leader 独立全量复跑 19 个回归文件：**275 项通过、退出码 0**（`.probe/lead-r9-final2.log`）。

**以上均为专项测试证据，不替代实机验收。** 真实客户端的暂停/全屏往返、静音与音量、快速切台、双播放器音频释放仍未验收。
