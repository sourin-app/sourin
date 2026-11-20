# Agent Note: 任务窗口安全与同包验收边界

Status: implemented

适用：2026-11-19；本仓库 runner、窗口插件的任务专用非激活路径，以及各自输入绑定的稳定性与同包验收。

本笔记持有任务所属 WinAPI 调用的安全边界，不取代[已有实例启动边界](2026-11-18-task-noactivate-existing-instance.md)与[非激活显示](2026-11-16-task-noactivate-window-show.md)的决定；PiP 转换恢复仍由其原笔记持有。详细事实及回执索引见[逐项验收台账](../../../../FINAL_ACCEPTANCE_20261118.md)，这里不复制逐轮流水账。

## Problem

任务验收要求窗口归本任务所有，不能抢焦点或恢复已最小化窗口。即使初次显示不激活，runner 与窗口插件后续调用仍可能激活或恢复窗口。用户确认手动最小化过 V4 最终烟测中一个遮挡窗口；该失败运行不能取得包验收资格，也不能据此归因更早的最小化事件。

## Decision

仓库所属 WinAPI 包装层由显式的 `SOURIN_TASK_NO_ACTIVATE` 控制：拦截激活调用，窗口修改必须属于当前进程，使用非激活的显示与定位标志，并拒绝恢复 iconic 窗口。普通启动保留原参数、返回值及 last-error 状态。runner 接入守卫，`windows/CMakeLists.txt` 强制包含仓库所属的插件预加载头；Windows、Flutter、COM 声明先于别名加载，避免改写 SDK 接口成员名。

任务私有最终烟测驱动只将其所属的可见主窗口置于 `HWND_BOTTOM` 一次，不移动、不缩放、不激活。源排序页通过原 Back 操作返回且不保存；窄选择器只接受实际观察到的两种 Back 结构。这是取证工具的动作，不是新增产品窗口策略。

任务私有Profile runner另有默认关闭的首显前主屏准入：编译宏
`SOURIN_TASK_PRIMARY_GUARD=1` 与原合法 `SOURIN_TASK_NO_ACTIVATE` 同时启用时，
只对新创建HWND、首次可见前越主工作区的位置消息加 `SWP_NOMOVE`，保留尺寸和其它标志。
不主动移动现有窗口、不恢复iconic、不改系统DPI；首次可见后释放，不是常驻锁屏。
自有隐窗的真实消息红控证明关闭门会实际跨区并失败，启用门仅阻止位置、尺寸仍改变。
两次当前原20运行均实见首显/ready为当前主屏96DPI、1592×904/DPR1，但blocked=0，
因此不把当前运行称为动态验证了“拦住跨屏”分支，更不推断历史移动来源。

新 `SOURIN_` hook不能绕过冻结AOT的允许集。首次传入额外primary hook导致Dart入口异常、
Quit扩展未注册和owned Job强制清理，该失败没有自然退出资格。现行私有后继仅用编译期开关
和原合法hook，AOT不改，静态AST门注入非法hook会拒绝；不把后继成功覆盖原失败。
消费者预检按base59加本次真实只读材料的精确成员/hash检查，不能沿捕获固定59而删除材料凑数。
同一原20pair的两臂、材料/退出/严格性能结果由
[渲染启动归因](../testing/2026-11-16-renderer-startup-cause.md)持有，当前性能仍失败。
这些任务私有输入没有进入已验生产Release，不替代普通默认启动或完整目标验收。

## Alternatives considered

- 放宽观察器或选择器能容忍更多结构，但会丢失窗口所有权及原动作目标的保证，因此不采用。
- 修改 SDK 或插件缓存便于直接插入守卫，但会把构建决定留在仓库外，也无法保持普通 SDK 声明的边界，因此不采用。
- 改变普通启动行为可以绕开激活路径，但会改变正常产品契约，因此保留普通路径，单独限定任务模式。

## Consequences

任务验收使用显式启用守卫的原生包和任务所属隔离配置。普通默认获焦启动仍是独立验收边界，需要获得授权的隔离交互式会话，不能用任务模式代替。早期构建失败、窗口最小化运行及旧 Cancel 选择器失败均保留为失败。V4 的手动操作只适用于已确认的该次事件；更早调用来源与唯一根因仍未确定，不为猜测重复已结束的运行。

