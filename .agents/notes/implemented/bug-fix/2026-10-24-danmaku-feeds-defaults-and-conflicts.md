# Agent Note: 弹幕来源默认全开、重复集号需显式选择、搜索草稿随播放器会话

Status: implemented

## Problem

总计划第 10 项要求「首次使用默认启用全部受支持来源，并保留用户主动关闭的选择」。改前 `_enabledFeeds` 只是面板内的一个集合，初值只有「本片源自带」，切换仅 `setState` 加回调，既不落任何偏好，也没有默认全开。用户关掉某一路，下次打开又全回来。

第 11 项要求批量绑定前展示映射预览并给出冲突提示、「不静默覆盖已有绑定」。改前 `batch_bind.dart` 用 `byNumber.putIfAbsent(n, () => m)` 按解析集号聚合，同集号的不同 `episodeId` 只留第一条，搜索页也没有任何冲突提示或候选调整入口，确认按钮始终可点。

第 11/12 项还要求「返回播放器后绑定生效」「导航返回不丢搜索与选择结果」。改前关键词、选中集合、预览开关都存在搜索页自己的 `State` 里，而该页由 `player_page.dart` 按 `_danmakuSearchOpen` **条件挂载**，关闭即整棵卸载，草稿随之消失。

与既有决定的关系（部分重叠）：本篇落实 [弹幕面板七项](../feature/2026-10-19-danmaku-panel-seven-items.md) 里「来源选择」那两项的默认值与持久化，并新增重复集号冲突判定；面板分区本身未变。那篇保留、不归档。

## Decision

来源选择改为真实偏好：键 `danmaku.feeds.enabled`，按 `DanmakuFeedChannel.name` 逗号分隔写入 `UiPrefs` 并 `flush`；无记录时默认**四路全开**，「本片源自带」恒在且不可取消。读出时对未知名字做过滤，避免旧版本残留名字把集合撑大。

重复集号改为显式决策：core 新增 `batchBindConflicts`，按解析集号聚合 `distinct episodeId`；搜索预览把冲突候选列出来，冲突未解除时禁用确认按钮，用户选定后只提交其保留的 ID。默认**不再**替用户选第一条。

搜索草稿改为播放器会话持有：`DanmakuSearchDraft`（纯 Dart，`keyword` / `selectedEpisodeIds` / `previewing`）由 `PlayerPage` 的 `State` 持有并传入搜索页；页面 `initState` 从草稿恢复，输入、勾选、预览、确认、结果变化都回写。

## Alternatives considered

- 把 `_enabledFeeds` 继续留在组件内、只做「每次打开全选」：改动最小，但用户主动关闭的选择每次重启都会被推翻，正是第 10 项明确禁止的行为，放弃。
- 用 `static` 全局变量保存搜索草稿：能扛住卸载，但跨视频串味——切到另一部片仍带着上一部的关键词与选中集，且测试之间互相污染，放弃。
- 把草稿写进 `UiPrefs` 落盘：能扛住重启，但把「临时输入」变成「设置项」，用户下次打开播放器会被上一部片的搜索词占住，语义错误，放弃。
- 让搜索页常驻（`Offstage` / `IndexedStack`）以保住页面内状态：能省掉草稿对象，但常驻会让该页持续参与重建与动画计时，与第 13 项的性能目标冲突，放弃。
- 重复集号保持 `putIfAbsent` 取第一条、只在 UI 上加一行提示：改动更小，但用户以为已经选了、实际绑的是别人，属静默错误，放弃。
- 默认只开「本片源自带」再让用户自己勾：最保守，但与第 10 项字面要求相反；`localService` 即使默认开启也不会伪造数据，因为 `_activeFeedChannels` 仍用 `_hasDataFor` 过滤。

## Consequences

首次打开来源面板四路都是勾选态；用户取消某一路后，`UiPrefs` 立刻写入并 `flush`，重建组件、重载偏好后仍保持关闭；旧配置没有该键时按全开处理，不必迁移。

同集号多候选时确认按钮禁用，必须先选一个；冲突解除后只提交所选 ID。代价是批量绑定多一步交互，换来不再静默绑错。

搜索页关闭再打开会恢复关键词、选中集与预览态；草稿跟着播放器会话走，换片即失效。代价是 `player_page.dart` 多持有一个对象并多传一个参数。

证据边界：红测首轮因定位器写错（来源行是自定义 `Icon` 行，不是 `Checkbox`）抛 `No element`／空串，已作废不计红；有效红为 `.probe/danmaku-regressions-red-v2.log`（3 项断言失败，EXIT_CODE=1），修复后 `.probe/danmaku-regressions-green-v2.log` 4 项通过 EXIT_CODE=0；四项故障注入 `.probe/danmaku-fault-{default,persistence,conflict,draft}.log` 均按预期失败且已恢复；最终 `.probe/danmaku-regressions-final.log` 覆盖新回归与既有 search page、batch bind 共 23 项通过、EXIT_CODE=0。Leader 独立串行复跑该文件与另四组共 22 项通过、EXIT_CODE=0（`.probe/lead-r5-final-serial.log`）。这些都是专项测试证据，不替代真实客户端验收：默认全开在真实首启、旧配置迁移、部分来源失败三类场景下仍需实机确认。
