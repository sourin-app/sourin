# Agent Note: csp resolve 剧集 id「URL 直通」判据（23018 猎捕二轮零日志死点）

Status: implemented

日期: 2026-10-30
任务: 23018 猎捕二轮诊断的修复（lead 授权：判据行 + playback 日志行，最小面）
相关: [../bug-fix/2026-10-29-aggregate-episode-id-prefix-broke-pan-play.md](../bug-fix/2026-10-29-aggregate-episode-id-prefix-broke-pan-play.md)
  （同一条 resolve 链路的上一段修复——聚合 episode 前缀对称剥离；本篇修的是剥完前缀之后的**下一跳**，不取代它）；
  [../feature/2026-10-29-share-page-play-resolves-to-direct-link.md](../feature/2026-10-29-share-page-play-resolves-to-direct-link.md)
  （分享兜底→直链链路本身原样保留，本篇只是让 URL 形剧集 id 能**走到**它）。

## Problem

```text
现象：4K网盘子站（csp-4kzhinan-*）真实剧集条目 9 条全部未起播，
      日志零 [PAN]、零 [PLAY]、连失败日志都没有（.probe/play-driver/results/hunt-20261030-065608-records.json）。
死点：csp/provider.rs resolve 的 detail 二跳判据 `episode.contains('|')`
      只认 bili 的 `bvid|cid` 形；zhinan 的剧集 id 是**纯夸克分享 URL**（zhinan.rs:406-415）
  ⇒ 被误判成"条目 id" ⇒ 拿 URL 再走一次 detail（resolve :458-462）
  ⇒ zhinan.rs:524 拼出 /book/https://pan.quark.cn/s/xxx.html ⇒ 只读探针实测 HTTP 404
  ⇒ resolve 整体 Err ⇒ 分享兜底（parse_share_page → resolve_share_play）根本到不了
  ⇒ 夸克零活动（与"零 [PAN]"逐字吻合）。
排除项：剥前缀无变形（shell.dart:1549）；上游存活（/book/20328 等 HTTP 200 且含 pan 链接）；
      无 resolve 缓存短路（playback.rs:149-168 直通）；dedupe 停用不挡 route（registry.get 不看 enabled）。
```

## Decision

1. `csp/provider.rs`：判据抽成 pub 纯函数 `episode_id_is_direct_play`——
   `contains('|') || starts_with("http://") || starts_with("https://")`；
   resolve 调用它（URL 形剧集 id 直达 play/分享兜底，不再触发注定 404 的 detail 二跳）。
   回归面：URL 形 id 走 detail 二跳本来就是死路，无源可回归。
2. `playback.rs` resolve 失败处补 `log::warn!("[PLAY] resolve 失败 …")`——
   脱敏口径（lead 指定）：只记 provider / 错误类别 / id 前缀（截 24 字符）/ needs_login，
   **不含完整 URL 参数与 token**。理由：此前 resolve 阶段失败零落盘（Dart catch 只进 _error、
   [PLAY] 只在拿到流后写）⇒ 本次"零日志"无法归因的观测黑洞。
3. 门禁 `tests/csp_episode_direct_play.rs`（独立新建）：
   形状×3（URL 形 / `|` 形不回归 / 纯条目 id 仍走二跳）+ 接线源码级断言
   （include_str! 先例：tvbox_aggregate.rs:2720；`for_test` 是 `#[cfg(test)] pub(crate)`，
   集成测试拿不到 ⇒ resolve 级假 site 门禁在 tests/ 搭不了，接线用源码级断言等价钉住）。

## Alternatives considered

```text
A. 在 zhinan.rs 里特判 URL 形 episode —— 只救一家；gui_gui/hd_moli/juhe_so 等 URL 形剧集
   的源全卡在同一判据，收口在判据一处才对。
B. resolve 里 try detail 失败再当 URL 播 —— 多一次注定 404 的网络请求（慢且日志更脏），砍。
C. 给 CspProvider 加 pub 测试构造器搭假 site 门禁 —— 超出本次授权面（for_test 保持 cfg(test)），
   接线改用源码级断言（仓内既有先例）。
D. 只加日志不动判据 —— 日志只能让"零日志"变"一行错误日志"，播放还是死的，砍。
```

## Consequences

```text
cargo test --test csp_episode_direct_play --release
  ⇒ test result: ok. 4 passed; 0 failed
注入证红（纪律②，删掉判据函数里的 URL 直通）:
  ⇒ test result: FAILED. 3 passed; 1 failed（url_shaped_episode_ids_are_direct_play 红）
  ⇒ 恢复后复跑 4 passed / 0 failed。
回归（lib 过滤）: --lib provider ⇒ 74 passed/0 failed；--lib playback ⇒ 4 passed/0 failed；
  --lib resolve ⇒ 8 passed/0 failed。真机验证：DLL 重 build + 部署由 driver-ops 统一轮做
  （lead 已把本笔排进部署序列），实机复播 4K网盘条目攒批末。
```