完整原始 18+12 目标仍为 active。严格全帧性能预算已有实际执行的失败结果，仍是必做目标，不是可跳过或已通过的项目。编译成功、自然退出、运行资格通过、组件等价及诊断 trace 均不等于性能通过；未知、skipped 与失败不能提升为 passed。没有远程发布。

旧稳定性包与点击 seek 同包续验是各自已完成的历史范围，不自动覆盖当前生产输入。相对已验点击修复包，当前新增差异涉及 `lib/ui/widgets/cover_image.dart` 的固定 URL 请求头与 hash 复用、`lib/ui/widgets/poster_card.dart` 的 Image 配置身份复用，以及 `third_party/flutter_miuix/lib/src/theme/miuix/foundation/miuix_pressable.dart` 的可选按压控制器按需分配。后两项分别由[海报配置复用](../simplification/2026-11-19-poster-image-configuration-reuse.md)与[按压反馈按需分配](../simplification/2026-11-19-miuix-pressable-lazy-feedback.md)持有局部决定；组件证据不赋予完整应用或新包资格。点击手势契约仍由[播放器 Miuix 控件](../feature/2026-11-08-player-miuix-controls.md)持有。

既有成功仅在 owning inputs 改变时重开受影响范围：上述差异涉及公共按压的指针、hover、焦点、键盘、语义及生命周期，封面的精确 URL/query/header/cache/transport，以及海报 URL/revision/尺寸/DPR、首帧、继承依赖与错误重试。未变化的成功不重复推进；原失败不由后继阳性覆盖，也不反复运行同一候选挑选成绩。采用新的生产或引擎输入后，受影响运行及最终包必须重新绑定实际源码、编译输入、AOT、运行时与 ZIP；重用原生对象和 core 时保留其真实谱系，不以同一 HEAD 冒充全部输入相同。

### 当前源码候选的静态绑定

相对旧已验包的328个项目编译输入，325项同字节、三项变化，seek的所属输入未变化，不重测。
只把最新源码的335个项目输入（含漏在旧输入表外的7项配置/注册器）、3352外部依赖和9工具
冻结到任务副本，不运行会改共享SDK的assemble更新链。精确Release frontend与gen_snapshot
各由独立owned Job自然exit0、双时钟空8.018/8.025秒；新实际kernel依赖3483/3483，无缺项/新项，
输出AOT `58131BEBB1C3661264F658FADB994B54ECD9439BA9233DDA72DF86717CA9361E`。
新构建回执为统一任务目录 `sourin-glpb-startup-20261120-round6/release-aot-owned-v1/compile-once-v1/result.json`；
这不是应用启动或新包稳定性验收。

保留的58个非AOT文件逐项比对实际旧runtime，其中35个资产也绑定旧assemble真实输出；23个
原生成员仅继承原谱系，未混入私有GLPB引擎。149真实asset输入同hash，1个Flutter wildcard
明确不存在。对新旧实际kernel分别运行ConstFinder，169常量/168 MaterialIcons码点/0非恒定；
fontPackage/fontFamily/codePoint集合一致，实际重建字体21404字节与旧包同hash。
空recorded_uses只支持native hook输入同值，不能代替icon证明。资产门20正反对照通过，
首次wildcard误分类拒绝原件保留。最终新目录 `release-candidate-v1` 59文件仅app.so不同，
manifest `B8C63848DCA1660B4967072E5747C9340614740EC05814B941D1D4AF561D1E20`，
另5个成员/路径/旧AOT拒绝对照通过。静态回执不继承旧三退出/16动作/ZIP的动态资格，不发布或封正式Release。
同一新包随后在三个不同fresh profile中实际完成playing/switch/pending，分别自然exit0、
无force/cleanup error，双空Job8.0368/8.0428/8.0442秒，18个加载包映像均匹配；
原Ask/Quit与确切HWND消失成立，挂起例在Quit前实际200且零body、无第二集首帧/原生失败。
主代理逐项核case/helper哈希后封 `release-exit-successor/CURRENT_RELEASE_THREE_OWNED_QUIT_CASES_V1.json`。
它只证明新包合成HLS退出与切集，不代替新烟测、普通启动、真实账户或严格性能；seek没有重测。

