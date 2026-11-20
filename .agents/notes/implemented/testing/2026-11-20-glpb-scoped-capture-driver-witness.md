# Agent Note: 同 DLL 与 AOT 的 GLPB 局部采集和驱动接受有真实回执

Status: implemented

适用：2026-11-20 的单机任务专用 capture/consume 运行，固定引擎、AOT、驱动与匿名内容 cohort。
与[GLPB 提案](../../proposed/architecture/2026-11-19-glpb-exact-engine-aot-cache.md)部分落地互链：
本篇只持有真实九条材料与九次驱动接受的已证范围，不表示生产采用、完整上下文覆盖或性能完成。
[静态接线](2026-11-20-glpb-task-native-aot-binding.md)与[有限闭包身份](2026-11-19-glpb-finite-closure-identity.md)
继续持有各自输入与构建资格，不重新执行。

## Problem

包返回不代表驱动接受，配置成功也不代表运行实际消费该 DLL/AOT 或该 manifest。
卡片已挂载、opacity 已稳定和无 dirty 祖先也不代表图片已解码；仅看就绪计数会错报封面视觉。
结果快照取回后到 Quit 之间仍可能产生帧，只报告旧快照会把缺失原始数据伪装成全程保留。

## Decision

任务 collector 复用原无调试器 20 动作、700 ms 窗口、严格整数预算与全部原始缓存，
冻结实际 source/module/manifest/EXE/DLL/AOT、模式 build ID、profile/run 路径与 exact quiet authority。
不以 native 模式编译不同 Dart AOT。运行使用任务独立 APPDATA/USERPROFILE/keyring namespace、
原匿名 seed 与既有无凭据 loopback route；窗口要求 owned HWND、noActivate、非前台，不切桌面或注入系统输入。

启动前 snapshot 必须匹配实际 native 配置；在工作负载外读取真正 loaded package modules 并核路径/hash。
Finish 后原 Quit 响应先独占/fsync 持久化，失败不重试到绿。真实 manifest/raw key/payload 的离线 bounded 校验
与运行生命周期分别计证；offline 检查器自己仍输出 runtimeWitness=false，运行 witness 来自拥有PID、加载模块和native回执。
消费者同时配置 read-only package 和 observer，以同 nonce/context/key/payload 的真实 driver result 计 accepted/fallback，
不能用 package_returns 替代 accepted。实际捕获原件与消费资产均按原字节保留，consumer 后重新核十个文件未写。

collector 的失败 finally 在可访问 VM/ext 的任意阶段读取既有 startupResult 并保存原始缓冲，再走 Quit。
它不能保证已退出或没有 VM/ext 时恢复数据，读取失败保留 secondary 而不覆盖 primary。
成功 consumer 还在最终截图后、Quit 前保存全 startupResult，以保留旧 result 之后追加的帧；不改变 timed 动作或 AOT。
截图用已有 owned PID/HWND PrintWindow 纯读取，在 timed 窗口之外；主智能体亲眼判读，不由metadata代替。

## Verification

### 实际 capture

- 单次原 20 窗口完成，PID 39116 自然 exit 0、无强制清理或 cleanup errors；owned 窗口未激活并准确消失。
  双时钟空 Job 8.0267459/8.0283209 秒，151 个空样本；18 个 loaded package 映像按 manifest 绑定。
- 相同 DLL `3AADD9C6…EF60C3`、AOT `8E68C741…0331A`、闭包 `F31E4336…C6191`；
  Finish 成功，40 observed/stores、31 context_rejected、9 entries，冲突/IO/limit/payload_rejected 均零。
- 真实 raw manifest SHA256 `EB0948683DB2F8569368D41EC045C7D97FB3D3DC4C415D74B51CF68881498DE4`，
  九个 descriptor key、九份 payload 共 92,168 字节，实际指纹绑定 Ganesh GL/ANGLE、AMD Radeon 780M、
  驱动 32.0.32015.2008、format 37798、interface/caps 与引擎/AOT。原 decoder 重开与离线实际字节检查通过。
- workload result 为 1,355 帧/201 receipts，帧号/timestamp/20窗口完整，预算超 build/raster/totalSpan=1/8/14。
  Quit 计数 1,362，多出的七帧只有计数；本次不声称从出生直到退出全部 raw 已保存。
- Home 实机 PNG 亲眼显示全部可见封面占位，而快照称 20 settled。task entry 原 limits 明确只量opacity/dirty/clip，
  不是 decoded pixels，因此不以此证明原 Home 视觉或内容等价。Settings 图完整不补足 Home 缺口。

### 实际 consumer

- 基于上述 manifest 只编 Runtime-consume 并链接，不重编 AOT/DLL；consumer EXE `0199A954…61AEE`，
  两个构建阶段自然 exit 0、双时钟空 Job 超八秒。69 文件包是 59 base 换 EXE 加原 manifest/九个 payload。
