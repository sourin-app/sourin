# Agent Note: 程序二进制兼容指纹区分固定能力与惰性读取缓存

Status: implemented

适用：固定 Skia、ANGLE 与本机驱动上的任务专用私有 DLL。这里只持有稳定指纹序列化和已实测的 39 条材料；
不代表生产采用或性能通过。[GLPB 总方案](../../proposed/architecture/2026-11-19-glpb-exact-engine-aot-cache.md)
持有总准入，[旧九条材料](../testing/2026-11-20-glpb-scoped-capture-driver-witness.md)保留原 DLL 与运行范围。

## Problem

旧 caps 摘要包含随 FBO 读回探测改变的状态。第一版原因诊断自然退出但零标签，没有证明原因；
其后继取得启用正见证，同一成功 render reader 的 78 个快照出现三个摘要，对应 read-query 计数 1→2→3。
第一个 caps 摘要与旧九条清单的 caps 字段一致，整组指纹不同。旧 31 次拒绝无逐次分支票据，
不能从同次摘要变化追溯每次具体拒因，更不能归给 resource 角色。

## Decision

任务版在 GLPB 指纹专用 writer scope 使用新摘要域 Ganesh/actual-options-and-program-binary-caps/v2，
普通 dump 与真实读回状态、查询、回退不变。仅省掉 read_queried，以及逐项 requires_read_query=true 时
可被 didQueryImplementationReadSupport 清零的 ex_read；非惰性项的 ex_read、requires 标志、共享 external type、
TexImage 格式、swizzle、stencil、shader caps 与所有其余项原样保留。scope 限定同线程同 writer，
无既有类布局或 vtable 变更，不在每次指纹读入时解析/重写 JSON。

实际 context role、generation、epoch、before/after、引擎/AOT、驱动、设备、接口 ABI 与格式守卫保持；
旧清单不重贴标签或自动迁移。源码写入点和调用点表明这两个可变项属于 ReadPixels 支持/格式选择，
未直接进入同 key 的程序描述符或着色器生成；这不证明不同读回条件下的回退、转换和间接绘制等价。

## Verification

- 真实 ANGLE D3D11 Pbuffer 使用固定 Skia 对象：读回格式实际查询使普通 dump 的 read_queried 变化，
  专用 dump 字节相同；独立受控不匹配查询只额外使 ex_read 从 0x80e1 清零，专用 dump 仍相同，
  external type/TexImage 保持。修改保留的 stencil 索引会改变专用 dump；普通 writer、嵌套和跨线程隔离见夹具。
  两次均真实编译、链接和自然退出，第二个夹具复用已验 caps 对象，未重跑第一个夹具或产品。
- 新 DLL 064F25F4…FCD4F35、闭包 654A87063AC7B2B3D3EC7F00162184BD02B7A0FA9B83DF4CA2BDF9C58A6AC1BC，
  32,812 个材料角色加 3 个 provenance；编一个新身份头消费者，复用同一 caps 对象，独立链接，原输出与 SDK 不变。
  同 AOT 8E68C741…0331A 的 59 文件 capture 与 98 文件 consume 都完成原 20×700ms 场景。
- 捕获 39 observed/stores/entries，0 context/payload/IO/conflict 拒绝；38 份唯一 payload、506,424 字节、
  实际 manifest SHA256 A6B4575C1B2D069A2F6F82F6D5F8FB11F707EE722B39C1FBB3EB79CFB20BE764。旧九条按 descriptor 与 payload 逐项相同，但由新程序实际重新捕获，
  新增 30 个描述符；差异指纹字段仅 DLL/闭包/caps，未导入旧材料。只读包 39 个材料文件事后 hash 保持、只读属性保留。
- 消费者 39 load/return/matched/实际 driver accepted，0 拒绝、0 回退。两个 owned 窗口不激活并消失，
  自然 exit 0、无强制清理、双时钟空 Job 均满八秒。独立离线校验只核材料与回执，不替代运行 witness。
- 首页与最终设置 PNG 各自跨这两个运行同字节；首页可见区是实际海报，不是全程像素等价或真实库 Top 20 修复。
  解码状态组件由[解码观察](../testing/2026-11-20-poster-decode-observation.md)持有，不追认旧 readiness。
- 捕获工作负载 1108 帧→Quit 前 1116 帧→Quit 计数 1121，末 5 帧无逐帧原件；消费 1112→1120→1120，
  两边前缀（含 timing receipts）逐项一致，均不声称 Quit→exit 全帧。捕获/消费已保存 Quit 前超限依次为
  **1/6/16、1/10/14**（build/raster/totalSpan）。消费者最坏 raster 193599μs、totalSpan 368039μs。
  采集前新增 Quit 前快照、消费预检按新实际材料数计文件；动作、20 个窗口和原预算不变，不把此诊断当正式性能。

原件在任务 sourin-glpb-context-20261120-round5/ 下的 stable-caps-overlay-v1、private-stable-caps-engine-v1、stable-run-v1。
联合只读校验和根回执 ROOT_STABLE_CAPS_NEW_RUNTIME_WITNESS_V2.json 更正首份摘要抄错的闭包及冻结消费清单中继承的
expectedCapturePackageEntries=9（实际未被 collector 使用）；不修改冻结清单、首份摘要、实际素材或运行结果。

## Alternatives considered

- **完整 caps dump 不分状态**：对所有变化保守拒绝，但对实际查询历史误区分，缩减本机同程序缓存范围。
- **冻结第一个 caps 摘要**：开销小且不会再受惰性查询变化，但会吞掉后来的真实能力变化，不采用。
- **多个动态 caps 清单**：能扩大覆盖，却仍把查询历史当身份，引入格式和包复杂度，不采用。
- **跳过 caps/context/before-after**：容易提高命中，但破坏程序兼容与实际当前上下文约束，不采用。

## Consequences

在固定版本与本机任务运行中，查询历史不再形成无意义的指纹阶段，真实可接受范围从旧样本九条扩至新样本 39 条。
代价是新摘要域、闭包及重新捕获，且仅证明当前 39 次实际渲染请求；没有失败包复用、跨驱动保证或对旧31次的逐条归因。
错误字段归类仍可能接受不兼容 binary，Skia、驱动、shader key、读回路径等所属输入变化必须复查。
正式性能、可见读回/交互等价、最新产品包与其余原始外部验收仍由[总方案](../../proposed/architecture/2026-11-19-glpb-exact-engine-aot-cache.md)
和[验收台账](../../../../FINAL_ACCEPTANCE_20261118.md)限定；不为了通过重跑本次未变候选。