同新包的原16动作烟测也实际自然exit0，无force，双空8.0049/8.0062秒；完整动作序列、
LAN标题展开/收起、source/sort原Back不保存、provider顺序和原Ask/Quit均通过，18加载映像
与包一致。另一次固定封面见证由新的合成端点要求精确Referer/UA并返回nonce图418字节；
应用真实200请求及卡片范围9/9色块、225/225像素共同匹配。原Ask/Quit自然0、双空8.0464秒，
没有使用VM、系统输入或焦点/桌面切换；只声称精确合成端点策略，OS防火墙隔离明确未证。
封面revision/cache identity/hover仍不由此GUI声称；原组件资格只在相同所属输入上复用。
独审明确封面执行器没有保存完整窗口观察历史，不能由最后成功重建全过程焦点记录；
同一实际PID/HWND/birth/Job的Home/Ask/Quit helper与源guard仍有各自证据。
错误权威的本地比较负控不冒充无效权威下的实际产品运行。

本地candidate ZIP `release-local-package-v1/sourin-windows-local-20261120-58131beb.zip`
为43831371字节、SHA256 `FBBFFD3BE0E38A3F2DA948A596C2A5BC4C87EF72459AEA3F66458987A6237F13`；
实际重开ZIP核59成员、逐内容hash及CRC，manifest/source/AOT/三退出/烟测/固定封面绑定一致。
这是最新源码的本地同包阶段通过，不是原18+12或正式发布；原seek不重测，严格预算、普通默认
启动、真实账户外链、Top20精确身份和历史caller继续未验收。

旧16动作只覆盖可见导航/展开/排序与退出，不读cover headers/cache identity或PosterCard
修订解码，也不覆盖Pressable hover/按压像素。新隔离回环与像素oracle的真实TCP/PNG正反对照
已可执行，但合成客户端和旧截图阴性不是新Release成功。新包GUI须确切manifest、只属本任务
的profile/密钥域/窗口、重新绑定的helper与一次权威；不扩展旧选择器或注入系统输入来凑资格。

## Verification

以下是原稳定性包已完成、仍限于原输入的证据，并非本次笔记修改重新运行所得：守卫通过 **189** 项无窗口行为检查，无守卫对照失败 **109** 项；普通原生构建通过 **19** 阶段，带守卫后继通过 **6** 阶段，所属进程均自然退出。播放中、切换第二集及请求未完成三场景沿原 ask/Quit 路径自然 exit 0，Owned Job 在两种时钟下均自然排空至少八秒。

原最终烟测覆盖 Home/源栏、Settings、原局域网标题展开与收起、源管理、排序页不保存 Back、源管理 Back 及原 ask/Quit。应用与全部 **16** 个辅助进程自然退出，双时钟空 Job 均超过八秒；Back 辅助工具的六项构建与守卫阶段也通过。独审核对 **59** 个运行时文件及有限源码/构建桥，重用对象和 core 保留原谱系。对应产品基线为 `be4bb0e3df7d54aa7113944bfdac5e6acee2ece6`；阶段回执为 `.probe/goal-root-acceptance-next-20261117/CURRENT_STABILITY_AND_FINAL_PACKAGE_PHASE_ACCEPTANCE_V1.json`，原记录 SHA256 为 `6D18B4FA8BC7D66634DBA454165198C6C2DCF5D463298E7B04CDBAB0B7A7DD54`。V29 保留封存 V28 的历史范围，不代表完整目标通过。

后续点击 seek 的独立 **59 文件** Release 包完成一次窗口内鼠标消息点击，隔离播放进度由 **32→93→98 秒**；同包三种稳定性场景、16 动作可见性烟测及 ZIP 一致性已有各自回执。该续验限 **96 DPI**、隔离合成媒体及任务非激活路径，不声明物理鼠标、125% DPI、公网取流、普通默认启动、真实账户或完整目标通过。详细入口为 `.probe/seek-click-release-v1/CURRENT_RELEASE_CLICK_STABILITY_VISIBILITY_ACCEPTANCE_V2.json` 及上述台账；它不自动覆盖其后采用的三项优化。既有未验收条件与失败原件继续按台账保留。
