# Agent Note: App99 媒体解析、真实换线与网盘具体文件播放

Status: implemented

## Problem

Owner 驳回上一批实机结果：搜索能看到胖妞，但资源不能播放；播放页切线路没有重新起播；网盘没有先检查有效性再播放指定集。返回 HTTP 地址和单测通过不足以证明真实媒体播放。

## Decision

- App99 详情保留线路协议码、标题与线路内集序号，使用 `app99:` 结构化剧集 ID。握手保存 `player/parser_api`；解析型线路允许上游的不透明非 HTTP 载荷，按线路配置走 `/app/vodParser`，直连线路仍要求 HTTP。`Proxy ... appdanmu` 是弹幕地址，不作为媒体候选。返回的播放网页被拒绝，解析器尝试有总预算。实际首帧仍单独验收。
- 播放页的线路选择调用生产 `_reload`，传目标线路对应的集 ID、`flag`、真实标题和线路内一基序号，沿现有起播路径续播当前位置。标题精确匹配或唯一明确集号才能跨线对齐；缺集、歧义不替播其他集。默认线路跟随当前集，同 ID 跨线路以当前集对象和 `flag + id` 区分。独立线路入口与画质入口分开，初次解析失败仍可换线。
- 底栏线路菜单使用局部 Focus 边界隔离播放快捷键，打开时聚焦当前线，上下移焦、确认换线、返回恢复工具焦点；失败层线路按钮的确认键进入实际选集面板。这些动作沿同一生产重解析入口，不只改变选中样式。
- 网盘播放采用检查、完整列真实文件、唯一选片、转存、取媒体地址的顺序。预检 `Bad/Locked` 立即停止；`Uncertain/Unsupported` 必须再由真实文件接口验证，不能当成功。`panfile:` 只保存网盘种类、分享 ID、提取码和稳定文件 ID，临时 token 在播放时重新取得。夸克、UC、迅雷详情展开具体视频文件；分享入口展开失败保留重试入口，不返回网页或最大文件冒充所选集。
- 选片优先稳定文件 ID，其次唯一精确文件名或明确集号；目录名、年份、分辨率不冒充集号，多个版本须用户选具体文件。唯一未编号电影仅允许第一集兼容兜底。分享文件枚举覆盖分页与子目录，超预算或重复分页明确失败，不把部分列表当完整结果。
- 迅雷生产与测试共用 `poll_until_done`，生产仍为十次、每次一秒。每次新建唯一专属目录，使用逐字取证的 `POST files` 与 `response.file.id`，只在该目录确认所选文件。不用根目录差集推断归属，不复用同名用户目录。建目录拒绝时不退回根目录；目标文件缺失或有效性失败时不转存、不清理。无具体选片上下文的兼容入口也只能播放唯一视频。
- 播放请求的 `extra` 传递每页稳定的 `play_consumer` 与全局单调 `play_generation`。CSP 在首个 await 前注册并以 task-local 传入网盘修改阶段；修改互斥锁内、清理/转存前与返回后检查代次。退出按同一会话和截至代次清理，关闭会话不能被迟到请求复活。旧成功/错误响应不得覆盖新线路或本地会话。夸克/UC 的现代播放器请求也使用本次独立子目录，避免跨会话同名去重共用 fid。
- FFI 的 `pan_cleanup_temp` 按 Dart 真实 `{cmd,args}` 信封从 `args` 读取 owner 与 invalidate；缺少 args 维持 legacy 契约，半个 owner、空 owner、错误代次类型立即拒绝，不退回 legacy 删除。测试通过完整生产 dispatcher 和实际本地 HTTP 删除请求观察归属，不用另一份清理实现替代。
- 独立目录不代表服务端绝不会内容级去重。夸克/UC 的 save 成功出口和独立子目录登记前，对照账本拒绝同种网盘的同 fid 被不同会话、代次或 legacy 调用方共用；不得把另一正在使用的副本登记到新请求后再由旧请求删除。同一会话同一代次的自愈死 fid 重试仍保留原有两类终态。这是已登记副本的冲突保护，不声称证明上游所有文件的实际目录归属。
- 迅雷清理账本按端点、当前凭据指纹、会话和代次保归属，只登记服务端返回的自建目录 ID。删除成功或确认不存在后才销账，失败保留供后续重试。上游响应原文、未知状态与网络请求 URL 不进入错误提示，已知状态只保留有限白名单。
- App99 真实夹具写出限制为显式 live 取证且排除回放本机地址，普通握手和离线测试不覆盖真实抓包。

