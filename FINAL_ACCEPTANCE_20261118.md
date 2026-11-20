# 当前交付逐项验收 — 2026-11-18

稳定性及最终整包阶段通过。性能场景已经实测执行但未通过严格帧预算：V32 Profile AOT/runtime 完成原始 20 场景并保留 1172 帧，预算超限数为 build/raster/totalSpan **1/7/14**。V30、V31 的失败记录仍保留；完整原目标尚未全部验收。
本表保留原 18 项反馈和追加 12 项，不覆盖 `.probe/` 中的封存前驱及失败记录。
本次并发审计未发现原计划明确指定的可达 UI、三类源播放或指定封面的新增本地产品缺口。后续只读检查发现一个可局部恢复的历史封面候选，详见下方增补；Top 20 中另一个空封面仍未解决。

原稳定性包产品提交：`be4bb0e3df7d54aa7113944bfdac5e6acee2ece6`。当前点击修复包以 `c58b7dc7cbd765b7fe469dc73aa81a0911ac4589` 工作树构建，未提交修复由逐文件编译输入绑定，详见文末同包续验。

| 项目 | 原要求 | 已有证据证明的范围 | 状态 |
| --- | --- | --- | --- |
| 1 | 聚合子源一级、独立排序、首页无前缀且排序显示来源 | 49 源保存及独立进程顺序读回；当前首页、源管理及排序不保存返回 | 范围内通过 |
| 2 | 源平铺、类型/聚合筛选、搜索、多提供方选择 | 正数据筛选，单/多提供方取消、保存及冷进程读回 | 范围内通过 |
| 3 | 播放器浮层统一 Miuix、细滑条及间距 | 可见面板与几何证据；当前播放、换集和请求未完成时原退出流程 | 范围内通过；旧事件来源未确定 |
| 4 | 详情 tag、按钮、线路使用 Miuix | 实际详情、窄窗布局、当前集与原线路切换状态同步 | 范围内通过 |
| 5 | 弹幕搜索及异常 | 受控端点正/空结果、取消、晚响应、卸载与再入 | 范围内通过 |
| 6 | 同一折叠标题行展开/收起 | 当前 SettingsDisclosure 原标题回调，偏好 1→0 | 通过 |
| 7 | 二级入口圆角 hover 无直角阴影 | 实际挂载 MouseRegion 原回调、圆角和可见像素 | 范围内通过 |
| 8 | 追更作品封面恢复 | 下述四张精确卡片及两库项的解码、身份和页面证据 | 指定范围内通过 |
| 9 | 直播保留布局改善 UI | 两组合成 60 频道、深浅主题、后段频道视频、隐藏暂停及返回 | 范围内通过 |
| 10 | 弹幕源 selected 可辨识 | 原 radio 选择、保存、独立进程读回、清除与默认恢复 | 通过 |
| 11 | 按钮文字居中 | 原要求入口的实际可见图、几何回归和 More 溢出修复 | 指定入口内通过 |
| 12 | 页面进入退出均有动画 | 五种风格、主 tab 正反及二级 route 进出、none 控制 | 动画行为通过；不代表性能通过 |
| 13 | 页面卡顿优化 | V32 Profile GUI 完成原始 20 场景及全帧采集（1172 帧）；严格 60Hz 预算超限 build/raster/totalSpan=1/7/14 | 已实测；性能预算未通过，仍属必做目标 |
| 14 | 替换剩余可见非 Miuix 组件 | 播放器、详情、弹幕、直播、设置和公共入口；样式桥不算残留视觉控件 | 指定入口内通过 |
| 15 | 首页一级源液态玻璃 | 当前生产实现、Home 实绘、历史选择/排序及最终烟测 | 范围内通过 |
| 16 | 二级返回标题统一 Miuix | 公共顶部栏及当前源管理、排序原返回流程 | 范围内通过 |
| 17 | 确认无用再删配置 | 已删除无换集消费的 keepSourceOnNext，保留旧存储兼容 | 原修改通过 |
| 18 | 稳定及频繁异常修复 | 已复现异常的修复；当前三种 Release 退出场景自然结束 | 范围内通过；旧事件来源未确定 |
| A1 | 主备地址降级、最终 URL 相对资源、并发所有权 | JS/直播/TVBox 实际本地生命周期回归，代理、备用、相对资源与禁用状态保持；地址 UI 独立进程读回 | 本地受控范围通过 |
| A2 | 声明式退役、聚合导入、GitHub 发现 | 原导入与退役证据；实际 12 仓库/48 候选及启停、移除、已读、冷读回 | 原范围内通过 |
| A3 | 来源/匿名协议/JS 与必要 WASM | 下述三家族精确选集到实际 PlayerPage；协议仅在需要时处理 WASM | 精确三链路通过 |
| A4 | 匿名网络、可见性与隐藏返回 | Home 隐藏有界窗口、弹幕晚响应和直播隐藏/返回 | 精确场景通过 |
| A5 | 指定集实际持续播放 | 同播放器、选集身份、实际视频与进度推进；上游短片范围保留 | 观测时段内通过 |
| A6 | 原生非零音频 | 同核心/解码器精确流三秒 PCM，静音零值与非零对照 | 解码器通过；未声明设备可听输出 |
| A7 | 封面身份、可见解码及冷重启 | 四卡精确身份；两库项同 profile 冷进程、排序/时间/进度与缓存封面 | 指定范围内通过 |
| A8 | 统一代理/FIFO/凭据全链 | 代理、匿名 HLS/headers、JS ABI、FIFO 和本地清理已有证据 | 真实账户与外部操作未验收 |
| A9 | 同源 AOT 启动、导航、滚动性能 | V32 Profile GUI 冷启动及原始二十场景实测；1172 帧完整保留；原始 60Hz 帧预算未通过 | 实测已完成；预算未通过，仍属必做目标 |
| A10 | 最新桌面稳定与原退出 | 正常生产 AOT，播放/换集/待请求原 ask/Quit，自然 exit0、双时钟空 Job ≥8 秒 | 当前阶段通过；旧事件来源未确定 |
| A11 | 普通未修改启动退出 | 已验任务模式原 ask/Quit；普通默认 focus 不在该证据范围 | 缺少合适的独立测试会话 |
| A12 | 最终同产品输入/包/运行绑定 | 历史点击修复包保留；最新源码本地59文件候选已实际三退出、原16烟测及固定封面HTTP/像素，并完成ZIP逐件绑定；不包括私有GLPB引擎或未过的全局条件 | 当前本地同包阶段通过；完整目标/正式交付未验收 |

## 2026-11-18 晚间继续验收增补

- **单个历史封面候选**：在授权后只读打开真实数据库，并把一个精确身份投影到全新任务副本；没有写真实库、真实配置或生产 core。未修改的生产 `repair_library_covers` API 在副本上补齐 1 条历史封面；精确身份、行键、全部非封面字段及 SQLite 类型保持不变，副本里空封面由 1 变 0；无网络，宿主自然退出。证据：[副本 API 验收](.probe/current-real-config-permission-20261118/one-real-cover-repair-owned-v1-c3ec451ca53241f3bbfafd8673d2d6ea/aggregate.json)。这只是一个已有精确身份候选的本地恢复；Top 20 的另一个空封面仍未解决，也不代表所有封面通过。
- **普通启动**：v1 观察器把有效空桌面枚举误判为错误，未能检查应用。v2 只修正测试观察器，保留未修改产品入口；任务非输入桌面上的启动以 `0xC0000142`（`STATUS_DLL_INIT_FAILED`）在首帧前退出。现存回执证明进程退出码和前台/输入桌面未改变，但没有可复核的 loader 诊断来识别具体失败 DLL 或初始化回调，因此不把失败模块归因于 USER32。进程自然退出、无强制清理；未进行 UI 操作、账号建立、偏好修改或运行包改写。A11 仍未验收；暂不在相同桌面环境重试，先补足模块级失败原因。证据：[普通启动 v2 失败回执](.probe/release-parallel-20261117/ordinary-inactive-desktop-boundary-v1/ordinary-desktop-actual-once-v2/result.json)。v1、v2 原始失败证据均保留。
- **凭据现状**：固定目标的只读存在性检查发现若干非空 Windows 凭据项及 WebDAV 配置；未读取凭据内容。这些条目可能是残留，无法推翻用户“没有应用账号”的说明，也未证明有效性、归属或新鲜度。未登录、未转存、未执行远端清理；A8 真实账户/外部操作仍未验收。证据：[凭据与配置存在性摘要](.probe/current-real-config-permission-20261118/config-presence-summary.json)。

## 精确播放与封面范围

- App99：`1068319`《独一无二的浪漫》，非凡线路，第 01 集。
- AppRJ：`75674`《飞驰人生3》，线路三，HD中字。
- Hxq：`Qsvt16e_nETeSuxWCUzU`《Doctor X:白色黑手党时代》，韩圈，“疯狗医生降临”。
- 三者从原 FollowPage 卡片进入 MediaPage/PlayerPage，实际 1920×1080 视频、进度、设置返回及自然 Quit 均有证据。卡片为任务隔离配置；不声明所有 Home 入口、所有线路或完整电影时长。
- 第四卡 `csp-yunduo-15dd007e:86421` 按精确 owning inputs 复用既有显示证据，六项当前封面源码仍匹配；本轮未新增第四卡 GUI 运行。
- 两库项为任务夹具 `owned-final-vod/1` Alpha、`/2` Beta。独立冷进程没有重新种入或启动前改写，Beta→Alpha 顺序、时间戳、各八秒进度、三 subtab 和缓存封面通过。它不证明任意用户库或无缓存冷启动。

## 尚需的条件

性能尚未通过，仍是完整目标的必做验收项。2026-11-19 在独立 loopback-proxy 网络 cohort 中，V32 Profile AOT/runtime 已实际自然启动并完成原始 20 场景：15 次导航、1 次滚动准备、4 次设置滚动；1172 个完整原始帧记录均保留，进程 exit 0，无强制清理，运行时通过资格检查，但 `performanceAccepted=false`、`allFrameBudgetMet=false`。保持原始 `rawUs * 60 <= 1,000,000` 判据；全帧 build/raster/totalSpan 超预算分别为 **1/7/14**，最大值分别 **35,998/346,368/530,909 μs**，p95 分别 **805/2,915/5,630 μs**。启动观察截至 frame 206；首个搜索导航窗口为 frame 207–248，raster 超预算 1 帧、totalSpan 超预算 2 帧，最大 raster/totalSpan 为 18,919/25,243 μs；首个设置导航窗口还有 1 个 totalSpan 超预算帧（最大 23,880 μs）。其余 18 个窗口未见各自窗口边界内的超预算帧；另有帧落在窗口外，仍计入总预算。首屏实际有 8 分类、154 卡片、20 张稳定可见来源封面。运行回执：`.probe/perf-route-adapter-20261119-766ae2cfa4/circle-current-normal-full20-v32-loopback-v1/result.json`。这是成功执行但严格帧预算失败，不是性能通过；直连旧网络 cohort 与代理 cohort 未经限定不可直接比较。

V32 的前置构建记录仍有历史价值：当前源码 Profile AOT 编译自然完成，暂存 59 文件运行时；静态 PE 桥审查 22 个原生映像、179 个 `flutter_windows.dll` 导入符号，未发现缺失符号或 ordinal 映射差异。这不证明完整调用 ABI，也没有覆盖动态加载。原始 GUI/帧测量后来已由上述 20 场景执行补齐，但预算仍未通过；不得把 `runtimeQualified=true` 或 exit 0 当作性能验收通过。构建与静态回执见 `.probe/pp33/build-once-v1/result.json` 和 `.probe/pp33/CURRENT_PROFILE_NATIVE_PE_ABI_STATIC_BRIDGE_V32.json`。

V30/V31 的失败和污染输入审计仍保留在 `.probe/`，不与 V32 混用：V31 实际执行在 `.probe/pp32/`，kernel 自然 exit 0 后因空 output census 停在 AOT 前；`.probe/pp31/source` 只是经审计发现含 V30 `app.dill` 的污染副本，不是 V31 的编译根。V32 使用新的 `.probe/pp33/source`、新的 output census 和新的 compiler input。其后续 GUI/测量已使用独立的运行适配器及新的 quiet-window 记录；不复用 V32 的一次性编译授权，也不覆盖早期失败证据。

普通启动会主动调用 `windowManager.focus()`，单实例还可能恢复并激活已有窗口。独立数据目录也不能隔离系统钥匙串。要验普通未修改启动，需要另行提供并授权的干净交互式测试会话/VM，允许应用在该会话正常获得焦点；当前不能启动普通路径来替代此条件。

真实凭据、登录、转存和远端清理需要专用测试凭据及明确授权的外部操作环境。模拟凭据和本地回归保留其范围。

## 2026-11-19 历史私有桌面证据校正

