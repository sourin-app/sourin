# Agent Note: GLPB 任务 runner 与全模式共用 AOT 静态绑定

Status: implemented

适用：2026-11-20，任务专用 Profile 构建与 off/capture 静态运行包，不是产品发布或 GUI 验收。
与[GLPB 真实采集消费提案](../../proposed/architecture/2026-11-19-glpb-exact-engine-aot-cache.md)部分重叠：
本篇持有已实现的 native/AOT 接线与类布局修复；真实 capture/consume、driver 和性能仍归提案。
[有限身份](2026-11-19-glpb-finite-closure-identity.md)的静态完成范围保留，不重新建立或运行该阶段。

## Problem

Dart MethodChannel 的定义不证明原生引擎在 Run 前完成配置。直接使用旧 wrapper 会错过 EngineCreate 后的钩子，
而 ViewControllerCreate 本身可能隐式启动引擎。给 FlutterWindow 添加 channel 成员后继续复用旧 main.obj，
又会让栈上对象分配沿用旧类布局；链接成功无法发现这种跨翻译单元 ABI 不一致。

模式若通过 Dart define 切换会产生不同 AOT，从而让 capture 与 consume 的程序身份不同。
必须把模式放在任务私有 native 配置，保留一个实际 AOT 与一个实际 DLL，并对最终静态包分别绑定。

## Decision

当前产品源码以 819 个源输入复制到新任务根，SDK kernel 工具与 custom gen_snapshot 生成一份任务 AOT。
三个 Dart defines 只携带 profile root、source commit 和 namespace，不含 capture/consume。
原 20 动作、700 ms 窗口、timing callback、结果与 _run 四段字节相同；native snapshot/Finish 回执在窗口外。
实际来源不是 HEAD 的替代物：相对 V40 只有当前 poster helper 字节及任务 MethodChannel 入口发生变化。

任务 wrapper 在 EngineCreate 后、messenger 与 ViewControllerCreate 前配置 Bridge。配置失败销毁该引擎并终止，
view wrapper 不把无 messenger 的 engine 交给 ViewControllerCreate。一个进程只有一个 Bridge；Finish 最多一次，
失败不可重试到绿。FlutterWindow 创建私有 channel，销毁时先卸 handler。shared SDK、ordinary runner 与生产源码不改。

新编私有 core/codec/engine/view wrapper、FlutterWindow、Bridge、Channel 与各模式 Runtime；旧 wrapper archive
和旧 FlutterWindow.obj 不参与链接，保留 hash 匹配的 runner 支持对象、任务非激活 win32 对象、插件和资源。
改变 FlutterWindow 类成员时，构造该类的 main.cpp 必须同时按当前 header 编译，不能因为 main 源码未改就复用旧对象。
capture 配置保持原 generator 的 .probe 限制，目录在统一任务根内部，不写项目 .probe 或真实数据；nonce permit 与空 glpb 子目录独立核验。

原生编译复用既有 Owned Job、有限环境与双时钟排空模块，每条命令实际 exit 0 后空 Job 至少八秒；
冻结输入在各阶段前后核对，实际 showIncludes 的 custom public/config 路径另行读回，不能用非空 include 日志替代正确来源。
最终 EXE 导入六个 GLPB API，仍只能说明链接；bundle 的 launchAdmitted 默认 false，禁止由编译结果推定可运行。

## Verification

以下均是本轮真实执行的静态证据，不是缓存或应用性能通过：

- kernel PID 56732、gen_snapshot PID 79544 自然 exit 0、无强制清理；双时钟空 Job 最低分别为
  8.0148/8.0164 秒与 8.0535/8.0544 秒。819 源/8,939 冻结输入，实际 kernel census 3,485 项含正确入口。
- 共用 AOT 为 17,138,568 字节，SHA256 `8E68C74124B34C78997E7A999A23963E9F9036EAB329CB589F966F993190331A`。
  DLL 固定为 `3AADD9C685363CFBCF94AC5AE41333A920E86DB82B77A677D261E3D733EF60C3`。
