# Agent Note: 缓冲条已满却仍转圈 —— 判据方向对，但验证前提不成立（未能复现现象）

Status: rejected — 判据方向正确，但产品真实播放走 streamproxy 并行预取，两次真机实验都绕过了它，无法复现 Owner 描述的「转圈很久」；无现象可复现时写门禁只能是恒绿。

## Problem

Owner N10：

> 进度条明明已经缓冲满了（数据在本地），松手后转圈还转很久。

复述（这是后续判据的前提）：

```text
用户拖到 T → mpv seek → 中央出现 AppLoading 转圈
→ 但「T 位置的数据其实早就下载完了」
→ 转圈仍然持续很久
```

**用户抱怨的不是「转圈」，是「不该转的时候转」。** 数据在本地 ⇒ 没有等待理由。

### 现状：两个互不相干的信号

```text
转圈的唯一渲染点   lib/ui/player_page.dart:14596
                     if (_buffering && !_loading)
                       const Center(child: AppLoading(ground: Colors.black))

_buffering 唯一写入 lib/ui/player_page.dart:861   bool _buffering = false;
                   lib/ui/player_page.dart:4004  _player.stream.buffering.listen((v) {
                                                   if (mounted) setState(() => _buffering = v);
                                                 })
```

「缓冲条画到哪」读的是**另一个**变量：

```text
lib/ui/player_page.dart:20149  class _BufferPoller   （每 500ms 轮询 mpv）
    demuxer-cache-time      → Duration? end      （缓存终点，绝对时间轴）
    cache-buffering-state   → double? statePercent
    demuxer-cache-duration  → double? spanSec    （缓存跨度）
  ⇒ onChanged 写 _bufferedRange（lib/ui/player_page.dart:13715）
```

⇒ **底栏缓冲条读 `_bufferedRange.end`，中央转圈读 `_buffering`，两者没有任何交叉验证。**
这就是「条满了、圈还在转」的结构性根因假设。

### mpv 侧配置：全仓零配置，走默认值

```text
lib/core/clip_download.dart:460  mpvCacheProperties() 只下发 3 项：
    demuxer-max-bytes / demuxer-max-back-bytes / cache-dir

★ cache-pause / cache-pause-wait / cache-secs 全仓 0 处配置
```

mpv 默认值（已从源码 `options/options.c` 的 `mp_default_opts` 核实）：

```c
.cache_pause      = true,   // 默认开
.cache_pause_wait = 1.0,    // 默认 1.0 秒
.demuxer_thread   = true,
```

## Proposal

（方案本身方向正确，但因验证前提不成立而未能落地，记录于此供后人参考。）

**用「seek 目标位置是否已落在 demuxer cache 区间内」作为显示判据，
不改任何 mpv 缓存参数，不加 seek 宽限期。**

```text
新增：bool get _showBufferingSpinner =>
    _buffering                    // mpv 说的真信号，不动它
    && !_seekTargetCovered;       // 且目标位置**不在**缓存区间内

_seekTargetCovered 由 _BufferPoller 每次 tick 重算：
    有 seek 目标 T： T <= end && (start == null || T >= start)
    无 seek 目标：   false   ⇒ 行为与改前**完全一致**
```

## 为什么被否决（2026-10-18 真机取证结论）

### 一、两次真机实测的读数

用 `lib/t66_buffer_probe.dart`（取证后已删除）在 Windows 真机跑了两组：

**第一组：本地 file://（`audio_only.mkv`，30023ms）**

```text
[buffering] t=10ms  → true      ← 起播
[buffering] t=13ms  → false

A 近处已缓存 (3002ms):   true → false  同一毫秒，持续 0ms
B 远处未缓存(25520ms):   true → false  隔 1ms，持续 1ms
C 回到近处 (4503ms):     true → false  同一毫秒，持续 0ms

demuxer-cache-time 全程 = 29977ms（= 时长）
```

**第二组：自建限速 HTTP（200KB/s，支持 Range）**

```text
A/B/C 三组：buffering=true 均持续 0ms
cacheEnd 恒 = 29977ms
42 次采样，生产那条「缓冲区间校验」一次都没不过
|end-(position+span)| 稳定在 252~318ms（阈值 2000ms）
```

### 二、三次怀疑全部排除

```text
怀疑 3（缓冲条谎报）：排除
  84 次采样（两组各 42），|end-(pos+span)| 稳定 250~320ms，
  离生产校验阈值 2000ms 差 6 倍。那条「校验不过」日志一次都没打。

怀疑 2（_loading 是真凶）：排除（代码路径证明）
  player_page.dart:15175  onSeek: (d) { if (!_isLive) _player.seek(d); }
  _loading = true 的写入点只有 _startPlayback 的 :4366 / :4922 两处，
  seek 路径**完全不触碰 _loading**。

怀疑 1（网络流）：验了，但没能造出对照组
  audio_only.mkv 只有 370KB，200KB/s 也 2 秒传完 ⇒
  mpv 整文件缓存在 demuxer-max-bytes=256MB 里 ⇒ cacheEnd 恒 = 时长
  ⇒ covered = T <= end 对任何 T 都为真 ⇒ 判据无法区分「已缓存/未缓存」
```

### 三、决定性原因：**我的实验环境与产品形态不同**