先前记录曾称 `PRIVATE_DESKTOP_INITIALIZATION_CAUSE_QUALIFIED_V1.json` 原始回执未找到。后来在 `.probe/goal-resume-20261115-evening/` 找到该回执及其关联文件，并重算其中声明的 27 个文件哈希，全部匹配。旧的原生夹具在 private desktop 上记录 `NtGdiInit` 返回 0、`STATUS_ACCESS_DENIED`，在 default desktop control 上记录返回 1；这是**历史夹具**结论，不是当前应用 loader 回调。旧报告绑定的 source commit 为 `1ffe4076…`、core SHA256 为 `A59BB48F…`；当前已封存 Release 的 EXE/core 哈希已独立核对，当前 core SHA256 为 `15A44581…`。故该证据不能确定当前 Release 在非输入桌面失败的 DLL，也不构成普通启动验收。逐文件核对与边界见 `.probe/goal-remaining-review-20261119-c8a4e3/REMAINING_REVIEW.json`。

用户确认的手动最小化仅适用于已记录的 V4 烟测；更早事件没有足够的调用来源证据，保持未确定。

## 交付与证据

- [已验证 Windows ZIP](dist-deliver/sourin-windows-stability-20261118-be4bb0e/sourin-windows-stability-20261118-be4bb0e.zip)：43,838,056 字节，SHA256 `40A5FFDC23C48193D97DC71539A712C5754DEE1A67597789F44E20DFEB145F28`。完整解压后运行 `sourin_spike.exe`。
- [ZIP 逐文件校验](dist-deliver/sourin-windows-stability-20261118-be4bb0e/package-verification.json)：59 个文件的大小、路径及解压内容 SHA256 与已验收 manifest 全部一致。
- [当前阶段验收](.probe/goal-root-acceptance-next-20261117/CURRENT_STABILITY_AND_FINAL_PACKAGE_PHASE_ACCEPTANCE_V1.json)及[原 30 项 V29 矩阵](.probe/goal-root-acceptance-next-20261117/RECONCILED_18_PLUS_12_MATRIX_V29.json)。
- [三源及四卡索引](.probe/protocol-parallel-20261117/next-playerpage-covers-v1/THREE_ORIGINAL_PLAYERPAGE_AND_CURRENT_COVERS_INDEX_V2.json)及[两库项独审](.probe/goal-resume-20261115-evening/TAKEOVER_LIBRARY_LIVE_20261117_AUDIT_V1.json)。
- [可见 UI 验收](.probe/goal-resume-20261115-evening/FINAL_UI_V24_CURRENT_SCOPED_AUDIT_20261117_V1.json)及[More 菜单几何/焦点验收](.probe/goal-resume-20261115-evening/MORE_MENU_SCROLL_FOCUS_20261117_VERIFIED_V1.json)。
- A1 的直接行为证据：[九项源生命周期 raw.log](.probe/goal-resume-20261115-evening/all-source-lifecycle-compat-v1/raw.log)。V29 A1 的摘要沿用来源筛选措辞，本表补充其实际降级/相对资源证据，不以地址编辑界面单独证明网络降级。

以上早期阶段仅执行真实库只读快照及任务副本内生产恢复 API 验证、一次未成功的非输入桌面启动观察；当时没有公网请求、账户登录/转存、真实库写入或远程发布。后续 2026-11-19 匿名源请求和 Profile 实测记录如下。完整目标仍保持未完成。

## 2026-11-19 V32 当前源码 Profile 构建续验（静态阶段）

- 新鲜 `.probe/pp33/source` 绑定当前工作树 HEAD `c58b7dc7cbd765b7fe469dc73aa81a0911ac4589`，冻结 819 个源码/工具输入；没有复用 V30/V31 的 `app.dill`。
- `current-full20-profile-kernel` 与 `current-full20-profile-gen-snapshot` 两阶段均自然 exit 0，均无强制清理，双阶段拥有的 Job 均自然排空超过 8 秒。Flutter 输出清单为空时，runner 只接纳该新源树内唯一生成的 `app.dill`，并复制到独立 `compiler-input/app.dill` 后再执行 AOT。
- AOT 已生成并通过 hash 绑定；静态运行时暂存恰好 59 个文件，仅 `data/app.so` 与 `flutter_windows.dll` 相对正常运行时改变。证据：`.probe/pp33/build-once-v1/result.json`、`.probe/pp33/build-once-v1/CURRENT_PROFILE_KERNEL_PRODUCER_BRIDGE_V32.json`、`.probe/pp33/build-once-v1/CURRENT_PROFILE_STATIC_RUNTIME_STAGE_V32.json`。
- 本轮继续只读重算 V32 runtime：清单与磁盘文件集合均为 **59** 项，逐个大小和 SHA256 一致；相对正常 runtime 的唯二变化仍为 `data/app.so`、`flutter_windows.dll`。回执 `.probe/pp33/CURRENT_PROFILE_STAGED_RUNTIME_REHASH_V32.json`。此静态重算不启动应用、不证明 runtime 初始化或性能。
- 上面是**构建阶段**的历史回执：那一阶段没有启动 GUI或采集帧。后续全帧运行另有独立回执，已在“尚需的条件”和文末性能续验段记录；预算仍未通过。
- 额外只读 PE 预检检查了正常 59 文件运行时中的 22 个 EXE/DLL 与 Profile `flutter_windows.dll` 导出表；179 个静态导入均可解析，ordinal 名称映射与 Release 引擎一致。该预检仅降低明显的导入表风险，不替代 ABI/动态加载验证。回执 `.probe/pp33/CURRENT_PROFILE_NATIVE_PE_ABI_STATIC_BRIDGE_V32.json`。

## 2026-11-19 V31 历史事实校正

- V31 确实消费了独立的一次性 Profile 编译授权并启动 kernel 阶段：`.probe/pp32/build-once-v1/current-full20-profile-kernel/result.json` 记录自然 exit 0，Owned Job 双时钟自然排空约 8.044 秒；实际输出清单仍为空，协调器随后在 output census 断言处停止，未启动 `gen_snapshot`，没有 V31 AOT、运行时暂存或 GUI/帧采样。主回执 `.probe/pp32/build-once-v1/result.json` 的 `passed=false`、`compiled=false` 与错误记录保留此失败。
- `.probe/pp31-output-contract-v1/CURRENT_FULL20_PROFILE_KERNEL_OUTPUT_CONTRACT_STATIC_PREFLIGHT_V31.json` 是单独的只读预检；`.probe/pp31/source` 则是被审计的污染副本，其 `app.dill` 哈希等于 V30 产物。两者均不能代替 V31 实际执行回执，也不能把 V31 归类为“未执行”。

## 2026-11-19 进度条点击 seek 续验

- Miuix 单击值可能在父级双击识别结束后才回到适配层。适配层在 pointer-up 后提交迟到的点击值；拖动仍按手势结束提交，双击取消则不提交 seek。普通单击没有额外延迟。
- 最终工作树隔离串行回归：播放器控件/进度条测试 **31 passed，exit 0**；启用 `native-media` 后，seek/自动跳过、PlayerPage 点击和本地 WAV 原生测试 **24 passed，exit 0**。对应日志：`.probe/seek-click-current-20261119/root-final-v4/widget.log`、`root-final-v4/native.log`。所有用例真实执行，不是跳过。
- PlayerPage 鼠标点击用例经过真实用户 seek 回调并断言播放头更新；独立 libmpv WAV 用例确认一次点击只提交一次，原生 `time-pos` 为 **22.576 秒**，之后播放继续推进至少 **300 ms**（三次当前工作树独立重跑观察到 303–340 ms；本次验收固定判据 ≥300 ms）。不使用网络内容、账户或音频设备。旧行为撤销对照会使父级双击下的单击测试失败，恢复修复后通过；日志见 `.probe/seek-click-current-20261119/rollback-red-v1/` 和 `restored-green-v1/`。
- 对实际修改的 6 个 Dart 文件执行 formatter check：其中五个无差异；`test/zz_t1024_skip_respects_user_seek_test.dart` 存在与本修复无关的既存格式差异。尝试格式化整个文件会重排该文件内大量旧代码，因此保留其原有格式并仅规范本次改动行。`git diff --check` 与 `node .agents/notes-scripts/notes-gate.mjs` 通过（423 篇笔记）。同六个 Dart 文件 `flutter analyze`：**exit 0，No issues found**（`.probe/seek-click-current-20261119/root-final-v4/analyze.log`）。未重建运行中的 Release、未重建最终 ZIP；整个原始 18+12 目标仍未完成。

## 2026-11-19 含点击修复的 Release 同包续验

- 已在独立源码副本以 `lib/shell.dart` 构建 Release AOT，自然 exit 0。AOT SHA256 为 `4B5B8A05D1F3C6E6BDB8833DBC8ED58AE7320B2457225E868C9CC5AC8870E170`。3681 条依赖包含 3680 个实际文件和 1 个 Flutter wildcard sentinel；328 个项目输入逐文件与当前工作树一致，不能仅用 HEAD 代替未提交修复的身份。生成的 35 个资源及 Flutter 引擎与原运行时一致；独立暂存包恰好 59 文件，仅 `data/app.so` 改变。构建、输入及包清单：`.probe/seek-click-release-v1/assemble-v3/build-result.json`、`staged-runtime-v1/compiler-input-manifest.json`、`staged-runtime-v1/runtime-manifest.json`。
- 同一 59 文件包的播放中、切集、等待空响应三场景均通过原 ask/Quit 路径自然 exit 0，Owned Job 双时钟排空均超过 8 秒，无强制清理；最终首页、设置、局域网标题展开/收起、源管理、排序页返回和原 ask/Quit 的 16 个辅助动作全部通过。统一回执：`.probe/seek-click-release-v1/CURRENT_RELEASE_STABILITY_AND_VISIBILITY_ACCEPTANCE_V1.json`。数据、凭据命名空间与测试媒体均隔离，窗口启用防激活；这些成功不替代普通未修改启动或发行版鼠标单击 seek 验收。
- 新包第一次窗口最小化失败及强制清理、旧辅助工具切集选择器失败均保留，未算通过。辅助工具将原 object 重新链接为 PerMonitorV2 DPI 清单后，22/28/8 项原有无窗口检查通过；最终流程工具另有 2 项 Back 结构检查。成功场景在 96 DPI，不能宣称已实测通过 125% 缩放。见 `dpi-helper-v1/result.json`、`smoke-dpi-helper-v1/result.json` 和 `helper-dpi-v1/HELPER_DPI_STATIC_REVIEW_V1.json`。
- 发行版单击验证通过：`release-click-v5` 对可见原进度条发送一次窗口内鼠标按下/抬起，没有拖动，也没有调用滑块 accessibility 增减动作；隔离 SQLite 的播放进度从 **32 秒跳到 93 秒，随后继续到 98 秒**，截图中视频自身时间为 `00:01:38.917`。同一生产 Release AOT 保持不变，原 ask/Quit 自然 exit 0、无强制清理、双时钟空 Job 均超过 8 秒，日志异常计数均为 0。统一回执：`.probe/seek-click-release-v1/CURRENT_RELEASE_CLICK_STABILITY_VISIBILITY_ACCEPTANCE_V2.json`。
- `release-click-v1` 至 `v4` 均在未找到可见滑块时停止，实际点击次数为 0，原失败记录保留。v5 将单条间隔悬停改成连续不同坐标的窗口消息后，实际 Slider 出现；这与系统光标仍在窗口外时 `TME_LEAVE` 删除指针、下一次同点 Add/Hover 被去重的代码路径相符，但未单独跟踪每条 Leave。没有移动系统鼠标、抢焦点或修改生产引擎；本次是 96 DPI 的窗口鼠标消息验收，不宣称物理设备、125% DPI 或公网取流验收。
- 新本地 ZIP 已封存到 `dist-deliver/sourin-windows-click-seek-20261119-4b5b8a05/`：**43,830,914 字节**，SHA256 `791F01507C28C19A4D166B7682BC9210E51C78E2BA2C9F28799510008F359175`。ZIP 恰好 59 个文件，逐项名称、大小和解压内容 SHA256 与上述同包运行时一致；重新核验 328 个项目编译输入。`package-verification.json` 明确性能、普通默认启动、真实账户和完整目标仍未验收，没有远程发布；原 ZIP 保留。
- **匿名内容源就绪已恢复（隔离 loopback-proxy cohort）**：未修改生产核心、既有隔离匿名 seed 和隔离配置通过已存在的无凭据本机 loopback 代理请求原分类 20/page 1，0.709 秒返回 14 项、13 张封面；独立 HTTP 核对约 0.88 秒亦返回 14/13。生产兼容回退未修改，实际 HTTP 数未仪器化。不同网络 cohort 不与此前直连冷启动作无条件性能比较。回执：`.probe/source-core-route-20261119-63b64ec557/environment/worker-result.json`、`owned-once/result.json`、`.probe/source-routing-20261119-6e3757a8c0/resolved-source-result.json`。真实资料、凭据未读，真实数据库未写入。
- **Profile 全帧性能运行**：与该独立代理网络 cohort 绑定的 V32 Profile 实际完成冷启动和原始 20 场景（15 导航、1 滚动准备、4 设置滚动），保留全部 1172 帧；首页 8 分类/154 卡片/20 张稳定可见封面，exit 0、无强制清理、运行时资格通过。帧预算未通过：build/raster/totalSpan 超预算 1/7/14 帧，最大值 35,998/346,368/530,909 μs，p95 805/2,915/5,630 μs。frame 5、6、17、65、66、67、81、195 为启动观察区间里的八个 totalSpan 超预算帧；此外首次搜索窗口 frame 207–208 和首次设置窗口 frame 371 超预算，窗口外另有 frame 413、1021、1026 超限。其余三项 build/raster 超限也保留在原始回执中。不可删帧、改门槛或宣称通过。详见 `.probe/perf-route-adapter-20261119-766ae2cfa4/circle-current-normal-full20-v32-loopback-v1/result.json`。
- 历史私有桌面初始化根因回执已找到并核对其中 27 个声明文件哈希；只证明旧原生夹具的 private/default 桌面 `NtGdiInit` 差异，不绑定当前 Release，也未确定当前失败 DLL。见 `.probe/goal-remaining-review-20261119-c8a4e3/REMAINING_REVIEW.json`。

