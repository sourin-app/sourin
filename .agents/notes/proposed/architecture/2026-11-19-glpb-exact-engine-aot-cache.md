# Agent Note: 用同一引擎与 AOT 验证真实 GLPB 采集和只读消费

Status: proposed

适用：2026-11-19 的隔离 Windows Profile 引擎候选与任务 runner；不是已采用的产品缓存策略。

## Problem

已有同运行 trace 识别冷 shader 与驱动链接区间，严格未追踪的原始 20 场景仍超预算。
源码审查发现 Windows 默认 persistent-cache 目录无效；仅开启缓存名称或重复启动不能证明真的存取了程序二进制。
旧引擎观测到的 39 对 key/payload 也不能直接用于另一个 DLL、AOT 或驱动上下文。
需要区分“捕获材料”“包返回”“驱动实际接受”和“整包性能通过”，否则容易以静态资格或模拟数据冒充真实收益。

## Proposal

仅在隔离、固定 SDK 引擎版本的构建树中准备 bounded GLPB capture/read-only consumer 和 driver-result observer；
共享 Flutter SDK、普通产品 runner 及真实用户数据保持不变。默认关闭，任务 runner 在 EngineCreate 后、
任何显式 Run 或可隐式 Run 的 ViewControllerCreate 前配置；任意配置失败都不得继续 Run。
capture 的 Finish 最多一次，失败、空包、pending 或不可读 stats 不能靠重试变绿。原 ask/Quit 与所属 PID/Job 自然退出守卫保留。

capture 与 consume 必须使用完全相同的 DLL 和 `data/app.so`。模式由任务原生配置选择，不用不同 Dart defines
产生两个 AOT。native EXE 的模式身份、初始配置回执与 Quit 响应携带的 Finish 后回执分别绑定；后者必须在自然退出前持久化，
不能用 Finish 之前的 result 证明 Finish 成功。消费包复制到任务资产目录，原 capture 材料不可覆盖；消费者只读。

capture 只写明确任务所属、nonce 绑定的普通目录，permit 字节和空 glpb 子目录先核验，祖先重解析点不得绕过。
配置与回执使用有界 ABI，uint64 计数用无符号十进制字符串，避免 JSON 数值损失。

缓存入库要求真实上下文指纹：引擎/Skia/源码闭包/AOT、GL/GLSL/EGL/ANGLE、驱动与设备、二进制 formats、
实际 interface ABI 与 caps/options。原始 manifest digest、完整 descriptor key 和 payload 字节必须一致，
拒绝畸形 payload、冲突/超限、重复字段及重解析/硬链接等不受控文件。缺指纹或解码失败时不得宣称命中。
真实消费需要 observer 以相同上下文、key 和 payload 关联 driver result；`package_returns>0` 不能代替 `driver_accepted>0`。

## 已有准备与未取得的资格

以下为现有代码、编译和夹具材料的补记，不是本次重新构建或执行：

- 固定版本 isolated engine 的完整 17 文件 full-v3 候选已链接，自然 exit 0，DLL 原记录 SHA256
  `AF08976298D79888C7BBD55C66B6ED7238A9D3BDB9A0606FA4F751C12C1CC652`，6 个 GLPB C API
  与 3 个原有 runner API 各导出一次；这个历史样本是 `kClosureQualified=false`，保留其 compile-only 范围。
  当前隔离 DLL 已完成[有限闭包身份及单次重链](../../implemented/testing/2026-11-19-glpb-finite-closure-identity.md)，
  DLL 为 `3AADD9C6…EF60C3`、identity true。当前已有同 DLL/AOT 的真实 capture 及离线材料核对，
  只有该范围通过；真实 consumer 已记录九次同 nonce/context/key/payload 关联的驱动接受；封面视觉等价、完整覆盖与性能仍未验收。
- 最终源码的有限材料边界已有独审：32,901 个词法输入、4,944 个编译动态依赖块、39 个目录集，
  真实 Ninja 图/命令/工具与 no-work dry run 有回执。生成身份头的派生输出不得回流到 canonical inputs，
  因而闭包身份不循环；该边界不声称 Windows 宿主或全构建完全 hermetic。
