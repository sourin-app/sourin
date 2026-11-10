# Agent Note: 用 playlistTotalMs 修正 DISCONTINUITY 清单的 duration 读数

Status: implemented

Independent: 与 [hls-facts-not-duration-guessing](./2026-10-30-hls-facts-not-duration-guessing.md)
（task-8，Rust 侧 hls_facts.rs）是**同一契约的两半**——Rust 读清单算出事实塞进
StreamCandidate 两字段，本篇是 Dart 侧的解析与消费；阈值禁令同源（Owner：
「不应该以时间判断」，时长阈值判据已被 49345b0 revert）。

## Problem

真机取证已定论（勿再猜）：Owner 报「播放都是 6 秒不是完整内容」。那条 dur=6
的「第33集」清单原文：`#EXT-X-TARGETDURATION:6` + `#EXTINF:6/4` 交替 17 段 +
两个 `#EXT-X-DISCONTINUITY` + `#EXT-X-ENDLIST`，EXTINF 求和 = **82.720s**。
mpv 在不连续点重建时间轴 ⇒ `stream.duration` 只报**当前分片**时长
（遥控 3s 采样实测 dur 6→6→6→4、pos 段间归零），内容一直正常播 82.72s——
**错的是时长读数，不是内容**。

后果（若不修）：顶栏/进度条/遥控显示 6s；1.3 样片判据把 82.72s 的完整内容
误判成「疑似样片」并跳过默认线（6 < 60s）。

## Decision

```text
① StreamCandidate 新增两可选字段（与 Rust serde camelCase 逐字对齐）：
   playlistTotalMs: int?（ms，仅点播清单有 ENDLIST 时非空——直播无总时长，
     填了就是错的）
   playlistDiscontinuous: bool（清单含 DISCONTINUITY 的事实标记，默认 false）
   fromJson 解析 + copyWith 同步；**无 toJson** —— 该类型从不从 Dart 序列化
   回 Rust（遥控 qualities 只发字符串），加 toJson 就是死代码。缺键（旧 DLL）
   安全降级 null/false 不抛（与 persisted/solo 的旧核心兼容口径同一套）。
② 权威时长判据（StreamCandidate.authoritativeDuration getter）：
   playlistTotalMs 非空且 >0 ⇒ Duration(ms) 即权威整集时长；否则 null。
   消费点 = _onDurationTick（duration 广播唯一处理点）：有权威值 ⇒ **覆盖**
   `_duration`/`_realDuration`（顶栏/进度条/遥控 duration/存进度/seek 夹取
   全部经这两个字段，单点覆盖全生效）；否则广播值原样（普通源/旧 DLL 零变化）。
   _recordLineDuration 记**权威值**——记分片伪影 6s 会触发 1.3 误判样片。
③ playlistDiscontinuous：只做**中性事实**——每条流一次 debugPrint
   「时间轴可能跳变（总时长已用清单值修正）」；不判流坏、不写"疑似片段"、
   不改任何行为分支。
```

**覆盖 vs max 的取舍（task-9 指定要写的理由）**：选**覆盖**。
`playlistTotalMs` 是从清单本身量出来的事实（EXTINF 逐段求和，且仅当 ENDLIST
存在——点播已完结才填），它是"整集有多长"的**权威口径**；mpv 的
stream.duration 在 DISCONTINUITY 清单上是"当前分片有多长"的**伪影**——两者
不是同一口径下的竞争值，max 会把伪影保留在判据里（并且 6 vs 82.72 时 max
碰巧对、伪影大于真值时就错，判据建立在巧合上）。覆盖的语义是"有更好的
事实来源时用事实"；manifest 量不出来（非 hls/读清单失败）时字段为 null，
自然退回 mpv 观测值，行为与改前逐字一致。

## Alternatives considered

### A. max(playlistTotalMs, 观测 duration)

最强理由：对"清单值偏小"的源更宽容（如源清单漏段）。

否掉的原因：口径混掺——观测值是分片伪影，max 的结果取决于两者谁大，
而"谁大"由分片切换时刻决定（6/4/3 交替时 max 恒等于清单值纯属巧合）。
判据要的是确定性来源，不是"取大的那个"；清单漏段属源侧数据缺陷，
应归源侧修，不该在播放端用 max 掩盖。

### B. 用 playlistDiscontinuous 做"时长不可信"判定，discontinuous 时显示
   "总时长未知"而不修正

