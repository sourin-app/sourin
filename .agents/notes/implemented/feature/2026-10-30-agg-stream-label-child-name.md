# Agent Note: TVBox 聚合播放源 label 补子源显示名（任务 2 的 Rust 半边）

Status: implemented

日期: 2026-10-30
任务: 现场反馈批次任务 2（task-4，执行者 rust-quark；Dart 展示半边归 dart-player）
计划: .probe/plan-2026-10-30-field-feedback-batch.md「### 2 播放源显示」
相关: [../bug-fix/2026-10-29-aggregate-episode-id-prefix-broke-pan-play.md](../bug-fix/2026-10-29-aggregate-episode-id-prefix-broke-pan-play.md)
  （同一个 `TvboxAggregate::resolve` 函数；那篇修 episode_id 前缀对称剥离，本篇只在其后追加 label 组装，不改路由）。
  Independent: 不取代该篇 —— 前缀剥离门禁与实现原样保留。

## Problem

```text
TvboxAggregate::resolve（rust/sourin_core/src/tvbox_aggregate.rs）把子站的
StreamCandidate 原样透传 ⇒ label 只有内层「原画」/「官方 HLS」/「分享页 · xxx」。
聚合把几十个子站揉成一个源，换源列表里分不清哪条是哪个子站。
```

## Decision

1. resolve 在子站返回后逐条套 `compose_stream_label(&child.manifest().name, label)`：
   - 内层有值 ⇒ 「<子源显示名> · <线路名/分享页文件名>」
   - 内层空 ⇒ 只给子源显示名（换源列表不许出现无名条目）
   - 内层已带「<子源> · 」前缀 ⇒ 不重复拼（有的子站 label 自带站名）
   - 子源名空 ⇒ 退回内层，不产出「 · x」残缺串
2. 子源名取 **route 到的 child 的 manifest.name**（不是配置 id）；组装循环产出空串时不改写原 label。
3. `compose_stream_label` 为 pub 纯函数（tests/ 直测）。

## Alternatives considered

```text
A. 在 model.rs 给 StreamCandidate 加 provider_name 字段 —— 动共享模型，影响全部源，砍。
B. 只在 Dart 层拼（task-2 的 Dart 半边已有「TVBox 聚合(<备注>) · <label>」）——
   子源名 Rust 侧最清楚（route 上下文），Dart 拿不到；两侧各补各的，格式用「·」对齐。
C. label 里再带聚合备注 —— 备注是聚合层信息，Dart 半边负责（读 AggregateConfig.note）。
```

## Consequences

```text
门禁文件: rust/sourin_core/tests/agg_label.rs（独立新建，不动共享测试）
cargo test --test agg_label --release
  ⇒ test result: ok. 5 passed; 0 failed
    （纯函数形状×3 + 全链路：注册假子站 → agg.resolve ⇒ label 前缀=子站 manifest.name×3，
     含"换子站名前缀跟着变"与"episode_id 透传不受影响"对照）
注入证红（纪律②）: 把 resolve 里套 compose_stream_label 的循环删掉
  ⇒ test result: FAILED. 2 passed; 3 failed
    （resolve_labels_prefix_child_name / resolve_labels_use_routed_child_not_hardcoded /
      resolve_passes_episode_id_through_unlabeled 全红）
  ⇒ 恢复实现后复跑 5 passed / 0 failed。
真机显示验证（播放页顶部/换源列表）攒到批末由 lead 统一安排。
```