## Alternatives considered

- **只补播放器格式或 UA**：改动小，但无法把弹幕代理或播放网页变为媒体，也无法修复只改高亮的换线路径，因此不采用。
- **网盘仍选最大文件，或按跨线路绝对下标对齐**：容易取到一个文件，但文件大小、全局列表位置不能证明用户选的是哪一集；因此仅保留明确目标文件选择，不用它们兜底。
- **预检不确定直接报无效**：能少发请求，但匿名预检受风控或缺少签名时不代表分享失效；因此由原生列文件接口复验，成功取得真实文件后才允许转存。
- **测试保留一份迅雷轮询副本**：测试可以缩短间隔，但副本不能保护生产分支；因此同一个生产函数接受间隔参数，生产常量不变。

## Consequences

收益是线路、剧集、网盘文件身份贯穿详情与播放请求；解析失败仍可恢复到其他线路；检查或选片失败不修改用户网盘。

代价是完整枚举比只找最大文件多发请求，使用请求数、目录深度和总时间预算限制。夸克/UC 首次 save 之后的所有自愈 await 都受真实 `timeout_at(40s)` 封顶，不能只在 await 之间检查时间。

迅雷建目录的 web 客户端启用 `withCaptcha:true`，有效 Bearer 是否足够尚未完成生产账户取证；验证码拒绝时明确失败，不声称当前账号必然可播。迅雷凭据指纹不是稳定账号 ID，重登或刷新凭据后的旧目录可能残留，尚未用未经取证的账户显示名推断身份。百度 dlink 仍未取证且既有凭据失效，本批不宣称百度可播。未接入网盘的文件播放明确失败。

夸克/UC 现代请求的删除失败保留归属账目，legacy 的既有 best-effort 清理节律没有扩大重构。

保留一个原有直接 FFI 输入校验 P2：`resolve_stream` 对错误字段类型的 PlayRequest 反序列化使用 `.ok()`，可能将整个 req 降为 None，丢失选集与归属上下文。当前 typed Dart 生产出口只产生合法 String、正整数与对象，不会自然生成该输入；这不是本批 typed 交互的新增回归，但不宣称任意直接 FFI 载荷也有同等保护。

## Verification

证据保存在 `.probe`。App99 旧实现真实协议回放证红：线路协议码没有解析为用户线路名，且 HTML 地址被直接交给播放器。播放页三端 widget 点击门禁证红：换线没有发起新解析。新增门禁还验证同集请求、线路内序号、进度意图、缺集不误播、过时响应不能覆盖当前线路和受控起播回调。widget 点击与受控回调不是实际应用首帧或 TV 遥控验收。

生产 Rust 真实站点探针从隔离配置走胖妞握手、搜索、详情、媒体解析。解析型线路先因错误的 HTTP 前置条件实际打红，修复后 NSYS 第 2 集与 PAN1 第 02 集各通过一次真实取流，均保留九条线路并读到 HLS 与 TS 媒体字节。该结果不等于播放器首帧。

迅雷新增回放实际证明根目录差集会误播并发用户上传、建目录拒绝仍会转存、转存响应泄密、清理失败丢账与未知分享状态泄密。另在源码一致的隔离快照注入代次失效、宽泛清理和无选择默认第一文件，实际打红对应门禁；恢复生产模块后回放转绿。

