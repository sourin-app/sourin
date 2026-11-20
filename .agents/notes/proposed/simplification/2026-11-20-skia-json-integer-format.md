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

人工原生写出器差分和真实surfaceless live caps reader的红控/正例均已实际执行；六次逐次读取完整字节与指纹等价，只关闭这些行为子项。产品采用前仍须冻结并重编整个受inline头变化影响的真实TU闭包、绑定产品引擎/同包并取得受影响行为、像素和原20预算的新证据。五个fixture TU不代表完整引擎图，live字节相等不代表速度或预算通过。

## Risks

整数格式化在当前off基线中没有相应ReadLive消费调用；本轮真实live reader只证明字节/指纹等价，未量其速度或应用收益。类的inline头变化扩大重编范围，不能仅重链单对象后宣称完整产品采用；本候选保留所有实时查询，不以潜在收益换取旧指纹复用。

## Consequences

真实C++正例各执行100000次伪随机十进制调用，另覆盖有符号最小/最大、无符号最大、0与进位边界、hex和嵌套混合类型。每模式数组有100068项；root独立按整数token核全部值（避免JSON浮点精度损失），不是只对两份可能同错的输出。kFast原/候选均1562905字节，kPretty均2263461字节，全部字节一致。故障把S32负数按unsigned写出，实际-2147483648→2147483648、5949字节总长度差，被同一门检出。

编译/链接前驱失败完整保留：MD与实际MT对象不匹配、受控搜索路径缺静态CRT/UCRT、Skia流对象的真实文件/内存/日志符号闭包缺失。后继只在输入改变时补依赖，成功编译对象按hash复用；没有force-unresolved或伪造函数来糊过链接。最终执行链接真实Skia实现，已冻结直接输入前后hash一致；实际include保留在编译日志中，但未以本次fixture冒充全SDK或引擎源码闭包资格。

根回执 sourin-performance-20261120-round13/ROOT_JSON_WRITER_DIFF_READBACK_V1.json，SHA256 C1A8930A66A005F233485D4DFEC7F1B182A170066F77300B3738BA118690407F。候选补丁 skia-decimal-writer.patch，SHA256 8FFE4D4392C574B283A6F493361BCED800D07A60DAB4DBA1B86E3DEF402F3144。

私有live夹具现在把四个真实Skia消费者（GrCaps、稳定版GrGLCaps、GrShaderCaps、SkJSONWriter）及Manager/ReadLive主TU编入同一执行体，五编译和链接均自然exit0/noForce/双空≥8秒。GrGLCaps明确复用已资格的stable caps源和原caps-fixture对象角色，未误换为当前SDK普通dump语义；实际267个include已按编译cwd解析并重哈，两个lexical候选头角色同字节。3513复用obj/556库在执行前后冻结核验；不是全SDK fresh或全引擎头依赖闭包。

同一真实surfaceless EGL Manager/Ganesh上下文，正例依次0→1→0、0→1→0逐次完整ReadLive；六次caps JSON各22109字节同SHA，完整fingerprint相等，caps/options hash为F23DBB7A…1EB5。真实S32/U32/S64/U64调用每次85/57/12/0，共154；计数不从静态调用点比例推断。真实故障模式2在相同dump路径改末位数字，154字节变化且hash变化，原生自然exit1/原stage passed=false；随后正例自然exit0，原代数context/generation/scope/unbound/rebind-epoch守卫均实际执行。Job双空分别8.0471/8.0544和8.0182秒，无force。此为新的真实输入差分，不重跑旧fixture取性能成绩。

根live回执 sourin-performance-20261120-round14/ROOT_LIVE_CAPS_JSON_DIFF_READBACK_V1.json，SHA256 AB30A64511084B1C3A3099A224E08DF56A723DFD2B8561769904D6A302E5B575。新增selector/counter/dump仅属于任务夹具，保持所有实时驱动/能力读取；它不属于生产实现，也不据此声明live-reader速度或应用帧预算改善。原R13人工差分仍单独有效。

