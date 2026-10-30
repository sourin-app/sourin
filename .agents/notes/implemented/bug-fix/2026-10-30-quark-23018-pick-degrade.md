# Agent Note: 夸克 23018「download file size limit」选文件策略降级重试

Status: implemented

日期: 2026-10-30
任务: 现场反馈批次任务 5（task-4，执行者 rust-quark）
计划: .probe/plan-2026-10-30-field-feedback-batch.md「### 5 夸克 23018」
相关: [../feature/2026-10-29-share-page-play-resolves-to-direct-link.md](../feature/2026-10-29-share-page-play-resolves-to-direct-link.md)
  （那篇建了 resolve_share_play 直链链路与"挑最大"的 pick_share_video，本篇只改**选文件策略**为降级重试，链路本身不动）；
  [../feature/2026-10-29-pan-temp-dir-for-share-save.md](../feature/2026-10-29-pan-temp-dir-for-share-save.md)
  （临时目录转存语义沿用；本篇补"失败尝试也 remember_temp"防堆积）。
  Independent: 不取代上述两篇 —— 它们交付的链路与目录语义原样保留。

## Problem

```text
resolve_share_play（rust/sourin_core/src/csp/pan_drive.rs）原逻辑：
  pick_share_video 只挑分享里**体积最大**的一个文件 → 转存 → file/download 取直链。
账号单文件下载上限挡住那个最大文件时，夸克回 {code:23018, message:"download file size limit"}
⇒ 整条链路直接失败 —— 分享里明明有能播的小文件（图4 现场）。
```

## Decision

1. `pick_share_video` → `pick_share_candidates`：BFS 收集**候选清单**按体积降序返回
   （视频优先；无视频退回"任意文件"清单，保持旧兜底语义；某层凑够 3 个候选即不再下钻）。
2. 新增纯调度 `degrade_pick`（pub，tests/ 可直测）：候选逐个试，
   遇超限错误（`is_size_limit_error`：`code=23018` 或 `download file size limit`）降级下一个，
   **最多 3 个**（`SHARE_PICK_MAX_TRIES`）；**其它错误不降级**原样抛；
   全部超限 ⇒ Err「该分享的文件超出夸克下载上限，请换一条线路（已尝试 N 个候选）」。
   每次降级 `log::warn!("[PAN] 降级：…")` + 记一条降级记录。
3. `degrade_attempt`：单次尝试 = 转存到临时目录 + 复用 `play` 取直链；
   失败的尝试**也** `remember_temp`（超限发生在取直链一步，转存已成功 ⇒ 不记则 purge 清不掉，会堆垃圾）。
4. UI 文案：降级发生后 `label = "分享页 · <文件名>（已跳过 N 个超出下载上限的文件）"`；
   `play` 对裸 23018 错误追加「（该文件超出账号单文件下载上限）」。
5. 文案用 `kind.display().trim_end_matches("网盘")`（夸克网盘→夸克 / UC网盘→UC），与 Owner 指定文案逐字对齐。

## Alternatives considered

```text
A. 转 123/网盘中转解析  —— 超范围，砍。
B. 在 pick 阶段就用 file/info 预查大小上限 —— 上限值没有取证来源（账号分档），不猜；改为"试错降级"。
C. resolve 失败后整体重扫分享 —— 每次都要重新转存+取直链，不如一次拿全候选按序试。
D. 降级时把中间错误也弹给用户 —— 会淹没「换线路」主文案；降级过程只进日志 + label 注记。
```

## Consequences

```text
门禁文件: rust/sourin_core/tests/quark_pick_degrade.rs（独立新建，不动共享测试）
cargo test --test quark_pick_degrade --release
  ⇒ test result: ok. 7 passed; 0 failed（is_size_limit_error 形状×1、降级命中×2、
     非超限不降级×1、全超限文案×1、3 个上限×1、候选不足 3×1）
注入证红（纪律②）: 把 degrade_pick 的回退循环删成"只试第一个候选，超限直接抛"
  ⇒ test result: FAILED. 3 passed; 4 failed
    （degrade_picks_largest_downloadable / degrade_max_tries_caps_attempts /
      degrade_all_exceeded_gives_clear_guidance / degrade_uses_candidates_shorter_than_max 全红）
  ⇒ 恢复实现后复跑 7 passed / 0 failed。
真机播放验证（播此前 23018 的线路）按批次纪律攒到批末由 lead 统一安排。
```