- 首次身份执行在安装前失败：实际 Python 3.8 的 strict Path.resolve 折叠相对 symlink 别名，生成器拒绝重复路径。
  原 execution claim 已消耗；没有安装 true 头、没有 relink 或 GUI，原 false 头保持。失败和备份不能覆盖或沿用为新许可。
- 恢复候选保留原词法名与实体字节关系：32,806 strict targets、95 redirects、57 alias groups、152 条实体证据、
  39 个目录根；resolved 清单包含 alias binding，共 32,807 行。false 生成测试只证明实际生成器能读取该输入，
  不等于 true 身份或执行资格。新恢复执行器已有实际新鲜只读 preflight：32,901 个词法输入（5,566,614,544 字节）、
  39 个目录、57 组/152 个同版本物理身份与 32,807 个生成器角色均通过；out 7,259 文件及 SDK Windows 112 文件
  快照与原基线一致。修正后的预检自然 exit 0、无强制清理，43.929 秒；这不安装身份、不构建或启动 GUI。
- payload 校验器在 MSVC /W4 /WX 下接受 39 个已有真实 key 条目、拒绝 702 个畸形变体；实际 Windows IO/decoder
  375 项与合成 context 关联 52 项、纯任务 C ABI 桥 104 项及一次性 Finish 撤销变红均有既有回执。
  接线候选还有 real-header 编译、fake-engine/codec 与 CMake 图检查；它们不执行真实 GL 或真实驱动。
- 已有硬件诊断的 39 对材料/39 次 saved return 仍属于原 DLL。其退役阶段线程 arm witness 缺口与失败前驱保留，
  不把旧材料换标签充当新 DLL 的采集或命中。当前新 DLL 已有单次无调试器 capture、实际指纹和九条材料，
  与旧 39 条不同；当前已局部消费九条，完整覆盖、视觉等价与未追踪性能仍未验收。

恢复执行器的解释器选择已有一个保留的安全失败：最初从未冻结的 alias 摘要选择 helper EXE，
可在 preflight 后替换该字段。现行实现从已冻结 plan.generatorPython 传参，真实调用语句 AST 的
负对照复现旧路径注入，新路径只接收 plan 参数。主执行器要求 Python >=3.11，原 Python 3.8.10
只用于生成器和同 ABI 物理 file-ID 核对。原有预检和失败审查保留，不用后继阳性覆盖；
只有这次 owning executor 输入改变才重做对应预检，没有重验 seek 或其它已完成组件。
当前恢复脚本 SHA256 为 `4417FB88B7C2B308B3E601FE74F8E8A68C236CC5B78404DFA69F9978B786BF74`。
新 preflight/fixed-plan、版本/AST 负对照与独审在任务产物 `sourin-glpb-recovery-20261119-round2` 内，
旧脚本和原始失败不改写。新 execution claim、一次 identity object/DLL 重链及前后输入不变检查均已有自然成功回执，
其静态完成范围由[有限闭包身份](../../implemented/testing/2026-11-19-glpb-finite-closure-identity.md)持有；本提案仍只对
尚未完成的 artifact/runtime、capture/consume 与性能提出要求，不重做已完成静态步骤。

继续 identity 改动前必须有匹配当前候选、别名关系、工具、图与目录集的新鲜只读 preflight，
独立复核及新的一次性有限执行许可；只允许原 identity object 与 DLL 单次重链，并对比前后输入角色/命令/材料、
输出白名单与共享 SDK 守卫。非预期变化立即失败，不能自动重试或自动恢复。身份-only 成功本身也不授权 GUI。
当前有界材料读回确认 isolated out 的 `flutter_windows.h` 与源码 public header 都为 `A0303C23…D2F412`，
且实际包含 capture 声明；旧任务 handoff 将该同 hash 头描述为缺少 GLPB API 的说法不采纳。
本机输出仍缺 `flutter_patched_sdk` 目录，共享 SDK 的 common product patched SDK 有两份 dill；
目录存在性不证明引擎/ABI/编译输入匹配，后续只做私有 staging 绑定，不能修改共享 SDK 来凑布局。

