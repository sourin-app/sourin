# Agent Note: 线路切换集数对齐 —— _pickEpisodeFlag 改集号归一化，匹配不到停当前集号

Status: implemented

Scope: 面板切线路路径已落地；遥控 switch_source 路径等真机复现（见边界）。

Independent: 判据本体 episodeNumberOf 与 1.1 同文件（widgets/episode_filter.dart）；
与 2026-10-29-aggregate-episode-id-prefix-broke-pan-play（播放链路 id 前缀）不同层。

## Problem

Owner 现场：切换线路后集数错位（/api/state 的集数疑似跳回第 1 集 —— 真机复现
等 driver-ops 驱动器就绪，Owner 纪律"先复现再修、不要猜"）。

面板切线路这条路径的缺陷**现在就能确证**（源码+门禁）：
`_pickEpisodeFlag` 用「标题全等」匹配 —— `e.title == cur.title`。
各线路标题形态不同时匹配不到：

```text
真机形态：线路A「第2集」 vs 线路B「第02集」（零填充差异）；
         「01」 vs 「第 1 集」（壳差异）
匹配不到 ⇒ _epIndex 停在旧线路的集上（高亮错位 / 集数对不上）。
```

## Decision

```text
_pickEpisodeFlag 匹配改两层：
① episodeNumberOf（集号归一化，提取数字）：第2集/第02集/01/1/EP3 归一比较；
② 数字也提不出（特别篇等）⇒ 退标题全等兜底；
③ 两层都匹配不到 ⇒ 停在当前集号（_epIndex 不动，刻意不写 else —— 绝不跳 1）。
门禁探针 debugPlayerPickEpisodeFlagForProbe / debugPlayerEpisodeIndexForProbe
驱动**生产方法**（不 mock）。
```

## Alternatives considered

### A. 顺手把 _remoteSwitchSource / _applySwitch 也改成归一化匹配

最强理由：真机复现命令（switch_source）走的就是那两条，多半同根因。

否掉的原因（**暂时**否掉）：Owner 纪律"先复现再修、不要猜"。_applySwitch 现在
匹配不到会**显式跳第 1 集并 flash 告知**（原版语义）；遥控路径把旧线路的
episode id 传给新 sourceCode 的 resolve，回落行为在 Rust 侧 —— 未复现前改动
可能改错层。episodeNumberOf 判据已就绪，复现确认后接线是小改动。

### B. 用"同下标"对齐（切线路保 index）

否掉的原因：各线路集数/缺集不同（本仓注释里就有《老舅》列表 2-27 与下标
不一致的实测），下标对齐是错位之源，正是要用集号替代的东西。

### C. 全等匹配 + 归一化做第二遍（顺序反过来）

否掉的原因：全等是归一化的子集（同串必然同号），先归一化少一次遍历且语义单一。

## Consequences

**收益**
- 零填充/壳差异的跨线路集号对齐（01/1、第2集/第02集 双向）。
- 匹配不到**结构性不跳 1**（门禁 ③ 钉住）。

**代价与边界**
- episodeNumberOf 的数字兜底对「2024 重映版」会归一成 2024 —— 只影响
  跨线路匹配（匹配不到就停当前集），且「第 N 集/话/回」正则优先，风险有界。
- initState 的 `_syncSelectedFlag` 默认第一条线路、与进入时 episodeId 所属线路
  可能不一致 —— 这是**进入路径**的另一个问题（与门禁②的夹具状态对齐有关），
  未复现前不动；如实记录，等真机读数归入 1.4 或另开任务。

## 验证结果（已发生）

```text
门禁：test/t20261030_episode_number_align_test.dart → 3 passed（真 PlayerPage 走生产 _pickEpisodeFlag）
  ① 线路A第2集 → 线路B ⇒ index 4（第02集）
  ② 线路B第02集 → 线路A ⇒ index 1（第2集，双向归一）
  ③ 线路C 只有「特别篇」⇒ 停在当前集号（不跳 1）
回归：test/zz_ikan_multiline_player_path_test.dart（native-media 手动跑）→ 7 passed
故障注入（实测真红后恢复复绿）：匹配退回标题全等 ⇒ ①② 红（③ 不跳 1 不变
—— ③ 钉的是"匹配不到停住"这条独立不变量）
纯判据 episodeNumberOf 的形态用例在 t20261030_right_detail_line_filter_test（01/1/第2集/第02集/EP3/预告）。
```

## 真机复现结论（2026-10-30 00:45，driver-ops 执行，lead 裁决：未复现 ⇒ 不额外接线）

```text
复现单：老舅（某直播频道源，official/cdn 两线路）goto_episode=2 →
  switch_source{code:'cdn'} → 终态。
读数：ep 保持 2/27 且位置续播；终态 episode_order=3 是 10s 样片**自动连播**
  到第 3 集（非跳 1）。换线前后 episode id 无前缀污染。
证据：.probe/play-driver/results/repro14-20261030-004500.{logtail.txt,state.json}
  + .probe/shots/ 截图。
协议限制：switch_source 只走 sourceCode 维度；flag 维度（选集面板点线路）
  遥控没有对应命令（csp resolve 完全忽略 sourceCode，csp/provider.rs:468 用
  req.flag），锁屏下无法遥控复现。
处置：维持 cead042 现状（归一化 + 停当前集号已覆盖面板路径，门禁+注入已证），
  不做 _remoteSwitchSource/_applySwitch 额外接线。真机终验批末在抽测矩阵
  （任务6）里顺带复核。
```

## Relations

- 判据公共化（同文件）：[./2026-10-30-right-detail-line-filter-and-badge.md](./2026-10-30-right-detail-line-filter-and-badge.md)
- 播放链路 id 前缀（另一层）：[./2026-10-29-aggregate-episode-id-prefix-broke-pan-play.md](./2026-10-29-aggregate-episode-id-prefix-broke-pan-play.md)
