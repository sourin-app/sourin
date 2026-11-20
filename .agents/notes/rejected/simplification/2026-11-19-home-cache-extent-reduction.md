# Agent Note: 首页 cacheExtent 收窄候选不得移入生产

Status: rejected — 四种 cacheExtent 候选均未同时保住方向键焦点、图像预热与现有首页行为；其中纵向归零在宽屏没有改善。

Related: [首页横向轨道鼠标拖动](../../implemented/bug-fix/2026-10-23-home-horizontal-rail-mouse-drag.md)、[首页卡片与动效边界](../../implemented/bug-fix/2026-11-08-home-card-and-motion-boundaries.md)、[首页缓存与区块失败反馈](../../implemented/bug-fix/2026-11-09-home-cache-and-section-failure-feedback.md)、[直播懒加载键盘揭示](../../implemented/bug-fix/2026-11-11-live-keyboard-lazy-channel-reveal.md) 与 [海报图片配置复用](../../implemented/simplification/2026-11-19-poster-image-configuration-reuse.md) 继续拥有各自的行为、焦点、缓存语义与图片生命周期。本篇只记录 2026-11-19 隔离实验的拒绝结论，不取代这些决定。V41 的帧号归因边界见 [同运行帧号 trace 归因](../../implemented/testing/2026-11-19-frame-number-trace-attribution.md)；它与 [渲染启动原因诊断](../../implemented/testing/2026-11-16-renderer-startup-cause.md) 一样，不把整帧阶段当成控件因果。

## Problem

V41 的 source-posters 首次观察有 36 个已挂载 PosterCard、20 个几何可见且绘制可见的首页海报；这提示存在挂载多于可见的分配候选，但不能单凭 36:20 断定 cacheExtent 是掉帧根因，也不能把框架级 BUILD、LAYOUT 或 SEMANTICS 阶段归因到某个卡片或某行 Dart 代码。V41 诊断证据明确说明 trace 有额外开销；整帧 BUILD/LAYOUT/SEMANTICS 阶段不能独立归因某个 widget，已有命名 widget scopes 也仅用于诊断，不等于 CPU 或性能因果，更不等价于未加 trace 的性能验收。

为探查是否能在不移除 UI、玻璃、文字、焦点、语义或图片预热的前提下降低挂载数，隔离副本对当前 HomePage、PosterCard/图片复用与 Miuix 输入实现做了四种 cacheExtent 边界实验。实验使用 8 个合成区块、每块 30 张卡、DPR 1 的真实 widget 渲染与 loopback PNG 解码，不是桌面客户端或引擎性能测量。原有 SDK 默认（纵向 250 dp，横向保持现状）在窄窗 360×800、宽窗 1592×904、TV 960×540 的读数分别为 12:4:12、36:20:36、14:6:14（挂载:几何可见:初始 PNG 请求）。

## Proposal

候选只改隔离副本的视口 lookahead/cacheExtent，不改生产源码、图片 provider、语义、焦点节点、输入路由、滚动控制器或缓存数据：

1. zero-both：纵向与横向都归零。
2. zero-rail：保留默认纵向 lookahead，仅把非排名横向轨道的横向 lookahead 归零。
3. small-rail-168：保留默认纵向 lookahead，把非排名横向轨道改为 168 dp。
4. zero-vertical：纵向归零，横向保持默认。

旧默认和四个候选的全部回执、失败日志、截图与哈希保留在 .probe/home-cache-extent-20261119-v1/；本篇不重跑、不删除、不把任何一个候选改入生产。

## 实验事实与拒绝结论

- zero-both 降低了初始挂载，但实际方向键边界失败：宽窗预期到卡片 10 却停在卡片 9；TV 预期行 0 卡片 6 却跳到行 1 卡片 5。两轴都为零时，目标子树可能尚未挂载，方向键无法保持原有轨道与焦点语义。
- zero-rail 同样在真实方向键边界失败：宽窗预期卡片 10 却停在卡片 9；TV 预期行 0 卡片 6 却跳到行 1 卡片 5。它还会使 Right 操作停滞或进入下一分区，因此不能以较少 mounted 数换取交互退化。
- small-rail-168 的初始挂载门槛看似改善：旧候选为 36，横向 168 候选为 33，且宽窗仍有 20 张可见卡；但实际快速鼠标拖动揭示同一个裁剪区域 [1493, 256, 75, 266] 时，旧臂已经收到并解码 Card s0-11，候选臂尚未发起或完成该请求，要求 decoded == true 的门禁失败。目标裁剪区 19,950 个 RGBA 像素中有 16,535 个变化，之后释放响应才解码。故它破坏图像预热与首次揭示等价，不能采纳。
- zero-vertical 在宽窗仍为 36 个挂载、20 个几何可见、36 个初始请求；没有宽屏挂载改善。窄窗或 TV 的挂载减少不足以证明整体收益，也不值得改变纵向揭示与焦点边界。

因此四种边界方案均拒绝。在这四种候选的对照范围内，保留默认 lookahead 是当前唯一已验证的行为安全选择；36 mounted / 20 visible 仅是该隔离 workload 的观察值，不是全局预算，也不能反推出 widget 级根因或生产性能收益。