2026-11-04 已完成的后台批次：

- `selected-episode-rust-ownership-final-release.log`：生产 Rust `cargo test --lib --release` 实际为 2065 passed / 0 failed / 94 ignored；`pan-owner-original-check-tests.log` 的 `cargo check --tests` exit 0。这不是下述后续补修的最新全量结果。
- `pan-owner-selection-final-green.log`：源码一致隔离快照专项 49 passed / 0 failed；`pan-owner-mutation-red.log` 实际 14 项失败，跨归属 fid 单独注入实际 3 项失败。八个恢复文件与生产源码 SHA256 相同。专项没有经过 FFI 命令信封，不能证明整个清理入口已接通。
- Dart 历史回归为 native 32/0 加 pure 106/0，共 138/0；文件名带 `final` 的两份旧日志实际失败，不能认绿。代次补修后可绑定冻结源码的窄回归为 `player-epoch-postrestore-green.log` 12/0、native 19/0、pure 12/0，共 43/0。analyze 为 0 errors、18 既有 warnings、7 既有 infos，exit 2，不称全绿。
- `selected-episode-flutter-final-build.log` 确认 Windows 构建成功。ownership 冻结版本的三处 core DLL 现算 SHA256 相同，为 `B149F38F19F42496772279D0F4020B4B03354B50CC64166457C9FBD142A39C25`。后续源码补修需重新冻结、构建和校验部署。

后续定向核查发现并修复两个此前门禁未覆盖的接线缺口：底栏线路 popover 与初始失败层的 OK 被父级播放快捷键截获；`pan_cleanup_temp` 从错误的外层信封读取 owner/invalidate。最新冻结源码验证如下，前述历史记录不替代本批结果：

