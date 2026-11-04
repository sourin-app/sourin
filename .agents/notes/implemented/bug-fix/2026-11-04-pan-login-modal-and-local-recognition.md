# Agent Note: 网盘独立登录弹窗与本地账号识别闭环

Status: implemented

Relations: [网页登录架构](../feature/2026-10-31-pan-webview-login.md) 的原生
CookieManager 与钥匙串保存入口保留；本篇补有界生命周期与保存后本地回读。
[扫码弹窗唯一真源](2026-11-01-pan-qr-dialog-weblogin-source.md) 的盘种与
115 撤除判据保留，本篇只将设置页扫码入口收敛到共享弹窗。

后续局部补修：[认证会话新鲜度](2026-11-04-pan-web-auth-session-freshness.md)
增加导航前内存基线，旧或未知会话需明确确认；本篇本地识别、取消及有界生命周期
决定保留。旧 Cookie 存在不再被当作本次网页登录已经完成。

## Problem

Owner 驳回网盘登录体验：扫码入口需要独立弹窗，不能在设置页内常驻二维码；网页登录即使浏览器里完成，应用也必须保存并识别账号，不能把捕获到 cookie 或保存命令成功当作完成。失败、过期、超时和取消需要有界且可行动的反馈。

既有扫码逻辑在设置页与共享弹窗中重复；网页登录在捕获 cookie 后只检查保存结果，没有本地后端状态回读。轮询读异常后继续静默等待，窗口创建或启动失败可能留下窗口。通用错误包装会打印原始异常，因此不适合接收可能含凭据的原生插件错误。

## Decision

- `lib/ui/settings/pan_settings_page.dart` 的扫码入口统一调用 `showPanQrLoginDialog`；每行入口直接传盘种，不改写通用盘种选择。QR/Web 在 Runtime 探测及窗口创建之前同步置忙，所有账号入口互斥，旧回调也不能再触发另一登录或登出；退出与启动异常通过 finally 释放锁。网页登录启动错误单独显示，保留账号行及重试入口，不冒充状态读取失败。扫码与网页登录成功后重新读取设置状态，刷新也有 15 秒上限，不永久占锁。登录状态文案明确是“应用已读取保存的凭据”，不承诺远端会话有效。天翼尚未接入登录协议，显示边界并不进入通用扫码名单。
- `lib/ui/widgets/pan_qr_login_dialog.dart` 使用现有 `AppGlassDialog`，宽度上限 460；共享入口同时服务设置页和播放补登录。请求上限 15 秒，二维码会话上限 3 分钟，轮询不重叠；失效、错误和重试清除旧二维码。扫码返回 confirmed 后仍检查 `pan_auth_status`，本地识别通过才返回成功。网页替代路径挂起旧二维码会话，在创建浏览器之前同步置忙，阻止双击与同时重新获取；关闭与代际检查阻止迟到结果继续推进。二维码显示失败只呈现固定重试提示，不显示会话 URL。
- `lib/ui/widgets/pan_login_session.dart` 统一调用、超时与本地识别判据。网页登录顺序固定为 `pan_save_credential` 返回 `ok == true`，再从 `pan_auth_status` 找到同一盘种，要求 `keyringAvailable == true`、`loggedIn == true`、`expired == false`。只有静态 `PanLoginFlowException` 文案可显示；其它异常使用固定可行动文案，不经会输出原始异常的公共日志包装。
- `lib/ui/widgets/pan_web_login.dart` 的捕获判据与 cookie 拼接共用同一过滤函数：限制目标域、拒绝控制字符与分隔符注入、同名后到覆盖；后来的空值或非法值使旧登录值失效。Runtime、创建、启动、读取及关闭均有 15 秒上限；90 秒截止计时器独立于轮询。失败停止并给出“重新检测”；超时暂停检测并保留原生窗口供用户确认或取消。创建晚于超时完成以及启动失败时关闭窗口；关闭失败不泄露原生异常。网页登录入口只读取 `PanWebLoginSpec`，不维护第二份名单。
- `rust/sourin_core/src/pan_login.rs` 的 `validate_web_login_credential` 使用 cookie 对解析与最后同名值，拒绝控制字符和非法键名，要求既定登录键齐全。生产凭据保存入口与钥匙串实现不变；新增 `pan_login_ux_gate` 仅用合成输入测试，不访问网络或钥匙串。
- 旧门禁只更新失效前提：`test/zz_t1050_pan_settings_page_test.dart` 的本地状态文案、独立弹窗、状态回读次数及组件复用；`test/zz_t1062_r2_entry_and_pan_honesty_test.dart` 的历史永久“未接入”文案；`test/t20261101_pan_web_login_115_test.dart` 仅 E1 改读唯一配置真源。其余断言语义不变，格式噪声经 AST 对比压缩。

