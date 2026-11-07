# Agent Note: 右侧详情栏选集仍平铺全部线路 + 「853 集」徽标是多线路总数

Status: implemented

2026-11-08 applicable update: [direct player controls](../feature/2026-11-08-player-direct-controls.md) partially supersedes the playback-only line choice described here. The pane provides a wrapping line selector and temporary browsing choice; player reports resynchronize it. Filtering, episode counts and the full episode-list contract remain in force.

Independent: 与 `2026-10-29-episode-panel-flattened-all-lines.md`（选集**抽屉**那条，
已修）同根因的另一条渲染路径 —— Owner 图5/图8 证明右侧**详情栏**不走 PlayerEpisodePanel。

## Problem

Owner 现场（图5 兰香如故 / 图8 老舅）：右侧详情栏的选集仍平铺 459 条（17 线路 × 27 集），
「第01集」出现 17 次；头部徽标写「459 集」（兰香如故 853 集）—— 多线路总数。

真读数修正（执行方现场核实，已反馈 lead 写回计划文档）：

```text
计划文档 1.1 假设右侧栏选集 widget 在 lib/ui/player_page.dart 的 hasRightDetailBar 路径内。
实际：右侧详情栏 = media_page.dart:1675 构造的 DetailPage（lib/ui/detail_page.dart），
选集网格 = detail_page.dart _bodyEpisodes（改前 `for (final ep in _episodes)` 直接平铺全集）；
player_page.dart 里没有右侧栏选集 widget（hasRightDetailBar 只隐藏底栏「选集」按钮）。
「853 集」徽标 = detail_page.dart _Info 的 `_Chip('$episodeCount 集')`，episodeCount = _episodes.length。
```

## Decision

```text
① 判据抽成公共函数：新文件 lib/ui/widgets/episode_filter.dart
   · effectiveFlag(episodes, selectedFlag)   —— 合法直通 / 失效兜底第一条 / 单线路 ⇒ null
   · episodesForLine(episodes, selectedFlag) —— 本线路的集（单线路原样返回，一集不丢）
   · lineCountOf(episodes)                   —— 线路条数（去重）
   · episodeNumberOf(title)                  —— 集号归一化（1.4 用：第2集/第02集/01/1）
   ★ 不放 episode_strip.dart：live_page.dart 持有「episode_strip 只读复用不改」的
     lead 约束（2026-10-30 裁决：判据落新文件，两条旧路径各自 import）。
② episode_panel.dart（抽屉路径）：_eps / EpisodeLineBar.selected 改引公共函数
   （语义与 2026-10-29 的兜底逐字一致，纯收敛不改变行为）。
③ detail_page.dart（右侧详情栏路径）：
   · _currentLineFlag：播放器在播的那集（_activeEpisodeId）所属线路；
     播放器还没报 ⇒ effectiveFlag 兜底第一条（与抽屉同一判据）。
   · _bodyEpisodes 遍历 _lineEpisodes（只画当前线路）。
   · ⚠️ 只收窄渲染：_episodes 本身不动 —— 高亮/滚动（按 id 查 key）、
     _currentEpisodeIndex（episodeIndex 落库全集下标）、下载全部集语义全保持。
④ 徽标（1.2）：多线路 = 「本线路 N 集 · 共 M 条线路」（N = 当前线路集数）；
   单线路 = 「N 集」（与改前逐字一致）。文案由 _buildHeader 算好传 _Info.episodeBadge
   （_Info 只有一个数，算不出 M；不许在这里抄第二份判据）。
```

数据流：当前线路的来源 = 播放态（media_page 把 `currentEpisodeId` 传给 DetailPage，
`_activeEpisodeId` 优先级：播放器上报 → 用户刚点 → 上次观看/第一集）→ 该集的
`Episode.flag` → `episodesForLine`。

## Alternatives considered

### A. effectiveFlag 放 episode_strip.dart（计划文档原方案）

