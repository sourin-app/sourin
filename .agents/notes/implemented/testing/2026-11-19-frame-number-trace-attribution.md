# Agent Note: 按真实帧号归因并保留所有原始帧

Status: implemented

适用：2026-11-19 的任务专用 Profile 诊断入口、FrameTiming 与时间线解析；不是产品性能通过声明。
与[渲染启动归因](2026-11-16-renderer-startup-cause.md)部分重叠：该笔记约束冷启动、
引擎与性能准入，本篇持有跨 chunk 事件重复次数、真实帧号匹配及当前解析器的验证边界。

当场检索 proposed/implemented/rejected 中的帧号、时间线配对和重复事件后，直接相关的旧篇是上述渲染归因；
它仍有引擎诊断与旧失败的独立价值，不归档。GLPB 的运行身份属于
[同引擎同 AOT 提案](../../proposed/architecture/2026-11-19-glpb-exact-engine-aot-cache.md)，不由解析结果赋予。

## Problem

FrameTiming 的长帧只能指出时间，不能确定 shader、驱动链接或建树工作。
时间线可跨 chunk 重复传送，但同一 tick 也可能有多次真实事件；按事件值集合全局去重
会误删合法调用，破坏 Begin/End 嵌套。用数组位置代替实际帧号，又会把错误的 scopes
接到另一个 FrameTiming，造成看似精确的错误归因。

## Decision

正式性能验收使用未追踪的原始 20 场景，保留冷启动、窗口内和窗口外的每一帧，
严格按整数 `rawUs * 60 <= 1,000,000` 判断。诊断使用单独绑定的任务入口，
只开启显式允许的引擎 trace flags；逐控件 build/layout scopes 只用于对应诊断包。
原产品效果、默认 renderer、内容 cohort、动作和 700 ms 窗口保持各自冻结身份。

解析器保留实际重复次数，按进程、线程、category、name 配对 Begin/End；
用 `Rasterizer::DoDraw.args.frame_number` 唯一匹配实际 FrameTiming，不按列表下标或跨运行帧号接线。
事件落在采样边缘而无法配对时，明确报告覆盖缺口，不伪造结束时点。
同一帧的 shader、driver-link、BUILD、LAYOUT 等嵌套区间按各自并集计算，不能相加；
exclusive 只扣除已记录的直接子区间，不等于纯 CPU 时间。

原始 timing、chunk、运行身份和解析输出分别保留。独立解析算法交叉核对所有原始帧、
实际 frame number、关键 B/E 配对与共同 named-scope 并集；错误解析结果保留为失败，
不覆盖原始数据。诊断通过只证明此批材料的解析一致性，不把耗时迁移到其它运行，
也不把某个引擎 scope 直接认作某个 widget 的因果证据。

## Verification

以下均是已有回执，本次补记不重新执行应用、构建或解析：

- V34 保留 1103 帧、90 chunks，两种保留重复次数的解析及 5851 项交叉检查一致；
  只有四个非关键采样边缘 B/E 不完整。frame 4 的 raster 465049 μs 中，shader 并集
  457369 μs、内含 driver-link 424233 μs，不能相加。首次搜索先前的两段 MakeGpuImage
  1133/329 μs 不能解释 shader-heavy raster，也不支持删除 SnapshotWidget。
- V36 的两种建树分析另有 1316 项交叉核对；RenderParagraph、Image 与 Scavenge 的
  同帧区间支持局部工作研究，不支持重写 HomePage 或把 phase 时间认作控件独占 CPU。
- V41 保留 1031 帧、90 chunks，全部按实际 draw frame number 唯一绑定；5192 项检查包含
  653 项共同 named-scope 并集。frame 3 的 raster 881912 μs 中，shader 867856 μs、
  内含 driver-link 792494 μs；frame 64 的 build 106530 μs 中，RenderParagraph exclusive
  44371 μs、Image 12450 μs、Scavenge 7044 μs。这些数值不能搬给 V40 同号帧。

