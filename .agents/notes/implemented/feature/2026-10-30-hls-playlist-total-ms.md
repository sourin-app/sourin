# Agent Note: resolve 链路读 HLS 清单，把真实整集时长带进候选（task-8「6 秒」问题）

Status: implemented

日期: 2026-10-30
任务: task-8（Owner「大部分都是播放都是6秒」——真机取证定论：时长读数错，不是内容短）
相关: [../feature/2026-10-29-share-page-play-resolves-to-direct-link.md](../feature/2026-10-29-share-page-play-resolves-to-direct-link.md)
  （同一 resolve 出口填字段，链路本身不动）。Independent: 不取代该篇。

## Problem

```text
那条 dur=6 的「第33集」清单原文（.probe 取证，tests/live_probe_6s_stream.rs）：
  #EXT-X-TARGETDURATION:6   ← 6 来自这里，是分片目标时长不是内容时长
  #EXTINF:6/#EXTINF:4 交替 17 段（末段 3.72s）
  #EXT-X-DISCONTINUITY ×2 + #EXT-X-ENDLIST，SUM total=82.720s
遥控每 3 秒采样：dur 6→6→6→4、pos 归零，正好对上 EXTINF 分片序列
⇒ mpv 在 DISCONTINUITY 处重建时间轴，stream.duration 报"当前分片时长"。
Owner 否掉时长阈值做法（「不应该以时间判断」），已 revert（49345b0）。
```

## Decision

1. `model.rs` StreamCandidate 新增两字段（serde camelCase，契约逐字）：
   - `playlist_total_ms: Option<u64>` → JSON `playlistTotalMs`（skip if None）
   - `playlist_discontinuous: bool` → JSON `playlistDiscontinuous`（skip if false）
2. `hls_facts.rs` 新增接线（复用既有 `parse_playlist_facts`，不重写）：
   - `fields_from_facts`（**纯决策**）：硬约束①只有 ENDLIST 且 EXTINF 求和>0 才填 total
     （直播必须 None；0 毫秒同样是错误读数）；约束⑤ discontinuous 照实反映计数>0。
   - `probe_playlist(url, headers)`：整体 1500ms 预算（PROBE_BUDGET_MS）包 master+子清单
     两次取数；master 追第一变体子清单（`master_variant_uri` + `resolve_uri`，支持相对/根相对）；
     非 200/超时/解析失败一律返回默认值，绝不 Err。
3. `playback.rs` resolve 出口：只对 `kind == Hls` 的候选、在 `maybe_proxy` **之前**
   （用原始上游 URL + 候选自带头 Cookie/Referer/UA）探测并填两字段；
   拿到事实就 `applog::write_file_log("PLAY", "清单事实 …")` 落文件日志（排障用）。
4. `providers/m3u_live.rs`：补新字段初始化（直播流恒 None/false —— 硬约束①的静态形态）。

## Alternatives considered

```text
A. 用时长阈值标样片/跳过 —— Owner 逐字否掉（「不应该以时间判断」），已 revert（49345b0）。
B. 解析 TARGETDURATION 当总时长 —— 那正是「6 秒」假象的来源，绝不混用（门禁断言 ≠）。
C. 对 mp4 直链也读 —— mp4 没有清单可读，且徒增起播延迟，砍（约束④）。
D. 每候选各给 1500ms —— 3 条 hls 候选最坏 4.5s，起播被拖慢；改整体 1500ms 预算。
E. 在 maybe_proxy 之后读清单 —— 本地代理地址读清单无意义且可能改变事实来源，砍。
```

## Consequences

```text
门禁 rust/sourin_core/tests/playlist_facts_wire.rs（独立新建）:
  cargo test --test playlist_facts_wire --release ⇒ 7 passed / 0 failed
    · 真实清单 total=82720 且 ≠ target*1000（离线）
    · 硬约束①：同一份清单去 ENDLIST（直播）⇒ total=None、discontinuous 仍照实 true
    · 有 ENDLIST 无分片 ⇒ None
    · probe 全链（本地 axum）：media 直读 82720；master→720/hls/index.m3u8 追子清单 82720；
      上游 2.5s 不响应 ⇒ 1500ms 预算内返回 None/false
    · 接线源码级断言：playback 经 probe_candidate 探测，守卫收口 should_probe_candidate
正向常驻门禁（lead 要求跑在 --lib）：src/hls_facts.rs tests 新增
  live_form_without_endlist_yields_none_total（有 EXTINF、无 DISCONTINUITY、无 ENDLIST ⇒ total=None）
  ⇒ cargo test --lib hls_facts --release ⇒ 6 passed / 0 failed
注入证红（纪律②）：把「无 ENDLIST 则 None」短路（`if f.total_ms > 0`，让直播也填）
  ⇒ live_playlist_without_endlist_must_be_none FAILED（"直播没有总时长——填了就是错的"）
  ⇒ 恢复后 grep 全 src 无「注入证红·临时」残留（提交前确认，恢复不彻底=直播时长写错的漏网）。
全量：cargo test --lib --release ⇒ 1932 passed / 0 failed（基线 2018+ 滤号计入新门禁后单跑见上）；
  --tests 口径读数见提交前最终记录（无编译错）。
```

## Consequences（续）：守卫补漏

```text
现象：csp-appyqk「老舅除三害」（就是取证里 82.72s 的清单）起播了但无「清单事实」行、
      duration 没修正 —— 该源把实际是 master.m3u8 的流标成了 kind=Mp4，
      旧守卫 if kind==Hls 正好被错标跳过（这类"标 mp4 实为 m3u8"不会是孤例）。
修法（客观事实，不猜）：判据抽纯函数收口一处——
  · looks_like_hls_url(url)：去 query/fragment 后 path 以 .m3u8 结尾（大小写不敏感）
  · should_probe_candidate(kind, url) = matches!(kind, Hls) || looks_like_hls_url(url)
  · probe_candidate(&mut StreamCandidate)：守卫+探测+填字段的候选级入口，playback 一行调用
门禁（追加到 playlist_facts_wire.rs，10 passed / 0 failed）：
  · looks_like_hls_url 单测（.m3u8 大小写 / .m3u8?query / #frag / .mp4 不认 / 无后缀不认 /
    query 里出现 .m3u8 不算 path）
  · should_probe 或语义单测（Hls+任意 URL 读；Mp4+.m3u8 读；Mp4+.mp4 与无后缀不读）
  · axum 全链：kind=Mp4 的 m3u8 候选 ⇒ probe_candidate 照样读出 82720/discontinuous=true
注入证红：删掉 should_probe_candidate 里的 URL 兜底那半
  ⇒ probe_candidate_fills_mislabeled_mp4_hls 与 should_probe_or_combines_* 两处 FAILED
  ⇒ 恢复后复跑 10 passed / 0 failed；「注入证红·临时」残留 grep = 0。
顺带抓到的真 bug：resolve_uri 此前不剥 base 的 query —— 带 `master.m3u8?sign=…` 的现场
  URL 追子清单会拼进 query 后面必 404（正是 appqk 的 URL 形态），已修（base 先去 query/fragment）。
最终绿读数：--lib hls_facts 6/0；--lib playback 4/0；--test playlist_facts_wire 10/0。
```