## 2026-11-19 原始帧分类独立复核

- 只读独立审计对原始 JSON 的 1172 帧、20 个窗口逐帧重算；raw FrameTiming 与接收回执逐行一致，20 个窗口帧号与原边界一致，`vsync + build + buildFinishToRasterStart + raster = totalSpan` 对每帧精确成立。回执与重算脚本在 `.probe/perf-frame-audit-20261119-d81ef6c9/`；审计 JSON SHA256 `3FC6E349FF72FB09AB9EAE8967851749BE0D47296B812420F214CA707183A565`。
- 14 个 totalSpan 超限帧分布为启动 8、导航 3、窗口外 3。启动 raster 的五个超限帧中，帧 5、6 最大（198.968/346.368 ms），当时首页快照尚无已挂载源海报卡；帧 17 的 raster 仅 4.092 ms，但紧随帧 6 大 raster 队列后有 329.396 ms 等待，不能计作第二次独立慢绘制。旧的单独 traced run 曾观察到 shader/driver link 冷启动成本；本次 untraced 帧没有事件级归因，因此这仍是解释线索而非当前逐帧因果证明。

## 2026-11-19 V40 最新工作树全帧续验

- 在 V39 后仅新增海报配置身份复用改动的产品源码，使用固定 Profile engine、相同 task entry 和原 20 场景；V40 source→kernel→AOT→59 文件运行时逐层绑定通过。相对 V39 产品编译输入仅 `lib/ui/widgets/poster_card.dart` 不同；不得由一次跨运行结果推断该改动造成性能变化。
- 20 场景全部完成（15 导航、1 滚动准备、4 设置滚动），1136 个原始帧全保留；运行时资格通过、进程自然 exit 0、无强制清理，Owned Job 双时钟自然排空均超过 8 秒。独立逐帧审计重算时间戳关系、窗口归属和 59 个运行时文件哈希：`.probe/perf-image-current-20261119-v1/V40_RAW_FRAME_INDEPENDENT_AUDIT_V1.json`；构建链审计：`.probe/pp40/PROFILE_BUILD_AUDIT_V40.json`；运行原件：`.probe/perf-image-current-20261119-v1/circle-current-image-full20-v40/result.json`。
- 严格判据仍为 `rawUs * 60 <= 1,000,000`。1136 帧中 build/raster/totalSpan 超限 **2/15/34**，最大值 **64,680/591,321/749,764 μs**，p95 **1,018/4,959/9,920 μs**。`performanceAccepted=false`、`allFrameBudgetMet=false`；这次虽完整执行，但性能目标仍未验收。V39 的单次观测为 2/29/66，不据此认定性能变化由产品改动导致，也不通过重复跑挑选有利数值。
- 同一 V40 59 文件运行时又有一条**单独启动、单独收据**的原 20 场景执行：`.probe/perf-allocation-current-20261119-v4/circle-current-allocation-full20-image-v40/result.json`。其 1124 帧、20 窗口均完整，build/raster/totalSpan 超限 **1/6/12**，最大值 **19,120/416,458/549,805 μs**，p95 **717/2,948/5,051 μs**；自然 exit 0、无强制清理、Owned Job 双时钟排空约 8.04 秒。独立原始帧及启动收据复核见 `.probe/perf-allocation-current-20261119-v4/V40_RAW_FRAME_INDEPENDENT_AUDIT_V1.json`。这是另一份样本，不覆盖或替代 1136 帧那次，也不构成因果对照；两次都没有达到全帧严格预算。不要从中挑较好的一份宣称通过。
- 下列帧号和时间均来自 **V32，不是 V40**：帧 65 是 V32 唯一 build 超限（35.998 ms），与首页首次观察到 36 个已挂载卡片、154 条数据、homeLoading=false 同期；首次搜索帧 208 raster 18.919 ms；设置帧 371 的 build/raster 为 6.193/3.636 ms，另有 12.785 ms build→raster 间隔。不能把这些帧号或旧 trace 的具体耗时对号入座到 V40。没有证据支持删除 SnapshotWidget、玻璃、卡片效果或启动帧。
- 下一步仅做独立帧号绑定的启动 trace/建树分析：保留默认 renderer、代理网络 cohort、原始内容与全部 20 场景；分别量 shader/cache/link、首批卡片 build/layout/semantics、首次搜索 SnapshotWidget capture。trace 只用于归因，之后必须重新跑未追踪的全帧原始预算验收。

## 2026-11-19 缓存材料及逐帧归因续验

- 完整目标仍 active，目标状态的 `remainingTokens=null`：没有 token 预算上限。点击 seek 的同包验收继续有效；以下诊断没有改变交付包。
- V6 在当前 Profile 引擎的真实生产路径捕获 **39 个不同 key 的 GLPB 材料及 39 个实际 saved return**，原始 20 场景完成、967 帧保留，原 Quit 自然 exit 0，无强制清理。独立复核 952 项检查及 182 个输入哈希通过；payload 总长 518184 字节，与 binary slice 总长区分。回执：`.probe/glpb-current-20261119-root-v6/circle-current-glpb-console-resize-v6/result.json` 及 `.probe/perf-frame-audit-20261119-d81ef6c9/GLPB_V6_INDEPENDENT_MATERIAL_REVIEW_V1.json`。
- 原 `mappingRegistryCompleteWithinTwoSlotPlan=false` 保留：唯一缺失 entry-arm witness 的线程创建于原始 20 场景结束后的退役事件，登记先后顺序已定位并有九项纯模拟后继检查。39 对已观察材料有效不等于全部调用覆盖；尚未接入实际缓存消费，没有 driver 通用兼容、画面等价或性能通过结论。V4 的 `abort.cpp:77` 仅定位到退出落点，触发原因仍未知，各失败记录保留。
- V34 使用仅允许两项 trace flag 的独立测试入口，产品代码及原始 20 场景保持；完成 1103 条原始帧记录、90 个 trace chunk，自然 exit 0，无强制清理。它有追踪开销，**不能替代 V32 未追踪性能验收**。两种保留重复次数的解析算法通过 5851 项交叉检查；全部帧按 `Rasterizer::DoDraw.args.frame_number` 唯一绑定，全部关键 B/E 配对完整。报告：`.probe/perf-frame-audit-20261119-d81ef6c9/V34_INDEPENDENT_REPORT_CROSSCHECK_V1.json`。
- V34 frame 4 的 raw raster 为 465049 μs，其中 shader 区间并集 457369 μs、其内 driver link 并集 424233 μs；frame 43 的 raw build 为 27594 μs，LAYOUT 并集 27052 μs、其内 BUILD 并集 18293 μs。嵌套范围不能相加，也不能把诊断耗时移用于 V32。首次搜索 frame 136 的 shader 并集为 16631 μs，两次较早的 MakeGpuImage 仅为 1133/329 μs，不支持据此删除 SnapshotWidget。
- 根目录初版 `FRAME_CAUSES_ROOT_V34.json` 的全局集合去重误删同 tick 合法重复事件，产生错误嵌套；该文件保留为失败分析，不采用其中的耗时。后继解析保留每个 chunk 内真实重复次数，独立按进程/线程配对和求交，仅余 trace 外缘的三个初始化 E 和一个末尾 B。下一步用独立测试入口的逐控件 build/layout scopes 定位具体布局工作；正式原始帧预算保持不变。

## 2026-11-19 控件分配优化及后继测量

- V36 仅测试入口启用逐控件 build/layout scopes，原始 20 场景完成，1081 帧、94 个 trace chunk 保留，原 Quit 自然 exit 0、无强制清理。两个独立解析结果另经 1316 项交叉检查一致。frame 41 的 build 为 29643 μs，其中 RenderParagraph exclusive 6556 μs、Image exclusive 5110 μs、Scavenge exclusive 1870 μs；HomePage 自身仅 34 μs。exclusive 只表示减去已记录直接子范围，不等于纯 CPU。诊断有开销，不能当作正式性能通过。交叉回执：`.probe/perf-product-candidate-20261119-root-v1/V36_TWO_ALGORITHM_CROSSCHECK_V1.json`。
- 产品新增两项分配优化：MiuixPressable 保持遮罩控制器，其余下沉/倾斜控制器按需创建并保留，普通按钮由 4 个控制器降为 1 个；封面 provider 将固定 URL 的请求头解析及 hash 复用，精确 URL、查询参数区分和 transport 规则保持。按压相关 57 项及最终 6 项专项测试通过；23 对优化前后 PNG 完全一致。该结论限控件范围，不表示完整应用性能通过。回执：`.probe/pressable-lazy-20261119-root-v1/PRESSABLE_LAZY_ALLOCATION_SCOPED_VERIFICATION_V1.json`。
- 条件 InkWell 包装层候选因 callback nullness 变化可能替换活态控件而撤回；原包装层保留。新增 input/header 四项测试通过。测试首次漏导入及第二次导入位置错误均保留日志；扩展封面测试的两个既有 HEAD blob 行尾断言失败也保留，未改门槛或称整组通过。
- V38 新鲜 819 输入、两阶段 Profile 编译通过，59 文件运行时中相较 V32 仅 app.so 不同。实际测量在首个导航前被原 signature 守卫拦下：等待 timing 回执时 settledVisible 20→19、dirtyAncestors 2→1；0 窗口、37 帧仍保留，原 Quit exit 0，无强制清理，双时钟空 Job 超过 8 秒。此轮 **runtimeQualified=false、性能未验收**，不能用局部帧对比宣称优化。回执：`.probe/perf-allocation-current-20261119-v1/circle-current-allocation-full20-v38/result.json`。
- V39 仅修测试入口的上述时序：记录并有界重观测变化快照，额外要求全部可见卡片提交、卡片 dirty 路径计数为零，再保留原 signature 一致检查。原 20 动作/700 ms 窗口、预算、启动及窗口外原始帧完全保留；不清缓冲、不预热、不删除失败。实际已完成 **20 窗口、1009 帧**，运行资格通过、自然 exit 0、无强制清理、双时钟空 Job 均超过 8 秒；严格预算仍失败：build/raster/totalSpan 超限 **2/29/66**，最大 **52898/744768/1053517 μs**，p95 **1476/9235/23429 μs**。19 条启动帧、239 条窗口外帧、585 条导航帧、42 条滚动准备帧、124 条设置滚动帧全部纳入。实际开始前一次即满足检查，未执行 retry；循环入口的 90 秒限制不保证包含每次最多 30 秒 drain 的严格总墙钟 90 秒。完整最后快照未保存，只有最后 signature 相同的布尔记录，故不可声称可独立重算该最后快照。回执：`.probe/perf-allocation-current-20261119-v2/circle-current-allocation-full20-v39/result.json`；逐帧及独立复核：`.probe/perf-product-candidate-20261119-root-v1/V39_UNTRACED_ALL_RAW_FRAME_AUDIT_V1.json`、`.probe/perf-frame-audit-20261119-d81ef6c9/V39_INDEPENDENT_RAW_FRAMES_AND_COLLECTOR_DELTA_V1.json`。单次跨运行差异不能确定两项优化的性能因果；不反复运行同候选以挑选好成绩。
- GLPB consumer 离线 ABI 研究修正了旧三槽假设：当前匹配 DLL/PDB 的 native vtable 实为析构、load、带 description 的 base store、derived store 共四槽。v4 静态读取通过，旧失败保留；没有加载引擎调用 GL、没有安装缓存、没有 consumer hit 或完整 context fingerprint 资格。资料：`.probe/glpb-consumer-followup-20261119-root-v1/owned-offline-cache-consumer-context-abi-once-v4/GLPB_CACHE_CONSUMER_CONTEXT_TYPED_STATIC_DISCOVERY_V4.json`。
- GLPB 独立 C++ payload 校验器已用 MSVC `/W4 /WX` 编译实测，接受 39 个真实 key 条目（37 份不同完整 payload）并拒绝 702 个畸形变体；输入哈希不变。`overlay-v3` 仅把该校验器接入候选 cache load，仍待完整引擎编译、有界 manifest 注册与真实 context 指纹；不构成实际缓存命中或性能通过。资料：`.probe/glpb-consumer-followup-20261119-root-v1/payload-validator-test-v1/result.json`、`GLPB_ENGINE_PAYLOAD_VALIDATOR_OVERLAY_V3.patch`。
- 海报 Image 配置复用候选现已按输入哈希采用：精确 URL/revision/宽度/DPR 未变时保留同一 Image，流事件及 Image 自身继承依赖照常更新。实际前后源码隔离组件验证 13 项通过，旧源码专项 identity 断言按预期失败；22 对 PNG 和布局/文案/透明度/语义快照完全一致。此处不声明首次挂载、首次解码或应用帧预算改善。root 补验首次误传不存在的测试文件名；随后扩展六文件结果为 34 通过、4 失败，正在分别做旧源码归因和本次 helper 提取后的静态接线检查，未声称整组通过。证据：`.probe/next-widget-perf-candidate-20261119-v1/POSTER_IMAGE_IDENTITY_COMPONENT_QUALIFICATION_V4.json`、`root-adopted-test-v1.log`、`root-adopted-test-v2.log`。原已验 Release/ZIP 不自动取得这些新增源码的资格。
- 独立引擎树 `隔离的固定版本 Flutter 引擎树` 已锁定 SDK 的 `af7e796e161ae0bb1ff0758c71a7105418bd9ded`，DEPS 浅同步实际 exit 0；原 SDK 未改。构建准备使用本机 VS2026、已安装 SDK 10.0.26100.0（仅隔离树构建脚本显式替换缺失的 22621）、git.bat 到既有 git.exe 的私有别名和进程级 UTF-8/代理环境。GN 生成 1211 target 成功，基础 Profile `windows` 和 `gen_snapshot` 已编译，`ninja-profile-base-result-v2.json` 记录 exit 0；基础引擎不含完整缓存候选。下载直连、Python 路径、VS 识别、可选 Git hook、缺失 SDK 与 GBK 失败均保留。证据目录：`.probe/engine-build-pinned-20261119-v1/`。
- 海报扩展失败已做精确旧源码对照：两份旧套件在改前、改后均为 **21 通过、3 失败**（无 callback 的 InkWell、已有 releaseStatus 构造参数、FollowPage 占位静态条件）。第 4 项为本次 helper 提取引起的旧排版断言；已仅更新 D2，检查真实 build→helper→coverImage 和布局宽高/fit，移除高度或调用的两个负例均失败。采用后的四文件真实图片测试 **14 项全部通过**。回执：`.probe/next-widget-perf-candidate-20261119-v1/REGRESSION_HANDOFF.md`、`regression-followup-v1/`、`root-adopted-test-v3.log`。旧失败未删除、未放宽原始预算，最终整包及全应用性能仍待新运行。

