# Agent Note: 遥控端选集平铺 —— /api/state 的 episodes 只报当前线路（1.1 类推）

Status: implemented

Independent: 与 1.1（右侧详情栏）同根因的另一条**数据出口**；判据同一份
（episode_filter.dart），不复制逻辑（lead 授权口径明示）。

## Problem

真机读数（driver-ops `drive-20261029-234208.json`）：
`/api/state` 的 `episode_count=2913`、`episodes` 把 1..164 重复了 ~17 遍 ——
手机端选集面板同样在平铺全部线路。改前 `_remoteGetState` 的 episodes 字段
直接遍历全集 `_episodes`。

## Decision

```text
① _remoteGetState：列表/计数改用 episodesForLine(_episodes, _selectedFlag)
   （公共判据，与选集抽屉/右侧详情栏同一份；线路 = 播放器真源 _selectedFlag）。
   episodeOrder 口径不变 —— 它回答"正在播第几集"，与列表过滤正交。
② goto_episode 回查**同口径**：手机端能发来的集号都来自已过滤的列表，
   回查若还在全集里找，会命中**第一条线路**的同集号 ⇒ 点了却切到别的线路。
   回查也走 episodesForLine。
③ 门禁探针 debugPlayerRemoteStateForProbe：直取生产 _remoteGetState()，
   断言真 RemoteState（不是手抄副本）。
```

## Alternatives considered

### A. 只改列表、goto 回查保持全集

否掉的原因：列表与回查是**同一契约的两半**。列表过滤后手机端发出的集号
仍是合法集号，但全集回查的 first-match 会落在第一条线路 —— 手机点第 5 集
切到别的线路的第 5 集，比平铺更隐蔽。

### B. 遥控列表报全部线路、由手机端自己分组

否掉的原因：要动手机端 page.html（不在本仓）；且与 App 内三条渲染路径的
既有裁决（按线路分组/过滤）相反方向。

## Consequences

**收益**：手机选集面板与本机选集抽屉/右侧详情栏同一口径（本线路 N 集）。
**代价与边界**：换线路后手机选集列表自动跟随（_selectedFlag 变化在下次
state 刷新时体现）；跨线路直接点集暂时做不到 —— 与 App 内行为一致，
不是回归。prev/next_episode 仍按全集顺序推进（既有行为，未在本授权内，
如需同口径另立任务）。

## 验证结果（已发生）

```text
门禁：test/t20261030_remote_state_line_test.dart → 3 passed
  ① 真 _remoteGetState（探针直取生产方法）：17 线路假数据 ⇒ episodeCount=27、
    episodes 只含 BD_*；真 _pickEpisodeFlag 切到 BF ⇒ 列表跟着换 BF_*
  ② 静态窗口断言 ×2（列表真用 episodesForLine、goto_episode 回查同口径；
    锚点用代码签名 —— 注释会被剥注释器删掉，第一次就栽在注释锚上）
回归：t20261030_episode_number_align_test 3 passed（同文件同跑）
故障注入（实测真红后恢复复绿）：列表退回全集 ⇒ ①+窗口红；回查退回全集 ⇒ 窗口红
真机复验：批末由 driver-ops 重放 /api/state 核对（episode_count 应=单线路集数）。
```

## Relations

- 1.1（同根因的渲染路径）：[./2026-10-30-right-detail-line-filter-and-badge.md](./2026-10-30-right-detail-line-filter-and-badge.md)
- 1.4（面板路径，同批）：[./2026-10-30-episode-number-normalized-line-switch.md](./2026-10-30-episode-number-normalized-line-switch.md)