## Alternatives considered

- **保留设置页内扫码并再叠一层弹窗**：局部接线更少，但保留两份状态和轮询，重试、退出与过期行为仍可能漂移；统一共享组件才使 Owner 指定入口具有一致生命周期。
- **捕获 cookie 或保存成功即返回成功**：少一次调用，回调快；不能证明应用识别到同一账号，也会掩盖钥匙串不可用和保存后仍未登录，故使用权威本地状态回读。
- **把本地 loggedIn 回读称为远端登录验证**：现有状态 API 足够快，但它只证明本地凭据识别，不证明提供商服务端接受；不以该结果代替真实文件检验与播放。
- **给所有错误输出原始详情以利排查**：插件详情有诊断价值，但可能含 cookie、会话 URL 或其它凭据；登录组件仅返回可信固定反馈，远端与生产错误取证归主线受控探针。

## Consequences

- 设置页扫码是独立模态入口；保存成功不再跳过本地账号识别，失败与超时停止并有明确下一步。
- 取消不能撤回已提交给原生后端的钥匙串写入。代际检查阻止取消后新写入，并阻止进行中的写入完成后继续读状态或返回成功；本修复不添加退出清理或凭据删除。
- 浏览器关闭、取消和超时不当作远端认证成功。重新检测会开启新的有界检测周期，不自动无限重试。
- 本次证据全是离线纯测试或离屏 widget 回放，不证明原生窗口视觉、真实登录回调、远端会话有效性或视频真实起播。Owner 的原生弹窗与浏览器验收、真实账号状态回读和播放属于主线统一实机验收。
- 全局 `userErrorText` 的原始异常日志行为不在本修复写入范围；本次 QR/Web 登录与状态回读错误路径不调用它，设置页原有分享浏览等功能没有顺带重构。

## Verification

全部夹具使用 `local-test-*` 合成值；测试前清除代理变量，进程 Hidden / BelowNormal，留档只写入新 `.probe` 路径，不覆盖历史取证。