## Alternatives considered

- 继续使用现有默认 cacheExtent：它保留实际鼠标或触摸前进后退、无误激活、打开身份、Home 与 ScrollPosition 保留、返回刷新、纵向滚动、30 步 Right/Left、Enter/TV Select，以及横向首次揭示前的图片解码预热；在现有证据下这是唯一没有触发上述行为红线的选择。
- 只归零纵向 lookahead：确实是最窄的减少方向，但宽窗仍为 36:20:36，实验已证明没有目标改善，故不能据此改变生产。
- 把横向轨道改成 168 dp：它能把隔离初始 mounted 数从 36 降到 33，但首次真实揭示丢失已解码图，违反图像与交互等价；不能以静态截图或初始卡片数掩盖这个失败。
- 将 V41 的整帧 BUILD/LAYOUT/SEMANTICS 或 raster 读数直接归因到 PosterCard/cacheExtent：否决。V41 的整帧阶段不能独立归因某个 widget；已有命名 widget scopes 也仅用于诊断，不等于 CPU 或性能因果。独立帧号归因笔记要求保留 multiplicity、真实 raster frame number 与嵌套 B/E union；这些诊断改进仍不替代 lead 独占的未加 trace Profile 验收。
- 新增第二棵屏外树或额外预热：否决并链接既有 [屏外 Miuix 启动预热被拒](../../rejected/bug-fix/2026-11-10-miuix-offscreen-startup-warmup.md)。本实验的目标是保留现有单树与 lookahead 图片预热，不得用另一个渲染生命周期制造假收益。

## Acceptance criteria

本篇拒绝的候选不得进入生产。若未来重新提出 cacheExtent 方案，必须在当前源码与隔离数据上串行（concurrency=1）取得改前红、改后绿，并同时满足：

1. 以独立的实际 mounted PosterCard State 计数，而不是 debugHomeReadout.cards 或 trace scope multiplicity；保留可见卡片、裁剪边界、标题文字、玻璃表面与页面语义。
2. 真实鼠标或触摸 forward/back 不误激活，打开的 provider/id 等身份不变，Home 与 ScrollPosition 返回后保持，纵向滚动仍可用；宽窗与 TV 的方向键必须到达预期卡片，不停在上一张、不跳到下一行或下一分区，Enter/TV Select 仍只激活目标。
3. 首次快速揭示前的目标图片必须已收到并解码；旧臂与候选臂的裁剪区域像素、卡片几何、文字、焦点环、hover/press 状态和规范化语义必须等价。所有已挂载海报都必须通过真实 PNG 解码，不得以占位图或延后请求假绿。
4. 候选若主张降低挂载数，必须给出独立可复核的 mounted ceiling 与 visible count；36 对 20 不能单独作为收益或根因。失败实验、截图、日志、receipt 与源哈希必须保留。
5. 完成上述组件、交互、图像等价后，才允许由 lead 在独占 quiet window 进行未加诊断 trace 的真实 Profile；组件绿、哈希或 trace 读数都不能单独宣称性能目标通过。

## Risks

- 归零 lookahead 会让未挂载目标不存在于焦点遍历和方向键路径中；即使初始截图相同，也可能在真实 Right/Left、TV Select 或快速鼠标揭示时失败。
- 横向 lookahead 同时承担图片请求预热与首次揭示的视觉连续性；缩小它会产生真实占位图或像素变化，不是单纯的内存削减。
- mounted、geometrically visible、paint visible、PNG request 和语义节点是不同读数；把其中一个当另一个会生成假绿。debugHomeReadout.cards == 240 只是数据目录卡片数，不是渲染树挂载数。
- 合成 loopback PNG 实验可以证明这四个边界在确定性输入下的行为，却不能外推真实网络延迟、GPU/引擎开销或所有屏幕几何；V41 的 36:20 也不能证明 PosterCard 是 raster 超时原因。
- 改动任何现有 UI、玻璃、文字、焦点、语义、图片 provider 或预热路径都会超出本拒绝提案；相关现行笔记继续有效，不得通过删除断言、放宽截图或跳过输入来制造绿色。

## Evidence

- 实验回执与事实报告：[HOME_CACHE_EXTENT_BOUNDARY_EXPERIMENT_V1.json](../../../../.probe/home-cache-extent-20261119-v1/HOME_CACHE_EXTENT_BOUNDARY_EXPERIMENT_V1.json)
- 实验交接说明：[HANDOFF.md](../../../../.probe/home-cache-extent-20261119-v1/HANDOFF.md)
- V41 帧诊断交接：[HANDOFF.md](../../../../.probe/perf-layout-trace-current-20261119-v41/HANDOFF.md)
- V41 根因报告：[ROOT_FRAME_TRACE_CAUSES_V41.json](../../../../.probe/perf-layout-trace-current-20261119-v41/ROOT_FRAME_TRACE_CAUSES_V41.json)

productSourceChanged=false、guiPerformanceMeasured=false、performanceAccepted=false、wholeGoalAccepted=false 均来自实验回执；本篇没有运行应用、性能测量或新的 Flutter 测试。