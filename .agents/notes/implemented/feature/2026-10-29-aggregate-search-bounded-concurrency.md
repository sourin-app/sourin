# Agent Note: 聚合搜索改有界并发 —— 240 条早就够了，等的是那 32 秒

Status: implemented

Independent: 与 `2026-10-28-aggregate-keeps-cross-source-same-title.md`（去重口径）和
`2026-10-29-share-page-…`（取流）都不同：本条只改**扇出的调度方式**，
不改候选集、不改去重、不改 UI 分组。

## Problem

Owner：「对照原版，确认搜索结果对标 75 个」。真机度量（`live_search_count` 探针，本机数据目录、真网）：

```text
搜「老舅」：tvbox_agg 出 240 条，耗时 **32.84 秒**
```

⇒ **条数早就超过原版 75 条**，问题在**速度**：`TvboxAggregate::fanout_search` 是
`for p in children { await p.search(...) }` —— 47 个子站一个等一个，每站 0.5~3s。

## Decision

```text
· 改**有界并发**（AGG_FANOUT_LIMIT = 10）：Semaphore 控并发 + JoinSet 收结果；
· 单站失败/超时**仍只记原因不中断**（硬纪律①一字不改）；
· 结果按**子站 id 排序**后再拼接 —— 顺序不再由"谁先回来"决定（否则每次刷新列表都在跳）；
· 峰值并发落进 `FANOUT_PEAK`（`last_fanout_peak()` 暴露）—— 门禁靠它证明"真的并发"。
```

真机复测（同一条命令、同一数据目录）：

```text
搜「老舅」：tvbox_agg 出 249 条，耗时 **6.70 秒**（原 32.84s，快 4.9 倍）
```

## Alternatives considered

### A. 保持串行，靠"流式出结果"掩盖慢

**最强理由**：`registry.search_all_stream` 本来就是"谁先回来先显示"，
用户不用等全部结束；串行时第一个子站 0.5s 就出结果。

**否掉的原因**：串行的"先出"只有**第一组**；后面 46 组要 30 秒才补齐，
而用户搜完会一直往下翻（原版是秒级全出）。而且 32s 里聚合这一路上限
`CHILD_TIMEOUT=8s × 47` 的极端情况会顶到 UI 的超时。
并发把"整体等齐"的时间压到个位数秒，对两种使用方式都更好。

### B. 一把 `join_all`（无上限）

**最强理由**：实现最短，最快（47 个一起打）。

**否掉的原因**：① 要等**最慢**的那个才返回（没有"先出"）；
② 47 路同时打，本条数据里存在"同一采集站家族的多个子站"，会瞬间给同一主机
5+ 并发 —— 更容易被限流/封 IP（registry 那边已用 12 路踩过这个坑）。

### C. 用耗时断言做门禁（"并发版必须 < 串行版"）

**最强理由**：直接测"用户感受到的东西"。

**否掉的原因**：CI 上时间抖动大，容易假红/假绿。改用**峰值并发**（确定性）：
串行恒 1，有界并发 >1 且 ≤ 上限。耗时只在真机度量里记录（真网探针），不进 CI。

## Consequences

**收益**

- 「老舅」从 32.8s → **6.7s**，条数 240→249（并发后没有丢结果，反而多拿到 9 条：
  串行时排在后面、被整体超时吃掉的那几站，这回赶上了）。
- 列表顺序稳定（按子站 id 排序），刷新不再跳动。
- `last_fanout_peak()` 让"并发"这件事**可观测**，不是只写在注释里。

**代价与边界**

- 峰值并发 10 路 × 每路一个 QuickJS runtime（插件源）：内存峰值比串行高，
  但远低于 registry 的 12 路（那里是 99 个源的全局扇出）。
- 每个子站仍只取**第 1 页**（原版"全部"也是逐源一页）；要"更多"是另一个决定（分页/加载更多）。
- 这次只改 `search`；`categories`/`list` 的扇出仍是串行（量级小，且列表页按渠道取，不走这里）。

## 验证结果（已发生）

```text
cargo test --lib tvbox_aggregate --release → 22 passed / 0 failed
  新增 fanout_runs_concurrently_within_the_limit：
    8 个 60ms 的假子站 ⇒ 结果 8 条不丢、峰值并发 in (1, 10]、结果按子站 id 排序
真机度量（live_search_count，真网、本机数据目录）：
  改前 240 条 / 32.84s
  改后 249 条 / 6.70s
故障注入（已实测真红）：
  AGG_FANOUT_LIMIT 10 → 1 ⇒ fanout_runs_concurrently_within_the_limit FAILED（峰值=1）
```

## Relations

- 去重口径（条数为什么是"几十上百"）：[./2026-10-28-aggregate-keeps-cross-source-same-title.md](./2026-10-28-aggregate-keeps-cross-source-same-title.md)
- 候选集（为什么能搜到 csp 源）：[./2026-10-28-aggregate-only-saw-hidden-children.md](./2026-10-28-aggregate-only-saw-hidden-children.md)