## 2026-11-19 Top 20 空封面身份续审

- 对既有隔离投影做了只读复核：候选走 cloud detail 分支；aggregate 中的 child 明确禁用且选择数为 0。该精确身份在 progress/history 各有一行，但都没有非空封面 donor；投影数据库前后 SHA256 相同。真实数据库未打开或修改，也未发网络请求、启动应用或读取凭据。回执：`.probe/remaining-cover-20261118-top20-v1/TOP20_EXISTING_PROJECTION_EXACT_BRANCH_20261119_V2.json`。
- 静态源码审计确认 search/detail/cloud 分支不会在该路径补出 poster，修复 API 仅按精确 provider/native ID 找 donor；对无 donor 来源的网络查询要求来源及 originating child 已启用。当前没有建立此候选与 recommendation/share poster 的精确身份映射。回执：`.probe/remaining-cover-20261118-top20-v1/COVER_ENDPOINT_STATIC_AUDIT_20261119_V1.json`。
- 结论仍是 **Top 20 空封面未解决**。不因标题相似猜图，不启用禁用 child，也不改写真实库。继续条件是先取得可复核的精确 share/response identity mapping，再在隔离投影验证实际图片解码和非封面字段不变；否则保持未验收。

## 2026-11-19 固定引擎构建状态

- 基础 Profile 引擎的 `windows` 与 `gen_snapshot` 目标已编译完成，`exitCode=0`，没有 GLPB 补丁；回执：`.probe/engine-build-pinned-20261119-v1/ninja-profile-base-result-v2.json`。这更新了上文的“正在编译”，并不证明 GLPB 候选已链接或可运行。
- GLPB 专用输出的首次生成尝试因 depot_tools 缺少 `python3_bin_reldir.txt` 退出，失败回执保留。随后直接使用固定源码下的 `gn.exe`，并在隔离工具链中设置本机 runtime 路径，生成 1211 targets / 394 GN files，exit 0；回执：`.probe/engine-build-pinned-20261119-v1/gn-glpb-profile-result-v2.json`。首次完整 Ninja 在 Windows TU 缺少生成的 identity header 时自然 exit 1；仅修正一行 include 后，增量 Ninja 的 `windows gen_snapshot` 完整编译及最终链接已自然 exit 0，见 `ninja-glpb-windows-result-v2.json`。DLL SHA256 为 `4EA8A9BF39DA7CE7A34583F99897E715B2C26A8B1CDDF8926295E1B959EC4D0D`。当前 identity 仍为 compile-only，不能证明闭包资格、同 DLL capture/consume、缓存命中、画面等价或严格性能通过。

## 2026-11-19 无预算上限及同运行归因准备

- 主任务再次实际查询为 `active`、`remainingTokens=null`，没有 token 预算上限；没有重复建立目标或标记完整目标完成。
- V41 的 814 个当前产品输入逐一与 V40 冻结输入相同，连同 5 个任务入口/原生 provenance 文件共 819 项。只对任务入口增加逐控件 build/layout scopes 和精确的两项引擎 trace flags；反向去掉这两块改动后，入口与 V40 原文相同。原 20 场景、700 ms 窗口、原始帧保留及默认 renderer 要求未变。实际 Profile kernel/AOT 两阶段均自然 exit 0、无强制清理、双时钟 Job 排空均超过 8 秒；3485 个实际 kernel 输入含正确 task entry，59 文件运行时相对 V40 仅 `data/app.so` 改变。静态读回：`.probe/pp41/ROOT_STATIC_BUILD_AUDIT_V41.json`（SHA256 `A84631D1AD864A93A82200BA662A425AAC1A91DE257188DBE67047DD9B5127E3`）。
- V41 随后在已观察无竞争工程重任务的 quiet 窗口实际完成原 20 场景，1031 条原始 FrameTiming、90 个 trace chunk 全保留。原 ask/Quit 自然 exit 0，无强制清理，双时钟 Job 排空约 8.02 秒；`runtimeQualified=true`、`diagnosticOnly=true`、`performanceAccepted=false`。root 逐帧重算时间戳等式、完整 timing receipt、窗口归属、全部 chunk 哈希及 59 文件通过，见 `.probe/perf-layout-trace-current-20261119-v41/ROOT_RAW_TIMING_AUDIT_V41.json`（SHA256 `34524F36FAC55A6B003D6816674A21E59159C272E8849B8DFE2216761C1D9AD1`）。带追踪开销的 build/raster/totalSpan 超限为 **6/21/50**，最大 **106530/881912/1118074 μs**；不是正式性能验收，也不能把其时间移用于 V40。下一步在该次运行内按真实 frame_number 绑定 scopes，区分 driver link、build/layout 和排队等待。
- 同运行 scopes 已完成真实 frame_number 唯一绑定：1031/1031 帧、50 个任一指标超限帧均覆盖。root raster parser、独立 widget parser 与原始 timing 的 5192 项交叉检查通过，含 653 项共同 named-scope 区间并集核对；见 `V41_TRACE_AND_RAW_CROSSCHECK_V1.json`（SHA256 `6622BA7B3D17B260338447F7C9E4540F31D4F8FDA4C6AB53B5456B7393336C53`）。frame 3 的 raster 为 881912 μs，shader union 为 867856 μs，其中 driver link union 为 792494 μs；这是嵌套区间，不能相加。frame 64 的 build 为 106530 μs，RenderParagraph exclusive 为 44371 μs、Image 为 12450 μs、Scavenge 为 7044 μs；exclusive 只扣除已记录直接子范围，不等于纯 CPU。该诊断支持继续接入真实缓存并评估首屏屏外建树工作量，不支持删除可见文字、效果、焦点或语义，也不证明 V40 的同号帧有相同原因。
- 本轮组件补验实际执行 11 项通过；原生点击补验有一次 `did not complete` 失败，后继单文件运行通过，观测 `position=22.576`、`commits=1`、`advancedMs=345`。前一次失败不被后一次覆盖，也没有足够证据把本次异常直接归因为既知 libmpv 崩溃。完整原目标仍未验收。

## 2026-11-19 完整缓存候选独审及任务接线准备

- capture 与 driver-result observer 已合成固定的 17 文件后继候选，补丁 SHA256 为 `8DC7D453AF1E51A64721F84B4BC0F5810B658F8C5BC60A97C102F4F25202BD96`。root 独立核对全部源文件的当前引擎基线/候选哈希、交接文件和 22 份编译/测试日志，并再次执行只读 `git apply --check`，全部匹配。七个真实 pinned-header 编译单元及两个实际 GN flags 的 syntax-only 单元通过；375 项真实 Windows IO/原 decoder 测试与 52 项合成 context 关联测试通过。后者的 accepted/fallback 是夹具输入，不是真实驱动结果。独审回执：`.probe/glpb-runtime-harness-20261119-v1/ROOT_CAPTURE_OBSERVATION_COMPILE_ONLY_REVIEW_V1.json`（SHA256 `71186D6011722463FD17EC03A0E674B63196AB3E774FAB85E00CAC12742AA34E`）。
- 该独审只批准隔离引擎的 compile-only 整合和实际构建，**未批准闭包置 true 或 GUI/capture/consume 运行**。原 false identity 的字节需保持；后续最终源码必须重新收集输入，并完成非循环身份及重链前后不变性核对。旧 39 份材料不能换标签充当新 DLL 的缓存命中。
- root 新增纯任务 C ABI 桥，显式区分 off/capture/consume；默认关闭、不读环境/用户数据/凭据、不自行启动或结束引擎。消费模式同时要求 observer 配置成功，任何配置失败都要求调用方禁止 Run；Finish 最多调用一次，失败不重试到绿，原始 stats 可读性单独记录。真实候选公共头下 `/W4 /WX` 编译及 **104 项 fake-engine-API 检查**通过：`.probe/glpb-runtime-harness-20261119-v1/fixture-v2/result.json`。在私有副本移除一次性 Finish 守卫，原夹具在第 18 项按预期失败；原桥文件哈希不变，见 `rollback-negative-v1/result.json`。v1 因测试器 stdout 编码异常在编译后停止，失败回执保留。此桥尚待接入任务 runner，不是实际引擎运行或产品性能通过。
- 随后实际执行了一次隔离整合：17 文件应用后字节匹配，identity/header 与 args 字节保持；GN regenerate 自然 exit 0。`2026-11-19 19:51:15 +08:00` 已启动 `windows gen_snapshot` 的 `-j6` Ninja 构建，root 读回日志及 PID 确认其正在运行。记录目录：`.probe/engine-build-pinned-20261119-v1/integration-full-v3-v1/`。这一时点尚无本次最终链接成功回执，不能沿用旧 DLL 的成功资格。

## 2026-11-19 完整缓存引擎链接及首页缓存实验结果