同模式共用任务 AOT 已实际生成：当前 819 个 source inputs 及 8,939 个冻结输入，真实 kernel 观察 3,485 项，
使用原 SDK kernel 工具与已绑定 custom gen_snapshot，未修改共享 SDK 或补入其 out 目录。
两阶段分别自然 exit 0 且 Owned Job 双时钟排空超过八秒。AOT SHA256
`8E68C74124B34C78997E7A999A23963E9F9036EAB329CB589F966F993190331A`，17,138,568 字节，
四个原动作/timing/result/_run 代码跨度与既有 workload 精确相同，Dart defines 不含 capture/consume 模式。
最初的 59 文件 AOT baseline 只用于静态暂存，明确 `nativeTaskWiringPresent=false`、`launchAdmitted=false`；
没有用旧 EXE 运行该新 MethodChannel。当前已有实际接线的 off/capture 私有 EXE 及各 59 文件静态 bundle：
private engine/view wrapper 在任何 Run 前配置，FlutterWindow 挂 channel，九个 task/SDK TUs 编译及两模式链接
共 11 阶段自然成功，双时钟 Job 空均至少八秒。编译器实际消费 custom public、各自 config 与当前注册头；
两 EXE import table 均包含六个 GLPB API，不仅是源码里出现名字。

该次首版 native 仍复用旧 main.obj，但 FlutterWindow 新成员影响栈上对象布局；未启动这版 EXE。
最小后继只按同一当前 header 编译 main.cpp 并重链两个模式，三阶段自然 exit 0、双时钟空 Job 均超过八秒，
其余九个已验对象/插件与资源按 hash 复用，没有重编 AOT。off EXE 为 `B687800C…CD722`，capture 为
`119DEB34…16D97`。两份最终静态 bundle 各 59 项，共用上述 DLL/AOT；`nativeTaskWiringPresent=true`
表示静态编译接线存在，`launchAdmitted=false` 与 `actualRuntimeQualified=false` 继续保持。
具体接线、ABI 修复及重开条件由[同模式 AOT/native 静态绑定](../../implemented/testing/2026-11-20-glpb-task-native-aot-binding.md)持有。
旧 native 阳性只限编译，类布局不完整的拒绝范围保留，不因后继通过覆盖。首个 authority 路径格式不符在 claim/编译前失败，
规范 Windows 路径后的新 authority 才触发第一次实际编译，原失败保留。

### 实际 capture 与明确未通过的范围

单次无调试器 capture 已在隔离匿名原 source-posters cohort 实际完成 20 窗口并自然 exit 0，无强制清理；
双时钟空 Job 为 8.0267/8.0283 秒，18 个实际加载包映像按路径/hash 绑定。Native pre-Run capture 配置与
Finish 回执一致，40 observed/stores_returned、31 context_rejected、9 entries，无冲突、IO/limit/payload 拒绝。
真实 manifest 为 `EB0948683DB2F8569368D41EC045C7D97FB3D3DC4C415D74B51CF68881498DE4`，
9 个 key/9 个 payload 共 92,168 字节，原 decoder Finish 重开与离线 bounded 校验均完成；指纹精确绑定
当前 DLL/AOT/闭包、Ganesh GL、ANGLE、AMD 设备与驱动、interface/caps，不能把它外推所有驱动。
31 次 context 拒绝必须保留，不宣称捕获所有 shader 或所有上下文。

只读截图亲眼显示 Home 可见卡片全为占位，不能把 20 settled 计数当 decoded pixel：现有 task entry 明确只看
opacity/dirty/clip，原 limits 也声明不验证图像解码。此运行不构成原 Home 封面视觉或内容等价通过。
保存 1,355 帧与 201 timing receipts 精确配对，build/raster/totalSpan 超预算 1/8/14；capture 自身有开销，
不替代正式未追踪预算。Quit 回执计数 1,362，后七帧只有计数没有 raw snapshot，不能称直到退出全帧保留。
原结果、两张 1592×904 PNG、native Finish 与离线材料回执保留，不重复该候选以挑成绩。