- `selected-episode-headless-rust-release.log`：生产 `cargo test --lib --release` 为 2069 passed / 0 failed / 94 ignored，exit 0。编译 8m43s，执行 103.16s；211 个 Rust 输入在冻结、测试后和最终 DLL 构建后 SHA256 一致。
- `pan-cleanup-envelope-evidence-20261104.md`：四项完整 dispatcher 门禁在隔离快照中逐项 fresh-process 实际证红，各 0 passed / 1 failed，修复后各 1/0，全部 FFI 测试为 30/0。恢复快照四个文件与生产 SHA256 相同；测试专用 TLS 凭据与端点 RAII 不读写 OS 钥匙串。
- `player-line-dpad-final-clean-native.log` 与 `player-line-dpad-final-clean-pure.log`：最新干净回归分别 58/0 和 20/0，包含 D-pad 12/0，源码前后 SHA256 一致。菜单拦截 mutation 为 6 passed / 3 failed，初始焦点与失败层入口 mutation 各 0/3，均为实际断言红并已恢复。
- `player-line-dpad-analyze.log`：0 errors、17 warnings、10 infos，exit 2；不称 analyze 全绿。
- `selected-episode-headless-core-build.log`：独立 target 的最终 Rust DLL release 构建 exit 0，3m41s；SHA256 为 `E30B05145BC1EFEB426B0797A1E4D9D0DACE7EE3E69547F2542FB2F0B8605F75`。没有替换 Owner 正在运行的旧 runner 或 DLL。
- `app99-headless-decode-20261104-144532`：旧部署 core 经生产搜索、九线路详情、结构化 code/index 选第 2 集、真实解析，把原地址和 UA 交部署 libmpv 软件内存渲染。NSYS/PAN1 分别产生 66/67 个实际新帧，各三张不同 SHA256 的 480x270 PNG；Root 亲眼查看第三张，确认清晰演员、场景和片头字幕，非黑帧或包装图片。该批只绑定旧 core `B149F38F...A39C25`；最终 core 重跑另存于下面的 v3 取证，未混写旧报告。
- `app99-headless-v3-20261104-151946`：最终 `E30B0514...B8605F75` DLL fresh 两路真实解码与关闭门禁 exit 0；NSYS/PAN1 第 2 集分别产生 67/66 个实际新帧，H264 1920x1080/25fps，丢帧计数为零，Root 再次亲眼查看两路第三张图。各自同一个已初始化 core 收到真实 `{cmd,args}` cleanup 并返回 `{}`，同 consumer 的 generation 2 重试均返回 `{"error":"播放解析请求已过期","kind":"other"}`，断言通过；实际网络流量未额外拦截，不把亚毫秒拒绝解释为独立测量了零网络请求。v3 的 13 个正负信封自测先过；v2 的 `ok:false` 误判导致 exit 1，原件及勘误完整保留，不算生产失败或 mutation 证红。系统新版 FFmpeg 的扩展名拒绝结果也保留，正证仅为部署 libmpv 软件内存解码，不是 Flutter 首帧、音频或全剧验收。
- `selected-episode-headless-flutter-build.log`：首次隔离 Windows 构建实际失败于 `NUGET-NOTFOUND`，原日志保留。插件实际读取 CMake 的 `NUGET` 变量，隔离 cache 指向已验证的既有 NuGet 工具并复用匹配版本缓存后，`selected-episode-headless-flutter-nuget-rebuild.log` 为真实 exit 0，411.2s；257 个前端输入在原项目与镜像 SHA256 全部一致。修复只在 `.probe` 镜像环境，未修改全局 Flutter 配置、生产插件缓存或运行中的产品。
- `selected-episode-headless-bound-core-sha256.json`：隔离 staging 与 Release 包内 core 均已替换为最终 `E30B0514...B8605F75`，与 v3 解码一致；包内 libmpv 也与解码库 SHA256 相同。exe 与 app.so 的完整哈希在 `selected-episode-headless-bundle-artifacts.json`。原产品 DLL 仍为 `B149F38F...A39C25`，PID 57184 的原启动时间未变；没有启动隔离应用，构建与 DLL 绑定不等于实际窗口验收。
- `panfile-live-listing-20261104-153159-41724`：最多三个历史分享候选的匿名只读探针实际运行，预检分别为夸克 Bad、UC Bad、夸克 Bad，实证 panfile 数量为零。未读取账号、取流、转存或清理，临时输入结束删除；没有用无效历史样本冒充可播文件。原探针错误地把无异常返回的 `{error,kind}` 也标成 get_detail 成功，且未保留该响应原文，因此其成功标记不可靠，不事后推断每次 detail 的具体错误；该批只支持预检结果和未取得有效文件的事实，未来仍需新鲜有效分享与账号补证。

实际窗口截图第一次采集超时，随后用户按 Escape 停止 Computer Use，未取得首帧、切线或网盘选集截图。用户随后要求使用不影响其电脑操作的方式测试，因此只进行后台回放、无窗口测试与解码，不抢焦点或发送全局输入。无窗口解码也不能替代实际应用的视觉验收；真实账号与所选具体文件的播放仍待证据。完整目标保持 active。

## Relations

本篇部分更新 [App99 游客握手与搜索源切换](2026-11-01-app99-guest-handshake-degrade-and-search-source-rail.md) 的播放覆盖边界与夹具写出事实，握手降级及搜索决定保留。

本篇部分更新 [线路集号对齐](2026-10-30-episode-number-normalized-line-switch.md) 的面板生产动作和默认线路事实，遥控 sourceCode 维度不扩大到本批。

本篇部分更新 [迅雷与百度取流](../feature/2026-11-01-xunlei-baidu-share-direct-link.md) 的具体文件选择、独立目录、归属清理与共用轮询事实，百度取证边界保留。

本篇延续 [网盘预检](../feature/2026-10-31-tvbox-pan-check-precheck.md) 与 [夸克有界自愈](2026-11-01-quark-retry-404-21001-purge-race-and-selfheal.md)，不将预检不确定态或去重失败伪装成可播放。
