# Agent Note: Quit响应携带同一边界完整原始帧

Status: implemented

Related: [渲染启动验证](2026-11-16-renderer-startup-cause.md)、[帧号归因](2026-11-19-frame-number-trace-attribution.md)、[整数序列化候选](../../proposed/simplification/2026-11-20-skia-json-integer-format.md)。本决定仅修任务Profile采集协议，不改变产品的Quit、动画、widget组成、默认渲染器或驱动能力读取；候选优化是否采用仍由既有提案持有。

## Problem

第15轮消费者动作末1116帧，pre-Quit原件1131帧，原生Finish/统计读取后的Quit状态计数1136，但Quit只返回status，没有那5条新raw。原门NO_DROPPED_OR_MISSING_QUIT_TAIL_FRAMES正确拒绝；原件及失败结论保留，不补帧、不把更早snapshot与更晚计数拼成不存在的原件。改写读侧把1131当1136全分母会是假绿。

## Decision

任务入口只修改Quit分支：改变phase之前局部保存measurementCompleteBeforeQuit；保留原phase=quit-requested、原native Finish await、原200ms AppTray.quitNow Timer。Finish返回后无新增await，使用既有同步_result()一次构造并经原jsonEncode输出完整frames、frameRecords、windows和timingReceipts，附quitRawSchema=1及rawBoundary=after-native-finish-before-quit-timer。_result的complete仍因真实phase为false，禁止为了复用旧checker而改成true。

_result、_status、_receiveTimings、_run及导航/滚动方法逐字不变；callback继续缓冲实际FrameTiming，不禁用、不截断、不等待“没有更多帧”。原700ms窗口、450ms linear滚动及冷帧/窗外分母保持。计数和frames在同一isolate无让出点的结果构造中属于一个响应边界；既有200ms Timer只是已排队，不会在同步构造和编码中执行。

collector同步open-x写入、flush/fsync/close并生成hash引用，before-quit-raw仍原样保留作前缀。最终唯一分母来自原quit-response-raw.json的frames，报告finalQuitRaw、measuredFramesSource；检查动作末和before-Quit的完整frame及回调批次顺序均是Quit的同值追加前缀，而非只核集合包含。原20动作体SHA保持3DED96A7…7BED8。

闭包资格和性能分开：缺协议/raw/count/clock/前缀/窗口成员任何一项就失败，不输出完整预算；完整原件则逐帧逐项用rawUs*60<=1000000。冷、动作内、窗外前中及动作后尾帧互斥计数，tail不能又作为窗外总数相加。p95只描述，永不替代全帧预算。

## Alternatives considered

- 把两次snapshot的帧合并：可最大复用旧AOT，但不存在一个真实原子原件能证明该合并与Quit count同边界；不选。
- 忽略退出新增帧或只验动作内/p95：无需新AOT，却删分母且旧捕获也存在冷帧超限；不选。
- 反复轮询直到帧数“稳定”：读侧改动小，但Finish本身可能跨await继续产生回调，且轮询无界、会改变任务时序；不选。
- 停掉FrameTiming callback再Finish：容易固定计数，却直接丢掉Finish期间实际帧；不选。
- 原生文件导出全进程寿命帧：能进一步覆盖真正析构尾帧，但扩到engine回调/关闭协议和新的生命周期合同；本轮无该必要输入，保留明确响应边界，不假称进程寿命全覆盖。

## Consequences

新任务编译树819文件只改上述入口，其余818份保持原R3产品cohort字节，不把当前工作树路径清理宣称已编入旧产品。8947编译输入及3485实际kernel输入冻结，实际kernel消费入口SHA30C874F73BB6769DDAB556AB216152BD1E4AC70E719F407DF91E938850DB5F6E。kernel与gen_snapshot实际自然exit0/noForce/双空>=8秒，新AOT A453D16D861706D80A14E2192EC9116527E59DCB44FE933AFFFB96F48DA75B80；仅编译不是运行资格。