消费者只基于上述真实 manifest 新编 native Runtime 配置并链接，两阶段自然 exit 0、双时钟空 Job 超过八秒；
DLL/AOT 未变，consumer EXE 为 `0199A954…61AEE`。69 文件静态包由 59 base 换 EXE 加 manifest/九个 payload，
原 capture 不改写；mode 同时要求 consumer 与 observer，nonce `823401215664289`。消费者已单次实际运行，原 20 窗口完成并自然 exit 0，无强制清理，双时钟空 Job 8.0388/8.0403 秒；
同 DLL/AOT 下 load_attempts=40、package_returns=9、binary_results=9、matched_results=9、driver_accepted=9、
driver_fallback=0、rejected=31，同 nonce `823401215664289`。联合离线材料/observer校验通过；
九次驱动接受只代表这些匹配返回，不代表其余31次拒绝或全局覆盖。
workload快照1,167帧后，Quit前保存1,174帧原始缓冲，与Quit计数相同；全部preQuit预算超1/7/12，
仍不声明Quit后exit前全帧或正式性能。Home部分解码封面/部分占位，与capture状态不同，不能跨运行因果比较。
真实已证范围和重开条件由[局部采集与驱动witness](../../implemented/testing/2026-11-20-glpb-scoped-capture-driver-witness.md)持有，
原capture与consumer分别一次，既有成功不再当待执行。

原 capture/consumer 运行必须各有冻结输入、隔离配置、no-focus 与一次性 quiet authority，不能套旧许可。
当前只接续严格性能/未覆盖上下文与视觉证据缺口，不重建已完成 AOT/DLL、重复capture或重复consumer挑成绩。

原材料见 `.probe/engine-build-pinned-20261119-v1/integration-full-v3-v1/`、
`.probe/glpb-runtime-harness-20261119-v1/ROOT_FULL_V3_FINITE_CLOSURE_REVIEW_V1.json`、
`ROOT_STRICT_ALIAS_CANDIDATE_REVIEW_V1.json`、`agent-wiring/HANDOFF.md` 及
`material-check-fixture-v1/result.json`。离线检查器刻意输出 `runtimeWitness=false`，不会自行升级真实运行。
日期、详细失败与包身份由
[验收报告](../../../../FINAL_ACCEPTANCE_20261118.md)持有，不因本篇提案成为通过项。

## 现有笔记审计

按 GLPB、persistent cache、程序二进制及 shader 缓存检索 proposed/implemented/rejected：

- [渲染启动归因](../../implemented/testing/2026-11-16-renderer-startup-cause.md)部分重叠，持有诊断与原始预算；
  本篇补充隔离引擎身份、采集与消费协议，不取代旧运行或失败。
- [按帧号归因](../../implemented/testing/2026-11-19-frame-number-trace-attribution.md)部分重叠，持有解析，不持有缓存准入。
- [任务窗口安全与同包验收](../../implemented/bug-fix/2026-11-18-task-window-safety-and-package-acceptance.md)部分重叠，
  继续约束所属窗口、普通启动范围及最终同包，不因新引擎准备而改变。
- [屏外预热拒绝](../../rejected/bug-fix/2026-11-10-miuix-offscreen-startup-warmup.md)、
  [shader quad AA 拒绝](../../rejected/architecture/2026-11-17-shader-quad-aa.md)仍保留防重犯价值。
  它们是不同机制，不被本提案归档，也不因换缓存路线而允许删帧、删效果或引入第二棵预热树。

## Alternatives considered

- **沿用默认 PersistentCache 或只加启动开关**：接入少；但 Windows 默认目录无效，缺乏真实持久化和驱动命中证据，
  不能完成本目标。
- **应用侧替换 ANGLE DLL 或复用旧捕获物料**：省引擎构建；但当前引擎的 ANGLE 静态链接，应用目录替换不改变它，
  旧 DLL/AOT/上下文的 payload 也没有新身份归属，故不采用。
- **第二棵屏外预热树**：可以提前承担一部分可见峰值；但旧实验未证明端到端启动收益，并增加渲染生命周期，保持 rejected。
- **减少效果、删除启动帧或从多次失败中选较好样本**：实现或报告简单，但改变视觉/验收对象，不能满足用户原目标。

## 未覆盖上下文的窄诊断准备