原回执位于 `.probe/perf-frame-audit-20261119-d81ef6c9/V34_INDEPENDENT_REPORT_CROSSCHECK_V1.json`、
`.probe/perf-product-candidate-20261119-root-v1/V36_TWO_ALGORITHM_CROSSCHECK_V1.json`，以及
`.probe/perf-layout-trace-current-20261119-v41/V41_TRACE_AND_RAW_CROSSCHECK_V1.json`。
逐项样本与失败范围由[验收报告](../../../../FINAL_ACCEPTANCE_20261118.md)持有。

### 默认环形缓冲的首批帧

稳定指纹消费者已全程验证 39 次接受，仍有启动长帧；另一次仅启动诊断复用该 98 文件包、DLL、AOT、材料，
在任务隔离的 owned/noActivate 窗口只读 Profile 默认 Ring。没有引擎开关、stream 修改或清缓冲；没有调用原 20 动作。
按一份包的实际顺序与时间戳配对，无需 chunk 去重。40 个首批帧和 2 个稍后帧与同 PID/TID 的唯一 DoDraw 区间一致，
Quit 前 70 帧中其余 28 帧只保留 FrameTiming，不能借用旧事件。592 次区间并集与独立覆盖扫描一致；
改错 PID、删关键开始边界、改帧号、错栅格时钟四个真实原件副本均按各自判据拒绝。

只读回执 `sourin-glpb-startup-20261120-round6/ROOT_ACTUAL_STARTUP_RING_ATTRIBUTION_V1.json`（SHA256 `2EB8C74AA4CEAC824DA9A01D416570C184E80EB86DCE8AC50F6358546014BA94`）；
大包络、排队重叠及不参与正式性能的范围见[渲染启动归因](2026-11-16-renderer-startup-cause.md)。

### 呈现子阶段与真实尾部缺口

round7新trace DLL只在compositor的原五个调用周围加互斥scope，继承原AOT。新启动capture与consumer
各一次默认Ring，前者106个raw/完整DoDraw/完整present全部对应，23823事件；消费者43个ready raw
全部覆盖，preQuit84个raw中44个完整draw（含ready之后的69），11158事件。末端frame70只有B，
其真实rasterFinish在packet终点之后34847 μs。其余6个unmatched均属尾链B，不补E、没有后续
closedDraw，frame70及其后总40个timing-only继续保留；ready之后新增41个timing不等于41缺失归因。

首次解析器把任何important gap一律拒绝，实际消费解析失败保留。后继只准唯一正在执行的尾draw
且critical gap全是同尾B、之后没有完整draw；中途掉begin/end仍红。每个完整draw要求唯一present，
每phase既要时间包含，也要原packet beginIndex/endIndex包含，并按time+原ordinal稳定配对；
相邻零宽/同tick事件不能跨parent借用。完整五段原序互斥、求并集与外包络剩余分别报告，不clip
有缺边界的部分帧来制造五段零值。实际packet五类变异（错PID、整phase缺失、错时钟、删早begin、
同时间phase对移到parent外ordinal）均拒绝，capture/consume各一组。

两个独立算法逐帧核对150个完整帧共1950数值一致，见统一任务目录
`sourin-performance-20261120-round7/lead/ROOT_TWO_PRESENT_ALGORITHM_CROSSCHECK_V1.json`，
独立原件 `independent-present-review/independent-present-result-v1.json` SHA256
`6D5C664706A98B1FB64CDECA9639C5CF4E7ED76DD20C854E631DD45D8C5D60C1`。
这次新微测与startupRing均不重跑旧正式20样本；全部预算失败与packet覆盖上限由
[渲染启动归因](2026-11-16-renderer-startup-cause.md)持有，不能升级为正式性能或全场内容等价。

## Alternatives considered

- **按事件值全局集合去重**：实现简单且消除重复传输；但真实同 tick 重复也会被删，
  已有首版解析因此产生错误嵌套，该结果保留为失败而不采用。