成熟Ninja实际依赖库现已枚举4944条记录，SkJSONWriter头有11个VALID依赖角色。与真实父DLL rsp交集10个Skia角色，另一个live-context逻辑角色对应父图中的私有identity对象；本次据此实际重编11个TU，而非把五夹具TU当整个引擎。GrGLCaps仍映射已资格R5 stable对象，identity重编使用新闭包；3506个未变物理对象按真实link去重，父sidecar中同一caps对象的两个词法alias不冒充两份物理对象。

纯候选头逐字节等于R13已对照版本，不带R14 selector/counter/dump；所有其他新source保持真正父输入字节。11次编译和DLL链接均自然exit0/noForce/双空≥8秒，400个实际include已按编译cwd核字节，全部TU确实看到纯候选头，identity看到新的identity头。新DLL SHA256为8A05A10E8DA8BA9B29CC226C31D6A4149B613C1472FDB5CB3019C1223CC80569，闭包12014899017F1A37799D4EB29B78F69D883BC5F9BE7F0A3F084817BC170A5052；import lib仍20C5510E…B4616F。原OUT的size/mtime/file-ID守卫不变，原实对象/库前后hash匹配。

PE与真实加载子项现有新原件：133个导出name/ordinal与父DLL相等，24个regular及2个delay模块、465个import symbol行保持；删真实导出和交换3/10 ordinal的实际子进程均exit4。RVA只要求有效，未把重编后的地址相等当ABI保证。真实LoadLibraryEx/GetProcAddress/FreeLibrary另由错误hash先exit23/不load，再正例解析6个GLPB+30个public导出、成功卸载/之后未映射；均noForce/双空≥8秒。没有调用已解析engine函数，故这不是完整runtime资格。

新的同DLL/同原AOT pair各只运行一次。新捕获完成原20、自然exit0/双空8.0269/8.0283秒，动作末1063、pre-Quit/quit1082帧含19尾帧，严格build/raster/total超3/36/74。原Finish成功、38descriptor/37唯一payload/496864字节，manifest362382F5…ABA24经原decoder独立校验；消费97文件=base59+物料38。

消费者虽完成20动作且原Quit自然0/noForce/双空8.0507/8.0522秒，但原检查以NO_DROPPED_OR_MISSING_QUIT_TAIL_FRAMES失败：动作末1116、已保存pre-Quit1131含15追加尾帧，Quit计1136，缺5条raw。保存前缀的1/5/15超限只属1131已保存帧，不是1136全帧预算；不补帧、不删分母、不把最终native-helper的静态false改绿，不重播该样本。原生有限计数是39load/38return/binary/matched/driver accepted、1reject、0fallback/reentrant，初态已有1load/1package return，nonce4604284952899482733保持；不推断每key全覆盖或该次拒绝原因。原38个物料及只读副本消费后字节均不变。

root亲看四PNG：capture Home可见多张真实海报，consume Home主要灰占位；最终Settings同hash。18个实际加载包映像两臂均匹配新DLL，采样窗口状态非iconic/nonforeground，只限保存采样点。两臂视觉内容状态不等价，不凭数字差异作跨运行因果提速或全程像素等价。

原collector最初因当前工作树隐私/探针变更触发旧AOT冗余live-root哈希拒绝，前驱保留。读侧后继对54（capture）及55（consume，新增服务器名注释脱敏）条路径仅映到旧build.sourceInputs中同relative/hash的真实冻结副本，仍检查9758绑定、819源码；其他SDK/helper/tool全部原地校验，不把当下改后源码叫已编入旧8E68…AOT。错副本字节/hash/非source path实际红控拒绝。consumer重复decoder模块名的前驱冲突同样保留，后继两私有模块均完整校验原bytes。根离线checker首稿错取capture的observation字段失败，按真实mode分支的只读v2完成原件核对，没有重启应用。

根pair原件回执 sourin-performance-20261120-round15/engine-build/ROOT_R15_PURE_ENGINE_PAIR_READBACK_V1.json，SHA256 4DBC73DAC572610D6BF7615D8AEC706EFEDB21E931317F800B1BBAA7B0473C86。这是派生对象图和记录头依赖角色的有限资格，不是父SDK全源fresh/hermeticity；消费者raw尾帧完整性和原严格性能未通过，候选仍proposed、不生产采用。后续只在采集边界或性能具体owning input改变时重开，不复跑seek、旧pair或已闭子项。
