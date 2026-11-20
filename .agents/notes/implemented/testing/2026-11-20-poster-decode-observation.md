# Agent Note: 任务快照以真实 RenderImage 区分解码与卡片稳定

Status: implemented

适用：2026-11-20 的任务诊断 observer 与隔离单组件资格；未编译/运行诊断 AOT，不是产品封面修复。
与[局部采集driver witness](2026-11-20-glpb-scoped-capture-driver-witness.md)部分重叠：该笔记保留实机占位反证，
本篇只持有新解码观察器与它的组件正反对照。后继[稳定caps指纹提案](../architecture/2026-11-20-stable-program-binary-caps-fingerprint.md)
独立研究缓存兼容，不拿图像观察变动解释旧driver时间。产品[首解码就绪](../bug-fix/2026-11-12-poster-first-decoded-frame-readiness.md)
和[同Image配置复用](../simplification/2026-11-19-poster-image-configuration-reuse.md)的决定不改变。

## Problem

旧 task 的 settled 只检查卡片祖先opacity、dirty与clip，实际 capture Home 全占位仍可报告20 settled。
这不是图像像素已解码的证据。只检查 Image widget、URL、请求成功或卡片几何，会把pending/失败占位当成封面。

## Decision

任务专用 helper 沿真实 PosterCard 元素的 Image→RawImage→RenderImage 观察。必须 RawImage.image 与 RenderImage.image
均非空且实际图尺寸存在，才记decoded；可见性另检查 attached/size、屏幕和page裁剪、父层paintsChild、opacity和近似clip。
settledDecoded还要求opacity>=0.999、干净路径、没有可见占位Icon。错误占位只按当前组件分支观察，不猜HTTP/codec根因。
它不读或写生产State，不直接请求焦点、不发额外网络或强迫解码。

新字段 homePosterDecodeObservation只挂在已有快照顶层，不进入content/_homeSignature，不改变旧等待、动作、700ms窗口或rawbuffer。
保持旧就绪字段的原几何含义，不用“等待解码”偷偷预热或把启动帧排除。新遍历/输出有诊断开销，不能当正式性能样本。
真实截图/同帧呈现与遮挡是另一条证据，不由RenderImage存在或近似clip保证。

## Verification

同一实际PosterCard、同一新用例串行两臂，完全隔离数据且只请求本机受控HTTP：

- v5 legacy-red实际旧 _posterVisibility加opacity/dirty把held卡判settled；同卡没有解码图、有占位。
  第172行目标断言 Expected false / Actual true，exit1。旧helper逐字等于绑定task源码，不是always-true桩。
- observer-green实际exit0，1/1，五行真实观察：held尚无RawImage/RenderImage图、503移除Image后失败占位、
  放行后同一PosterCard元素实际32×48解码且visible/settled、祖先opacity0与完全clip下图仍保留但不计可见/settled。
- 红绿日志原hash分别 `36F168C4…272A8` 与 `CA505A88…4A97CE`；源helper为 `24D45507…FD6E5`、
  task候选 `D4946E86…2D30`、实际test `B7AEE42C…0758B`，前后product/source匹配。
- 原pair receipt的 intendedLegacyFailure=false是读取侧reason字符串前缀误判；继任103项只读复核按实际日志/行号
  确认目标失败，保留原receipt，不重跑测试或覆盖原证据。
- v1–v4均在CLI/bootstrap进入测试前失败（环境/PATHEXT、PROGRAMFILES(X86)、私有SDK snapshot缺项），不能当行为红。
  v5才实际执行；后续不为更好读数重复两臂。

回执在统一任务 `sourin-glpb-context-20261120-round5/decode/`：`widget-test-v5/`两臂command/result/log、
`TASK_POSTER_DECODE_OBSERVER_V5_RAW_AUDIT_V1.json`及`HANDOFF.md`。主智能体亲读目标红断言与全部五行绿观察，
未凭执行者口头把组件结论当实机。候选entry/helper仅放新任务目录，不写已冻结round3或生产lib。

## Alternatives considered

- **沿用卡片几何settled当解码**：无新增遍历，成本低；但真实held反例与实机占位已经证明它不能作为像素证据。
- **读取私有 _loaded 或只数Image/请求**：易取值，但可能读到配置/声明或提前状态；本观察直接看渲染图及其呈现路径。
- **把新观察立即变为正式readiness**：可以延后首次导航，但会改变启动测量与网络cohort；本次只观察不改门槛。
- **为测试复制多个精简SDK**：隔离强，但四次缺项bootstrap与重复占用暴露维护代价；不把环境失败当产品失败，也不继续复制。

## Consequences

收益是几何稳定、未解码、失败占位、实际可见解码和被压制图可以区分，旧假阳性判据有真实变红对照。
代价是快照遍历和诊断输出；observer只在组件范围合格，尚未集成新AOT/实机截图同帧，不能追认旧Home图片或原Top20通过。
保留bootstraps、实际红绿与读取侧误判，原五套SDK/包复制属于可再生中间，总约2.22GB；没有授权删除，本轮不删除，
不得把它们全说成原始证据或再复制同工具。未来执行优先复用成熟本地工具并隔离数据。
只有实际observer/组件生命周期/clip语义或新诊断输入变化才重开相应验证，不重复旧成功组件组，不去掉budget或UI/focus/语义。

## 现有笔记审计

检索 active树的 RawImage/RenderImage/decoded-settled/解码就绪：上述runtime、首解码、Image复用为部分重叠，互链保留；
[封面生命周期](../bug-fix/2026-11-08-library-cover-lifecycle.md)仍拥有精确作品身份和真实数据限制。
shader/cache与旧geometry不拥有本观察，未找到另一直接owner，不归档仍有安全/时序约束的笔记。
