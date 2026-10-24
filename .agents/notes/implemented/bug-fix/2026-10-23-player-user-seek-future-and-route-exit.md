# Agent Note: 用户跳转保留异步契约并在路由退出时回传直播快照

Status: implemented

## Problem

遥控 seek_to 与 skip_preview 接入用户意图保护后，void helper 丢弃了原生 seek Future，导致命令提前完成、seek 异常不再沿原入口传播。同步 UI 回调与遥控异步命令共享 helper，需要同时保留同步意图更新和原有等待契约。

系统返回已经真实退出播放器路由，但直播快照仅在 dispose 兜底上报。路由 Future 先完成，调用方拿不到本次播放状态。主动退出路径已有提前上报和去重保护。

Independent: 检索既有笔记的 seek_to、skip_preview、返回顺序、snapshot、用户意图与续播，未发现讨论这两个异步边界契约的既有决策；缓冲与健康检测笔记不覆盖本问题。

## Decision

在 lib/ui/player_page.dart 中让 _seekByUser 同步设置 _introSkipped、清空 _pendingSeek、推进 _seekToken，然后返回原生 seek Future。��仅原本等待 seek 的遥控 seek_to 与 skip_preview 恢复 await。相对跳转、百分比跳转与底栏同步 UI 回调保持原契约，不引入额外异步等待。

为行为测试增加每个播放器实例独立的可控用户 seek 边界；未注入时直接调用 _player.seek。测试仍从生产 RemoteBridge 分发命令，使用 Completer 控制原生操作完成与失败，不以源码字符串匹配代替行为证明。

在播放器根部添加 PopScope<bool>，仅 didPop 为真时调用已有 _reportLivePlaybackExit。主动退出提前上报与 dispose 兜底保留，由原有去重逻辑保证只报告一次。不阻止返回，不改路由结果。

## Alternatives considered

- 保持 void helper：用户意图保护有效，但丢失遥控命令原有完成时序和异常传播，行为测试已证实回归，放弃。
- 将所有 UI 回调改为异步等待：扩大修改面，且同步 UI 入口原本不等待 seek，放弃。
- 在 dispose 才回传快照：系��统返回行为红例显示 route-future 已完成而 snapshot 尚未报告，放弃。
- 拦截返回后手动 pop：增加返回重入和路由结果处理复杂度；现有成功 pop 通知已满足测试顺序，放弃。

## Verification

所有 Flutter 命令均先执行 export PATH="/c/Users/iuuuuuuuu/flutter/bin:$PATH"，原生测试显式使用 --run-skipped --concurrency=1 --reporter expanded，并在协调后的独占测试窗口串行执行。

- flutter test test/zz_t1023_player_seek_behavior_test.dart --run-skipped --concurrency=1 --reporter expanded：异步语义修复前原有 5 项通过，新增 4 项失败，退出码 1。两条遥控命令分别暴露提前完成和未传播原 seek 错误。
- 同一命令修复后 9 项全部通过，退出码 0。覆盖自动片头、手动零点保护、两条遥控零点保护、两条完成时序、两条错误传播和失败态底栏卸载。
- flutter test test/zz_t1023_player_route_exit_order_test.dart --run-skipped --concurrency=1 --reporter expanded：修复前 1 项通过、1 项失败，退出码 1。主动退出 events=[snapshot, route-future]；系统返回 events=[route-future]，canPop=false 且播放器仍处于反向过渡，证明路由已退出而 dispose 尚未执行。
- 同一返回测试修复后 2 项全部通过，退出码 0。两条路径均 events=[snapshot, route-future]，后续 dispose 不重复上报断言通过。
- 原生启动异常退出 79 不作为通过证据。本轮新增异步与返回修复的有效�绿例均正常退出 0。

## Consequences

遥控命令恢复可等待和原异常传播，同时用户意图仍在第一次 await 前同步生效。系统返回不再依赖反向过渡结束后的 dispose 才提供快照。

Leader 已独立联合复跑 seek_behavior 与 route_exit_order：11 项通过，退出码 0，主动退出与系统返回均为 events=[snapshot, route-future]。这是独立测试证据，不等同于真实客户端验收；可控 seek 测试证明命令异步契约，不证明真实媒体 seek 落点。

收尾将 Scaffold 保存为局部 page，再由 PopScope 包裹返回，避免整段 UI 重缩进；未做全文件格式化。已修正声称页面没有 PopScope 的过时注释，说明当前只观察成功 pop、不拦截返回，并复用快照去重保护。