现行 reader 明确捕获 manager.render_context 的 EGL handle/generation，并在 ReadBoundRenderContext 要求当前
registered ticket 匹配且 role=Render；resource 上下文不被准入。40 次尝试中的31次拒绝没有分支级回执，
不能仅凭此源码限制说31次都属于resource，也不能去掉角色、generation、fingerprint或before/after检查。
下一任务候选只在独立overlay对象中增加默认关闭的有界原因输出，设置明确任务nonce时才写无路径/无凭据
的predicate标签；不加载缓存、不返回新字节、不改原返回结果。诊断使用新的DLL身份、独立编译和运行准入，
不冒充原qualified DLL或正式性能样本。旧九条接受与原闭包身份保持其原范围。
单个旧nonce诊断overlay已按实际GN参数编译为对象，自然exit0、3.870秒，未安装、未链接或运行；
为不触发原AOT的未知SOURIN_隔离拒绝，后继只把诊断hook改为TASK_GLPB_REJECT_TRACE，旧对象不覆盖。
独立私有有限候选保留原32807材料并只替换live-context源码，新增4个显式source-map/recipe/rsp/preparer输入，
共32811+3provenance；单对象和单DLL链接的所有输出在任务目录，原source/out/SDK不改。
真实GN187参数与3601链接参数有限独审确认只有该映射和私有输出变化；3534个复用native输入由原快照绑定。
第一私有变体已生成独立身份并实际编译/链接，保留原OUT/SDK；第一次原因运行自然退出且旧材料0returns/39reject，
但[GLPB_CONTEXT_GATE]实际零标签，没有启用正见证，因此原因目标失败，不推定旧31全resource或说明没有问题。
真实提取helper的独立fixture证明off/wrong=0、exactnonce=192，只说明helper本身可工作，不证明DLL内调用或通道。
第二私有变体增加identity-enabled/bound-reader-enter正见证、Win32标准错误句柄输出和成功reader的实际caps digest/
read-query与stencil计数；原guard及HashBytes输入不变。只在明确nonce时解析，最多512次输出，trace内部保存LastError。
真实提取新helperfixture为off0/on512且LastError保持，不替代应用调用证据。
新静态编译/链接通过，DLL为5A28921C…741275E、独立闭包7AB177EA…1529902，原OUT7259/SDK112及3534复用
native输入前后不变；新69包只DLL不同、原AOT/EXE/旧材料不变，仍预期旧fingerprint安全miss。
正见证后继已实际运行：157连续标签（identity-enabled1、bound-reader-enter78、caps-snapshot78）均来自同一成功render角色/线程；
实际caps出现三digest，与queried1→2→3同次变化。没有nullreject标签，不能推原31逐条原因或resource归因。
原guard不改，旧包在新DLL身份下仍39load/39reject/0return，非cachehit。
[稳定指纹](../../implemented/architecture/2026-11-20-stable-program-binary-caps-fingerprint.md)在任务私有 DLL 中已实装：
只剔除两个已验证的惰性读回状态，保留其余 guard。局部 fixture 与新同 DLL/AOT 实际 39 次接受均有回执。
旧零标签失败及新正见证仍保留；不归因旧31次、不重复未变诊断。

## 解码观察诊断组件

卡片几何settled与真实像素的差异已有一项新isolated单组件正反对照：旧实际几何helper在heldPNG时目标断言变红，
新观察器真实RawImage/RenderImage放行后32×48、同卡identity、失败占位及opacity/clip控制通过；仅诊断资格，
未改变旧ready/signature/动作rawframes或生产组件。后继snapshot/AOT集成未执行，不能追认旧截图。
完成范围与v1-v4bootstrap失败、v5reader字段误判及磁盘上限见
[解码观察笔记](../../implemented/testing/2026-11-20-poster-decode-observation.md)。

## 满命中后的启动时间线诊断

[渲染启动归因](../../implemented/testing/2026-11-16-renderer-startup-cause.md)持有新实际读回：复用同 98 文件包，
仅从默认 VM Ring 取证，不改引擎/AOT/材料，不重跑原 20 动作。35 次实际接受仍有长帧，第 3 帧栅格 232241 μs 中
程序构建与呈现的并集 225520 μs；读取是构建子包络，第 12 帧的大部分排队与前一帧栅格重叠。
不把嵌套区间相加，也不把粗粒度 cache_hit/Present 标记解释成二进制调用或 SwapBuffers 单项耗时。
后续改变只依据可独立验证的子成本，不复跑同一诊断，不从正式预算排除冷启动或窗口外帧。