实际源码detector先拒旧status源码、把Result换Status、把capture移到Finish之前、增加await、改Timer及改_run的负副本，再接受实际新源；这是source-only。落盘持久化另用原函数AST精确提取，7真文件负控exit1、三个独立完整JSON（含5MB UTF8）读回exit0，不等于断电/目录fsync/rename原子事务，也不能补上游未给的raw。原decoder以实际新AOT哈希对第15轮旧物料真实exit4，旧物料不可复用；新AOT必须新capture再消费。

无窗真实Dart夹具现已实际执行：对旧/新完整入口做可逆的同library适配，保留真实_finishGlpbBeforeQuit/_receiveTimings/_status/_result与原jsonEncode；使用真实dart:ui FrameTiming类型，在controlled Finish future挂起时两次真实event turn追加102/103帧。7组均真实编译0；旧源、Status回归、提前快照、编码前await各真实run1并命中对应marker；新源、新源microtask fence、非complete phase各run0，后者measurementCompleteBeforeQuit保持false。适配仅替服务注册、timing注册及物理AppTray，Finish由受控Future替代，非真实native/driver资格；旧part位置编译失败和首runner quoting失败保留。

实际新capture/consume各只执行一次原20，均自然exit0/noForce/Job双空>=8秒、原窗口消失。capture动作末1070、before/原Quit1090，consumer动作末1214、before/原Quit1234；两臂原Quit包frames.length与frameRecords完全一致，phase仍quit-requested、complete=false、measurementCompleteBeforeQuit=true，动作后20帧全部保留。两实际native Finish期间新增回调数恰为0，不谎称这两次强制重现了晚回调；真正强制晚入场景由上述受控真实Dart夹具覆盖。

两个独立读侧分别核数学/时钟/批次/原20前缀和预算；每臂9种真实原件变异均子进程exit17，正例原件完整性exit0。首读侧错误假设report顶层quitRawSchema而exit17；v2只接真实nested quitRawQualification并核finalQuitRaw精确引用、post-response=false，未改原run/result或帧，前驱失败保留。严格预算两臂均真exit3，capture build/raster/total超1/21/45，consumer超1/11/25，p95虽可合格仍为red。consumer互斥冷/动作内/窗外前中/尾170/793/251/20=1234，对应total超7/11/6/1=25。

新capture真实39descriptor/38payload/506424字节，manifest5B0C6B3A…4BAF12经两路原decoder身份核验绑定A453…AOT与8A05…DLL；39个物料原件和只读副本消费后字节不变。consumer最终39load/39driverAccepted/0reject/0fallback，保初态nonce和counter，不推断每key记录或整驱动实现。root亲看四PNG：capture海报完整、consumer仍混几处灰占位，Settings同hash；不据timing差异断言提速或全程像素等价。两臂实际加载18/17包映像逐hash亲核，保存窗口状态sample非iconic/nonforeground，非连续窗口证明。

根原件读回sourin-performance-20261120-round16/ROOT_ATOMIC_QUIT_PAIR_READBACK_V1.json，SHA256 2B29ACFE7A0FDCC145092B2129674E0B30582CDD3B246EDDBFB93B36E1334C92；25个consumer实际超限frameIDs/时钟/动作标签另存NEXT_PERFORMANCE_FRAME_INPUTS_V1.json，不从FrameTiming猜根因。本决定关闭声明响应边界的采集协议子项，不关闭严格性能或原完整18+12。所有产物/原件在统一任务根；旧R15缺5raw原件和失败完全保留。最终测量只覆盖native Finish后同步响应已计数的每条帧，不覆盖响应后200ms到实际析构的全部帧；postResponseDestructionFramesClaimed=false。

收益是原计数与原raw属于同一可复核包，Finish期间晚回调不再被较早快照吞掉；代价是Quit响应更大、任务AOT身份改变，必须新编译/新物料/新隔离profile。只在该协议或真正性能owning input改变时重开，不复跑已验seek、旧pair或稳定Release。