新增独立 dispose-only 行为测试：直接挂载播放器，先断言尚无快照，再用 pumpWidget 替换整个树，不调用主动退出或 Navigator pop；断言播放器已卸载、快照恰好一次，并在后续清理后再次断言没有重复。现有退出顺序与去重断言保留。Leader 首次联合运行时，退出套件出现 did not complete，整体退出码 1；未找到残留测试进程或匹配的 Windows 崩溃事件，原因尚未证实。随后不改变断言和等待时长，独立运行直接销毁用例，1 项通过、退出码 0；独立运行完整退出套件，3 项通过、退出码 0。后续通过不抹除此前未完成记录，也不证明其根因已经解决。此后播放器跳转、退出与搜索三组联合回归为 16 项通过、退出码 0；这些结果均不替代真实客户端验收。

旧续播跨会话问题已取得行为复现，替代此前“仍待行为复现”的阶段性结论；上文历史失败和未完成记录保持不变。

### 续播取消的决策与最小修复

旧 waiter 在等待 duration 时保留 120 秒目标，仅清空 _pendingSeek 不会取消它。_gotoEpisode 在有效剧集校验后、_applySwitch 在详情读取和记录迁移前、_remoteSwitchSource 在同线路早退后，均在首次 await 前递增 _seekToken，使旧 waiter 在时长就绪时退出。applySession 已有跨会话取消逻辑，其同会话早退保留原 waiter。

备选方案：仅清空 _pendingSeek 的优点是改动局部且保留现有状态流，但行为红测证明它不足以取消已捕获目标的 waiter；延迟到新续播任务启动才取消可集中管理令牌，但无续播的新请求不会启动该任务，解析期间仍存在旧 waiter 生效窗口。因此选择在真实切换入口同步推进取消令牌，保留同会话早退语义。代价是取消边界分布在三个入口，后续新增切换入口也需维护这一契约。

测试通过真实 _gotoEpisode、RemoteBridge 的 switch_source 命令及无续播 _applySwitch 入口触发切换，不以直接修改会话字段替代生产入口。_applySwitch 探针只替换详情读取和记录迁移的外部边界；详情夹具不含 sources，因此不执行额外 getEpisodes 分支。流解析使用受控 Future 暂停，取消逻辑、状态迁移及 _seekAfterReady 保持生产实现。

### 续播取消的执行证据

- 初次新增用例运行退出码 1，存在异步回调内 expect 与 pump 的测试守卫冲突，不计作行为红测；日志为 .probe/player-resume-entries-red.log。修正测试回调后再运行，未先修改生产取消逻辑。
- 有效红测：不切换、同会话 applySession 两个正控通过；切集、遥控切源、无续播跨源换源三项失败，均为 Expected: empty、Actual: [Duration:0:02:00.000000]。合计 2 项通过、3 项失败，退出码 1；日志为 .probe/player-resume-entries-red-2.log。
- 最小修复后五项全部通过，退出码 0；两个正控仍执行 120 秒 seek，三条切换入口取消旧 waiter。日志为 .probe/player-resume-entries-green.log。
- 播放器组完整联合运行 seek_behavior 与 route_exit_order，报告 19 项通过，退出码 0；日志为 .probe/player-seek-route-full-green.log。
- Leader 独立联合复跑并读回终态：seek_behavior 16 项、route_exit_order 3 项、live_shell_playback_handoff 3 项，共 22 项通过，退出码 0；日志为 .probe/player-seek-route-live-lead-independent.log。主动退出和系统返回均记录 events=[snapshot, route-future]。
- 上述 Flutter 回归显式使用 --run-skipped --concurrency=1，完整输出及 EXIT_CODE 保存在对应日志中。

### 验证边界与交接

测试启动真实 _seekAfterReady，但通过探针建立未知时长的旧 waiter，并注入最终原生 seek 边界记录目标；不覆盖 _startPlayback 发起 waiter 的完整链路、真实解码或实际媒体 seek 落点。换源用例覆盖无续播请求，不证明含 sources 的剧集补取、真实记录迁移及全部网络失败路径。真实客户端的鼠标、键盘、手机跳转，慢源续播与片头交互，短时长、未知时长及失败恢复仍需验收。自动化通过不等于总计划或真实客户端验收完成。

Flutter 测试窗口已明确释放。队友返回的笔记编辑文本未自行落盘，由 Leader 读取当前笔记后应用更新并继续运行门禁。本次笔记更新不启动测试。未构建部署、操作鼠标焦点、提交、推送或发布。