无窗真实子项使用同源 Flutter EGL Manager 的 surfaceless render context：原 Package::Open/Load、精确 EGL/GL/DXGI/driver/format 门保持。原 Pbuffer 初始化因 EGL 指纹不同在送入驱动前拒绝，失败保留，不放宽守卫。39个实际程序逐一成功；紧随 link 查询的等待远大于 ProgramBinary 调用。固定批4另有一次真实后继，但不能由跨运行差值断言 worker 并发或正式提速。只复用已保存原件做独立算术复核，不再重跑串行或原20样本。详情和失败边界由[渲染启动归因](../../implemented/testing/2026-11-16-renderer-startup-cause.md)持有；微测不替代引擎 RegisteredPackage/observer、实际draw、整场内容与严格预算，也不授权把IO/提交/查询排除正式启动窗口。provider-only和五段呈现trace均未生产采用。新实时Reader无窗子项将主要成本定位到D3D查询合段及caps JSON dump；不凭同device或epoch冻结首次值。新的五段trace私有DLL已在两TU和actual复用对象/库闭包下完成链接，另有453条实际include记录与双时钟自然Job终态；只核派生对象谱系，不是全父源码fresh验证或运行/性能资格。本次新startup-only捕获35项及同DLL/AOT只读35次实际驱动接受已有原件；两份Ring五段均记录，consumer有尾frame70未闭合，只有44个完整帧归因。保留新相应scope和原20正式预算失败，不重复取得这些证据。

### 呈现子包络的私有派生诊断

原默认Ring只有外层present，五段CPU trace候选仅改变诊断DLL，不改变原OnFrameGenerated、
MakeCurrent、blit、swap或OnFramePresented调用及参数。新compositor对象和唯一identity
消费者必须重编；旧caps及其它实际链接对象可按父构建谱系和实际hash继承。派生身份明确
用已验父DLL/sidecar、实际复用对象、两个新单元/source/compile/include及link输入闭包，
不冒充重新验证全部父源码或完整宿主。生成头和输出不回流自身输入；新DLL/AOT匹配后
只采一次启动材料，再新建同DLL/AOT的只读consumer取默认Ring。不得把旧39材料换标签，
不得因为诊断而重复原20正式失败样本。子事件仍是同调用线程CPU wall包络，五段互斥
才能求和，真实frame_number/原时钟绑定与缺失边界由现行解析器约束；不是性能通过或采用。

### 同设备不可变shader对象复用的私有候选

新35项实际物料离线检查到68个合法嵌入DXBC（34VS/34PS），完整container+stage+length
相同者有13类/20次额外出现；检查前置64位长度、header/chunk bounds和SHDR/SHEX，
但未完整解析ANGLE外层metadata，不把它叫实际load/create次数或耗时证明。
只据此准备一个不落生产的窄候选：同ID3D11Device持有强身份、独立VS/PS全字节key、
classLinkage固定null、只保留原Create成功返回，bounded内存/条数；reset/release清空，
命中仍检查device健康、stage/bytecode不同不可共用，失败不缓存。用真实本次字节调用D3D
原Create API验证局部生命周期/负控，然后才考虑私有引擎与原应用行为/预算。

替代方案中的实时driver-version/caps缓存已缺不可变性证明，不采用；线程数调整/屏外预热
会改变时间归属，也不采用。同设备shader对象是D3D已创建不可变资源，不等于缓存live指纹；
缓存若忽略device reset、class linkage、stream-output或计数语义同样不合格。初期仅VS/PS，
geometry/compute/stream-output保持原样，不擅改ShaderExecutable头布局或原ResourceManager计数。
真实API fixture随后以同源Manager取得D3D设备及本次合法DXBC执行19项，通过exactbytes/stage/device/ref/Clear/并发/禁用/实际driver失败不store；无window/draw/ProgramBinary。首次将已证feature0xb100误写11_0在shader前拒绝，原件保留；后继改正确11_1而不放宽硬件门，三阶段自然0/双空8s。另私有副本只去memcmp时同一真实API功能门在full-byte-key检查自然exit1/noForce变红，原positive和header不改。它不是性能因果比较，单次原Create/miss/hit的顺序读数不宣称提升百分比。