- 同一个 Ninja PID 64140 执行到 599/599，`2026-11-19 19:58:48 +08:00` 自然 exit 0。新 DLL SHA256 `AF08976298D79888C7BBD55C66B6ED7238A9D3BDB9A0606FA4F751C12C1CC652`；gen_snapshot 字节不变。静态导出表确认 6 个 GLPB API 和任务桥所需 3 个既有 API 各存在一次。回执：`.probe/engine-build-pinned-20261119-v1/integration-full-v3-v1/build-result.json`、`coff-export-review.json`。这次仍是 `kClosureQualified=false`，不是实际缓存运行。
- 对这次链接的 **最终源码** 重新取证并独立复核：逐字节重验 32,901 项材料（含 1 项边界定义），检查 4,944 个实际命令及 VALID 动态依赖块、39 个目录的成员集合、真实 Ninja 图及生成工具依赖；fresh `ninja -n` 无任务。生成身份头只有一个直接消费者，未发现其派生输出回到材料集合。该边界是明确列出的源码、配置和工具，不声称 Windows 宿主完全可复现。回执：`.probe/glpb-runtime-harness-20261119-v1/ROOT_FULL_V3_FINITE_CLOSURE_REVIEW_V1.json`（SHA256 `7E3250F65137CEE3F70FD7B4E2F883E7E4326B993F755F78B063E006C671A6F5`）。仍需仅换身份头的一次重链及前后不变性证明；随后才允许用同一 DLL 和同一 AOT 实测。
- 首页组件实验确认宽屏首屏真实挂载 36 张海报，20 张可见。横向缓存降到 0 会让方向键卡住或跳错行；降到 168 虽将挂载降到 33 且静止画面一致，同样拖动首次露出的卡片却失去了图片预热，实际显示占位图，旧版已解码。只缩纵向缓存没有减少该宽屏场景的挂载。四种候选均未合入；保留旧焦点、语义和提前显示封面的行为。证据：`.probe/home-cache-extent-20261119-v1/HOME_CACHE_EXTENT_BOUNDARY_EXPERIMENT_V1.json`（SHA256 `2C2D25F16A3D8CEAF58F00B1E6FD1027D2F9A751077397A931A68A9C527388C4`）。组件实验不算应用级性能验收。

## 2026-11-19 输入别名失败及恢复审计

- 第一次一次性身份尝试在**安装前的临时生成阶段**失败：实际 Python 3.8 strict `Path.resolve()` 折叠了保守工具目录里的重复符号链接输入；生成器以重复路径断言拒绝。原始失败及所有备份留在 `.probe/engine-build-pinned-20261119-v1/qualification-full-v3-v1/execution/`；没有写入/覆盖产品身份头，没有启动 Ninja relink 或 GUI。False header SHA 仍为 `D51EB2D3D10BE86FBB9EDCC5D8AA9A319B6F73D76B650C4EB2F05D7CAF38389A`。
- 对 32,901 个原词法输入做只读 strict-target 核对：32806 个实际路径目标、57 组相对 symlink、95 条别名映射，均在已审边界内并逐组核对真实字节/同文件身份；39 个词法目录成员清单没有改变。恢复候选将实体输入各列一次，并把原词法名、链接目标与文件字节关系单独绑定，保留 `qualified_by_release_pipeline=false`。root 独立报告：`.probe/glpb-runtime-harness-20261119-v1/ROOT_STRICT_ALIAS_CANDIDATE_REVIEW_V1.json`（SHA256 `1689ADE74C35D219656D4F6A72306CC9955111F1CC4B02642ED70D0F6F078B0E`）。使用实际固定 Python 3.8 生成器、只在 `.probe` 新目录生成 compile-only false 头，exit 0；当前引擎头没有变。**这只验证去重输入可被生成器读取，不是 true 身份或资格验收。**
- 还须为此恢复候选做全新的逐字节 preflight 和新执行授权；不能重用之前的执行 claim。只有 preflight 与新授权匹配后，才进行一次隔离单对象重链及前后闭包比较。
- root 增加离线捕获物料检查器，在已有 2 条合成缓存材料上执行正例和 **17 个负对照**（wrong DLL/AOT/nonce、未完成 capture、冲突/上限、损坏 key/blob、重复字段、硬链接、回执计数假阳性等），全部按预期通过；真实 Windows 文件 IO sink fixture 原结果也只证明合成上下文。检查器刻意输出 `runtimeWitness=false`。回执：`.probe/glpb-runtime-harness-20261119-v1/material-check-fixture-v1/result.json`。这不是实际 GL 缓存采集/驱动接受。
- 历史最小化事件只读复核 54/54 项通过，确认相关运行的主窗口确实最小化，但没有公共时钟/调用栈/焦点目标把 native 消息与具体 Dart/键盘/辅助功能调用唯一连接。现有标题栏焦点路径只是可能，不算归因；不重跑过去已结束的失败运行。报告：`.probe/minimize-attribution-static-20261119/result.md`。
- A11 准备工具离线复核了当前点击修复 ZIP 的 59 文件及启动链哈希，并证实历史 USER32 Loader Snaps 属于另一 EXE。当前会话没有可用的已授权隔离交互桌面；因此没有再次启动应用、抢焦点或切桌面。普通启动和退出仍未验收。证据：`.probe/a11-interactive-acceptance-20261119-v1/A11_EVIDENCE_PREPARATION_RECEIPT_V1.json`。
- native-click 早期 `did not complete` 原始失败仍保留；后续日志有完整媒体位置、单次 commit 和播放推进，并通过补齐异步播放器 FakeAsync 清理后完整通过，且在当前测试源码之后还有两份完整 native 通过运行。只读核查不足以定位最早超时在播放器初始化/seek/cleanup 的哪一步；已有当前版本阳性复测，无需为猜测性归因重复运行。不要抹去首次失败。当前失败/通过证据分别位于 `.probe/seek-click-current-20261119/root-native-v1/`、`native-click-final-v1/`、`root-final-v5/` 和 `continuation-v6/`。


## 2026-11-19 GLPB 有限身份单次重链续验

- 已从别名失败后的新恢复执行器推进，不重跑 seek、旧组件或原性能失败候选。新主入口限制现代 Python，pinned 3.8.10 仅供生成器及保存物理 ID 的同 ABI 核对；先前 helper 从未冻结摘要选择 EXE 的缺口由真实调用 AST 负对照复现，修正为 frozen plan 参数。旧预检阳性、失败独审和撤回脚本保留，不算当前执行资格。
- 修正后的新鲜只读 preflight 自然 exit 0、无强制清理，43.929 秒；32,901 项原词法输入共 5,566,614,544 字节、39 目录、57 组/152 物理成员/95 redirects/32,807 生成器角色均通过。输出树 7,259 文件、SDK Windows 112 文件快照与原基线相同，随后才签新的 exact approval。
- 单次 execute host 自然 exit 0、无强制清理，112.848 秒。Ninja PID 64704 自然 exit 0，只编译 identity object 并链接 DLL；133 export names 不变，6 GLPB API 各存在一次，import lib 与 gen_snapshot 字节不变。前后材料、路径角色、命令及全部别名核对保持，输出只有 header/object、DLL/PDB 和 Ninja log/deps 六条白名单内容变化，共享 SDK Windows 守卫快照不变。
- 当前隔离 header 为 `kClosureQualified=true`，有限闭包 SHA256 `F31E4336CF3D1E4BD7FBE33A72A796E311A1EF7EBCDD922728D9B682863C6191`；新 DLL 21,839,360 字节，SHA256 `3AADD9C685363CFBCF94AC5AE41333A920E86DB82B77A677D261E3D733EF60C3`。canonical sidecar 为 32,810 条（32,807 材料 + 3 provenance），生成身份及最终 DLL 不回流输入。主智能体重读 15 项当前产品/回执哈希与前后小快照；这不是重新哈希 5 GB 源码，也不声称完整宿主 hermeticity。
- 回执在统一任务产物 `sourin-glpb-recovery-20261119-round2/lead/qualification-resolved-v2/` 的 `preflight-v1.json`、`execute-host-v1/result.json`、`execution/result.json`、`ROOT_STATIC_IDENTITY_RELINK_RESULT_REVIEW_V1.json`。设计与重开条件见 [有限闭包身份笔记](.agents/notes/implemented/testing/2026-11-19-glpb-finite-closure-identity.md)。
- **本阶段仅静态身份与构建通过**：没有 GUI、真实 GL、缓存采集/消费、驱动命中、视觉等价或原始性能预算通过；build host 自然 wait 也不是应用双时钟空 Job 八秒验收。下一步只接续同 DLL+同 AOT 的私有 artifact/runtime 绑定，不重做这一已完成静态步骤。原 18+12 仍 active，普通启动/真实账户/Top20/旧最小化归因及最终新产品包边界不变。


## 2026-11-20 同 DLL 同 AOT 原生接线静态续验

- 新任务副本冻结当前 819 源输入与 8,939 外部/产品绑定；相对冻结 V40 仅当前 poster helper 字节与 task MethodChannel 入口改变。实际 kernel census 3,485 项含正确入口，20 动作/700 ms/raw timing/结果及 _run 四段保持原字节。kernel PID 56732 与 custom gen_snapshot PID 79544 均自然 exit 0、无强制清理，双时钟空 Job 各超过八秒。共用 AOT 为 17,138,568 字节、SHA256 `8E68C74124B34C78997E7A999A23963E9F9036EAB329CB589F966F993190331A`。首个 authority 路径格式拒绝发生在 claim/编译前，原失败保留，规范路径的新授权才执行第一次实际编译。
- 实际 private wrapper 在任何 Run 前配置，FlutterWindow channel 与模式 config 已编译接线；九个 compile + 两 link 共 11 阶段自然 exit 0，最低双时钟空 Job 8.0012/8.0022 秒。实际 showIncludes union 467 个头的来源/hash已读回，custom public 与 mode config 正确；两 EXE 实际导入六个 GLPB API。此处不是只读源码声明，也没有运行 EXE。
- 首次 native 静态成功仍复用了旧 main.obj，而新增 FlutterWindow 成员影响 main 栈对象类布局；未运行该 EXE，独审将其 runtime/layout 资格明确置 false。最小后继只重编 main.cpp 并重链两模式，三阶段自然 exit 0、双时钟空 Job 均超过八秒；实际 main 消费当前 header，已通过九个对象及其它支持对象/资源按原谱系 hash 复用。
- 最终 off EXE SHA256 `B687800CFD47073F0671090A7A068B70CE9A4480EA9B9DF8A75FB9E4832CD722`，capture EXE `119DEB34C18F3E5EF39E53B1B960CDFCE3AB317F1D6E1AC8F74FFEBE3B416D97`。两份静态包各 59 文件、只 EXE 不同，共用上述 AOT 和已验有限身份 DLL `3AADD9C685363CFBCF94AC5AE41333A920E86DB82B77A677D261E3D733EF60C3`。mode 必须以 taskGlpbBuild 读，不以 variant 标签猜测；off manifest 的历史 variant 含 capture 字样但 mode=off，保留该标签局限。
- 回执位于统一任务产物 `sourin-glpb-runtime-20261119-round3/`：`aot/ROOT_GLPB_SAME_AOT_STATIC_BUILD_REVIEW_V1.json`、`native-direct/layout-successor-v2/result.json`、`bundles/STATIC_SAME_AOT_ENGINE_BUNDLE_BINDING_V1.json`；独立 source/result 审查保留于 `review/`，最终 layout/bundle V4 为 14 项有限核对。范围/取舍/重开条件见 [任务 native/AOT 笔记](.agents/notes/implemented/testing/2026-11-20-glpb-task-native-aot-binding.md)。
- **只完成静态接线与包身份**：`launchAdmitted=false`、`actualRuntimeQualified=false`；没有 GUI、真实 GL、采集/消费或驱动命中，consumer 仍等待实际 capture manifest。不能把构建自然退出、PE imports、静态同包或旧组件阳性当性能/完整目标通过。下一步骤是无调试器 collector 的精确输入/native receipt/模块/隔离与无焦点启动准入，不重新编译共用 AOT 或重做静态身份。


## 2026-11-20 同身份真实 capture/consumer 与九次驱动接受

