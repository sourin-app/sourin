# Agent Note: 弹幕来源默认全开、重复集号显式选择与独立搜索页的草稿归属

Status: implemented

本篇与既有弹幕笔记的关系：接在 [弹幕设置搜索边界](2026-10-23-danmaku-settings-search-boundary.md) 与 [弹幕来源默认与冲突](2026-10-24-danmaku-feeds-defaults-and-conflicts.md) 之后。前者确立了"搜索与选集拆到独立页"的边界，后者确立了来源默认全开与重复集号冲突的判定；本篇补上**草稿归属**与**加载反馈形态**两项，并为第 12 项的诊断区补齐真实可达的补救入口。三篇均为**部分重叠**，全部保留、不归档。

## Problem

第 12 项把「请求」「搜索番剧」「服务端返回」从设置弹窗拆出、搜索与选集迁到独立页 `DanmakuSearchPage` 之后，留下四个缺口：

**① 拆出去的内容没有落点。** 第 12 项原文要求「请求状态与返回详情进入该页的**可展开诊断区域**」，但拆分后该区域并不存在。随之而来的是凭证补救文案（「这是凭证问题。可行的几步（按代价从低到高）…」）从 `lib/` 整体消失——它不是搬家，是被删掉了。

**② 提示悬空。** 原文案依赖「「重新获取弹幕」按钮在「请求」节可达」。请求节被搬走后，提示指向的动作不再可达，正是 `zz_t66_r3_no_dangling_hint_test` 守的「提示不得悬空」不变量被打破。

**③ 搜索草稿随页面卸载丢失。** 关键词、选中集合、预览开关都存在搜索页自己的 `State` 里，而该页由 `player_page.dart` 按 `_danmakuSearchOpen` **条件挂载**，关闭即整棵卸载。

**④ 加载反馈形态改变。** 搜索流程原先用行内小圈 `AppInlineSpinner`，迁到独立页后改为整行 `LinearProgressIndicator`。`zz_t66_app_inline_spinner_test` 守的是"那 5 处**行内**小圈不许退化"，清单里的两处随搜索迁走。

## Decision

**搜索页新增可展开诊断区**，承载请求状态、异常与服务端返回 body。诊断区里两条补救动作接**真实生产入口**：`onReload` → `PlayerPage._loadDanmaku()`（与底栏"重新获取弹幕"同一实现）、`onOpenLocal` → `PlayerPage._useLocalDanmakuSource()`。凭证补救文案按 `onOpenLocal` / `onOpenReload` 的**存在性**生成，不再引用已被有意摘掉的凭证入口，也不再引用旧「请求节」。

**草稿由播放器会话持有。** `DanmakuSearchDraft`（纯 Dart：`keyword` / `selectedEpisodeIds` / `previewing`）由 `PlayerPage` 的 `State` 持有并作为可选参数传入搜索页；页面 `initState` 从草稿恢复，输入、勾选、预览、确认、结果变化都回写。

**来源选择走真实偏好。** 键 `danmaku.feeds.enabled`，按 `DanmakuFeedChannel.name` 逗号分隔写入 `UiPrefs` 并 `flush`；无记录时默认四路全开，「本片源自带」恒在且不可取消。

**重复集号必须显式选择。** core 新增 `batchBindConflicts`，按解析集号聚合 `distinct episodeId`；搜索预览列出冲突候选，冲突未解除时禁用确认按钮，用户选定后只提交其保留的 ID。

**加载反馈形态按现状迁移判据，不硬塞旧控件。** 搜索页保留整行 `LinearProgressIndicator`（在 `searchLoading || b.loading` 时显示），**不**为了凑旧清单往搜索页塞 `AppInlineSpinner`；同时新增断言锁住"在途必须有加载反馈且不许用 `CircularProgressIndicator`"，让"加载反馈存在"这个真正的不变量仍被守住。

**来源页签不做废页。** 第 12 项明确「来源选择移入高级设置」，故四来源行留在高级页签；来源页签保留导航入口 + 只读的启用状态摘要（第 12 项禁的是重复渲染搜索表单，不是状态摘要）。

## Alternatives considered