- `test/t20261104_pan_login_ux_capture_test.dart` 4 项：空或非法登录键、被清空的同名键、控制字符、设置页独立 PopupRoute 与 `AppGlassDialog`。初始 RED：`.probe/pan-login-ux-capture-red-20261104.result.json`，4 失败；纠正仓库玻璃弹窗不依赖 Flutter `Dialog` 的查找后，真实取消模态入口的 mutation RED 留档 `.probe/pan-login-ux-modal-mutation-red-20261104.result.json`。
- `test/t20261104_pan_login_ux_session_test.dart` 14 项：保存后本地回读、错误账号/过期/钥匙串不可用、不重叠轮询、读取超时、关闭取消、保存后仍未识别、QR 过期重试与 confirmed 验证，以及错误日志/窗口清理/会话 URL 边界。
- 隐私实际 RED：`.probe/pan-login-ux-privacy-red-20261104.result.json`，原始日志含合成凭据；关闭异常与会话 URL 保护移除后的 mutation RED：`.probe/pan-login-ux-cleanup-url-red-20261104.result.json`，12 通过 / 2 失败。两处保护均恢复。
- QR/Web 与设置页 9 文件本地回归 GREEN：`.probe/pan-login-ux-regression-final-20261104.result.json`，exit 0，95 通过 / 0 失败。该轮之后有测试函数声明 lint 修正、旧测试等价格式压缩与下述追加互斥及状态刷新上限；由主线最终联合回归绑定最终工作树。
- 主线审查追加的启动互斥 gate 为 `test/t20261104_pan_login_ux_concurrency_test.dart` 3 项。有效 RED：`.probe/pan-login-ux-concurrency-valid-red-20261104.result.json`，0 通过 / 3 失败，确实读到 Quark 双击与 Baidu 启动共 3 次、QR 后 Web 1 次及启动错误逃出。首轮 `.probe/pan-login-ux-concurrency-red-20261104.result.json` 因原生 Runtime 测试初始化不可用而红，不作为缺陷证据；改用插件提供的 `NativeTransport.testing` 与合成启动回调，不启动原生窗口。
- 追加 5 文件回归 `.probe/pan-login-ux-concurrency-green-20261104.result.json` 为 47 通过 / 1 失败，失败确实指出启动错误复用状态错误字段会隐藏账号行。修正独立错误字段后，`.probe/pan-login-ux-concurrency-final-green-20261104.result.json` 为 exit 0，3 通过 / 0 失败，覆盖同盘双击、跨盘并发、QR/Web 互斥、旧登出回调与失败后可重试。最终联合需纳入上述第 10 个测试文件；不把中间 47/1 称为全绿。
- Rust 纯门禁 RED：`.probe/pan-login-ux-rust-red-20261104.result.json`，1 通过 / 3 失败；GREEN：`.probe/pan-login-ux-rust-green-20261104.result.json`，exit 0，4 通过 / 0 失败。Rust owning diff 只有上述 validator 与纯测试模块，没有修改扫码网络协议。
- `trim` 前控制字符校验保留在 Dart 原始键名与 Rust 原始 cookie 上，补首尾控制字符负例，不用规范化隐藏坏输入。最终 Rust `.probe/pan-login-ux-rust-final-control-green-20261104.result.json` 为 exit 0，4 通过 / 0 失败。
- QR 弹窗内部网页替代路径的双击锁、状态刷新 15 秒上限及首尾控制字符 Dart 负例是追加后的源码边界；设置页 3 项并发 GREEN 不作为这些路径已独立回放的证据，最终联合与原生视觉仍由主线覆盖。
- 范围内静态分析 `.probe/pan-login-ux-analyze-late-20261104.stdout.log` 与 `.probe/pan-login-ux-analyze-sealed-20261104.stdout.log` 均无问题；最终冻结工作树的结果以 `.probe/pan-login-ux-analyze-frozen-20261104.stdout.log` 为准。保留的旧 115 测试在 E1 之外有既有 `unnecessary_string_interpolations` 提示，不为求全目录零提示扩大授权修改。
- 独立笔记三门禁使用 `.probe/pancheck-final-notes-gates-20261104.ps1`。初版与 v2 留档均三项 exit 0；最终结果以全新 `.probe/pan-login-ux-final-notes-v3-20261104/result.json` 为准。

Root 最终审查补修：pending 阶段重新检测会取消旧 90 秒截止计时器，
确保新周期不被旧计时器提前终止。新增第 15 项会话门禁先实际 14 通过 / 1 失败，
修复后十文件联合 `.probe/playback-ux-pan-login-joint-green2-20261104/summary.json`
为 99 通过 / 0 失败，child 和 runner 均 exit 0。无凭据来源的旧门禁现在等待
15 秒请求截止并继续断言错误态不冒充已登录；QR 来源旧门禁严格检查新增
网页忙锁与原 Runtime 判据。首次联合的两条旧测试失败保留，不算整体绿。
这批回归仍未操作原生登录窗口或证明远端账号有效。