- 没有重做已完成seek、静态身份或同AOT构建。新无调试器collector沿用原20动作/700ms/全部原缓冲/整数预算，绑定实际新包、native build ID、隔离profile与原匿名loopback路由；一次quiet authority分别限定capture和consumer。未注入系统鼠标键盘、激活窗口或切桌面，未读取凭据/真实库，也无远端写入。
- **capture局部运行成立**：PID39116完成20窗口，自然exit0/noForce/无cleanupError，owned窗口准确消失，双时钟空Job8.0267459/8.0283209秒。18个加载包映像与运行包相符，preRun capture及Finish回执绑定。40 observed/stores_returned、31 context_rejected、9 entries，无conflict/IO/limit/payload错误。真实manifest SHA256 `EB0948683DB2F8569368D41EC045C7D97FB3D3DC4C415D74B51CF68881498DE4`，9key/9payload共92,168字节；原decoder重开和离线bounded指纹/key/payload检查通过。它绑定同DLL `3AADD9C6…EF60C3`、AOT `8E68C741…0331A`、闭包 `F31E4336…C6191`、实际ANGLE/AMD780M/driver32.0.32015.2008/format37798及interface/caps，不是旧39条材料换标签。
- **capture不代表原内容视觉或性能通过**：工作负载快照1355帧/201receipts，build/raster/totalSpan超1/8/14。Quit回执1362，多出的7帧只有计数，不能宣称直到exit全raw。主智能体亲眼Home-ready图中可见封面全占位，虽然快照20settled；实际predicate只看opacity/dirty/clip，原limits也明确不看decoded pixels。这是content/readiness证据上限，不删运行或把它算原Home视觉等价通过。
- **consumer实际九次驱动接受成立**：真实manifest到consumer config仅新Runtime编译+link，两build阶段自然0/双空8秒；consumerEXE SHA `0199A954A98BF705BCA804ACBCAF48A00DC0002115322EF4CFAFC4A983361AEE`。69文件=59base换EXE+rawmanifest/9payload，同DLL/AOT保持，十个材料后读hash不变。PID69984完成原20窗口，自然exit0/noForce，双时钟空Job8.0388406/8.0402817秒，18加载包映像相符。observer nonce `823401215664289`，load40/package_returns9/binary_results9/matched_results9/driver_accepted9/driver_fallback0/rejected31/reentrant_rejected0。联合离线真实材料+observer回执校验通过，不以package return或fake结果代替driver accepted。局部9次不外推其余31次拒绝或全shader/context覆盖。
- consumer workload快照1167帧/178批（预算1/7/11）；Quit前全缓冲1174帧/179批精确append，timestamp/receipt均一致，Quit计数同1174。全部preQuit严格预算为 **1/7/12**，max **20123/463730/670874 μs**、p95 **739/2800/4915 μs**，仍失败；不声称Quit→exit全raw。主智能体亲眼consumerHome部分真实封面与部分占位，与capture状态不同，不能直接跨运行推断缓存性能因果或视觉等价；最终Settings图同字节仅限该截面。
- 原始回执集中于 `sourin-glpb-capture-20261120-round4/`：两个circle结果、PNG、native-quit-receipt、actual capture/consumer材料检查logs、consumer/ROOT_ACTUAL_CONSUMER_DRIVER_AND_PREQUIT_RAW_REVIEW_V1.json。独审capture V4、consumer V3及1174帧V4增补在review内；没有重复5GB/8939输入/旧组件测试。失败准备锚点、重复timing字段修正、消费者父任务module-census首拒绝、authority/raw负对照均保留，后继不覆盖。
- 决定/取舍/重开条件见 [局部capture-driver witness笔记](.agents/notes/implemented/testing/2026-11-20-glpb-scoped-capture-driver-witness.md)。本阶段只完成同身份局部采集→材料→只读消费→真实driver接受的闭环；**严格性能、完整内容/视觉等价、未覆盖上下文和最终产品整包仍未验收**。原18+12保持active，A8真实账户外链、A11普通启动、Top20精确封面及历史最小化归因边界不变；不重跑已完成capture/consumer以挑好成绩。


## 2026-11-20 就绪反例与上下文指纹诊断

- 未重跑已完成seek、旧capture/consumer或正式未改候选。新增task-only decode observer读真实PosterCard下RawImage/RenderImage及paint路径，字段独立于旧content/signature/等待/预算。隔离单个回环case两臂实际执行：旧实际geometryhelper在heldPNG时第172行Expected false/Actual true、exit1；新observer真实exit0、1/1，覆盖held未解码、503失败占位、放行后同元素32×48解码、零opacity/全clip仍保留图但不计可见。原读取侧intendedLegacyFailure=false前缀匹配误判由103项只读继任核查纠正，不改原receipt，不重test。四次bootstrap失败不是行为红；多份私有SDK/包复制约2.22GB可再生中间但无删除授权未清。组件范围见 [解码观察笔记](.agents/notes/implemented/testing/2026-11-20-poster-decode-observation.md)，未集成AOT/GUI，不能追认旧Home像素。
- 静态源码确认cache reader只准render_context绑定/roleRender，仍不能由31聚合contextRejected推定31全resource。首个新增私有reject-only诊断独立生成身份/一个对象/一个DLLlink，原qualifiedsource/out/SDK保持。实际运行自然exit0/noForce双空8秒，39loads/39reject/0return，与新DLL/旧包fingerprint不同的safeMiss相容；但FILE*日志实际零reason标签、无启用正证，**原因目标失败**，原回执及V13拒绝审查保留，不重复未变样本。
- 后继只有新的原因观测输入：directSTD_ERROR_HANDLE WriteFile、明确identity-enabled/bound-reader-enter正证、successful actualcaps digest及readquery/stencil计数；原guard/HashBytes输入不变，explicitTASKnonce，最多512条。真实helper fixture验证off0/on512和trace内部LastError保持，不作为GL原因证据。新私有DLL `5A28921C96BE8826A80EFBC2CCBCBE03C1C75CDB07DD8D49998D7572E741275E`、闭包 `7AB177EAAF5D7C9AE04DD78CAECA4EB8CC4DCE7B04B45EB1B63DB7D4C1529902`，自然compile/link0；原OUT7259/SDK112和3534复用native输入前后不变，32811材料+3provenance形成独立身份，不拿原qualified标签套用。
- 新正见证单次原20诊断实际自然exit0/noForce，双空8.0352179/8.0362611秒；日志157连续行=identity-enabled1、bound-reader-enter78、caps-snapshot78，均render role1且成功caps同tid20032。三digest按序 `46791330…26CC1`（18次/queried1）、`D028AA27…53C4`（52次/queried2）、`5B3A7716…DC742`（8次/queried3），无null-reject标签。它证明本次同成功renderreader指纹随惰性read-query状态变化，不证明仅这些字段变、不回溯原31每次根因，也不说明所有资源context可用。旧包在新DLL下39load/39reject/0driver接受，不能算cache性能样本。
- 新有限执行器准备曾出现授权前未绑定helper/旧plan选Python、GEN自证字节门和字符串替换语法错误；均在实际身份/引擎执行前被拒绝/修正，原失败审查及日志保留。稳定后继自含earlyrecord绑定已核helperbytes再exec、pinnedPython/GEN执行前hash、acceptedOUT/SDK比较及实际privateidentitypath/hash消费门通过，真实负对照拒绝wronghelper/subEXE/changedGEN；这只是取证工具质量，不等性能通过。
- 原始材料集中 `sourin-glpb-context-20261120-round5/` 的decode/、private-engine-variant-v1/v2、两次reasoncollector结果及ROOT_ACTUAL_FINGERPRINT_POSITIVE_DIAGNOSTIC_V2.json；本轮不改生产控件或sharedSDK，不登录/凭据/真实库写/远端操作/焦点桌面。此诊断推动了下节的 [稳定程序二进制指纹](.agents/notes/implemented/architecture/2026-11-20-stable-program-binary-caps-fingerprint.md)：逐字段确认不影响shader key/GLSL/interface/binary后才建立稳定schema，不能冻结第一次digest或删caps/context/before-after来造命中。严格性能、Home解码/匹配输入与完整18+12仍未验收，旧稳定/seek/九条driver成功各保原范围。


## 2026-11-20 稳定指纹：本机 39 次实际驱动接受

- 固定 Skia 字段消费检查、真实 ANGLE D3D11 无窗夹具前后对照支持窄摘要变更：只隔离惰性 read-query 日志及其可变 ex_read，普通 dump/读回行为与其它 caps/上下文 guard 保持。实际查询及受控 ex_read 清零后专用 dump 同字节，保留 stencil 字段改变时专用 dump 变化；没有重跑旧夹具。
- 任务 DLL `064F25F4CA7C0E7BD32FE92F673AD90B2549A28CF267A31501D988542FCD4F35`、闭包 `654A87063AC7B2B3D3EC7F00162184BD02B7A0FA9B83DF4CA2BDF9C58A6AC1BC`，32,812 材料+3 provenance；复用已验 caps 对象，原 OUT/SDK 未改。新 capture/consume 共用原 AOT `8E68C74124B34C78997E7A999A23963E9F9036EAB329CB589F966F993190331A`；只调整启动器任务常量，未重编 AOT、未覆盖旧包。
- 新捕获 **39/39** observed/stores/entries、0 context/payload/IO/conflict；manifest `A6B4575C1B2D069A2F6F82F6D5F8FB11F707EE722B39C1FBB3EB79CFB20BE764`，38 唯一 payload/506,424 字节。新包新增 30 个描述符，九个旧对应项是原样重新捕获，不是复用旧清单。新 98 文件消费者实际 **39/39 driver accepted、0 reject、0 fallback**；39 个材料文件事后 hash 和只读属性保持。两次均 20 窗口、owned/noActivate、自然 exit 0、无强制清理，双时钟空 Job ≥8 秒。
- **性能仍失败**：捕获 1108→1116 个已保存原始帧、Quit 1121（5 帧仅计数），消费 1112→1120、Quit 1120，均不保证 Quit→exit 逐帧。按原整数预算，已保存 Quit 前分别超 **1/6/16** 和 **1/10/14**；消费者峰值 **18181/193599/368039 μs**，分别位于 build/raster/totalSpan 指标。消费者 14 个 totalSpan 超限分布为启动 11、20 窗口内 1、启动后窗口外 2，均保留。
- 两个任务的首页、最终设置分别同字节；首页实际有海报、非占位。这只证明两个截面，不追认旧解码就绪、全程视觉或真实库 Top 20。旧 31 拒绝没有历史逐项原因，39 次只属新任务 cohort。
- `sourin-glpb-context-20261120-round5/stable-run-v1/ROOT_STABLE_CAPS_NEW_RUNTIME_WITNESS_V2.json` 只读校验冻结身份、素材、回执与原始帧，纠正 V1 摘要抄错的闭包及未使用的清单展示字段 `expectedCapturePackageEntries=9`。原件、执行输入和历史结果不改。该局部通过不关闭严格性能、普通启动、A8、Top 20、最小化归因或最新产品整包。

## 2026-11-20 稳定指纹后的冷启动归因

- 同 98 文件包原地复用，不重编、复制 DLL/AOT 或缓存，不设引擎开关、不执行原 20 动作。一次独立 owned/noActivate 启动只读 Profile 默认 Ring，PID 70176；原退出自然 0、无强制清理、151 次空 Job 采样，双时钟 8.036565/8.0382904 秒。只记录 35 次实际请求，35/35 驱动接受、0 拒绝及回退，不能与上一全工作负载分母 39 混算。
- 时钟与真实帧号绑定：10298 个事件、42 帧（含首批 40 帧）；40→70 帧/8→13 receipts 逐项追加，Quit 70。未被读回覆盖的 28 个较晚帧不删除但不归因。592 项区间并集交叉重算、四个真实数据负对照都到达指定拒绝条件。
- 第 3 帧 raster **232241 μs**，**164174 μs** 程序构建包络与 **61346 μs** 呈现包络的并集为 225520 μs；其中读取 22036 μs 是前者子范围，cache_hit 126162 μs 也不是 glProgramBinary 单项。第 12 帧自身 raster 3900 μs，其 220531 μs 栅格前等待有 220516 μs 与较早 DoDraw 重叠。呈现包络不可直接归给 swap、GPU 或纯 CPU，仍未验收严格预算。
- 实际首页截图亲眼看见部分海报与灰占位，非旧首页像素等价证据。根回执 `sourin-glpb-startup-20261120-round6/ROOT_ACTUAL_STARTUP_RING_ATTRIBUTION_V1.json`；所有实际原件、负对照和失败范围保留。正式 20 动作的旧失败样本不重跑，普通启动、真实数据与最新产品验收不由此升级。

## 2026-11-20 无窗真实子项与最新 Release 候选

