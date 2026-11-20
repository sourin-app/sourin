# Agent Note: 隔离 GLPB 引擎用非循环有限闭包身份限定重链

Status: implemented

适用：2026-11-19，固定引擎版本的任务专用 Windows Profile 构建；不是产品引擎发布或缓存运行验收。
与[同引擎同 AOT 缓存提案](../../proposed/architecture/2026-11-19-glpb-exact-engine-aot-cache.md)部分重叠：
本篇只持有已落地的输入闭包、别名、解释器选择与身份-only 重链流程；采集/消费/驱动/性能仍由该提案持有。

## Problem

引擎 HEAD 不包含实际工作树补丁、生成输入、工具与构建配置。把最终 DLL digest 写回自身身份又造成循环。
保守工具目录包含相对 symlink，同一实体的多条词法路径在实际 Python 3.8 strict resolve 后重合，
直接交给生成器会以重复路径失败；粗暴去重会丢掉原始目录成员和路径角色的约束。

恢复过程还暴露一个具体执行入口：从未冻结的 alias 摘要选择 helper EXE，会使 preflight 后的路径修改
绕过已冻结的解释器。源码门禁和字节预检必须约束实际调用，不能只检查脚本声明。

## Decision

有限 canonical boundary 明确包含最终源码、配置、工具、声明依赖、VALID 动态依赖及 39 个保守目录，
排除生成身份头及其派生输出、最终目标产物与可变 Ninja 元数据。不声称 Windows 宿主完全 hermetic。
实际 loaded DLL 与 AOT 的哈希在运行时另行绑定，不能嵌入同一 DLL 再参加自身闭包。

原 32,901 个词法输入及各自角色保持。生成器只列 32,806 个 strict targets 各一次，再列入别名绑定文件，
共 32,807 项；3 个冻结 Ninja provenance 带 kind 单列，canonical sidecar 共 32,810 条记录。
95 redirects、57 组、152 成员均保留原路径、相对 link text、strict target、hash 与同文件关系。
现代 host 校验当前 samefile/字节；保存的 Windows file IDs 由原 Python 3.8.10 ABI 逐项比较，避免跨 ABI 错比。

执行器要求现代 Python >=3.11，生成器和物理 ID helper 只使用 frozen plan.generatorPython。
helper 不能从摘要、环境或未绑定文件另选可执行。实际调用语句 AST 的对照复现旧摘要注入，
新语句只接收已冻结 plan 参数；用 3.8 误启动主脚本会在任何 plan/执行前明确拒绝。

每个 successor 使用新输出根、plan、preflight、独审和 exact approval。只读预检成功不等于执行授权。
执行以独占 execution claim 开始，不复用旧失败 claim；先备份 false 头和原产物，在新 staging 验证
完整 canonical sidecar、digest、header 字节后才安装一次。dry 必须恰好报告 identity object 编译及 DLL 链接。
Ninja 日志只能追加该对象与四项链接输出，前后材料/角色/命令相同；输出树只接受白名单变化，共享 SDK Windows
守卫快照逐字节不变。非预期变化保留失败，不自动重试或回滚；身份 true 也不授权 GUI。

## Verification

这是已实际执行的静态流程，不重跑 seek、旧组件、桥接 fake API 或原性能失败候选：

- 实际角色与授权自测 34 项通过；16 项增量能反演为原执行器全部字节。3.8 主入口负例在生成 plan 前 exit 1。
- 未冻结摘要选择 EXE 的旧实现由真实 assignment AST 复现；修正后四项精确增量逆向一致，
  新真实 argv 只读 plan 参数。旧成功 preflight、失败独审及撤回脚本保留，不作为当前 execute 依据。
- 修正输入后的 fresh preflight 自然 exit 0、无强制清理，43.929 秒；32,901 项共 5,566,614,544 字节、
  39 目录与全部别名检查通过。输出 7,259 文件、SDK Windows 112 文件快照与原基线相同。