- **直接用 traced 时长验收性能**：可少建一个包，但 trace 本身增加开销，且不满足原未追踪预算。
- **把嵌套 shader 与 driver-link 相加或套用另一运行同号帧**：能得到单一解释，
  但前者双计时，后者没有共同帧身份，均不能作为因果结论。

## Consequences

保留重复次数和真实帧号使归因可复核，并阻止通过删启动帧、挪用追踪耗时或重复跑失败候选
来取得假绿。代价是独立诊断包、原始材料与双算法解析需要额外存储和维护。
V34/V36/V41 的自然退出和解析通过不代表严格性能通过；原 18+12 的性能目标仍未验收。
只有采集接口、trace schema、chunk 协议、帧号语义、解析器或对应输入改变时才重开影响面；
没有输入变化不重复这些已完成诊断。

### 同一原包的第17轮默认Ring新采样

第16轮同一98文件消费者包、新原子Quit AOTA453…75B80与纯DLL8A05…C80569不变，仅新task observer在全新隔离profile读默认Ring：未设置engine switches/recorded streams、未clear、不stream、不调用原20。首次root命令的authority模板未替换，在创建app/run/profile前拒绝，失败原件保留；只纠正argv摘要后的实际应用仅一次。PID16692实际原Quit自然exit0/noForce/Job双空8.010688/8.0122255秒，HWND消失；root亲看Home真实海报，17实际加载映像及39物料原/副本逐hash核对，包未复制/修改。

原Ring23340事件，4095同tick组及60个精确重复extra均原样保留，默认streams为Dart/Embedder/GC/Microtask。ready原始114帧、pre-Quit/同响应原始124帧、0动作窗、complete=false/measurementCompleteBeforeQuit=false不伪装complete；完整原件仅声明同步Quit边界，非进程寿命。Ring覆盖115个完整DoDraw，唯一frame147在packet尾只有开始、rasterFinish在packet外；148–155仅FrameTiming，ready114均有完整trace。3个早期E缺B、2个worker尾B及3个raster尾B均明报，不补结束或零时长。

根复用成熟R6帧号核对与R7有界尾draw规则/coverage-delta并集，另一执行体用time+原ordinal子属配对及sorted-interval merge；115帧的1840项整数对比全一致。新原件四项错PID/错frame/保时钟方程但搬raster/删早期DoDraw B均在指定门真实拒绝，既非套旧报告，也未改新app结果。文件/时钟覆盖另有7个真实子进程负控及新原件正例；源码RPC调用另核禁止start/setflags和包身份错配。

本次frame2 raster287836微秒，shader_compile并集148806（其中PersistentCacheLoad39030、cache_hit76688），compositor present115077；frame3 raster316914，shader254162（load36179/hit178337），present43550；frame45 raster122750，shader97398（load58336，其中单load53517/hit28512），present21243。嵌套值不相加。35个program/load/hit闭区间与同进程35次driver accepted计数呼应，Ring无cache_miss或driver_link_program名称；这是当前binary命中路径仍有大量工作的证据，不是“零driver工作”。

frame3的buildFinish→rasterStart181247微秒，其中181227与前序同raster线程Draw重叠；frame14对应312961/312933。它定位了排队等待，不把totalSpan等同单帧独占计算。cache_hit包含真实ProgramBinary、LinkStatus、observer及后处理，现Ring没有单独ProgramBinary/CheckLinkStatus/DXGI/GPU子段，不能把该包络移作任何一个API独占或VSync根因，更不能把本次同号帧耗时搬给第16轮原20。UI细粒度或特定控件归因仍以实际存在scope为限，不补mock。

根双算法回执 sourin-performance-20261120-round17/root/ROOT_TWO_ALGORITHM_CROSSCHECK_V1.json，SHA256 605EBB138B64F5FC11406243AF726C158F4B2D76D53FF02C568FF8E03A294A0F。同包时序实验只关闭此批Ring的有限归因与覆盖校验；它不是新的原20预算样本、普通未修改启动或像素/性能验收，第16轮1234完整帧及1/11/25超限仍原样保留。
