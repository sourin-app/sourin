# Agent Note: 选集面板把 N 条线路平铺成"重复一大堆"

Status: implemented

Independent: 与 `2026-10-29-aggregate-episode-id-prefix-broke-pan-play.md`（播放链路）不同，
本条只关**渲染口径**：同一个 459 集的详情，面板该按线路分组显示 27 格，而不是铺 459 格。

## Problem

Owner 现场（截图）：右侧"选集"里 **第01集 出现 3 次、第03/04 各 2 次**，看起来"重复一大堆"。

真机读数（探针，搜「老舅」→ 详情）：

```text
集数=459  线路分布={"BD":27,"BF":27,"FF":27,"HH":27,"HN":27,"JS":27,"JY":27,"KC":27,
                    "LZ":27,"MT":27,"NN":27,"SD":27,"SN":27,"UK":27,"WJ":27,"XL":27,"YZ":27}
```

⇒ 459 = 17 条线路 × 27 集，本身没有脏数据；面板**没按线路过滤**才会看到重复。

根因（不是"没有过滤代码"）：`episodeLineFilter(all, flag)` 在 `flag == null` 时**原样返回全部**
（那是为单线路源设计的"零开销"语义）。而 `PlayerEpisodePanel` 把上游传进来的
`selectedFlag` 直接用 —— 一旦上游那一刻是 `null`（初始化未同步 / 换源被清空），
面板就把 17 条线路全铺出来。线路条也依赖上游传的 `flags`，没传就不画 ⇒ 用户既看不到线路、也切不了。

## Decision

```text
面板自己兜底（不依赖上游状态）：
① `_eps`：`widget.selectedFlag ?? _firstFlag`（第一条出现的线路）⇒ 有 flag 就只显示一条线路；
② `_flags`：上游没传就从 episodes 推（去重保序）⇒ 线路条照样画得出来；
③ `EpisodeLineBar.selected` 同样用兜底值 ⇒ 当前线路有高亮。
单线路源（flag 全是 null/空）仍走"原样返回"，一集不少。
```

## Alternatives considered

### A. 只在上游（player_page）保证 `_selectedFlag` 永不为 null

**最强理由**：状态只有一个来源，面板保持"哑组件"。

**否掉的原因**：`PlayerEpisodePanel` 是**公开组件**（`lib/ui/player/episode_panel.dart`），
被 live_page 等其它入口复用；把"必须传对 flag"变成调用方的隐含义务，
下一次有人新增调用点就会重演一次"重复一大堆"。兜底放在组件内部，是唯一不依赖调用纪律的做法。

### B. 直接在面板里去重（按 title 去重）

**最强理由**：一行代码，重复立刻消失。

**否掉的原因**：同名不同线路是**不同 id 的不同流**（同一集在不同线路码率/清晰度不同），
按标题去重会把用户能切的那几条线路**删掉**。要的是"分组"，不是"去重"。

### C. 把 459 集拆成"每线路一个 Section"

**最强理由**：结构上最干净。

**否掉的原因**：`MediaDetail.episodes` 是扁平契约（Rust `Episode.flag` 已承载线路维度），
改成嵌套要动 FFI/模型/多端，收益不比面板内分组大。

## Consequences

**收益**

- 459 集的多线路剧集：面板显示 **27 格 + 17 个线路 chip**（不再出现重复）。
- 上游状态异常（null）时也不会退化 —— 用户不会看到"重复一大堆"。
- 单线路源零变化（门禁里有一条专门守"别把集弄丢"）。

**代价与边界**

- 面板多了两处兜底逻辑（`_firstFlag` 已存在、`_flags` 新增），复杂度略升；
  由 `zz_episode_panel_line_segregation_test.dart` 三条门禁钉住（含单线路回归）。
- "默认显示第一条线路"是产品选择：与播放页 `_syncSelectedFlag()` 的默认一致（第一条）。

## 验证结果（已发生）

```text
flutter test test/zz_episode_panel_line_segregation_test.dart → 3 passed
  ① 17×27、selectedFlag=null ⇒ 标题"共 27 集"、第 1 格在、第 28 格不在、BD/BF/YZ 三个 chip 都在
  ② 点 BF 线路 ⇒ onPickFlag 回调触发
  ③ 单线路 40 集 ⇒ "共 40 集"（一集不少）
故障注入（已实测真红）：把 `_eps` 的兜底去掉（回到 `flag = null`）
  ⇒ ① 报 `Found 0 widgets with text "共 27 集"` ⇒ FAILED
真机读数：见 Problem 段（459 = 17×27，来自真网详情）
```

## Relations

- 播放链路修复（同一天、同一部剧）：[./2026-10-29-aggregate-episode-id-prefix-broke-pan-play.md](./2026-10-29-aggregate-episode-id-prefix-broke-pan-play.md)
- 聚合搜索按源分组（另一个"分组"口径）：[../feature/2026-10-28-aggregate-keeps-cross-source-same-title.md](../feature/2026-10-28-aggregate-keeps-cross-source-same-title.md)