最强理由：与 episodeLineFilter 同文件，找判据只看一处。

否掉的原因：live_page.dart 明写「episode_strip.dart **只读复用，不改它**（lead 明确）」，
约束仍然有效；lead 2026-10-30 裁决落新文件。新文件也避免了"改公共文件牵连 18 个 import 方"。

### B. DetailPage 自己维护一套 selectedFlag（仿抽屉传参）

否掉的原因：右侧栏没有线路切换 UI，"选中线路"的真源是**播放器**；
播放器上报的当前集天然携带线路维度（flag 挂在集上），直接读它 = 零新增状态、
换线路后右侧栏自动跟随（currentEpisodeId 变 ⇒ didUpdateWidget 重滚）。

### C. 徽标只改数字不加「共 M 条线路」

否掉的原因：Owner 指定文案逐字是「本线路 N 集 · 共 M 条线路」；
只改数字会让用户以为少了集（459→27）而不知去向。

## Consequences

**收益**
- 右侧详情栏选集：17 线路源只画 27 格，与抽屉同一判据，不会再分叉。
- 徽标诚实：本线路 27 集 + 线路总数可见。
- 单线路源零变化（渲染与徽标都有"单线路回归"门禁守着）。

**代价与边界**
- 混合源（同一列表里部分集无 flag、部分有）时：当前集无 flag 会退到第一条线路，
  无 flag 的集不显示 —— 真实数据里 tvbox_agg/ikan 全部集都带 flag，此边界未出现，
  如实记录（episode_filter.dart 文件头有注释）。
- episodeNumberOf 的数字兜底（无「第…集」壳时取第一段数字）对「2024 重映版」这类
  标题会归一成 2024 —— 只用于 1.4 的匹配（匹配不到就停在当前集，不会跳错集），
  且优先匹配「第 N 集/话/回」正则，风险有界。

## 验证结果（已发生）

```text
门禁：test/t20261030_right_detail_line_filter_test.dart → 10 passed
  ① 纯函数 5 条（effectiveFlag 直通/兜底/单线路、episodesForLine+lineCountOf、episodeNumberOf 01/1/第2集/第02集）
  ② 真 DetailPage 渲染 3 条（未上报 ⇒ BD 27 格；上报 BF|5 ⇒ BF 可见 BD 消失；单线路 40 集不丢）
  ③ 徽标 2 条（多线路「本线路 27 集 · 共 17 条线路」；单线路「40 集」）
  夹具：真 DetailPage(embedded) + debugSetDetail 注入 17×27（同 t64_panel_fixed 手法，绕 FFI）
既有门禁无回归：test/zz_episode_panel_line_segregation_test.dart → 3 passed（与本文件同跑 13 passed）
flutter analyze（episode_filter/episode_panel/detail_page）→ No issues found
故障注入（三条都实测真红，再恢复复绿）：
  ① _bodyEpisodes 遍历退回 _episodes ⇒ 组① 2 条 FAILED
  ② 徽标退回 '$episodeCount 集' ⇒ 「本线路 27 集 · 共 17 条线路」FAILED
  ③ episodesForLine 恒返回 all ⇒ 本文件 4 条 + 抽屉门禁 zz_episode_panel_line_segregation 1 条
    FAILED（证明判据真被两路径共用，没有被 mock 掉）
真机截图：等 driver-ops 驱动器就绪后批末统一（Owner 纪律④：攒批实测）。
```

## Relations

- 抽屉路径的同一根因（上批已修）：[./2026-10-29-episode-panel-flattened-all-lines.md](./2026-10-29-episode-panel-flattened-all-lines.md)
- [Live progress and modal workflow](2026-11-04-player-progress-and-danmaku-modal-workflow.md)
  updates the live resume observation in this same detail pane. Current-line
  filtering and honest episode counts remain unchanged; neither decision
  supersedes the other.
