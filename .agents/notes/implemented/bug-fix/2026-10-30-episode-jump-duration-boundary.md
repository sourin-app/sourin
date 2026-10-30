# Agent Note: ep2→ep1 单次回跳排查 —— 5a07e73 链排除 + duration 边界钉住

Status: implemented（排查 + 边界门禁；非缺陷修复 —— 深查结论见下）

Independent: 起因是标题跟随真机核对（老舅 cctv 10s 样片连播 70s）中的单次
ep2→ep1 回跳（t=30→35s，仅一次未复现）。与 cead042/3668667 的无关联判定
已在上一轮给出（调用图可达性排除）。

## driver-ops 假设（假设标记）与代码级排查结论

```text
假设：10s clip 起播 ~3s 后 duration 测量完成（<60s 命中 1.3 样片判据）
     ⇒ 默认选线重新评估 ⇒ 二次 resolve 回落 ep1。

排查（逐行核对 5a07e73 全部调用链）：
① _recordLineDuration：只写内存 Map + UiPrefs.set —— 无 setState、
   无 resolve/goto、无任何监听器消费缓存写入；
② pickDefaultPlayable：全仓唯一调用点在 _load() 内部（resolveStream 返回
   后的既有流程）—— duration 广播**不会**进入它（没有任何路径在播放中
   重跑 _load 的选线段）；
③ _sampleBadgeFor：只在线路面板 build 时只读。
⇒ **假设不成立**：duration 到账在代码层不可能触发二次 resolve/选线。
```

## 触发源排查（08:29:15.663 那次 resolve）

```text
_startPlayback 全部调用点枚举：_load 主挑 / _bootLocalFile / set_quality（遥控）
/ _remoteSwitchSource（遥控）/ live 路径 ×3 / 线路面板 onPick / popover 换流
/ retry 按钮 / _reload→_gotoEpisode 链 —— 除自动连播外全部需要显式动作
（用户/遥控 cmd，窗口内为零）。
自动连播链：completed → _onEnded → 三分支（singleLoop seek(0) 同集 /
autoNext index+1 / stop）—— _nextEpisode 恒 = _epIndex+1，**结构性到不了 0**。
_onEnded 单集循环是 seek(0)+play 同一条流（无 resolve、无集变化）。
⇒ App Dart 层没有任何自动路径能产生"落点 ep1"的二次 resolve。
```

## 结论（判定）

```text
最可能形态：**播放内核/流层重开**，而非 App 切集 ——
· 时序：ep2 首帧 08:29:12.8（起播卡顿 16s，cctv 官方线已知间歇失败形态
  audit 问题3）→ 08:29:15.663 第二次起播，间隔 2.9s。App 侧切集走
  _gotoEpisode 全链（日志必有「当前集变化」+ 保存进度行），两次起播仅隔
  2.9s 且无 cmd，更像 mpv/media_kit 对卡顿 HLS 的重开/EOF 语义。
· 终判所需证据（转 driver-ops）：第二次起播 [PLAY] 行的 **URL** 与
  ep1/ep2 各自 m3u8 比对 + 窗口内有无「当前集变化」行：
  · URL=ep2（或同 main.m3u8）⇒ 内核重开、App 无切集动作，
    /api/state 的 order=1 读数是重开窗口期的读数毛刺；
  · URL=ep1 ⇒ 存在未知 ep1 信号，重新回来深查；
  · 窗口内有「当前集变化 → ep1」行 ⇒ 有一路显式切集信号，同样回来深查。
· 单次出现、未复现二，与"间歇性流层毛刺"吻合。
```

## 防回归产出（本批实际落地）

```text
① 监听体收敛：duration 订阅体抽成生产方法 _onDurationTick（与
   _onPositionTick 同模式）—— mpv 订阅与门禁探针同调一份，
   "duration 到账的行为边界"从此有单一执行点；
② 探针 debugPlayerPushDurationForProbe / debugPlayerLineDurationForProbe；
③ 边界门禁 test/t20261030_duration_arrival_no_replay_test.dart 3 passed：
   duration 到账 ⇒ _startPlayback 调用数不变、_epIndex 不变、缓存本职写入
   还在；duration=0 ⇒ 连缓存都不写；静态断言监听体只许走 _onDurationTick
   （内联回调会让边界失去单一执行点，将来挂选线/重试进去时运行时断言抓不到）。
```

## Alternatives considered

### A. 按 driver-ops 假设直接"修"：把 _recordLineDuration 挪出监听/延迟写入

否掉的原因：假设已被代码级排除——修一个不存在的因果链等于掩盖真因；
且延迟写入会让 1.3 的"下一轮选线避开样片"变慢，无收益。

### B. 给自动连播加"不许回跳"守卫（如 goto 前断言目标 index > 当前）

否掉的原因：现有链路（completed→_onEnded→index+1）结构性到不了更小 index，
守卫判不出任何东西（假守卫）；真回跳若来自内核重开，App 侧守卫也拦不住。

## 验证结果（已发生）

```text
门禁：t20261030_duration_arrival_no_replay_test 3 passed
故障注入（实测真红后恢复复绿）：_onDurationTick 挂"duration 到账 ⇒ 重播
首候选"（模拟假设回归形态）⇒ ①② 调用数断言红
回归：样片门禁 9 passed（1.3 无回归）、标题跟随门禁 10 passed（分 4 组跑，
组③两次撞文档载明的 libmpv 偶发崩溃后单组复跑通过——非代码问题）、
analyze 0 errors
仪器坑（如实记录）：_recordLineDuration 的 UiPrefs 300ms 防抖 Timer 在
widget 测试结束时报"Timer still pending"假红 —— 测试内 pump 过防抖窗口
即可（已在门禁注释里写明）。
```

## Relations

- 1.3（被假设波及的功能）：[./2026-10-30-sample-line-duration-cache.md](./2026-10-30-sample-line-duration-cache.md)
- 标题跟随（真机核对引出本次排查）：[./2026-10-30-display-title-follows-autonext.md](./2026-10-30-display-title-follows-autonext.md)
