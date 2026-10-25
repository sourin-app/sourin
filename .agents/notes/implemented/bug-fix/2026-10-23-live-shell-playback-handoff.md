# Agent Note: Shell 直播路由播放快照交接

Status: implemented

## Problem

Shell 的直播全屏回调接收 initialPlayback，但未传入 PlayerPage；退出快照没有订阅，也没有在路由完成后返回。内嵌播放器与全屏播放器已有快照接口，实际入口却断线，源码字符串测试未覆盖该边界。

与既有决定的关系（部分重叠）：本篇补齐 [直播频道分组与冷启动](../feature/2026-10-18-live-channel-groups-and-cold-start.md) 留下的**交接面**——那篇解决「进直播页取流」，本篇解决「从全屏返回时把播放状态带回去」。那篇保留、不归档。

## Decision

lib/shell.dart 的 handoffLivePlayback 是实际直播入口调用的路由交接函数。它向 PlayerPage 构造回调传入初始快照和退出报告回调，等待 push 完成后返回已捕获的快照。没有退出报告时保持 null，不根据路由布尔结果或初始状态推断播放意图。频道列表、切台回调及设备参数仍由原入口提供。

## Alternatives considered

仅在原闭包中补参数和 return 的改动更少，但难以在不初始化整个 Shell 和原生播放器的条件下控制路由完成时序，因此提取同文件内的最小交接函数。

完整 Shell 客户端测试会带入核心初始化、页面加载和原生播放器依赖。本次使用实际交接函数、真实 PlayerPage 对象和可控路由 Future 验证边界，不将其描述为真实客户端播放验收。

## Consequences

初始播放、静音和期望音量可经现有快照接口交接；退出报告在路由完成前捕获，交接 Future 不因提前报告而提前完成。新增公开函数是测试接缝，未改变 PlayerPage 实现或其他生产文件。测试未挂载 PlayerPage，未验证原生音频输出、真实导航动画、快捷键和播放器销毁时序。

## Verification

命令：export PATH="<flutter-sdk>/bin:$PATH"; flutter test test/live_shell_playback_handoff_test.dart --concurrency=1 --reporter expanded。

保留原断线语义的提取基线：退出码 1，初始快照为 null、退出报告回调为 null 两项真实断言失败；缺失报告返回 null 一项通过。接线修复后同命令退出码 0，三项全部通过。红基线是在当前工��作树中提取接缝后、修复前运行，不是纯净历史提交基线。

仍需真实客户端验收内嵌暂停进入全屏、全屏调音量和静音后返回、快速切台与退出、双播放器音频释放；本次修复不代表第 15 至 17 项总体验收完成。

### Task-6 Decision：验收入口与异步回执

内嵌底栏和 toggleUserPlaybackForProbe 共用 runLiveUserPlaybackToggle，传入当前原生 Player 的 pause/play 方法，保持原生命令完成后再调用 onUserPause 的顺序。命令失败不发布成功的用户意图。

LivePage.watchLiveForProbe 直接等待原有 _watchLive，不创建第二套导航。LiveRoundtripReceipt 分别暴露 routeResultReturned、finished、routeReturnedAt、restoredAt 和 error。路由结果在原回调 await 结束后记录；恢复完成仅在原操作正常结束且页面仍 mounted 时记录。finished 表示操作终止，不等于恢复成功；路由结果也不等于退场动画或原生销毁完成。

LiveEmbeddedDisposalReceipt 由 State 持有，探针须在卸载前保留引用。同步 State.dispose 清理引用后启动原生 dispose Future 的观察，回执保留实例标识、是否存在原生播放器、完成时间、错误与堆栈。completed 表示观察结束，调用者必须同时检查 error 与 hadNativePlayer；无原生播放器的完成不冒充原生释放证据。进入全屏仍暂停保活，不改变播放器生命周期。

### Task-6 Alternatives considered

直接调用内嵌 pause 或修改 _userPaused 更短，但前者不发布用户暂停意图，后者复制状态机，因此使用底栏共用方法。为探针另建 PlayerPage 会绕过生产 Shell，故包装原有 _watchLive。单个布尔完成标志会混淆路由返回、恢复与释放，故保留独立 Future 和时间戳。把 State.dispose 改为异步破坏 Flutter 生命周期契约，故同步启动观察并通过独立回执报告异步结果。仅以组件卸载或播放器引用清空作为释放证据会过早完成，未采用。

### Task-6 Consequences

仅增加验收接缝，不改变全屏暂停保活、导航或恢复状态机。回执是 Dart 异步操作证据，不证明实际音频输出。无路由、页面卸载或恢复失败时不报告恢复成功；调用者需检查 finished、restoredAt 和 error，不应无限等待没有发生的 routeResultReturned。

### Task-6 Verification

新增 test/live_acceptance_receipts_test.dart，行为测试使用可控 Future 验证暂停与播放的命令先于意图通知、命令失败不通知、路由返回先于恢复完成、卸载或恢复失败不报告恢复成功、销毁等待与成功/错误回执；另有 stream:null 的组件卸载测试检查同步生命周期与保留回执。原生 pause/play 方法接线另以明确标注的源码契约测试防漂移，该项不是行为或原生播放证据。

当前状态：待跑。按 lead 指令未运行 Flutter 测试，未进行故障注入，尚无本次测试退出码或 .probe 日志。后续串行窗口需运行基线，并分别注入提前发布意图、提前标记恢复、提前完成销毁观察的故障，记录真实失败退出码，再恢复代码并运行绿测。以上测试不证明实际声卡输出、真实生产频道往返、路由退场动画或原生播放器释放。
