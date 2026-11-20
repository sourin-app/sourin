# Agent Note: 复用未变化的海报 Image 配置

Status: implemented

适用：2026-11-19，PosterCard 的 Image 配置生命周期。
关联：[可选按压反馈分配](2026-11-19-miuix-pressable-lazy-feedback.md)只持有控制器；
[封面 provider 身份复用](2026-11-19-cover-provider-identity-reuse.md)只持有 URL 请求头与 hash。
本篇不改变它们的决定。[首页 cacheExtent 缩减拒绝](../../rejected/simplification/2026-11-19-home-cache-extent-reduction.md)
保留实际首揭图片与焦点失败，不将减少挂载当作本篇配置复用的替代方案。

## Problem

PosterCard 在首个解码帧移除占位后，以及标题、hover、焦点等无关状态变化时构造相等的 Image 配置。
SDK 保留 ImageState 且避免解析相等 provider，但不同的 Image widget 仍触发父级驱动的更新。

## Decision

封面 URL、cover revision、有效卡片宽度和设备像素比不变时，在 PosterCard State 中保留同一个
Image widget。这些字段就是 provider、解码尺寸和就绪回调的构造输入；URL/revision 或解码尺寸
改变时创建新配置。ImageState 自身的图片流与继承依赖照常更新。错误、有界重试、首帧淡入、
交互与占位路径保持，首页 lookahead 和图像预热也不改变。

## Alternatives considered

- **移除 loadingBuilder**：能少一层回调，却改变加载中行为，因此不采用。
- **绕过 ScrollAwareImageProvider 或改变已挂载内容**：可以跳过框架路径，却改变图片生命周期或可见行为。
  本实现只复用框架既有的精确 widget identity 更新机制，不规避首次 ImageState 挂载、首次 provider resolve 或解码。

## Consequences

隔离实际源码前后对照覆盖真实回环 HTTP、解码/就绪、hover/焦点/键盘激活、URL/宽度/DPR 变化、
继承的 invertColors/TickerMode/disableAnimations、失败/重试、A-B-A 和销毁，13 项范围用例通过。
对旧源码启用同一图片身份断言会变红；22 对 PNG 及布局/文字/透明度/语义快照在两主题下逐字节一致。
原回执为 `.probe/next-widget-perf-candidate-20261119-v1/POSTER_IMAGE_IDENTITY_COMPONENT_QUALIFICATION_V4.json`。

原采用补验第一次命令含不存在的文件名，失败记录保留；扩大六文件组合记录 34 通过、4 失败。
精确旧源码对照确定其中三个为原有失败：无 callback 的 InkWell、已有 releaseStatus 构造参数清单、
FollowPage 占位静态条件。第四项是 helper 提取引发的旧静态 coverImage 调用点断言；替代断言检查
真实 build→helper→coverImage 路径、解码宽高与 fit，删除高度或 helper 调用的两个负例均变红。
两份旧套件改前、改后均保留 21 通过/3 失败，不宣称整组绿。采用后四文件真实图片套件在
`root-adopted-test-v3.log` 中为 14 项通过，详见同目录 `REGRESSION_HANDOFF.md` 和 `regression-followup-v1/`。
原记录只格式化新增测试文件，不用格式重排抹掉旧失败。

需要区分冻结字节：V40/原组件候选绑定的 poster_card 输入为 `8163C421…918EF72`，
helper 提取后的工作树为 `A778C574…14F93`；前者的运行或像素回执不直接宣称后者逐字节相同。
后者已有上述局部补验，不因补记再次测试。新Release的只读输入桥另外核对V4私有候选到当前源码，
唯一差异为 `_imageLoaded` 的早退加花括号格式，按这一处精确替换后全文字节一致；
这不是把两个不同hash声称同字节，也没有重采像素。`release-component-binding/CURRENT_COMPONENT_BINDING_V1.json`
绑定当前三组件到新实际3483项kernel输入/AOT，继续只继承原局部行为/像素范围；MSAA无任意
revision/hover选择器不是重跑未变组件的新条件。当前本地59文件包的三退出/16动作/固定封面
及ZIP由[同包验收](../bug-fix/2026-11-18-task-window-safety-and-package-acceptance.md)另持实证。V40 两次原 20 场景均未过预算，不能挑较好的一份宣称通过。

保留 key 每卡增加少量状态分配；收益只到减少无关父级更新，并有局部等价证据。
它不省首次挂载/解码，不证明全应用帧时间改善或原始 20 场景性能通过。新的生产输入需要新的
同包 Release 绑定；[同包验收](../bug-fix/2026-11-18-task-window-safety-and-package-acceptance.md)持有该边界。
URL/revision/宽度/DPR、错误重试、继承依赖或配置构造输入改变时才重开影响面，不重复未变化的成功。