产品真实播放链路是：

```text
mpv → 本项目自己的 Rust streamproxy（127.0.0.1:PORT）→ 上游源站
      rust/sourin_core/src/streamproxy.rs
```

而 `streamproxy.rs` 里有**并行预取**（`plan_prefetch`，:1385）：

```rust
// streamproxy.rs 已实测的吞吐（该文件注释原文）：
//   单连接 206 KB/s；4 并发 879 KB/s；8 并发 1501 KB/s
// PREFETCH_MIN_REMAINING = 512 * 1024   ← >512KB 才启用
```

它对 `Range` 请求做**多连接并行预取再按序拼接**。

⇒ 我的两组实验（本地 file:// / 自建 HTTP 200KB/s）**都绕过了项目自己的 streamproxy**，
测的是「mpv 直连」的行为，而产品跑的是「mpv + 代理 + 并行预取」。

**这两者在这件事上行为不同。** ⇒

### 四、最关键的矛盾，至今无法解释

```text
Owner：「拖动结果还是要转圈圈好长的时间」
实测：  seek 后 buffering=true 持续 0~1ms（三组 × 两种媒体类型，全部如此）
```

**这个矛盾未能解决。** 而它意味着：

```text
· 若 Owner 的场景确实存在持续很久的转圈
  ⇒ 我两次实测的读数**不能代表产品行为**（缺 streamproxy / 并行预取 / 防盗链握手）
· 若不能复现，就不能确认自己要修的是不是 Owner 报的那个问题
```

**没有复现现象就写门禁，只能写出恒绿门禁。** 这是本方案被否决的直接原因。

## Alternatives considered

### F1 · seek 宽限期（"先别转圈，等 N ms"）—— 否决

```text
· 真慢网络下 N 毫秒后照样转，只是晚了 ⇒ 用户看到「先黑屏一下再转」
· 它篡改了转圈出现的时机 ⇒ 时序类假绿
· lead 红线明确禁止「转圈不出现 ≠ 播放流畅」
```

### F2 · 改 cache-pause / cache-pause-wait / cache-secs —— 否决

```text
cache-pause=no     ⇒ mpv 不再暂停等数据 ⇒ 慢网络下花屏/断续播放，比转圈更糟
cache-pause-wait↑  ⇒ 本地更快，但慢网络转圈**更长**（拆东墙补西墙）
cache-secs↓        ⇒ 前向缓冲变浅 ⇒ 网络抖动更易卡
```
★ 初稿曾打算把 `cache-pause-wait` 调到 5s，**自己推翻了**：
判据层面已解决本地场景，再动 mpv 参数是用新的不确定性换一个已解决的问题。

### F3 · 写一条「本地已缓存 ⇒ 不转圈」的门禁 —— 否决（本次的关键决定）

```text
widget 测试里**没有真 mpv** ⇒ `_player.stream.buffering` 一条事件都不发
⇒ `_buffering` 恒 false ⇒ 中央转圈永远不出现
⇒ 这条断言在改前改后**都是绿的**。

★ 写一条恒绿的门禁比不写更糟 —— 它会让后人以为这里被守住了。
```

## 什么时候可以翻案（需要什么材料）

```text
要验本方案，必须同时满足：
  ① 媒体足够大（>50MB 或时长 >30 分钟），使 demuxer-cache-time < 时长
  ② 让它**经过项目的 streamproxy**（走 SourinApi 起代理那条路），
     而不是直连 —— 这一步是我两次实验都漏掉的决定性变量
  ③ 能复现 Owner 那种「转圈持续很久」的现象
  ★ ③ 最关键：没有它就无法确认修的是不是真问题

若 ①②③ 都满足后本方案仍无效（例如 covered 判据压不掉转圈），
则说明缺陷在 media_kit 的 PlayerStream 封装层或 streamproxy，
应重新定位。此时本 note 可整体作废。
```

## Consequences

### 保留的价值：两份真机读数（避免后人重复劳动）

```text
1. seek 后 buffering=true 只持续 0~1ms（本地文件与自建 HTTP 两种环境）
   ⇒ 若有人想用「缩减转圈时长」这类指标做门禁，先看这个数
2. 生产那条「缓冲区间校验」(player_page.dart:13883, 阈值 2000ms) 在 84 次采样里
   从未触发，|end-(pos+span)| 稳定 250~320ms
   ⇒ 缓冲条画的是自洽的，没有「谎报」问题
```

### 一个仍然成立的正面结论

```text
「缓冲条读 _bufferedRange.end、转圈读 _buffering，两者没有交叉验证」
这个结构性问题**客观存在**（代码可证），只是：
  · 它在本地/小文件/快网络下不产生可见症状
  · 在产品的 streamproxy + 并行预取形态下是否产生症状，**未验证**
```

### 未做的事（如实记录）

```text
· 没有把 streamproxy 接进实验（缺真实大文件源与慢速上游）
· 没有复现 Owner 描述的「转圈持续很久」
· 没有写任何门禁（写了是假绿）
· 没有改一行生产代码
· 加过的两个探针（debugPlayerSetBufferingForProbe /
  debugPlayerBufferingSpinnerVisibleForProbe）已按 lead 指示撤除 ——
  无调用点的公开 API 是死代码
```