- **把四来源行搬回来源页签**（这样旧语义测试就不用改）：最省事，但直接违反第 12 项「来源选择移入高级设置」的原文。放弃。
- **用 `static` 全局变量保存搜索草稿**：能扛住卸载，改动也小。但会跨视频串味——切到另一部片仍带着上一部的关键词与选中集，且测试之间互相污染。放弃。
- **把草稿写进 `UiPrefs` 落盘**：能扛重启，但把"临时输入"变成"设置项"，下次打开播放器会被上一部片的搜索词占住，语义错误。放弃。
- **让搜索页常驻（`Offstage` / `IndexedStack`）以保住页面内状态**：可省掉草稿对象，但常驻会让该页持续参与重建与动画计时，与第 13 项的性能目标冲突。放弃。
- **重复集号保持 `putIfAbsent` 取第一条 + 只在 UI 加一行提示**：改动更小，但用户以为已经选了、实际绑的是别人，属静默错误。放弃。
- **为凑旧清单往搜索页硬塞 `AppInlineSpinner`**：能让 `zz_t66_app_inline_spinner_test` 的旧清单原样通过，但那是**为测试造代码**——搜索页的真实形态是整行进度条。放弃，改为按现状迁移判据 + 新增形态断言。
- **把诊断区做成不可展开的常显区块**：实现更简单，但第 12 项明确要求「**可展开**诊断区域」，且常显会挤占搜索结果空间。放弃。

## Consequences

首次打开来源面板四路都是勾选态；用户取消某一路后立刻写入并 `flush`，重建/重载后仍保持关闭；旧配置没有该键时按全开处理，不必迁移。同集号多候选时确认按钮禁用，必须先选一个。搜索页关闭再打开会恢复关键词、选中集与预览态；草稿跟着播放器会话走，换片即失效。

代价与边界：

- 批量绑定多一步交互，换来不再静默绑错。
- `player_page.dart` 多持有一个草稿对象并多传一个参数（该文件由 Leader 独占，避免与弹幕侧并发写冲突）。
- 诊断区在高级页签内容增长后，`测试连接` 按钮可能被挤到折叠线以下（实测日志出现 `Offset(424.0, 1496.0) would not hit test`）——这是**产品可发现性问题**，测试侧用 `ensureVisible` 解决，但**真实可用性需实机确认**，已记入批末观察项。
- `setUp` 注入 `{'danmaku.feeds.enabled': 'biliSource'}` 的种子**有效**（非 inert），但代价是这些文件不再覆盖第 10 项「首次默认全部启用」⇒ 已补一条空偏好下四路皆勾的用例补回覆盖。
- `zz_t66_danmaku_startup_gate_test` 的 N5「故障注入 ⇒ 门禁必须变红」曾是**仪器自身失效**（误用瞬时在途值）。已在仪器层改为传输层历史峰值 + 真实请求数 > 0，并做撤销验证：注入后 `5004ms/在途0/已发1/峰值1`、退出码 1；恢复后 10 项通过、退出码 0。
- 未覆盖边界（如实标注，不开工）：空回调时按钮隐藏、标题/集数真实分行、详情 UI 的完整形态。

## Verification

全部 `--run-skipped --concurrency=1`，先 `export PATH="/c/Users/iuuuuuuuu/flutter/bin:$PATH"`：

- 本范围 11 文件串行：`+107: All tests passed!`，退出码 0（`.probe/regress-danmaku-after.log`）。
- 三文件定向回归：`+36: All tests passed!`，退出码 0（`.probe/regress-danmaku-progress2.log`）。
- 第 10/11 项红→绿：红为三项断言失败、退出码 1（`.probe/danmaku-regressions-red-v2.log`）；绿为四项通过、退出码 0（`.probe/danmaku-regressions-green-v2.log`）。
- 四项故障注入均按预期失败并恢复：`.probe/danmaku-fault-{default,persistence,conflict,draft}.log`。
- N5 仪器层撤销验证：`.probe/regress-danmaku-n5-inject.log`（退出码 1）、`.probe/regress-danmaku-n5-recovery.log`（10 项通过，退出码 0）、`.probe/regress-danmaku-n5-restored.log`（15 项通过）。
- Leader 独立全量复跑 19 个回归文件：**275 项通过、退出码 0**（`.probe/lead-r9-final2.log`）。
- `node .agents/notes-scripts/notes-gate.mjs`：三道门禁通过、退出码 0。

**以上均为专项测试证据，不替代实机验收。** 首次安装、旧配置迁移、主动关闭后重启、部分来源失败四类场景仍需实机确认；搜索页诊断区的实际可展开性、高级页签拥挤度、封面渲染效果均需亲眼看过。
