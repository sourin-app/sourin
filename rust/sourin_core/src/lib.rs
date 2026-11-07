// ═══════════════════════════════════════════════════════════════════════
//  源影核心 —— lib 入口（脱离 Tauri 的验证）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一步在验证什么
//
// 「复用 81% 代码」这条硬指标，成败取决于一件事：
// **这些模块能不能脱离 Tauri 编译？**
//
// 如果能 → Flutter 只写 UI，业务层原样复用
// 如果不能 → 要么大改业务层，要么放弃复用
//
// # 为什么先只声明模块、不写逻辑
//
// 这一步只要**编译通过**就证明了：
// ```text
// ① 模块之间没有循环依赖
// ② 没有隐藏的 Tauri 类型渗透到公开签名里
// ③ 依赖清单是完整且自洽的
// ```
// 逻辑封装（FFI 函数）是下一步的事 —— 那要等 UI 端确定需要哪些接口。

#![allow(dead_code)]
#![allow(unused_imports)]
#![allow(clippy::too_many_arguments)]

// ── 数据模型 ──
pub mod model;

/// 重新导出 —— sync/mod.rs 里写的是 crate::PersistedProvider，
/// 抽核心时它从 lib.rs 搬到了 model.rs，这里保持旧路径可用。
pub use model::PersistedProvider;

// ── 内容源 ──
pub mod provider;
pub mod registry;
pub mod providers;

// ── 存储 ──
pub mod store;
pub mod library_covers;
pub mod source_discovery;

// ── 域名池（插件给候选、宿主选路）──
pub mod hostpool;

// ── 网络 ──
pub mod proxy;
pub mod streamproxy;

// ── 文件日志直写器（log 门面无 sink，文件日志唯一 crate 级入口；见 applog.rs 头）──
pub mod applog;

// ── 功能 ──
pub mod follow;
pub mod backup;
pub mod sync;

// ── 插件引擎 ──
pub mod plugins;

// ── 源个性化覆盖层（二次编排 / 劫持）──
//
// 挂在 `plugins::PluginProvider::call_js` 取出 `data` 之后、`js_value_to_rust` 之前。
// 设计见 .agents/notes/proposed/architecture/2026-10-24-source-override-layer-after-call-js.md
pub mod overrides;

// ── 局域网遥控 ──
pub mod remote;

// ── 应用状态与启动 ──
//
// 从 Tauri 的 lib.rs 搬过来：AppState 定义 + bootstrap 流程 +
// 数据目录迁移。这是「搬 90 个命令」的前置条件。
pub mod state;

// ── 清单持久化 ──
pub mod persist;

// ── 参数解码（契约的唯一所有者）──
//
// 起因见 .trellis/spec/guides/cross-layer-thinking-guide.md 的 Mistake 4：
// 每个命令各自解析 JSON 字段 = 每个消费者一份私有契约。
pub mod args;

/// m3u / txt 直播播放列表解析（TVBox lives[] 导入的前置能力）
pub mod m3u;
/// HLS 清单的客观结构判定（不靠时长阈值，读清单自身的 DISCONTINUITY/ENDLIST 标记）
pub mod hls_facts;

/// 网盘分享链接识别（网盘能力的第一个跳）
pub mod pan;
pub mod pan_check;
pub mod pan_list;

/// 网盘登录凭据管理（系统钥匙串，cookie 不落盘）
pub mod pan_auth;

/// 网盘**扫码登录**协议层（R3-C B1：拿 token → 出码 → 轮询 → 换 cookie）
///
/// 与 `pan_auth` 分工：那个是与协议无关的凭据仓库（存/取/清），
/// 各家的端点/UA/Referer 差异归这里。
pub mod pan_login;

/// OAuth **设备码**（device flow）那一族网盘的扫码登录：光鸭 / 迅雷
///
/// 与 `pan_login` 分开放的理由：它们不是"把 token 拼进固定 URL 出码"，
/// 而是"服务端给 verification_uri_complete，用户拿手机扫/输码"，
/// 会话状态、轮询端点、凭据形态都与 CAS/passport 族不同（见该文件头）。
pub mod pan_login_device;

/// 天翼云盘（`PanKind::Tianyi`）的扫码登录：logbox 的 uuid 扫码（三跳 + 轮询）
///
/// 与 `pan_login` 分开放的理由：它的"二维码内容"是**本地拼出来的**
/// （`URLDecoder.decode(getUUID.do 的 encodeuuid)`），不是服务端给的 QR；
/// 且准备会话那一步必须**关闭重定向**读 `Location`（与所有其它家的形状都不同）。
pub mod pan_login_tianyi;
pub mod provider_migration;

/// 真网络度量探针（`#[ignore]`，只在手动跑时联网）：搜一个词到底出多少条
#[cfg(test)]
mod live_search_probe;

// ── 详情与播放链路 ──
pub mod playback;

// ── 首页链路 ──
pub mod home;

// ── 命令实现 ──
//
// 从 Tauri lib.rs 搬来的业务逻辑。签名从 	auri::State<'_, AppState>改为 &AppState，函数体不动。
pub mod commands;
pub mod commands_write;
pub mod commands_provider;
pub mod commands_backup;
pub mod commands_remote;

// ── TVBox 配置导入（task-5）──
//
// 把 TVBox 配置里的苹果CMS 站点就地转成原生 Provider。
// 为什么不生成 JS 插件：见 tvbox.rs 顶部说明。
pub mod tvbox;
pub mod tvbox_aggregate;

// ── ★ TVBox `csp_Xxx` 路由层（第19项）──
//
// 配置里 `type:3` + `api:"csp_Bili"` 的源，在原版 APK 里是 Android DEX jar
// 里的 Java 类。本仓**不嵌 JVM**（桌面端没有 DexClassLoader，且 DEX 是
// Android 专属），改为用 Rust 重写用得到的类：
// ```text
// api "csp_Bili" → 注册表键 "Bili" → csp::bili::Bili（真发上游接口）
// 没写的类       → 导入报告 skipped，reason "csp_X 尚未实现"
// ```
// 配置格式零改动。设计见 csp/mod.rs 顶部。
pub mod csp;

// ── ★ FFI 层（给 Flutter 用）──
//
// Flutter 与核心之间唯一的接口。设计说明（为什么是一个 JSON 入口、
// 内存怎么管、线程模型）见 ffi.rs 顶部。
pub mod ffi;

/// 最早的探针入口 —— 返回 `*const u8`
///
/// ⚠️ 新代码请用 `ffi::sourin_core_version()`（返回 `*const c_char`）。
///    这个保留是因为第一轮验证 FFI 链路时用过它，
///    删掉会让当时的验证记录对不上。功能上两者等价。
#[no_mangle]
pub extern "C" fn sourin_core_version_u8() -> *const u8 {
    // 静态字符串，生命周期是整个进程，返回裸指针是安全的
    static V: &[u8] = b"sourin-core 0.1.0\0";
    V.as_ptr()
}

pub mod pan_login_123;