- 单次原 20 窗口，PID 69984 自然 exit 0、无强制清理，owned noActivate 窗口准确消失；
  双时钟空 Job 8.0388406/8.0402817 秒，151 个空样本，18 个加载包映像与该包相符。
- consumer build ID `4229FAE92D8A4837C868E77C342F5CA58D7038E298A83C28AE4C883E1A4CCB64`，
  observer nonce `823401215664289`；初始零计数到最终 load_attempts=40、package_returns=9、binary_results=9、
  matched_results=9、driver_accepted=9、driver_fallback=0、rejected=31、reentrant_rejected=0。
  九次接受是实际关联回执，不是 fake API 输入；31 拒绝保留，不能宣称全 shader/context 覆盖。
- workload result 1,167 帧/178批，Quit 前快照 1,174 帧/179批精确 append-only，全部 receipt/时间戳一致，
  Quit 计数同为 1,174；仍不保证 Quit 后到 exit 的全部帧。1,174 帧严格预算超限为 1/7/12，
  maxima 20123/463730/670874 μs，p95 739/2800/4915 μs；生命周期完成与局部命中不等于性能通过。
- consumer Home 亲眼可见部分真实封面与部分占位；与 capture 的占位状态不同，不能直接跨运行比较缓存性能因果
  或宣称 Home 图像等价。Settings final PNG 与 capture 同字节，只证明这个最终截面。

### 取证与审查范围

12 项 native receipt/authority 真实路径及 AST 负对照、六项失败 raw finally AST 对照均按预期执行，
旧条件在 settling/ready 阶段漏取 raw、wrong build ID/freeze hash 失败、failed Finish 持久化但不accepted；
这些是假输入的取证工具验证，不是驱动 witness。consumer 首次 no-GUI module-census 漏计父任务 helper，
在任何 claim/app前拒绝；只扩到同任务父目录的观察范围，expected exact module set保持，原失败保留。

根及独立审查只重算实际快照、计数、原始帧与小回执，不重复 8,939 编译输入/5 GB 引擎审计或旧组件成功项。
统一任务材料 `sourin-glpb-capture-20261120-round4/` 内包含两个 circle result、native-quit-receipt、PNG、
actual capture/consumer material-check logs、根原始帧范围报告与 `review/` 的 capture V4/consumer V3。
详细运行绑定见[验收报告](../../../../FINAL_ACCEPTANCE_20261118.md)，不能只用本篇摘要代替原回执。

后继[解码观察组件](2026-11-20-poster-decode-observation.md)已有真实held/503/解码/opacity/clip红绿，
只补任务诊断字段，不改变本篇旧AOT或追认旧Home像素。
[稳定指纹任务版](../architecture/2026-11-20-stable-program-binary-caps-fingerprint.md)另有新 DLL 的独立 39 条真实接受，
本篇依旧只证明旧九条，不把新材料归到旧身份或补写旧31次原因。

## Alternatives considered

- **以包返回数或配置成功作为driver命中**：更容易观察，但未证明实际二进制进入驱动并接受，因此要求同nonce真实observer。
- **把 settled/opacity 直接当封面解码**：无须更多观测，但本次截图反证明确，保留原几何含义并拒绝视觉通过。
- **在正式测量里删启动/窗口外或最后七帧**：能减轻超限数字，却改变判据，不能接受；后继保存Quit前追加快照。
- **重复同一 capture/consume 挑更好预算或预热后再量**：容易取得较好样本，但不提供新因果证据，故只保留各一次真实运行。

## Consequences

收益是同身份局部 capture→manifest→readonly package→real driver result 链路取得可复核 witness，
消费者构建和运行可从当前已证边界继续，不需重复旧capture。代价是精确驱动/设备指纹限制复用、
一次性 quiet 运行、材料锁定及回执维护；九条材料/九次接受没有覆盖其余31次拒绝，也没有消除所有冷帧。
完整原始18+12仍active：严格性能未通过，封面视觉/匹配输入、普通启动、真实账户外部条件及历史最小化归因不由此关闭。
后续只因所属输入变化、证据缺失或新反证重开影响面；不能把本篇 implemented 等同生产采用或重新运行成功阶段的理由。

## 现有笔记审计

检索 active proposed/implemented/rejected 的 GLPB、capture/consume、driver witness：本提案及上述静态两篇为部分落地/职责重叠，
保留并互链；[帧号归因](2026-11-19-frame-number-trace-attribution.md)持有解析、
[渲染启动诊断](2026-11-16-renderer-startup-cause.md)持有原预算与历史失败，均不取代。
[封面生命周期](../bug-fix/2026-11-08-library-cover-lifecycle.md)持有精确身份与恢复，不因UI占位而扩大真实数据授权。