- 单次 execute host 自然 exit 0、无强制清理，112.848 秒；Ninja PID 64704 自然 exit 0，
  仅编译一个 identity object、链接一次 DLL。执行前后原材料/角色/命令及全部 57/152 别名验证保持。
- 新 header 为 true，闭包 SHA256 为 `F31E4336CF3D1E4BD7FBE33A72A796E311A1EF7EBCDD922728D9B682863C6191`。
  新 DLL 为 21,839,360 字节，SHA256 `3AADD9C685363CFBCF94AC5AE41333A920E86DB82B77A677D261E3D733EF60C3`。
  import lib 和 gen_snapshot 字节不变；133 个 export names 相同，6 个 GLPB API 各存在一次。
- 实际输出树只有 identity header/object、DLL/PDB 与 Ninja log/deps 六条白名单内容变化，SDK 112 项快照不变。
  主智能体重新核对 15 个当前产物/回执与 canonical sidecar，生成头及最终 DLL 均不在闭包输入中。

精确运行记录在统一任务产物 `sourin-glpb-recovery-20261119-round2/lead/qualification-resolved-v2/`：
`preflight-v1.json`、`execute-host-v1/result.json`、`execution/result.json`、
`ROOT_STATIC_IDENTITY_RELINK_RESULT_REVIEW_V1.json`；独审位于同任务 `independent-review/`。
独立 V5 对 claim/approval/源码/新鲜预检、真实产物、保存的前后树与 canonical 角色做 25 项有限核对，
不重复 5 GB live 材料审计；其 JSON 对象键序误报已改为逐键/逐行比较并在回执披露，不是产品失败。
详细范围由[验收报告](../../../../FINAL_ACCEPTANCE_20261118.md)持有。上述自然退出只是 build host，
不是应用的双时钟空 Job 八秒验收，不能替代真实客户端退出。

## Alternatives considered

- **只记录 HEAD 或只列直接编译头文件**：成本低，但会漏掉实际工具、生成材料和保守目录变化，不能支持完整闭包身份。
- **不保留角色直接按 strict path 去重**：能避开重复输入错误，但丢失原词法成员与 alias 约束，故将原角色与实体列表分别绑定。
- **现代 host 直接对比旧保存的 file ID**：少一个 helper，但 Python Windows ABI 暴露方式不同，故由原版本核对保存 ID。
- **从 alias 摘要选择 helper EXE**：容易沿用原工具记录，但它没有进入冻结 plan，真实 AST 对照已复现替换入口，故拒绝。
- **共享 SDK 原地替换、复用旧 approval 或自动重试**：步骤少，却污染其它构建或把失败状态变成不明重入，均不采用。

## Consequences

收益是当前隔离 DLL 取得有限、非循环、可读回的静态身份；原 alias 重复失败与解释器选择缺口均有可复核后继。
代价是保守 5.56 GB 材料读取、别名双视图、独立解释器 helper、输出/SDK 快照和一次性许可的维护。
有限边界不覆盖全宿主，身份 true 不是驱动支持、实际 cache hit、视觉等价或性能通过；没有启动 GUI 或真实 GL。
capture/consume 必须后续绑定同 DLL、同 AOT、正确 header/import lib、匹配 patched SDK 和私有 runner。
只有所属引擎源码/工具/目录成员/命令/alias/执行器输入改变或新反证时才重新打开影响面；
没有变化不重做本阶段，不复用已消耗 execution，不覆盖旧失败，也不因此让应用旧包取得新引擎资格。

## 现有笔记审计

按有限闭包、alias、解释器绑定检索 proposed/implemented/rejected：直接前驱为上述 GLPB proposed，
属部分落地而非整个提案完成，两篇互链并保留。
[渲染启动归因](2026-11-16-renderer-startup-cause.md)持有 trace 与原预算，
[按帧号归因](2026-11-19-frame-number-trace-attribution.md)持有解析，
[任务窗口安全](../bug-fix/2026-11-18-task-window-safety-and-package-acceptance.md)持有窗口/同包；均部分重叠而不取代。
其它媒体项的对象或源码归属记录不拥有引擎闭包，属于无关命中；不归档这些现行安全决定。
