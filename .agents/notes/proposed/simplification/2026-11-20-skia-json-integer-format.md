# Agent Note: 私有Skia JSON整数写出候选保留逐次实时指纹

Status: proposed

Related: [同引擎缓存提案](../architecture/2026-11-19-glpb-exact-engine-aot-cache.md)；[渲染启动归因与原始预算](../../implemented/testing/2026-11-16-renderer-startup-cause.md)。

## Problem

实际同线程指纹子项曾记录 caps JSON dump 中位约100.4微秒，它属于缓存消费路径的额外成本，并非第12轮GLPB关闭样本704219微秒raster峰值的根因。已有证据不足以缓存driver version或caps结果；同device、epoch不变和设备未removed均不构成全部能力不可变的证明。

Pinned SkJSONWriter的S32/U32/S64/U64十进制方法使用通用printf格式化；Skia已自带有边界常量的SkStrAppendS32/U32/S64/U64。候选只替换这四处格式化，减少通用格式解析，不省略任何逐次查询、字段或JSON输出。

## Proposal

只在统一任务目录保留可应用的私有补丁和真实C++差分执行体，不修改仓库产品、原SDK、当前DLL或AOT。四种整数方法用现有Skia函数、各自最大缓冲长度、64位minDigits=0；字段顺序、beginValue、32KiB输出缓冲、stream、hex、float、UTF-8、嵌套状态和对象布局保持。当前状态是行为资格候选，不是实际引擎采用或性能改善结论。

原写出器、候选和故障写出器都是实际pinned头/源码编译出的不同类，使用实际Skia核心实现而非桩。先执行符号位故障副本使原生进程自然exit73；再执行原/候选逐字节正例，原生自然exit0。两者均无force，Job双空均至少8秒。negative阶段原始passed=false保持，不被改写为执行通过；独立对照只判定它确实按预期变红。

## Alternatives considered

- 缓存整个caps或driver version：能避免更大查询包络，但没有充分不可变性证据，可能复用过期指纹；不选。
- 新写整数转换、改用另一套JSON库或to_chars：可去掉printf，但会增加额外实现/格式等价审计；现有Skia函数足够，直接复用。
- 删除caps dump或仅hash手选字段：实现简单、开销更小，但会丢掉动态backend onDumpJSON和有效能力成员，破坏原指纹契约；不选。
- 原样保持printf：维护面最小且无需新依赖；作为原件对照保留。候选尚无实际live reader收益，不能仅凭低层实现就淘汰原路径。

## Acceptance criteria

当前原生fixture的红控、正例、全字节与独立整数值检查均已实际执行；这只关闭该差分子项。采用前还须冻结并重编所有受inline头变化影响的真实TU、在同一live caps reader逐次验证原/候选指纹，并取得同包受影响行为和原20预算的新证据。编译成功或此次fixture相等均不替代这些条件。

## Risks

整数格式化在当前off基线中没有相应ReadLive消费调用；即使底层更省格式解析，也未量到实时reader或应用收益。类的inline头变化扩大重编范围，不能仅重链单对象后宣称全路径采用；本候选保留所有实时查询，不以潜在收益换取旧指纹复用。

## Consequences

真实C++正例各执行100000次伪随机十进制调用，另覆盖有符号最小/最大、无符号最大、0与进位边界、hex和嵌套混合类型。每模式数组有100068项；root独立按整数token核全部值（避免JSON浮点精度损失），不是只对两份可能同错的输出。kFast原/候选均1562905字节，kPretty均2263461字节，全部字节一致。故障把S32负数按unsigned写出，实际-2147483648→2147483648、5949字节总长度差，被同一门检出。

编译/链接前驱失败完整保留：MD与实际MT对象不匹配、受控搜索路径缺静态CRT/UCRT、Skia流对象的真实文件/内存/日志符号闭包缺失。后继只在输入改变时补依赖，成功编译对象按hash复用；没有force-unresolved或伪造函数来糊过链接。最终执行链接真实Skia实现，已冻结直接输入前后hash一致；实际include保留在编译日志中，但未以本次fixture冒充全SDK或引擎源码闭包资格。

根回执 sourin-performance-20261120-round13/ROOT_JSON_WRITER_DIFF_READBACK_V1.json，SHA256 C1A8930A66A005F233485D4DFEC7F1B182A170066F77300B3738BA118690407F。候选补丁 skia-decimal-writer.patch，SHA256 8FFE4D4392C574B283A6F493361BCED800D07A60DAB4DBA1B86E3DEF402F3144。

代价是32位inline方法变动需要重编实际消费者，单换SkJSONWriter对象不构成完整引擎接线；未来构建须冻结所有实际受影响TU和include，而非重标旧对象。重新考虑采用只限：同一真实live caps输出/指纹等价、实际调用路径、同包受影响行为与原20严格预算都有新证据。尚无live reader、完整引擎DLL、GPU像素或应用性能资格；本轮无GUI，不重播旧seek/原20。第12轮1096帧及3/12/26超限保持失败。