- 首次 authority 使用路径分隔符不同，在 build claim 和编译前被精确匹配拒绝；规范路径的新 authority 才开始实际编译。
  原拒绝保留，不改源代码或放宽 equality，也不算产品失败。
- native 首轮 11 阶段全部自然 exit 0，双时钟空 Job 最低 8.0012/8.0022 秒；actual headers union 467，
  主智能体重读其 hash，并确认 runtime-off/capture 分别消费正确 config、task TUs 使用 custom public。
- 首轮复用旧 main 的布局缺口在任何 EXE 启动前发现，有限独审标 nativeLayoutComplete=false。后继仅 main 新编+两次 link，
  三阶段自然 exit 0，双时钟最低 8.0143 秒，main 实际包括当前 FlutterWindow.h。旧阳性不变为运行通过。
- 最终 off EXE SHA256 `B687800CFD47073F0671090A7A068B70CE9A4480EA9B9DF8A75FB9E4832CD722`，
  capture EXE `119DEB34C18F3E5EF39E53B1B960CDFCE3AB317F1D6E1AC8F74FFEBE3B416D97`。
  两模式各 59 项静态包共用相同 AOT/DLL；实际 PE import 证明六个任务 API 各已接入，不执行 EXE。

原回执在统一任务产物 `sourin-glpb-runtime-20261119-round3/`：`aot/build-once-v1/result.json`、
`aot/ROOT_GLPB_SAME_AOT_STATIC_BUILD_REVIEW_V1.json`、`native-direct/build-once-v1/result.json`、
`native-direct/layout-successor-v2/result.json`、`bundles/STATIC_SAME_AOT_ENGINE_BUNDLE_BINDING_V1.json`。
独审 source/result 与旧布局不完整结论在 `review/`，原始失败和计划不覆盖。详细包身份见
[验收报告](../../../../FINAL_ACCEPTANCE_20261118.md)。

## Alternatives considered

- **复用旧 EXE 与 wrapper，仅替换 DLL/AOT**：构建少，但没有新的 pre-Run 配置与 channel，因此不是采集接线。
- **每模式各编 Dart AOT**：配置简单，但违反 exact same AOT 的缓存身份，故模式只放 native。
- **旧 main.cpp 源字节没变就复用 main.obj**：省一次编译，但它嵌入 FlutterWindow 的旧栈布局，故按当前 header 重编 main。
- **重建整个插件和引擎**：会扩大输入变化与验证面；未改变的支持对象按实际谱系/hash复用，只编译必要的新对象。
- **修改共享 SDK 或用 CMake 自动补下载/工具**：便于模板构建，但污染已验环境；使用任务目录手工编译，不调用 cargo/GN/下载。

## Consequences

收益是同 DLL/AOT 的任务包具备真实原生接线、类布局一致与原始编译回执，后续只需接续 collector/run 准入。
代价是手工构建输入、对象谱系、静态 manifest 与模式 EXE 分别管理；compilation scope 不等于完整 ABI/driver 运行保证。
本篇的静态构建阶段没有启动 GUI 或真实 GL。后续同身份 capture/consume 与九次真实驱动接受已有
[局部运行 witness](2026-11-20-glpb-scoped-capture-driver-witness.md)，该笔记持有运行范围；本篇不将局部运行
扩为生产或严格性能通过，也不重做已完成静态构建。consumer EXE 使用实际 capture manifest 单独配置。
task profile、no-activate/owned window 与最终模块/运行包绑定继续适用，不授权账号/真实库/远端操作。
只有 task native/类布局/编译输入/公共头/引擎/AOT 改变或新反证时重开影响面；不会重编已完成 AOT 或重链已完成静态身份。

## 现有笔记审计

按 GLPB、native/AOT、wrapper 与类布局检索 proposed/implemented/rejected：上述提案与有限身份为部分重叠，
两者继续有效；[窗口安全与同包边界](../bug-fix/2026-11-18-task-window-safety-and-package-acceptance.md)持有非激活、
普通启动及最终包，不由本编译记录替代。[帧号归因](2026-11-19-frame-number-trace-attribution.md)持有采集解析，
本次没有改变原始预算或采样动作；不归档仍有安全约束的笔记。
