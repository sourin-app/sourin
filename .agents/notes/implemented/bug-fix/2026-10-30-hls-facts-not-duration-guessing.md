# Agent Note: 6 秒假象的真因是 mpv 按分片报时长 —— 建客观清单事实模块，不猜阈值

Status: implemented

Independent: 本篇**取代** `2026-10-30-duration-shape-implausible-tag.md`（该篇已被 revert 49345b0 删除）：
那篇用「电影 <20min / 剧集 <3min」这种自定时长阈值给内容贴「疑似片段」，
被 Owner 一句「不应该以时间判断」否掉 —— 阈值是猜的，而且猜错了对象。
本篇改为读清单文本里**客观存在的标记**，并给出被实测推翻的因果链。

## Problem

Owner 现场反馈：「我今天还看了你大部分的都是播放都是 6 秒，根本就不是完整的视频内容」。

我第一反应是"内容确实是片段，需要识别并标注"，于是加了时长阈值判据 —— 这是错的，
既没回答「6 秒到底是什么」，又要靠猜阈值工作。

补做取证（`rust/sourin_core/tests/live_probe_6s_stream.rs`，走生产 `resolve_stream`
拿真实 URL 后直接 GET 清单），拿到那条 `dur=6` 的「第33集」清单原文：

```text
#EXT-X-TARGETDURATION:6          ← 6 来自这里
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:6.000000, / #EXTINF:4.000000,   （6/4 交替，共 17 段）
…
#EXTINF:3.720000,
#EXT-X-DISCONTINUITY             ← 不连续点 1
#EXTINF:3.000000,
#EXT-X-DISCONTINUITY             ← 不连续点 2
#EXT-X-ENDLIST

SUM extinf_count=17 total_seconds=82.720
```

再看运行中 App 的实测时序（遥控 `/api/state` 每 3 秒采样同一条）：

```text
t=9s   dur=6 pos=1
t=12s  dur=6 pos=3
t=15s  dur=6 pos=5
t=18s  dur=4 pos=0     ← duration 从 6 变 4、pos 归零
```

`dur` 的变化序列（6→4）**正好对上清单里的 `#EXTINF:6, 4, 6, 4…` 分片序列**。

⇒ **真因**：该清单含 `#EXT-X-DISCONTINUITY`，mpv/media_kit 在不连续点重建时间轴，
`stream.duration` 报的是**当前分片**的时长，不是整集时长。
整集其实 82.72 秒、一直在正常播；错的是**时长读数**（显示 6 秒、进度条/剩余时间/
连播判据全部跟着失真）。

⇒ 所以这不是"内容不完整"，也不是"要用阈值识别片段"，而是 **duration 读数不可信**。
Owner 的「不应该以时间判断」正好指向这一点：拿一个本身就错的数去做判断，怎么定阈值都是猜。

## Decision

新增 `rust/sourin_core/src/hls_facts.rs`（纯函数、零网络、永不 panic）：

```text
parse_playlist_facts(text) -> PlaylistFacts {
    is_master, has_endlist, discontinuity_count,
    segment_count, total_ms,          ← ★ EXTINF 求和 = 真实内容时长
    target_duration_secs,             ← ★ 明确命名为 target_，防止被当 duration 用
}
```

三条刻意的防误用设计：

1. **门禁直接断言 `total_ms != target_duration_secs * 1000`**，
   把"混用两者 = 6 秒假象根因"这条教训钉在测试里，而不是只写在注释里。
2. `#EXT-X-DISCONTINUITY-SEQUENCE` 不算不连续点（它只是序列号）——
   单独一条测试钉住，防将来误判。
3. master 清单 `segment_count/total_ms` 恒为 0，**不许回落到 TARGETDURATION**
   （`targetduration_alone_is_not_duration` 测试专门守这条）。

本模块只做"事实读出"，**不做任何"这算不算坏流"的判断** ——
`DISCONTINUITY` 在合法的多段拼接（广告切回正片）里也会出现，
据此判死刑就又回到猜了。真实用途是：给上层一个可信的整集时长，
替代不可信的 `stream.duration`。

## Alternatives considered

- **时长阈值判据（本篇取代的那版）**：阈值是猜的；而且它建立在"mpv duration 可信"这个
  错误前提上 —— 读数本身错了，阈值定多少都是在错数据上雕花。Owner 否掉，成立。
- **按源名判（短剧源不判片段）**：源清单会漂、新源接进来就漏、同名源内容混杂。否决。
- **直接把 `TARGETDURATION` 当 duration 用**：这就是本次 bug 的成因，正是我们要消除的误用。
- **在 UI 上显示"疑似时间轴跳变"**：只报症状不解决读数错误；而且 DISCONTINUITY 合法场景很多，
  等于把正常内容标成可疑。否决。
- **修 mpv 行为**：不是我们的代码，且它是按 HLS 规范在处理不连续清单。否决。

## Consequences

门禁：`cargo test --lib hls_facts --release` ⇒ **5 passed / 0 failed**。

注入证红（实测，已回滚并 grep 确认无残留）：

```text
把 #EXT-X-DISCONTINUITY 解析分支短路（if false && …）⇒
  test hls_facts::tests::real_case_reports_82s_not_6s ... FAILED
  assertion `left == right` failed: 两个不连续点
  test result: FAILED. 4 passed; 1 failed
回滚后复跑 ⇒ 5 passed
```

关键读数固化：

```text
那条被报成「6 秒」的节目：
  segment_count = 17
  total_ms      = 82720   ← 真实整集 82.72 秒
  target_duration_secs = 6 ← mpv 报的"dur=6"来自这里，它是分片目标时长
```

⚠️ **仍未修的部分（如实记录，不虚报完成）**：

- 本模块只提供了"正确读数的能力"，**还没有接到播放链路上**。
  要让 UI 时长/进度条/连播判据不再被 6 秒污染，需要下一步：
  resolve 阶段读一次清单（实测 1.7KB，可忽略）把 `total_ms` 带进 `StreamCandidate`，
  Dart 侧用它修正 `_realDuration`。这一步跨 Rust/Dart 且会改 duration 语义，
  需要独立设计与门禁，不在本篇范围。
- Owner 看到的"滚到下一集"现象：实测该源每集本来就是 ~82 秒的短剧，
  正常播完自动连播 ⇒ 与"时长读数错"是两回事，本篇不把它算作已修复。
- revert 49345b0 已撤掉基于猜阈值的那版判据（含其门禁与笔记），
  `pickDefaultPlayable` 回到只有 `<60s` 样片判据的状态（那是 Owner 原话指定的规则，保留）。