私有集成再保留原ResourceManager的allocate/decr/unique wrapper，只换VS/PS CreateResource路径与Renderer release前Clear，同task宏显式1；原返回失败不再Create第二次。header/localstatic会产生exit-time destructor警告，其生命周期不能外推一般进程卸载，debug labels副作用未证；候选task-only不装生产。已编ResourceManager11/Renderer11/identity三TU加directlink（856actualinclude），新DLL `BBC682A6D42FF9498F74B904EDEEFB94C78DAFD04F8D7649E43A6AA538CCA9F0`，派生闭包 `A15BECD24966482BF6E51F407F662D647999DDC44BF1C075687478C1197AF6B3`，仍只实际对象谱系，不是fullfreshsource。新runtime必须重采自己manifest，不用前次35材料。这次shader候选已startup-only实际捕获35store/0reject并自然0，但退出没有经过Renderer清理日志，实际命中计数输出为零条（不是证明hits=0）。该运行只operational资格，cacheWitness=false；新增即时见证版本随后生成新DLL `09C3889226C0A4468CB18846B83F036D8D97E2ABB91A33BAF338B41DFF495A43` /闭包 `42AC2EB454957B8A8A674F5F46C08B29AE0C3E8794FD0845C5E1B6FAFDB2B1F2`，三TU+link双时钟自然0，新startupcapture95raw/35store/0reject自然0；实际stderr出现first-store(0hit/1miss/1store)和first-hit(1hit/8miss/8store)，不同worker线程38564/42704但都属同实例累计计数，不归GLkey或推worker并发。header逆除onlytrace代码后与原候选同字节，原HRESULT/key/statefields未改；WriteFile失败/partial未查、同锁同步写可阻塞，仍只诊断。新rawmanifest `4BCE53AF3AEC8603A32A56BEA370EE1ACC7356C338A67D1F90F615D4306FA7BC` 35descriptor、33unique payload/434416字节，不能把不同payload数量直接归因cache，未与旧差做因果比较。同DLL/AOT的93文件consumer也已单次启动，自然0/dual8、即时firststore/firsthit可见，实际36load/35return+binary+matched+driveraccepted/0fallback/1reject；不改分母或回溯拒绝原因。该consumer97raw/97完整present，而capture95raw/46完整/49timing-only；全raw预算仍红。真实hit只到instance aggregate，pixel/content/DPR状态异，无正式原20性能/生产采用或同包交付升级；当前已验Release ZIP仍保原输入。保留原件，不拿19API阳性代替应用缓存命中。后继仅加默认关闭/固定编译显式启用的有界即时命中标签，必须新DLL/身份和新capture，不重标旧材料或重跑未变样本。

这只是proposed+实际API fixture和私有静态资格，尚未证明像素、全部状态、应用链接收益或正式性能。

## Acceptance criteria

闭包与 alias 恢复、identity-only 重链、SDK 未改分别具备新鲜有限回执，且真实 runtime 绑定正确 DLL/header/import lib/AOT。
同一 DLL 和 AOT 实际跑原 20 场景完成 capture，Finish 成功、原 decoder 重开、完整指纹/key/payload/manifest 可独立复核。
同包 consume 保留只读材料，并有真实 matched driver acceptance/fallback counters，不以 fake API、包返回数或 compile-only 代替。
保留全部失败、原始帧、图像/布局/焦点/语义与播放/退出行为；自然 exit 0、所属 Job 双时钟空至少八秒、无激活/切输入桌面。
之后在独占窗口执行未追踪原始 20 场景，全部帧按原严格整数预算判断；不删冷启动/窗口外帧，不重复候选挑成绩。
只有性能、受影响行为和最终同产品包绑定均有证据，才考虑生产采用；这不会自动关闭账户、普通启动或历史归因等其他未验收项。

## Risks

精确指纹限制跨驱动/设备复用，数据不符需要真实正常回退；缓存准入、IO 与 observer 本身也有成本。
有限闭包不是全宿主可复现保证，身份头 true 不是运行授权；alias 去重若丢失词法角色或输入字节会失去可信度。
native capture/consume 代码、GL driver 和窗口生命周期都可能失败；必须保留失败终态、一次性调用与自然退出约束。
普通默认启动需要授权交互式会话；真实账户、凭据、真实库写入、远端传输或清理不在本提案授权内。
已有分开的旧九条与新 39 条同 DLL/AOT 实际材料及关联驱动接受。新样本只在当前实际 render 请求内零拒绝，
两个现存截面同字节，不代表全程视觉等价、其它上下文覆盖、生产采用或原始预算通过。