- 按 Owner 最新要求，活跃目标 revision 9 把可独立实质工作交给可见 Agent Teams 并发、互斥写入，主代理同时推进并亲自核验。只有同文件、前后依赖及独占实测窗口串行；没有 token 预算上限。该规则已在现有流程笔记原位记录，不建 TODO 或第二份索引。
- 独立无窗原生微测在精确 EGL/GL/DXGI/driver/format 门下使用现有实际 Package::Open/Load、39 条真实材料和同源默认 EGL Manager 的 surfaceless render context。39 程序全部 link status=1/GL error=0；编译、直接链接、夹具各自然 exit0/noForce/双空≥8秒。Package::Load 合14954.3 μs，CreateProgram419.7，ProgramBinary2421.2，紧随 link 查询137630.2；首次 MSVC 链接遗留vctip导致强制收尾，后继旧Pbuffer EGL指纹不符在驱动前拒绝，原失败均保留。读数不是应用第3帧或GPU耗时。
- 另一次仅改变固定批4调度，39真程序/10批均接受，ProgramBinary/查询API合7159.8/104087 μs，同线程submit→join包络并集111296.7，含IO/log/间隙的整个schedule138212.9。1489项审读+6离线负控，主代理对原始QPC作独立算术复算及六个自然Job终态核对通过；旧串行不重跑、driver cache未重置，不是受控因果提速，不观测worker并发，不准把预热移出正式窗口。回执：`sourin-glpb-startup-20261120-round6/ROOT_SAVED_NATIVE_API_READBACK_V1.json`、`binary-schedule/BATCH4_SAME_THREAD_RAW_AUDIT_V1.json`。
- provider-only候选的7批×256小调用，中位批均值旧HashBytes0.658594 μs、新0.301563、Open/Close0.287109；不足解释22ms load/126ms cache_hit。原v1/v2编译失败、v3实际27/31 exit1、IO-only v4 6/6 exit0分别保留，未生产采用。呈现链13/13 source对应同DLL canonical输入，原Ring内61346 μs present无子scope；限定四任务树无已存ETW。五段trace候选未应用/编译，不归给SwapBuffers/DXGI/DwmFlush/VSync。
- 最新产品相对旧Release的328项目输入仅cover_image/poster_card/miuix_pressable三项改变，seek所属输入保持。任务副本冻结335项目/3352外部/9工具，真实Release kernel/gen_snapshot各自然0/noForce，双空8.018/8.025秒；新depfile3483/3483、无缺/新项，新AOT `58131BEBB1C3661264F658FADB994B54ECD9439BA9233DDA72DF86717CA9361E`。已取得原工作树字节绑定，不用同HEAD冒充输入不变。
- 58个非AOT文件逐项相符（35资产+23原生原谱系），149真实asset输入同hash/1wildcard明确缺省。新旧kernel各ConstFinder实际169常量/168 MaterialIcons码点/0非恒定，重建21404字节字体与旧包同hash；空recorded_uses只作native hooks输入同值而非字体证据。20正负控通过、首次wildcard失败保留。主代理只在新目录组合原58+新app.so，59项manifest `B8C63848DCA1660B4967072E5747C9340614740EC05814B941D1D4AF561D1E20`、五个路径/成员/旧AOT拒绝控制通过。构建/资产/组装回执在 `release-aot-owned-v1/compile-once-v1/result.json`、`release-assets/RELEASE_NON_AOT_REUSE_GATE_V1.json`、`release-candidate-v1/result.json`。这时仅静态候选，不继承旧三退出/16动作/ZIP资格，不发布。
- 新包退出脚本已重绑当前manifest/source/tool、合成媒体/六目录及密钥域；同次只读预检59文件/34输入/三个fresh case和三拒绝对照通过，没有用旧GUI authority。固定封面的真实TCP/PNG oracle另有局部正反对照和旧实际截图阴性，仍不是新Release HTTP/像素见证；旧16动作也不覆盖cache identity/revision或Pressable反馈。任何新GUI结果另按实际回执写，不把静态接线作通过。
- 新候选三个独立任务profile已实际完成playing/switch/pending；各自然exit0、无强制清理/cleanup error，双时钟空Job分别约8.0368/8.0382、8.0428/8.0443、8.0442/8.0442秒。18个实际加载包映像保持与新59manifest匹配；原Home卡/切集与原Ask/Quit成功，pending在Quit前两次200请求实际零body且没有第二首帧或原生超时失败。root逐项核helper哈希和同包输入，封 `release-exit-successor/CURRENT_RELEASE_THREE_OWNED_QUIT_CASES_V1.json`（SHA256 `12D9F0BBD2023DABBFA45B6BAC809C34087D431519B342B8E9196FAD1CCC0957`）。这次只续验新输入，不重播旧包/seek；新16动作烟测和封面见证仍各自另证，普通启动/A8/严格预算不升级。
- 同一新候选的原16动作烟测已实际自然exit0/noForce，双空8.0049/8.0062秒，完整动作/LAN展开收起/source-sort Back不保存/provider顺序及原Ask/Quit均通过，18加载包映像匹配。结果 `release-smoke-successor/runs/app-1da2bf36395148ee96eda7b52692994a/result.json` SHA `41629669C5FC2BF81CE7E981154FAF460F8D4808C78A170096A0B1D18A3855D1`。固定封面另一次真实应用回环精确Referer/UA请求200，418字节nonce图hash `20F1492957384A6096B76545BEC6B56164730641704290005A3F1A81013EBC56`，同屏卡9/9tiles、225/225像素；原Ask/Quit自然0/双空8.0464秒。root亲查PNG。回执 `release-cover-launch/runs/app-dc5cfaf14129413d98037aebee10d1ad/result.json`，截图 SHA `7B8663BAD1FB3982DF1BE0432F3E00F7B9F8528596CFA4A7720C5CD247EC1CBC`；不是Top20恢复、全场视觉等价、任意revision/cache或Pressable状态测试，OS防火墙隔离仍false。
- 当前源码本地candidate ZIP已生成并实际重开验证59条成员、逐项内容hash与CRC：`release-local-package-v1/sourin-windows-local-20261120-58131beb.zip`，43,831,371字节，SHA `FBBFFD3BE0E38A3F2DA948A596C2A5BC4C87EF72459AEA3F66458987A6237F13`。`package-verification.json` 同时绑定335项目输入、新Release AOT、58资产/原生谱系、三退出、16烟测、固定封面；`formalRelease=false`、`remotePublicationPerformed=false`、`wholeGoalAccepted=false`。这是A12最新源码本地同包阶段，不把本地candidate当正式完整交付或给未验条件假绿。
- 三组件source→实际kernel/AOT的只读桥已实跑，不重跑组件或seek：`release-component-binding/CURRENT_COMPONENT_BINDING_V1.json` SHA `6F3014F36848103BA901DBD4CF36D5ACF402798E282E6F0B7E5FB5A59EE1E304`，三owner current/staged/frozen一致且在3483项实际depfile。Pressable精确9809哈希继承原57/6/23PNG局部范围；Poster V4 8163与当前A778不同，但root亲查唯一early-return花括号格式归一化后完全同字节，保留V4 13范围/22PNG与后续14/13例、旧21pass/3fail；cover provider原4项日志阳性，前两失败不抹去。首次checker日志匹配错误 `PROVIDER_SCOPE_LOG` 原件保留，不把它说成产品行为失败或重跑到绿。该桥不是全场视觉/性能新验收，但不会因MSAA缺hover/revision selector再重复未变组件。
- 独立同包审读V3 `release-runtime-review/review-result-v3.json`（SHA `B5BCD6A96B409425A64014942B46DCDED45E4FF1DD4CFD2777F85FF56D8F4DD6`）只读取当前59成员、三退出、16烟测及独立封面原件，通过；没有新GUI/测试/编译/ZIP回放。封面launcher没有落完整windowObservations历史，审读明确available=false/count=null，仅保留实际Home/Ask/Quit helper PID/HWND/birth/Job与源guard边界，不能伪造全过程焦点历史。错误digest/scope的本地比较负控不称无效权威的真实应用运行；smoke不需要另一个pending字段，挂起证据属于单独pending场景。
- 原18+12继续active；严格性能、普通默认启动、Top20精确身份、A8真实外链、历史最小化caller及正式完整交付仍不因此升级。详细取舍归[渲染启动归因](.agents/notes/implemented/testing/2026-11-16-renderer-startup-cause.md)与[同包边界](.agents/notes/implemented/bug-fix/2026-11-18-task-window-safety-and-package-acceptance.md)，旧seek与各历史成功不重跑。

## 2026-11-20 五段呈现与实时指纹子项

- 本轮只推进原性能尚缺子边界，不重复seek、当前本地包或原20失败样本。四条可见队友互斥：实时指纹、trace私有构建、新capture/consume接线、后端源码；主代理独立审命令、执行owned Job和原始帧归因。新材料/执行器统一在 `任务证据根/sourin-performance-20261120-round7/`，原件保留，未推送/正式发布。
- 原stable Reader在default EGL Manager/Ganesh的无窗同源fixture真实读24次，首906.7 μs，后23中位563.7；D3D包络385.5（四COM合段366.2）、OptionsAndCaps146.4（caps JSON100.4）、EGL query+封装/hash11.5、ABI5.5。974项读回及5个原数据篡改拒绝。三阶段自然0/noForce/dual8，原对象只核stat未变，不说全字节重验。7次新的COM邻接拆分另外证CheckInterfaceSupport首390.9、后6中位203.55 μs，QI/GetAdapter/GetDesc约0.30/0.30/0.10；root重算raw7条一致，不能把旧合段重标或外推应用帧。没有driver-version/caps缓存，不删实时guard。
- 五段present原候选只改变trace；主代理纠正preparation draft的实际lld SHA、module名、response引号/flags、stable-caps include和父DLL谱系后，新两TU+direct link各自然0/dual8/noForce。DLL `AAEE1D80906AA920CD8A754A2C0B663656FF28515AAB7D26C921EE2F2D7BC127`，有限派生对象闭包 `8F525D744F177CBFBE1FB8EDBEFB15F65171B975B783661F666C775A613BF052`。453实际include按父canonical核hash；3534真实复用对象/实际库字节核验，原OUT7259/SDK112的size/mtime/file-ID不变。父源码资格继承不是重新核整个32812材料，不声称hermetic宿主。
- 保持原AOT `8E68C741…0331A`，本次startup-only fresh capture35store/35entry/0reject，34唯一payload/460892字节，manifest `7FF03DF213BB4444C7FBF3B0BE3DEE3BBBBF7D8E1EC8B10453C4B20A26192DE9`，真实Finish/原decoder通过后才编consumer任务常量。新94文件消费者同DLL/AOT只读35项，真实35load/return/binary/matched/driver-accepted、0fallback/reject。两个原生配置compile/link各自然0/dual8；两GUI自然0/noForce/窗口精确消失，空Job8.000983、8.0409463秒，17个actual包映像匹配。root回执 `lead/ROOT_PRESENT_TRACE_STARTUP_PAIR_V1.json`。
- 默认Ring原件：capture23823事件/106raw与106完整present全覆盖；consume11158事件，ready43全部覆盖，preQuit84中44完整present。frame70 B在RPC尾尚执行，真实rasterFinish在packet终点后34847 μs；6 unmatched均属tail B，之后无closedDraw；40raw只保留timing，未删、未补end。首次strict全boundary解析拒绝原件保留，后继只认有唯一尾gap；完整帧仍要求同PID/TID/真实frame_number与原时钟、time+原ordinal containment、五段原序互斥。两算法150帧/1950值一致，actualpacket五类负对照×2均拒，见 `lead/ROOT_TWO_PRESENT_ALGORITHM_CROSSCHECK_V1.json`、`lead/ROOT_PRESENT_EVENT_ORDINAL_REVIEW_V1.json`。独审 `independent-present-review/independent-present-result-v1.json` SHA `6D5C664706A98B1FB64CDECA9639C5CF4E7ED76DD20C854E631DD45D8C5D60C1`。
- 消费本次frame2 raster224570 μs中present80289，SwapBuffers70605/OnFramePresented8844/OnFrameGenerated488/MakeCurrent1/blit338/外剩13；frame3 raster240528中present49390，SwapBuffers49315/OnFramePresented1/OnFrameGenerated6/MakeCurrent11/blit51/外剩6。只能归给这些API墙钟包络，SwapBuffers还有ANGLE校验/offscreen copy/DXGI/通知，不能无内层事件叫GPU、DXGI或VSync；后通知也不凭源码条件就叫DwmFlush。root亲查capture全图、consume部分占位，两图不同，不作全场视觉/缓存因果。
- 捕获全raw严格build/raster/total超1/5/10，消费1/7/13。诊断始终 `performanceAccepted=false`，未完成原20正式预算，不删除冷帧或窗口外帧；所有既有红/未知保持。
- 本次35描述符/34真实payload离线DXBC scanner找到68合法embedded container（34VS/34PS），48unique exactstage、13repeat类/20额外重复，8个长度/offset/overlap反例拒绝；不完整解ANGLE外层、不叫实际create次数或driver耗时。回执 `shader-bytecode-census/census-result.json` SHA `7953768B0E0796E72CFD3B450DF8E82F8478E58FFE47CCAF43D94F4CA32ACE1C`。它只支持后续同device/逐字节/VS-PS分离/原Create成功资源的私有复用候选资格；当前没有新生产优化、正式性能或全目标通过。

## 2026-11-20 私有shader对象复用与即时命中见证