否掉的原因：playlistTotalMs 本身就是可信总时长——有事实不用、反而展示
"未知"，是把已取证的信息丢掉；且"discontinuous ⇒ duration 不可信"是
推断链，而"ENDLIST 清单 EXTINF 求和 = 整集时长"是直接事实，用后者。

### C. 时长阈值判据（<60s 视为片段，用 EXTINF 求和纠正）

否掉的原因：Owner 逐字否决（「不应该以时间判断」），且阈值正是 1.3 样片
误判的根源形态——任何阈值都会在"真 60s 内容"与"伪影 6s"之间划错线。
49345b0 已 revert 过一次，此路不通。

## Consequences

**收益**
- DISCONTINUITY 清单条目：总时长显示 82.72s（非 6s）；样片判据不再误判
  （缓存记权威值，门禁运行时断言）；顶栏/进度条/遥控/存进度/seek 夹取
  单点覆盖全生效。
- 普通源 / 旧 DLL：playlistTotalMs 缺失 ⇒ 全链路零变化（有专门用例钉住）。

**代价与边界**
- 进度条 position 仍是 mpv 分片时间轴（段间可能归零）——那是时间轴形态
  本身，Owner 定论"内容正常播"，修正它需要累计分片偏移，属另一命题，
  本批不做（playlistDiscontinuous 中性日志已如实告知形态）。
- 连播触发仍是 mpv completed（取证确认 DISCONTINUITY 不产生早期 completed），
  本改动不触碰连播触发链。
- Rust 未填字段（task-8 未部署/旧 DLL）⇒ 字段 null ⇒ 全部退回旧行为。

## 验证结果（已发生）

```text
门禁：test/t20261030_playlist_total_duration_test.dart → 6 passed
  ① 解析 4 条（82720/true 逐字解析 + 权威值 82.72s、缺键降级 null/false 不抛、
    0 值权威不可用、discontinuous 缺键 false）
  ② 真树 2 条：灌 playlistTotalMs=82720 + 探针推 6s 广播 ⇒ 遥控 duration=82、
    1.3 缓存记 82（不误判样片）、集序不变；推 4s（分片重建）仍 82；
    无清单事实 ⇒ 广播 6s 原样（普通源零变化）
  中性日志实测输出一行：「该线路清单含 DISCONTINUITY，时间轴可能跳变
  （总时长已用清单值 82720ms 修正）」
故障注入（实测真红后恢复复绿）：_onDurationTick 退回广播值直写（覆盖失效）
  ⇒ 组②红（读数回到 6）
回归：duration 边界门禁 3 passed（task-9 改动不违反"duration 到账不重播"
  边界）、样片门禁 9 passed（其静态断言随实参更新为 _recordLineDuration(
  authoritative)——契约本体未变，运行时证明在新门禁缓存断言）、标题跟随
  纯函数组 7 passed；analyze（models/player_page）0 errors
真机：批末由 driver-ops 复播那条 dur=6 的清单，核对显示 82s 与 1.3 不误标。
```

## Relations

- 同一契约的 Rust 半边：[hls-facts-not-duration-guessing](./2026-10-30-hls-facts-not-duration-guessing.md)
- 样片判据（缓存记权威值的直接受益者）：[./2026-10-30-sample-line-duration-cache](../feature/2026-10-30-sample-line-duration-cache.md)
- duration 边界（本改动所在监听的行为契约）：[./2026-10-30-episode-jump-duration-boundary.md](./2026-10-30-episode-jump-duration-boundary.md)


## Effective duration updates (2026-11-09)

media_kit already deduplicates raw duration events. Distinct segment readings can
still map to the same authoritative playlist total. `_onDurationTick` now rebuilds
the page only when the effective display/progress duration or the cached line's
sample badge changes. `_recordLineDuration` skips serialization when the same
line already has the same whole-second value. The authoritative fact selection
and existing sample policy are unchanged.

Do not early-return from the duration callback merely because the displayed total
is equal: a new current line still needs its own cache entry and progress identity.
Record before comparing the line badge. A rendered regression caught a first draft
that left a second short line's badge stale; the final code updates that label.

`player_duration_rebuild_test.dart` uses the real PlayerPage, native media library
and isolated transport. It counts actual page builds, reads the rendered bottom
bar and line labels, and checks precise duration, zero-value preservation, same
duration on another line, and no playback restart. Eight distinct segment values
caused eight builds before the fix and zero afterward; genuine duration/badge
changes still build. This is widget behavior evidence, not a measured external
playback frame-rate improvement. Native/client receipts belong in the execution
plan. The related sample-cache note still owns its labeling/default-line policy.
