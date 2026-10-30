# Agent Note: 标题跟随自动连播 —— 详情标题展示层剥内嵌集数后缀（Owner 解锁授权）

Status: implemented

Independent: 与 1.1-1.4/P1/遥控选集过滤各条同文件不同关注点；判据仍在
episode_filter.dart（与集号归一化同源，不复制逻辑）。

## Problem

真机读数（repro14-20261030-004500.state.json + 实机抽测矩阵 #4）：
`/api/state` 同时有 `title="《老舅》 第1集"` 与 `episode_order=3` ——
自动连播推进后标题陈旧（右栏/顶栏/遥控三处同病）。

根因：CCTV 类源**一集一个详情**，`detail.title` 把集数编进标题
（「《老舅》 第1集」），但 episodes 列表是完整 27 集；`_title` 是详情
加载时的快照，自动连播只推进 `_epIndex`，快照不刷新。

## Decision（Owner 口径：「这些你自己想办法解决别再问我」；lead 立项）

```text
原则：**不改写 _title 本体**（t61 写库契约 title: _title / _liveTitle 兜底
逐字不动），只在展示层用实时字段拼装。判据 = 公共纯函数（episode_filter.dart）：

① showTitleOf(detailTitle, episodes)：title 以某条**含数字**的集标题**逐字**
   结尾才剥出剧名；找不到（普通源纯剧名）⇒ 原样。剥的是"标题里嵌的那一次"，
   与当前在播第几集无关 ⇒ 剧名恒定。
② detailDisplayTitle(detailTitle, episodes, currentEpisodeTitle)：
   剥掉才缀当前在播集标题；当前集=内嵌那集 ⇒ 拼装结果与原串逐字相同
   （往返恒等）；普通源原样返回（连当前集都不缀 —— 展示零变化）。

接入三处（全展示层）：
· 遥控 state（_remoteGetState）：title = 剧名 + 「 第N集」（order 实时，
  lead 背书的拼装口径；order=0 单集/直播 ⇒ 只出剧名）；
· App 顶栏（_TopBar.title）：showTitleOf 剥后缀，集名仍由 episodeTitle
  独立渲染（改前顶栏会同时出现「…第1集」快照 + 实时集名两份集数）；
· 右栏（DetailPage 头部）：displayTitle = detailDisplayTitle(d.title,
  _episodes, _episodeById(_activeEpisodeId)?.title)，_Info 新增 displayTitle
  参数（调用方算好传入 —— 与 1.2 徽标同一手法，_Info 不抄判据）。
```

## Alternatives considered

### A. updateDisplayTitle 时就把 _title 改写成剥好的剧名

最强理由：一处写入，三处读数自动跟随，无需各自接入。

否掉的原因：_title 同时是**写库标题**（t61 契约：_saveProgress 读 _title 活值）
——改写会让播放记录里的标题丢掉 CCTV 源自带的集次信息；且 updateDisplayTitle
只在详情加载时调一次，自动连播后仍需展示层重拼，省不掉任何接入点。

### B. 正则启发式剥离（`/第\d+集$/` 一类）

否掉的原因：lead 原则明示"不启发式改写"。逐字后缀匹配（标题以某条集标题
结尾）是确定性判据；再加 episodeNumberOf 含数字护栏防「《西游记》×集名『记』」
这类尾部误剥。

### C. 只修遥控、App 内不动

否掉的原因：Owner 看到的是**右栏标题**（App 内），只修遥控等于"手机对了、
电视还错着"；三处同根因，一次修齐（顶栏顺带消掉了"快照集数 + 实时集数"
双重显示的隐性不一致）。

## Consequences

**收益**：自动连播后右栏/顶栏/遥控三处标题同步跟随（「《老舅》 第3集」）；
普通源展示逐字零变化（detailDisplayTitle 原样返回有专门门禁守着）。

**代价与边界**
- 集**列表**为空时（详情先到、剧集未到）剥不出来 ⇒ 首帧短暂显示原串，
  剧集到达后重建即正确 —— 与旧行为相比只会更准，不会更差。
- 目录型源（思君如故的「第1-20集」合集条）剥+缀=往返恒等，无观感变化。
- `_title` 本体、写库、换源导航路径零改动（t61 全量 17 passed 回归）。

## 验证结果（已发生）

```text
门禁：test/t20261030_display_title_follow_test.dart → 10 passed
  ① 纯函数 7 条（CCTV 剥离 / 普通源原样 / 无数字短集名不剥 / 全等防空串 /
    缀当前集 / 往返恒等 / 普通源连缀都不缀）
  ② 真 _remoteGetState：order 推进 1→3 ⇒ title「《老舅》 第1集」→「第3集」
  ③ 真顶栏：剧名「《老舅》」与集名「第3集」分离渲染、陈旧串消失
  ④ 真右栏（DetailPage + debugSetDetail + currentEpisodeId ep1→ep3）：
    「《老舅》 第1集」→「《老舅》 第3集」
回归：detail 门禁 10 passed（1.1/1.2 无回归）、t61_progress_title 17 passed
（写库契约零变化）、遥控选集门禁 3 passed、聚合标题门禁 5 passed
analyze（player_page/detail_page/episode_filter）→ 0 errors
故障注入（三条全实测真红后恢复复绿）：
  ① 遥控 title 退回 _liveTitle ⇒ 组②红
  ② 顶栏退回 _liveTitle ⇒ 组③红
  ③ DetailPage 头部退回 detail.title ⇒ 组④红
真机：driver-ops 复播老舅样片自动连播场景核对（lead 安排）。
```

## Relations

- 判据同源：[./2026-10-30-right-detail-line-filter-and-badge.md](./2026-10-30-right-detail-line-filter-and-badge.md)
- 同批标题相关：[../feature/2026-10-30-aggregate-source-title-dart.md](../feature/2026-10-30-aggregate-source-title-dart.md)