- 仍按活跃目标并发，root独立build/真API/应用，队友各管candidate header、fixture物料、未应用集成草稿和只读审查。没有改生产engine/SDK或已验本地Release，旧seek与本地59文件包不重测。所有新证据仍统一放round7性能根（跨round8续接），不在仓库散落脚本。
- 同实际D3D设备与本次合法VS/PS字节，私有default-off缓存只按canonical COM device强引用+stage+length+完整字节匹配，原GetDeviceRemovedReason保留；成功Create才入、hit单AddRef、Clear同步且先放shaderref、上限128/4MiB无驱逐。root修fixture的void GetDevice误写HRESULT/恒真记录，只改私有复制，保留不可编draft。首次本机feature已是0xb100却误用11_0 enum在创建前安全拒绝；枚举校正11_1后的真正API19/19通过，compile/link/run自然0/noForce/dual8s。原Create/miss/hit顺序QPC不做因果提速。只删除memcmp的privatefaultnegative同真API在full-byte-key检查自然exit1/noForce，证明功能门会红；原positive/source不改。额外8个HRESULT/nullout/capacity常量control只是source稿，未执行不称通过。
- 实际原生集成只动两个CPP的VS/PS CreateResource与device release前Clear，不改Resource11或ShaderExecutable布局和每wrapper allocate/decr；新identity消费者重编，856actualinclude+3533父对象/真实库闭包，四阶段自然0/noForce/dual8s。三稿集成patch的错误静态API/二次Create、instance命名/include和宏条件由root读回纠正后才写真正CPP，不使用draft patch作编译资格。DLL `BBC682A6D42FF9498F74B904EDEEFB94C78DAFD04F8D7649E43A6AA538CCA9F0`，派生闭包 `A15BECD24966482BF6E51F407F662D647999DDC44BF1C075687478C1197AF6B3`；它不是full-parent source fresh hash，exit-time-destructor warning、debug-label共享状态及一般卸载生命周期仍有限制，未生产采用。
- 该候选首次startupcapture35store/0reject/Finish、86raw自然退出，但日志放在Renderer清理路径，实际退出未经过，stderr计数0条。不证明hits=0，也不能把真APIhit当应用见证。旧run保持operational=true/cacheWitness=false。
- 新后继只增defaultoff、显式macro==1的first-store/first-hit即时metadata：actual cache publish/hit同mutex，保存LastError、240byte buffer、不含key/bytecode/path/凭据；root逆除onlyobserver additions与原候选同字节，独审v2同意key/state/返回无改。v1两个false是checker切片错、原v1保留；WriteFile失败/partial和锁内同步阻塞仍best-effort诊断上限，非durability/性能保证。
- 新DLL `09C3889226C0A4468CB18846B83F036D8D97E2ABB91A33BAF338B41DFF495A43`、闭包 `42AC2EB454957B8A8A674F5F46C08B29AE0C3E8794FD0845C5E1B6FAFDB2B1F2`，保持原AOT8E68…0331A。只此新身份的capture35descriptor/33unique payload/434416字节，manifest `4BCE53AF3AEC8603A32A56BEA370EE1ACC7356C338A67D1F90F615D4306FA7BC`，原decoder重开后组新93文件readonly consumer。捕获、消费均真实firststore(0hit/1miss/1store)、firsthit(1hit/8miss/8store)；不同调用worker线程不等于GLkey/device归因或完整并发历史，只证该owned进程cache实例至少一次actualhit。
- 消费实际36load/35package return+binary+matched+driveraccepted、0fallback、1reject（不可说0reject或fullcoverage），session nonce6166147067304357515，原initialReceipt1attempt/0return而非初态全0。两GUI自然0/noForce/精确窗口消失，18实际映像匹配，双空capture8.0386/8.0402、consume8.0483/8.0540秒；原物料只读hash不变。root回执 `lead/ROOT_OBSERVED_SHADER_STARTUP_PAIR_V1.json`（文件名V1、schemaV2，SHA `91411F4643EE791201EF0FD1E031C161F7AB9337FF2F42DEBDE10B0776E4490C`）。首次root checker regex与旧capture路径错误由只读V2修正，应用不重run。
- 捕获95全raw/ready42/完整46/49timing-only（RPCtail frame101）与消费97全raw/ready97/完整97均保留。默认Ring12035/22411事件，五类actualpacket拒绝均检验，sourceordinal/time/frameNumber共同匹配；不补end、不删帧。消费heavy frame6 raster264696，present36860含swap27870/afterpresent8227；frame7 raster211582，present48770含swap48693，不能拿同号旧帧或API微测解释。root亲查两图部分占位/内容就绪不同且控件尺度异，不能认定同DPR/content状态或全场像素等价。
- 磁盘实盘点：统一round7性能根约1.775GB/7198文件，当前可用约78.53GiB；最大三份派生DLL/PDB/对象身份构建各约300MB，两个真实pair运行包与快照各约290MB，早期无见证捕获约146MB、lead原始执行/失败/读回约102MB。原件成功/失败和可复用构建对象暂保留，不安装生产或正式发布；未获删除确认不清理数据。报告 `lead/disk-inventory-v1.json`。434篇笔记门禁及git diff --check实际exit0，原repo工作树的既有产品改动保持。
- 独审 task53 在原收束时只有失败解析稿，原 `ROOT_INDEPENDENT_REVIEW_UNQUALIFIED_V1.json` 与两次解析错误说明保留。随后晚到的 `observed-pair-review/observed-pair-review-v2.json`（SHA `6E35A441A46C97A01085D59D7EF9EB37A900287D87D21E85EE2AE872D1A5C336`）已由root读取：修正ready原始文件与quit原始计数来源后，有限读回95/97 raw、两臂各两标签及36/35/1/0计数；身份桥仍引用root报告，不是另一套独立完整帧归因，也没有性能或生产资格。应用没有重采样，旧失败不升级为成功。
- **性能仍未通过**：全部保留raw的build/raster/total，捕获超1/6/11、消费超1/9/11；这不是正式原20，无performanceAccepted。当前只完成task-only对象复用actualhit、局部driver接受与可归因帧；原18+12继续active，A11普通启动、A8真实外链、Top20精确封面、历史caller与正式完整交付不变。当前已验生产本地ZIP保留原范围，不混装此私有引擎。

## 本地提交前的已完成补证

- 后继真实D3D离屏绘制只针对原私有缓存header（无即时日志）验证像素：固定人工VS/PS、同设备/常量/纹理/顶点/光栅与混合状态，直接Create和cache miss/hit分别画入独立RGBA8 render target，CopyResource到staging后Map，opaque与alpha两对共32768字节完全一致；真实覆盖各1152像素，中心色和边角clear另检。先改变候选alpha draw的红色常量，实际GPU回读出现1152字节差，同一像素门自然exit1；随后原状态自然exit0，所有owned Job无force、双空≥8秒。root另从原raw重算并亲看PNG。它只证明人工shader/指定状态的局部绘制等价，不是35程序的全像素、debug-label等价或性能通过。证据 `sourin-shader-validation-20261120-round8/lead/pixel-execution/PIXEL_READBACK_V1.json`。
- Owner要求的本地检查点已完成：43cfb07、22b9846、71fba84、f440d68。既有seek与已验UI源码已入库，原实测范围不变；私有引擎/脚本/日志/图片仍只留统一任务目录，不入源码库。无新增trace候选的当前结果以下述原件为准，不沿用准备阶段状态。未执行远端push、PR、tag或发布。

## 无新增 trace 候选的第 9 轮保留失败

- 新私有 DLL `C65C5AD538301D0F45586391663CED3D660C16A2205EBEBE4EA73608570773CB` /派生闭包 `7FA1F59A40EE667ADDD9C78041F2472F6D9DEE8D19A9C068C61421F72DB12587` 已实际单身份编译/重链自然0、无force、双空≥8；3535复用对象/实际库字节及246实际include已核，原OUT/SDK成员stat不变，不是全父源码新鲜重验。它仅恢复原compositor以去除新增trace，cache算法、原AOT8E68…0331A及原20动作区保持；没有生产安装或正式性能通过。
- 首捕获在start前 `CAPTURE_SIZE_BOUND` 失败，26 raw、0动作，Dartready1592×904/DPR1而原生日志160×28；无同期iconic/placement/caller，不能归因Owner或DLL。原退出自然0/无force/双空8.0096秒，清理35材料未资格。
- 被动状态观察后继先经自有未显示窗口真实API及错误birth红控验证；首次测试因亲和前置不足在子进程前拒绝，原件保留。后继只读PID/birth/Job/HWND、状态变化和三时钟，不恢复/激活/输入。第二次捕获8区块请求失败、0卡片，90秒原就绪门拒绝，551 raw、0动作；已保存四条状态均非iconic/foreground但不是连续历史。自然0/无force/双空8.0110/8.0123秒，清理30材料仍未资格，未建consumer。
- 两次失败raw的build/raster/total超限分别2/13/17和1/22/35，577帧全保留；原20未开始，不是正式性能样本。既存原20读回另发现动作末1112帧与preQuit1120帧分母不同；计入尾部totalSpan超限14而非13。新读回经时钟/窗口/Quit计数的实际数据篡改拒绝，原动作700ms窗口不改。
- 本次Flutter快照1990×1130/逻辑1592×904/DPR1.25/display65539，不等于前次DPR1/display65537。显示只读枚举和源码仅给准入边界，不追溯Owner移动、最小化或caller；Win32桌面矩形与Flutter尺寸不可混用。
- 只对原匿名分类20/page1同公开GET经既有loopback路由单次请求，零重试/凭据/跳转、TLS不放宽：curl35、HTTP000、0字节握手失败。这不是此前八请求共同根因，也不采用更新服务502来解释区块。网络队友报告漏lead根而未读当前run，保持partial；root读取正确原件核结论，不把独审未覆盖标绿。
- 根离线读回 `sourin-performance-20261120-round9/lead/ROUND9_FAILED_CAPTURE_SCOPE_READBACK_V1.json`，SHA `7D06222203B300EC2DD4CF61B9996FFBCFEF481B3D9E5A21CF369313D60A3C66`。读回通过只证明原件链一致，非采集/性能/生产资格；无第三次客户端、无新合格材料或消费，完整18+12继续active。路由内容恢复及原显示cohort的新只读准入证据缺失前，不延长超时/换内容/改DPR或重复启动挑成绩。
- 统一round9任务目录实盘点约584.2MB，其中唯一plain引擎构建约298.9MB、两份不同失败native配置/运行及根验证约285.2MB；可用约78.29GiB。保留唯一可复用构建及失败原件，不删证据、不安装生产；未创建第三套运行包。

## 主屏私有入口的原 20 动作实测及严格预算失败

- 第10轮先对同包core现成匿名文本接口做一次分类20/page1 GET：HTTP200、14记录/13非空封面，独立六根/命名空间、无账号或凭据读取，自然0/无force/双空8.0481秒；真实非HTTP scheme被拒绝。它是reqwest/rustls路径，不重播curl/Schannel，也不反推此前八区块共同根因。
- 仅私有runner main加入编译宏与原合法非激活hook控制的首显前主屏准入；共享guard真隐窗红控自然1、绿控自然0且尺寸保留。初版误传新增环境hook被原AOT隔离拒绝、Quit未注册、owned强制清理，原件完整保留。修订删除新hook、保持AOT白名单，静态非法hook负控明确拒绝；main真实编译后只读纠正报告路径，不重编成功对象。
- 同plain DLL C65C5AD5…773CB、闭包7FA1F59A…12587、原AOT8E68…0331A和修订main对象401239C3…6098：capture/consume各一次完成原15导航+1准备+4滚动，700ms窗口/450ms linear/原动作区逐字保持。两臂实见首显/ready为当前主屏、96DPI、1592×904/DPR1，8区块154卡片；各18加载映像匹配，准确HWND消失，原Quit自然0/无force，双空分别8.0463/8.0486、8.0282/8.0282秒。只记录采样窗口状态，不声称连续历史或历史caller。
- 捕获39描述符/38唯一blob/506424字节，manifest `3156F44CCCA7D1E17515ED90C7573E0B398716FDBFB3692C63F2E0452EB7EB18`，真实Finish及原decoder重开后才编消费配置。消费者base59+材料39=98件，首预检固定59误拒发生在GUI前；读侧修正后缺材料/多成员负控均拒绝，未重采或重编AOT。原件与只读副本39文件消费后逐项同hash。
- 消费真实41load、39return/binary/matched/driver accepted、2reject、0fallback/reentrant，session nonce8119367108902853076。不写成41全命中，不从总数回溯拒绝原因，也不改helper静态false为资格绿。root实际counter/session/material链及38blob/key/长度/格式已读回。
- capture动作末812/preQuit830（18尾帧），consume动作末908/preQuit925（17尾帧），冷/窗内/窗外全部计入；Quit计数等于preQuit，不声明Quit后到exit逐帧完整。原整数判据下build/raster/total超限capture **7/156/301**，consume **8/150/263**；consumer最大52550/372920/690855μs，p95为4572/38033/82312μs，冷启动115帧和窗外199帧保留。**原20运行完成，但性能明确未通过**。
- root亲看四张PNG：捕获首页全占位，消费者首页可见海报；最终设置图同hash，不能宣称全程像素等价或跨运行因果提速。有限独审只核capture830raw/39材料及38blob，环境审查为partial，不能转作consumer独审成功。root离线另核两臂完整原件；时钟、700ms窗口、Quit分母篡改及“隐藏拒绝”/错误payload hash负控都拒绝。
- 根回执 `sourin-performance-20261120-round10/lead/ROUND10_PRIMARY_FULL20_PAIR_ROOT_READBACK_V1.json`，SHA `9554E764B8B945AC08FDD461F58434586C26525883D5BF69EBB75028F346F55D`。仅读回通过，不生产采用、不正式发布、不推送。已验seek、生产源码和Release ZIP保持；原18+12继续active，普通启动、Top20精确封面、A8真实外链、历史caller和完整交付不因本轮局部通过而升级。
