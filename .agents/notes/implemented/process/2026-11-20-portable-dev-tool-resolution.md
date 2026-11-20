# Agent Note: 开发工具与独立探针显式解析本机输入

Status: implemented

Related: [显式账户与快照夹具](../testing/2026-11-20-explicit-probe-fixture-inputs.md)、[开发播种的只读合同](2026-10-15-dev-data-seed-readonly-no-credentials.md)。本决定只改变开发启动工具、独立诊断和测试的路径解析，不改变产品普通数据目录、默认UI、既验seek或账户协议。

## Problem

旧脚本和诊断把Flutter、ffmpeg、参考源码、输出目录或媒体固定在某台开发机。机器路径既阻碍提交前隐私清理，也使换机执行选择到错误工具或数据；仅把用户名随机替换会破坏路径夹具输入/预期关系。参考Vue用例遇到缺失文件直接return，记录成功却没验证原断言。独立T74诊断缺数据输入时还会退回APPDATA/HOME，隔离不完整。

## Decision

PowerShell共享Resolve-SourinFlutter只接受实际Application命令和明确SDK。run_client及live计数脚本保留显式SDK先、PATH后的意图；run_t107保留PATH先、SDK后的意图。SDK候选按SOURIN_FLUTTER_ROOT、FLUTTER_ROOT选择；在SDK-first/PATH-first选择之前先验证显式候选，已配置但无bin/flutter.bat是真错误，不因PATH恰好有另一工具而掩盖损坏配置。仓根与exe/log路径从PSScriptRoot解析，不依赖调用cwd；run_client原开发播种和普通数据授权合同保持，本轮不运行其GUI本体。

图标字体按测试所选package:flutter/foundation.dart的真实SDK位置解析，不假定flutter_tester和SDK在同树；Windows CJK字体按SystemRoot查询。t84媒体工具用显式SOURIN_FFMPEG/SOURIN_FFPROBE或PATH，无机器ffmpeg目录；插件输入必须显式SOURIN_T84_PLUGIN_DIR，不隐式发现用户plugins。旧网络ignore与断言保持。

29个独立Dart探针用probe_paths.dart选择PROBE_ARTIFACT_ROOT、PROBE_MEDIA、必要的参考checkout和DATA_DIR_OVERRIDE/T74_DATA。输入缺失、相对路径或缺文件明确报错；子路径拒绝空段、dot/parent/drive及Windows尾空白/点，URI字面#、%不被当fragment/转义分隔符。环境产物/媒体设置优先于Dart define；T74保留运行期T74_DATA非空时优先DATA_DIR_OVERRIDE的意图，17个独立诊断的APPDATA/HOME隐式回退移除。root由操作者显式选择，未声明对恶意并发reparse替换的沙箱。

Task32/37通过ORIGINAL_VUE_FIXTURE_ROOT读指定参考源码/CSS；缺参考是环境错误，不以提前return把未执行断言写绿。保留原断言及synthetic路径输入/预期，不改产品组件行为。

## Alternatives considered

- 只把硬编码用户名替换为另一串常量：diff最小，但换机仍错、可能改坏成对fixture且不能表达操作者选择；不选。
- 统一强制PATH先：最少配置，但会翻转run_client原先明确SDK优先的调用合同；保留每个消费方原顺序意图。
- 缺fixture时继续skip或找默认用户目录：更易在干净环境显示绿，但缺验证不透明且可能读取真人目录；不选。
- 改产品全局数据路径解析：能统一更多调用，但扩散为无关产品行为并使既有包资格失效；不选，本轮限定工具/诊断。

## Consequences

PS7与Windows PowerShell5.1分别实跑4个负例exit2、4个正例exit0，分别执行不同真实fixture.bat输出标记，验证SDK/PATH两顺序而非mock；7脚本在两代解析器实际AST零错误。Dart实际图标字体函数2负例exit255、1正例0，读得1645184字节；这是SDK定位，不是widget渲染资格。Rust真实媒体路径函数4负例、4正例执行标记进程，插件输入缺失红控与显式夹具读取另核，不运行旧t84网络目标。

SDK直接运行test/probe_paths_check.dart的6组真实临时文件测试exit0，覆盖缺/相对/缺文件、子路径逃逸、Unicode/#/%2F、环境优先与defines。移除绝对路径检查的真实副本同一测试exit255，证明门会红。50个冻结文件隔离离线类型分析0error、127warning、143info、exit2，不包装成0诊断；缺主工作树package配置，参考Vue及旧独立GUI/网络诊断均未运行。无真实账户/凭据/DB/网络读取或seek/原20重播。

收益是工具输入可搬迁、缺验证显式、任务产物路径可选择；代价是调用者必须设置正确SDK/媒体/夹具/数据根，旧诊断不再无配置就运行。回执在统一任务目录sourin-performance-20261120-round15/parallel/portable-tools与portable-probes。测试的是新路径解析和独立源码接线范围，不外推整产品/UI/播放或全目标通过。BOM/原行尾与实际调用点另由根diff核对；提交/推送必须全树区分公开身份、占位/合成fixture与真正机器路径，不能只扫本次diff或删公开作者链接。
