// ═══════════════════════════════════════════════════════════════════════
//  应用状态与启动 —— 从 Tauri 层搬过来的（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件解决什么问题
//
// `ffi.rs` 里的 `dispatch_inner` 目前只接了 `ping`，因为 90 个命令
// 都依赖 `AppState`，而 `AppState` 原来定义在 Tauri 的 `lib.rs` 里。
//
// 所以「搬命令」这件事的**前置条件**是：先把 `AppState` 和它的
// 构造流程搬过来。本文件就是这一步。
//
// # 与原版的差异（有意为之，逐条说明）
//
// | 原版（lib.rs） | 这里 | 为什么 |
// |---|---|---|
// | `app.path().app_data_dir()` | 调用方传 `data_dir` | 核心层不该知道 Tauri 的路径 API |
// | `tauri::async_runtime::spawn` | `tokio::spawn` | 等价替换 |
// | `log::info!` | 保留 | 核心层可以直接用 log |
// | `app.manage(state)` | 返回 `Arc<AppState>` | 由 FFI 层持有 |
//
// # 保留的关键设计（不能丢的）
//
// ## ① 数据目录迁移
//
// 原版在 identifier 从 `com.dsh.mediaclient` 改成 `app.sourin.player`
// 时做了迁移。**Flutter 版的 identifier 会再变一次**，所以这段必须留。
//
// 三个条件缺一不可（否则会覆盖用户数据）：
// ```text
// 1. 新目录没有数据库   （说明是全新安装）
// 2. 旧目录有数据库     （说明确实是老用户升级）
// 3. 旧目录 != 新目录   （避免自己搬自己）
// ```
// 而且是**复制不是移动** —— 保留旧目录，出问题能退回去。
//
// ## ② 零内置 Provider
//
// Owner 明确要求：「零内置插件，srcl 和某动画站都是外置的，
// 我要能看到代码怎么写的」。所以核心**不注册任何内置源**，
// 全部由 `plugins/*.js` 提供。

use std::sync::atomic::{AtomicBool, AtomicI64};
use std::sync::{Arc, RwLock};

use crate::model::PersistedProvider;
use crate::proxy::ProxyStore;
use crate::registry::Registry;
use crate::remote::RemoteHub;
use crate::store::Db;
use crate::streamproxy::StreamProxy;
use crate::sync::SyncEngine;

/// 应用全局状态
///
/// # 与原版的唯一差异
///
/// 原版是 `pub struct AppState`（在 Tauri 的 lib.rs 里）。
/// 这里原样搬过来，字段一个不少 —— 因为 90 个命令都依赖它们。
pub struct AppState {
    pub registry: Arc<Registry>,
    pub db: Arc<Db>,
    /// ★ 站点级代理（按 Provider 配置）
    pub proxy: Arc<ProxyStore>,
    /// ★ 当前同步引擎（未配置云盘时为 None）
    pub sync: tokio::sync::RwLock<Option<Arc<SyncEngine>>>,
    /// 本机标识（写进远端 manifest，便于诊断）
    pub device_id: String,
    /// 应用数据目录（持久化第三方源清单用）
    pub data_dir: std::path::PathBuf,
    /// ★ 第三方源的**来源记录**（声明式 JSON / HTTP 基址），用于重启后重建
    pub third_party: RwLock<Vec<PersistedProvider>>,
    /// ★ 局域网遥控的共享状态（手机遥控 TV/客户端）
    pub remote: Arc<RemoteHub>,
    /// ★ 本地流代理（给「播放需要自定义请求头」的流用，如 外部视频站的 Referer）
    pub stream_proxy: Arc<StreamProxy>,
    /// ★ 内容源配置的最后修改时间（毫秒）—— 云同步的 LWW 判据
    ///
    /// 每次导入 / 编辑 / 移除源时刷新。**必须由所有写路径维护**，
    /// 漏掉任何一处都会导致「本机明明改了，同步却判远端更新」
    /// （表现为：改完同步一次又被打回旧配置）。
    pub providers_updated_at: AtomicI64,
    /// ★ 自动同步循环是否已起（幂等守卫，契约 §6，2026-09-29 task-75）
    ///
    /// # 为什么需要它
    ///
    /// 起循环的地方**有两处**（都是合理的）：
    /// ```text
    /// ① bootstrap 从 sync-settings.json 恢复出引擎之后
    /// ② 用户在设置页配好云盘（configure_webdav）之后
    /// ```
    /// 没有守卫就会起**两个**循环 ⇒ 每分钟同步两次、整包备份两份。
    /// 对外的表现就是「云端齐齐地多一倍备份」，而用户根本不会知道为什么。
    ///
    /// ⚠️ 用 `compare_exchange` 而不是 load-then-store：两个调用点
    ///    有可能并发（用户配好云盘的同时 bootstrap 还在跑）。
    pub auto_loop_started: AtomicBool,
}

impl AppState {
    /// 启动核心
    ///
    /// # 参数
    ///
    /// `data_dir` —— 应用数据目录。**由调用方决定**，
    /// 因为核心层不该知道 Tauri / Flutter 各自的路径 API：
    /// ```text
    /// Tauri   → app.path().app_data_dir()
    /// Flutter → path_provider 的 getApplicationSupportDirectory()
    /// Android → /data/data/<pkg>/files/
    /// ```
    ///
    /// # 与原版 setup 的对应关系
    ///
    /// 原版 `lib.rs:3643-4238` 做的事，这里一一对应：
    /// ```text
    /// migrate_from_legacy_dir(&data_dir)   数据目录迁移
    /// create_dir_all(&data_dir)            确保目录存在
    /// load_or_create_device_id(&data_dir)  本机标识
    /// Db::open(&db_path)                   打开数据库
    /// Registry::new()                      建源注册表
    /// ProxyStore::new()                    建代理存储
    /// AppState { .. }                      组装
    /// ```
    ///
    /// ⚠️ **不注册任何内置 Provider** —— 见文件顶部说明。
    pub async fn bootstrap(data_dir: std::path::PathBuf) -> Result<Arc<Self>, String> {
        log::info!("核心启动，数据目录: {}", data_dir.display());

        // ① 从旧 identifier 目录迁移（只在「新空旧有」时发生）
        migrate_from_legacy_dir(&data_dir);

        // ② 确保目录存在
        std::fs::create_dir_all(&data_dir)
            .map_err(|e| format!("建数据目录失败 {}: {e}", data_dir.display()))?;

        // ③ 本机标识
        let device_id = load_or_create_device_id(&data_dir);

        // ④ 数据库（打开失败回退内存库 —— 与原版一致）
        let db_path = data_dir.join("dsh-media.db");
        let db = Db::open(&db_path).unwrap_or_else(|e| {
            log::error!("打开数据库失败 {db_path:?}: {e}，回退到内存库");
            Db::in_memory().expect("内存库也失败")
        });

        // ⑤ 源注册表（空 —— 源全部由 JS 插件提供）
        let registry = Registry::new();
        log::info!("内置 Provider 已清空（源改由 plugins/ 下的 JS 插件提供）");

        // ⑥ 站点代理
        let proxy = Arc::new(ProxyStore::new());

        /*
         * ⑦ ★ 加载 JS 插件（**这一步决定了界面上有没有源**）
         *
         * 源：原版 `lib.rs:3762-3777`
         *
         * # 三个必须做的动作（缺一个用户就看不到源）
         *
         * ```text
         * 1. seed_demo_plugin   首次启动释放 demo.js（默认停用）
         * 2. 扫描插件目录        加载所有 .js
         * 3. 应用停用状态        ★ 必须在【注册完之后】——
         *                       早于注册的话，注册会把 enabled 重置回 true
         * ```
         *
         * # 为什么这里 await 是合理的
         *
         * 读插件的能力位要执行脚本（async）。但插件只有个位数，
         * 每个约 0.2ms，总开销可忽略 —— 换来「注册时能力位就是准的」。
         * 原版注释里明确权衡过这一点（它用 block_on 是因为 setup 是同步回调；
         * 我们本身就是 async，直接 await 即可，**不需要 block_on**）。
         */
        let plugin_dir = plugins_dir(&data_dir);
        seed_demo_plugin(&data_dir);
        /*
         * ★★★ 清理历史遗留的「某旧版直播插件」文件（迁移，task-34/48 时代的遗留）
         *
         * 必须在 `load_plugins_hydrated` **之前** —— 否则这一次启动仍会
         * 扫到那个旧文件并注册它（扫描器的判据是"扩展名是 .js 就加载"），
         * 与用户自己的插件重复注册，**没有任何报错**。
         *
         * ⚠️ 架构口径（Owner 逐字）：客户端只提供**视频播放能力**；
         *    具体的视频网站由用户的**本地插件**提供，不进仓库。
         *    ⇒ 我们**不再**随程序释放任何"某个具体网站"的插件，
         *       只保留这里"清理老用户机器上残留的旧版文件"这一步 ——
         *       删掉它对老用户仍是**正确**的（避免重复注册）。
         *    理由与"为什么改名不够 / 为什么无条件删"见 `remove_legacy_live_plugin` 的注释。
         */
        remove_legacy_live_plugin(&data_dir);
        let (js_plugins, js_bad) =
            crate::plugins::load_plugins_hydrated(&plugin_dir, Some(proxy.clone())).await;
        let js_count = js_plugins.len();
        for p in js_plugins {
            registry.register(Arc::new(p));
        }
        if js_count > 0 {
            log::info!("已注册 {js_count} 个 JS 插件");
        }
        for (f, why) in &js_bad {
            // 坏插件不能拖垮启动，但要让用户知道是哪个文件有问题
            log::warn!("插件 {f} 加载失败: {why}");
        }

        let registry = Arc::new(registry);

        /*
         * ⑦-b ★★ 恢复第三方源 —— **重建 provider 实例并注册**
         *
         * 来源：原版 `lib.rs:3716-3749`
         *
         * # 这一步修的是一个「跨任务级真 bug」：导入的源重启后从界面消失
         *
         * 原来的代码只做了 `load_persisted()`，把清单塞进 `AppState.third_party`
         * 就完了 —— 而 `registry.manifests()`（`registry.rs:106`）只遍历
         * `self.providers`，`third_party` 是**另一个字段**，两者之间没有桥。
         *
         * 症状：
         * ```text
         * · 文件还在磁盘上（third-party-providers.json）
         * · 但列表里没有、删不掉、也点不到「编辑」
         * · 启动日志自相矛盾：
         *     [SHELL] 核心已启动: {providers: 26, thirdPartyProviders: 2}
         *     [HOME]  listProviders → 26 个     ← 那 2 个没进 registry
         * ```
         * 所以「读清单」和「把清单变成活的 provider」是**两件事**，
         * 缺了后者用户就看不到源。
         *
         * # ★ 为什么必须在这里（⑧ 之前）
         *
         * 注册会把 handle 的 `enabled` 重置回 true —— 见 ⑧ 的注释。
         * 所以「注册」必须早于「应用停用状态」，否则用户上次停用的源
         * 又会自己「活」过来。
         *
         * # ★ 隔离失败（约束①）
         *
         * 单个源坏了只 `log::warn!` 跳过，**不能拖垮其它源**：
         * 第三条源坏了不该让第四条也恢复不了，更不该让应用起不来。
         *
         * # ★ 声明式源同步重建、HTTP 源异步重连
         *
         * 原版注释（`lib.rs:3721-3724`）：
         * > HTTP 源的恢复需要网络（要重新握手），而 `setup` 是**同步**回调，
         * > 不能 await —— 故：声明式源在这里同步重建（纯解析，无需网络），
         * > HTTP 源放到 `setup` 之后的后台任务里异步重连
         *
         * ⚠️ 我们的 `bootstrap` 本来就是 async（不需要原版那个 workaround），
         *    但**照样不能直接 await**：一个连不上的 HTTP 源会让启动卡住
         *    （reqwest 超时 + 逐个串行 = 启动白屏）。
         *    所以 HTTP 源仍然走后台 spawn（见 ⑪），并且在里面再套
         *    `tokio::time::timeout` 兜住「服务没起但在黑洞地址上挂着」的情况。
         */
        let persisted = crate::persist::load_persisted(&data_dir);
        log::info!("恢复 {} 个持久化的第三方源", persisted.len());

        // HTTP 源待重连清单：id / base_url / headers（同步阶段收集，后台阶段使用）
        let mut http_to_restore: Vec<(String, String, std::collections::HashMap<String, String>)> =
            Vec::new();
        // ★ 恢复失败的源（第19项：csp 未实现类等）——
        //   除了 warn，还落盘到 data_dir/restore-failures.json，供界面/排查查询。
        let mut restore_failures: Vec<crate::persist::RestoreFailure> = Vec::new();
        let mut ok = 0usize;
        for item in &persisted {
            match item {
                PersistedProvider::Declarative { id, json } => {
                    match crate::providers::DeclarativeProvider::from_json(json)
                        .map(|p| p.with_data_dir(data_dir.clone()))
                    {
                        Ok(p) => {
                            registry.register(Arc::new(p));
                            ok += 1;
                        }
                        // 单个源失败只跳过它自己 —— 不影响其余源与内置插件
                        Err(e) => {
                            log::warn!("声明式源 {id} 恢复失败（已跳过）: {}", e.message)
                        }
                    }
                }
                PersistedProvider::Http {
                    id,
                    base_url,
                    headers,
                } => {
                    http_to_restore.push((id.clone(), base_url.clone(), headers.clone()));
                }
                // m3u/txt 播放列表直播源：纯 HTTP，同步重建即可（不联网）
                PersistedProvider::M3uLive { id, name, url } => {
                    let p = crate::providers::m3u_live::M3uLiveProvider::new(name, url);
                    registry.register(Arc::new(p));
                    let _ = id;
                    ok += 1;
                }
                // TVBox 源是纯 HTTP 协议，不需要握手 → 同步重建即可，
                // 分类表在导入时已探测并持久化，这里不再联网。
                PersistedProvider::Tvbox {
                    id,
                    name,
                    api,
                    categories,
                    parsers,
                    ext,
                } => {
                    /*
                     * ★★★ 第19项收口：`csp_Xxx` 必须走 **csp 路由**，不许走苹果CMS
                     *
                     * # 为什么这里要分支（改前是单一路径）
                     * csp 源的 api 是 `"csp_Bili"`（不是 URL）：
                     * ```text
                     * TvboxAppleCmsProvider::new("csp_Bili") → Err("接口地址不是 http(s)")
                     * ⇒ 用户重启后源消失，且日志只有一句"恢复失败"
                     * ```
                     * 现在按 api 形态分流：
                     * ```text
                     * csp_Xxx → csp::provider::CspProvider::new(id, name, api, ext, categories)
                     * 其余    → TvboxAppleCmsProvider::new(...)（原行为一字未改）
                     * ```
                     *
                     * # 未实现的类：如实降级，不静默、不 panic、不连坐
                     * ```text
                     * · 落一条 warn（含类名与原因）
                     * · 记进 restore_failures ⇒ 写入 data_dir/restore-failures.json（可查询）
                     * · **只跳过这一条**：其余源照常恢复
                     * ```
                     * 为什么不做成 panic 或整体失败：一条旧配置里的坏类
                     * 不该让用户所有源都起不来（那正是本文件反复强调的
                     * "单个源失败只跳过它自己"）。
                     */
                    if crate::csp::is_csp(api) {
                        let ext_text = ext.as_deref().unwrap_or("");
                        match crate::csp::provider::CspProvider::new(
                            id.clone(),
                            name.clone(),
                            api,
                            ext_text,
                            categories.clone(),
                        ) {
                            Ok(p) => {
                                registry.register(Arc::new(p));
                                ok += 1;
                            }
                            Err(e) => {
                                log::warn!(
                                    "csp 源 {id}（{api}）恢复失败（已跳过，其余源不受影响）: {e}"
                                );
                                restore_failures.push(crate::persist::RestoreFailure {
                                    id: id.clone(),
                                    api: api.clone(),
                                    reason: e,
                                });
                            }
                        }
                    } else {
                        match crate::tvbox::TvboxAppleCmsProvider::new(
                            id.clone(),
                            name.clone(),
                            api,
                            categories.clone(),
                        ) {
                            Ok(p) => {
                                registry.register(Arc::new(
                                    p.with_proxy(proxy.clone())
                                        .with_parsers(parsers.clone()),
                                ));
                                ok += 1;
                            }
                            // 单个源失败只跳过它自己 —— 不影响其余源与内置插件
                            Err(e) => log::warn!("TVBox 源 {id} 恢复失败（已跳过）: {e}"),
                        }
                    }
                }
            }
        }
        if ok > 0 {
            log::info!("已同步恢复 {ok} 个第三方源");
        }
        /*
         * ★ 把"哪些源没恢复起来 + 为什么"写出去（可查询）
         *
         * 为什么不是只打 warn 就完：日志用户看不到，而"我明明导入过的源
         * 重启后没了"是必须能自查的事。写失败**不影响启动**（只是少一份报告）。
         */
        /*
         * ★ 必须**无条件**调用（不能套 `if !restore_failures.is_empty()`）。
         *
         * 套了守卫的后果：上一次留下的失败报告，在"这次全部恢复成功"时
         * **永远不会被删** —— 用户修好之后仍旧看到一条陈旧告警，
         * 而陈旧告警比没有告警更误导。空列表由 `write_restore_failures`
         * 自己翻译成"删文件"（见 persist.rs 的同名函数）。
         */
        if let Err(e) = crate::persist::write_restore_failures(&data_dir, &restore_failures) {
            log::warn!("写 restore-failures.json 失败（不影响启动）: {e}");
        }

        /*
         * ★ TVBox 聚合源（A′，第 01 项）：把已启用子站聚成**一个**条目。
         *
         * 子站自己 `hidden: true`（列表不展示），但仍留在 registry 里
         * ⇒ `provider:native` 路由不变 ⇒ 收藏/进度/弹幕绑定零迁移。
         *
         * ⚠️ **幂等**：bootstrap 可能被调用多次（测试、开发者热重启）。
         *    重复 `register` 同 id 会让清单里出现两条、`list_providers` 重复，
         *    所以先按 id 查一次，已存在就跳过（**绝不 panic**）。
         */
        if registry.get(crate::tvbox_aggregate::AGGREGATE_ID).is_none() {
            registry.register(std::sync::Arc::new(
                crate::tvbox_aggregate::TvboxAggregate::new(
                    registry.clone(),
                    data_dir.clone(),
                ),
            ));
        }

        /*
         * ⑧ 应用「停用」状态 —— ★ 必须在所有源注册完之后
         *
         * 顺序错了的后果：注册会把 `enabled` 重置回 true，
         * 用户上次停用的源又「活」了。
         */
        let disabled = crate::commands::load_disabled(&data_dir);
        let mut restored = 0usize;
        for id in &disabled {
            if registry.set_enabled(id, false) {
                restored += 1;
            }
        }
        if restored > 0 {
            log::info!("已恢复 {restored} 个源的停用状态");
        }

        /*
         * ⑨ 应用用户保存的源顺序（**同步阶段这一次**）
         *
         * 来源：原版 `lib.rs:4204-4221`。放在这里（所有**同步**注册都完成
         * 之后 —— 声明式源在上面、JS 插件在 ⑦）：
         *
         * ⚠️ 注册是「追加」语义，边注册边排序会被后来的注册打乱，
         *    所以排序必须等到注册结束。
         * ⚠️ 后台异步注册的 HTTP 源赶不上这一次 ——
         *    那边注册完会**自己再排一次**（见 ⑪），否则用户特意排在前面的
         *    HTTP 源会被"追加"到末尾。
         */
        {
            let saved = crate::commands::load_order(&data_dir);
            if !saved.is_empty() {
                let actual = registry.reorder(&saved);
                log::info!("已恢复源顺序（{} 项）", actual.len());
            }
        }

        // ⑩ 组装
        //
        // ⚠️ 组装会把 `registry` / `proxy` / `data_dir` move 进 state，
        //    而 ⑪ 的后台任务还要用它们 —— 所以先留一份 clone（Arc 很便宜）。
        let registry_for_http = registry.clone();
        let proxy_for_http = proxy.clone();
        let dir_for_http = data_dir.clone();
        let http_pending = http_to_restore.len();

        let state = Arc::new(Self {
            registry,
            db: Arc::new(db),
            proxy,
            sync: tokio::sync::RwLock::new(None),
            device_id,
            data_dir: data_dir.clone(),
            third_party: RwLock::new(persisted),
            remote: Arc::new(RemoteHub::new()),
            stream_proxy: Arc::new(StreamProxy::new()),
            // 启动时以「现在」为基线：本地磁盘上的配置就是本机当前状态，
            // 若云端更新，下一次同步会正确地采用云端那份
            providers_updated_at: AtomicI64::new(chrono::Utc::now().timestamp_millis()),
            // 循环尚未起（下面 ③ 才决定要不要起）
            auto_loop_started: AtomicBool::new(false),
        });

        /*
         * ⑪ ★ 后台重连 HTTP 源（**不阻塞启动**）
         *
         * 来源：原版 `lib.rs:4240-4279`
         *
         * # 三个约束在这里同时被满足
         *
         * ```text
         * ② 不阻塞启动 —— spawn 到后台，失败只 warn。
         *                再加上 tokio::time::timeout 兜住「黑洞地址」
         *                （reqwest 默认超时可能很长）
         * ③ 顺序排第二次 —— 同步阶段的 apply_saved_order 只管得到
         *                声明式源与插件；HTTP 源是这里异步注册的，
         *                如果不再排一次，它们会被"追加"到末尾 ——
         *                而用户可能特意把某个 HTTP 源排在前面
         * ④ 停用状态再应用一次 —— HTTP 源是在 ⑧ 之后才注册进来的，
         *                否则「用户停用过的 HTTP 源」重启后会自己活过来
         * ```
         */
        if http_pending > 0 {
            log::info!("后台重连 {http_pending} 个 HTTP 源（不阻塞启动）");
            tokio::spawn(async move {
                let mut done = 0usize;
                for (id, base, headers) in http_to_restore {
                    let spec = crate::providers::http::HttpProviderSpec {
                        base: base.clone(),
                        headers,
                    };
                    // 单个 HTTP 源最多等 8 秒 —— 超时只跳过它自己
                    let r = match tokio::time::timeout(
                        std::time::Duration::from_secs(8),
                        crate::providers::HttpProvider::connect(spec),
                    )
                    .await
                    {
                        Ok(inner) => inner,
                        Err(_) => {
                            log::warn!("HTTP 源 {id} 重连超时（8 秒，已跳过）: {base}");
                            continue;
                        }
                    };
                    match r {
                        Ok(p) => {
                            /*
                             * ★★★ 2026-10-14（CR #27）：**不许 HTTP 源顶掉本地插件**
                             *
                             * # 缺陷（CR 指出，属实）
                             * ```text
                             * `Registry::register` 对**同 id** 是"先删旧的再插新的"
                             * （registry.rs:29-30，那是有意的热重载机制）。
                             * 而 HTTP 源的 id 来自**远端 manifest** ⇒
                             * 一个声明了已存在本地插件 id 的远端源，会**静默替换**它。
                             * ⇒ 用户的本地插件被远端悄悄换掉（数据/行为都可能变），
                             *   且**没有任何提示**。
                             * ```
                             * # 修法：同 id 已被**非 HTTP 源**（插件/声明式）占用 ⇒ 拒绝
                             * ```text
                             * 判据用"注册表里同 id 那个是不是也是 http kind"：
                             *   · 是 http（重连同 id 的 HTTP 源）⇒ 照常覆盖（热重载语义）
                             *   · 不是 http（插件/声明式）⇒ **拒绝 + 明确 warn**，
                             *     不顶掉别人的源。
                             * ⚠️ 不用 `.expect()` panic —— 隔离失败（只这一个源不可用）。
                             * ```
                             */
                            // ⚠️ 用循环里的 `id`（= 该 HTTP 源的 manifest id，
                            //   走到这里必然与它一致）—— `HttpProvider` 的
                            //   `manifest` 是**私有字段**，没有公开 getter。
                            let pid = id.clone();
                            let clash = registry_for_http
                                .get(&pid)
                                .map(|e| e.manifest().kind.clone());
                            if let Some(kind) = clash {
                                if kind != "http" {
                                    log::warn!(
                                        "★ 拒绝 HTTP 源 {pid}：本地已有一个同 id 的 {kind} 源 \
                                         —— 远端 manifest 不得顶掉本地源"
                                    );
                                    eprintln!(
                                        "[HTTP] ★ 拒绝 HTTP 源 {pid}（与本地 {kind} 源撞 id）"
                                    );
                                    continue;
                                }
                            }
                            registry_for_http
                                .register(Arc::new(p.with_proxy(proxy_for_http.clone())));
                            done += 1;
                        }
                        // ★ 隔离失败：服务没起只是这个源不可用，不影响其它源
                        Err(e) => log::warn!(
                            "HTTP 源 {id} 重连失败（服务可能未启动，已跳过）: {}",
                            e.message
                        ),
                    }
                }
                log::info!("已异步恢复 {done}/{http_pending} 个 HTTP 源");

                /*
                 * ★ 顺序要在 HTTP 源也恢复完之后再应用一次
                 *
                 * 同步阶段的 `apply_saved_order` 只管得到声明式源与插件；
                 * HTTP 源是这里异步注册的，如果不再排一次，
                 * 它们会被"追加"到末尾 —— 而用户可能特意把某个 HTTP 源排在前面。
                 */
                let saved = crate::commands::load_order(&dir_for_http);
                if !saved.is_empty() {
                    registry_for_http.reorder(&saved);
                }

                /*
                 * ★ 停用状态补一次
                 *
                 * 上面的 ⑧ 只能管到「那时已注册」的源。HTTP 源是此刻才进
                 * registry 的，当时 `set_enabled(id, false)` 找不到它 →
                 * 用户停用过的 HTTP 源重启后又会「活」过来。
                 * 注册完补一次即可（读文件是唯一真相，与 list_providers 一致）。
                 */
                for id in crate::commands::load_disabled(&dir_for_http) {
                    registry_for_http.set_enabled(&id, false);
                }
            });
        }

        /*
         * ══════════════════════════════════════════════════════════════
         * ⑫ ★★ 局域网遥控：**开机自启**（2026-09-25 修）
         * ══════════════════════════════════════════════════════════════
         *
         * # 用户原话
         *
         * > **我要只要这个软件打开了,这个遥控就能用**
         *
         * # 修之前是什么状态（移植时漏了这一段）
         *
         * ```text
         * RemotePref::default().auto_start = true   ← 抄对了 ✅
         * 但**没有任何执行点** —— spawn_remote_server 只被
         * commands_remote::remote_start（设置页那个按钮）调用
         * ⇒ 每次启动应用，遥控都是"没开"的，用户必须进设置页点一下
         * ```
         * 原版 `src-tauri/src/lib.rs:3834` 是这么写的：
         * ```rust
         * if remote_pref.auto_start { tauri::async_runtime::spawn(...) }
         * ```
         * ——**开机就起**。我们移植时把偏好读回来了、却没拿它做事。
         *
         * # 为什么放在 `bootstrap` 末尾（而不是别处）
         *
         * `bootstrap` 正是"宿主启动核心"的那一步（`ffi.rs` 的
         * `sourin_start` 调它），与原版放在 `lib.rs` 的 setup 里同层。
         * 放在这里，Dart 侧**不需要**额外记得调什么（少一个隐式契约）。
         *
         * # 三条约束
         *
         * ```text
         * ① 不阻塞启动 —— spawn 到后台（与原版一致）。
         *    端口探测是 async 的，失败只记日志 ——
         *    遥控起不来**不该**让用户开不了程序。
         * ② 尊重用户意愿 —— 只读 auto_start；用户在界面关掉后
         *    它被置 false（见 remote_stop），下次就**不再**自动开。
         *    每次又拉起来比不默认开更烦人。
         * ③ 幂等 —— remote_start 里已有 is_running 早退；
         *    这里再判一次，避免与"用户手动开"撞车。
         * ```
         */
        let remote_pref = crate::commands_remote::load_remote_pref(&state.data_dir);

        /*
         * ★ 固定配对码要在**启动服务之前**恢复
         *
         * 原版 `lib.rs:3824-3832` 就是这么做的，注释写明了原因：
         * > 必须在建 hub 之后、启动服务之前 —— 否则开机后有一小段时间
         * > 固定码不生效（用户输了码却被拒，很困惑）。
         *
         * ⚠️ 我们之前**也漏了这一步**：`remote_set_fixed_pin` 会把码写进
         *    `remote-pref.json`，但重启后没人读回来 ——
         *    表现为"设了固定码，重启后手机连不上，得再进一次设置页"。
         */
        if let Some(fp) = remote_pref.fixed_pin.as_ref() {
            // 顺手校验一次：文件可能被手改坏（比如塞了字母）
            match crate::remote::validate_fixed_pin(fp) {
                Ok(ok) => {
                    state.remote.set_fixed_pin(Some(ok));
                    log::info!("已恢复固定配对码（随机码仍然有效）");
                }
                Err(e) => log::warn!("偏好文件里的固定配对码不合法，已忽略: {e}"),
            }
        }

        /*
         * ★★ 测试/CI 的逃生阀（2026-09-24 实测踩到后加的）
         *
         * # 踩到了什么
         *
         * 自启生效后，**任何调用 `bootstrap` 的测试进程都会去绑 8642**：
         * ```text
         * flutter test  → flutter_tester.exe 起核心 → 绑住 8642
         * cargo test    → 每个集成测试的 bootstrap → 绑住 8642
         * ```
         * 后果：
         * ```text
         * ① 用户的应用若也在跑，双方抢同一个端口（一方只能打 warn）
         * ② 我的端到端验证被一个 peer 的 flutter test 挡住了好几分钟
         * ③ 测试之间可能互相干扰（并行跑时抢端口）
         * ```
         * 这不是自启的 bug（产品行为是对的），但**测试不该占产品端口**。
         *
         * # 用法
         *
         * ```text
         * SOURIN_NO_REMOTE_AUTOSTART=1   → 跳过自启（测试/CI 用）
         * ```
         * ⚠️ 默认**不设** ⇒ 生产行为完全不变（用户开机就能用遥控）。
         *    这是**显式 opt-out**，不是"猜环境"—— 不去嗅探
         *    `cfg!(test)` 或进程名，那些在生产里会误判。
         */
        let autostart_blocked = std::env::var("SOURIN_NO_REMOTE_AUTOSTART")
            .map(|v| !v.is_empty() && v != "0")
            .unwrap_or(false);

        if autostart_blocked {
            eprintln!("[REMOTE] 已按 SOURIN_NO_REMOTE_AUTOSTART 跳过自启（测试/CI 模式）");
        } else if remote_pref.auto_start {
            let hub = state.remote.clone();
            let port = remote_pref.port;

            /*
             * ★★★ 必须用 `eprintln!` 而不是只 `log::info!`（2026-09-24 实测教训）
             *
             * # 为什么（点 D —— 这是查不出问题的真正原因）
             *
             * 本 crate **从来没有初始化过 logger**：
             * ```text
             * grep env_logger|simplelog|set_logger|log::set_max_level  →  0 处
             * ```
             * 所以 `log::info!` / `log::warn!` 的宏体虽然执行了，
             * 消息却被**全部丢弃**（`log` crate 在没装 logger 时是 no-op）。
             *
             * 后果：我上一轮的自启代码**其实跑了**，但：
             * ```text
             * · 成功时看不到「遥控已随程序启动」
             * · 失败时看不到「遥控自启失败: 端口被占」
             * ⇒ 排查时**无法区分**"没执行"和"执行了但失败" ⇒ 白白绕远路
             * ```
             * `eprintln!` 走的是 stderr，**不受 logger 影响**，一定能看到。
             *
             * ⚠️ 保留 `log::info!` 是为了将来接了 logger 之后仍有结构化日志 ——
             *    两者并存，不互相替代。
             */
            eprintln!("[REMOTE] ★ 遥控开机自启：auto_start=true, 端口={port}，正在启动…");

            tokio::spawn(async move {
                match crate::commands_remote::spawn_remote_server(&hub, port).await {
                    Ok(()) => {
                        log::info!("遥控已随程序启动（端口 {port}）");
                        /*
                         * ★ 用 `hub.port()` 而不是闭包里的 `port` ——
                         *   `spawn_remote_server` 里 `set_port(port)` 写的是
                         *   它自己收到的那个值；两者理论上相同，但读 hub
                         *   才是**真正在监听的**那个端口（单一真相）。
                         */
                        let real = hub.port();
                        hub.set_autostart(Ok(real));
                        eprintln!(
                            "[REMOTE] ★ 遥控自启成功：{}",
                            crate::remote::remote_url(real)
                        );
                    }
                    Err(e) => {
                        log::warn!("遥控自启失败（不影响其它功能）: {e}");
                        /*
                         * ★★ 把失败**原因**存进 hub，让 UI/FFI 能查到
                         *
                         * 用户报的是「开了自启但没启动」—— 光有日志不够，
                         * 因为用户看不到 stderr。存进 hub 之后，
                         * 界面可以直接显示"端口被占用"这类**可操作**的原因。
                         *
                         * ⚠️ 注意 `e` 已经被 `format!` 成了给用户看的中文，
                         *    所以这里**原样**存（不再包一层"自启失败："）。
                         */
                        hub.set_autostart(Err(e.clone()));
                        /*
                         * ★ 日志分两行：第一行是**给用户看的结论**，
                         *   第二行是原始错误。这样 grep "自启" 就能看到
                         *   到底是"没跑"还是"跑了但端口被占"。
                         */
                        eprintln!("[REMOTE] ★ 遥控自启被跳过：{e}");
                        eprintln!("[REMOTE]   （遥控不影响其它功能；可在设置页换端口后手动开启）");
                    }
                }
            });
        } else {
            log::info!("遥控未自启（用户此前已关闭）");
            eprintln!("[REMOTE] 遥控未自启（用户此前已关闭，auto_start=false）");
        }

        /*
         * ③ ★ 从磁盘恢复云盘引擎，并起自动同步循环（契约 §3② / §6）
         *
         * # 修的是一个硬阻塞
         *
         * 改之前 `WebdavConfig` **只在内存**，于是：
         * ```text
         * 用户配好云盘 → 能用
         * 重启          → sync_status() 必然 connected:false
         *                 ⇒ 每次开机都要重新配一遍，自动备份无从谈起
         * ```
         *
         * # 三个必须遵守的约束
         *
         * ```text
         * ① 零网络请求 —— `WebdavBackend::new` 只做 URL 规范化，
         *              没有任何 I/O ⇒ 不会阻塞启动。
         *              （故意**不**调 `prepare()` / `test()`：那两个要联网）
         * ② 失败只 warn —— 云盘配错不该让用户开不了程序。
         * ③ 钥匙串里没密码就不恢复 —— 否则建出来的引擎没凭据，
         *              等到同步才报 401，用户看不懂。
         * ```
         */
        {
            let s = crate::sync::load_settings(&state.data_dir);
            if s.base_url.is_empty() || s.username.is_empty() {
                // 没配过（或已断开）—— 这是最常见的情形，不打日志
            } else {
                match crate::sync::webdav_credential::get("webdav") {
                    Some(pw) if !pw.is_empty() => {
                        let cfg = crate::sync::WebdavConfig {
                            base_url: s.base_url.clone(),
                            username: s.username.clone(),
                            password: pw,
                            remote_dir: s.remote_dir.clone(),
                        };
                        match crate::sync::SyncEngine::new_webdav(
                            cfg,
                            state.db.clone(),
                            state.device_id.clone(),
                        )
                        /* ★ 挂 data_dir —— 凭据平面要读 `<data_dir>/plugins/.data/` */
                        .map(|e| e.with_data_dir(state.data_dir.clone()))
                        {
                            Ok(engine) => {
                                *state.sync.write().await = Some(Arc::new(engine));
                                log::info!(
                                    "已从 sync-settings.json 恢复云盘配置（未做网络请求）: {}",
                                    s.base_url
                                );
                                // ★ 只要有引擎就起循环（开关判断在每一轮 tick 里）
                                crate::commands_backup::spawn_auto_sync(&state);
                            }
                            Err(e) => log::warn!(
                                "恢复云盘配置失败（不影响启动，可在设置页重新配）: {e}"
                            ),
                        }
                    }
                    _ => log::info!(
                        "有云盘地址但钥匙串里没密码，跳过自动恢复（重新配置时输入即可）"
                    ),
                }
            }
        }

        // 启动自检：registry 里的真实源数（含第三方）——
        // 就是 listProviders 会给前端的东西，便于与界面核对
        log::info!(
            "核心启动完成：registry 共 {} 个源（其中已同步恢复声明式源 {} 个，待异步重连 HTTP 源 {} 个）",
            state.registry.manifests().len(),
            ok,
            http_pending
        );
        Ok(state)
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  JS 插件目录
// ═══════════════════════════════════════════════════════════════════════

/// 插件目录（应用数据目录下的 `plugins/`）
///
/// 为什么放数据目录而不是程序目录：Owner 明确要求
/// 「我要能看到代码怎么写的」—— 放在用户能打开、能改、能自己写的位置。
pub fn plugins_dir(data_dir: &std::path::Path) -> std::path::PathBuf {
    data_dir.join("plugins")
}

/// 随程序发布的示例插件源码
///
/// ⚠️ 用 `include_str!` 编进二进制（而不是运行时读文件）——
///    这样即使用户把 exe 单独拷走，示例也还在。
const DEMO_PLUGIN_SRC: &str = include_str!("../plugins/demo.js");

/// 首次启动时把随程序发布的 demo 释放到插件目录（**默认停用**）
///
/// 只在**文件不存在**时写 —— 用户可能改过 demo 拿它当模板，
/// 不能每次启动都覆盖掉。想恢复原样删掉文件重启即可。
///
/// # ★ 为什么默认停用（Owner 要求）
///
/// 原话：「示例源默认应该关闭，不要打开，给人示例看就行了」
///
/// 它的定位是**给人看怎么写插件的模板**，不是一个内容源：
/// ```text
/// · 它返回的是假数据，混在首页里会让人以为"这个源怎么都是示例"
/// · 首页的源切换条会多出一个没有实际内容的项
/// · 真要用它当模板的人，会自己去插件目录看源码
/// ```
/// 所以：**装但不开**。用户想体验就在设置页手动启用。
///
/// # ⚠️ 一个已踩过的坑（原版注释里记录）
///
/// 第一版把停用逻辑写在「刚写完文件」的分支里，而 `demo.js`
/// 在旧版本就已经释放过了 → `path.exists()` 命中 → 直接 return
/// → **停用逻辑根本没执行**（实测 `enabled: true`）。
///
/// 所以两件事必须分开：文件该不该写是一回事，「默认停用」是另一回事。
fn seed_demo_plugin(data_dir: &std::path::Path) {
    let dir = plugins_dir(data_dir);
    let path = dir.join("demo.js");

    if path.exists() {
        // ★ 文件已存在也要确保停用状态（见上面那个坑）
        ensure_demo_disabled_once(data_dir);
        return;
    }
    if let Err(e) = std::fs::create_dir_all(&dir) {
        log::warn!("创建插件目录失败 {:?}: {e}", dir);
        return;
    }
    match std::fs::write(&path, DEMO_PLUGIN_SRC) {
        Ok(()) => {
            log::info!("已释放示例插件到 {:?}（默认停用）", path);
            ensure_demo_disabled_once(data_dir);
        }
        Err(e) => log::warn!("写入示例插件失败: {e}"),
    }
}

/// 把 demo 插件加入停用名单，**只做一次**
///
/// # 为什么需要「只做一次」的标记
///
/// 这个函数在每次启动时都会走到（见 `seed_demo_plugin`）。
/// 如果无条件写停用名单，用户**手动启用 demo 之后，下次启动又会被关掉** ——
/// 那就成了一个「用户改不了的设置」，比默认启用更糟。
///
/// 所以用一个一次性标记文件：写过一次就不再碰。
/// 用户之后想启用/停用，都完全由他自己决定。
fn ensure_demo_disabled_once(data_dir: &std::path::Path) {
    let marker = data_dir.join(".demo-seeded");
    if marker.exists() {
        return;
    }

    let mut list = crate::commands::load_disabled(data_dir);
    if !list.iter().any(|x| x == "demo") {
        list.push("demo".to_string());
        if let Err(e) = crate::commands::save_disabled(data_dir, &list) {
            log::warn!("写入示例插件的停用状态失败: {e}");
            // 写失败就不留标记，下次启动再试
            return;
        }
        log::info!("示例插件已默认停用（可在设置页手动启用）");
    }

    // 留标记：以后不再干预用户的选择
    if let Err(e) = std::fs::write(&marker, b"1") {
        log::warn!("写入 demo 标记失败（下次启动会再尝试停用一次）: {e}");
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  清理历史遗留的「旧版直播插件」文件（迁移）
// ═══════════════════════════════════════════════════════════════════════
//
// ★ 架构口径（Owner 逐字）：
// > 拆分成插件,只存在本地,并不发布到仓库…他们都是插件提供,
// > 我们是提供的视频播放能力,这个是重点,不要搞错了
// ⇒ 客户端只提供**视频播放能力**；具体的视频网站由用户的**本地插件**
//    提供，**不进仓库**。下面这个函数**不释放任何插件**，只负责
//    在启动时**删掉老用户机器上残留的旧版文件**，避免与用户的插件
//    **重复注册**（这在用户侧是好事，且与"仓库里不放具体网站"不冲突）。

/// 删除历史遗留的旧版直播插件的**残留文件**（一次性迁移，不是 seed）
///
/// # 它删什么
///
/// 旧版本里我们曾随程序释放过一个直播插件，其**文件名**与**插件 @id**
/// 相同（见下面代码里的字符串常量 —— 那是**真实的历史文件名，必须逐字
/// 保留**，否则匹配不到老用户机器上的旧文件）。
///
/// ⚠️ 现在那份"新版"插件**也已从仓库移除**（见上面的架构口径），
///    但**老用户的插件目录里可能还留着旧的残留文件** —— 它仍会被
///    扫描器加载并注册。所以这一步保留。
///
/// # 为什么改名**不够**（"文件已改名，为什么还要在老用户目录里删文件"）
///
/// 插件扫描器 `plugins/mod.rs::load_plugins` 的判据是
/// ★ **"扩展名是 .js 就加载"**，**不是**按文件名白名单：
/// ```text
/// for e in read_dir(dir) {
///     if path.extension() == Some("js") { JsPluginProvider::from_source(..) }
/// }
/// ```
/// 而注册去重（`Registry::register`）按**插件内部 `@id`**，不是文件名。
///
/// ⇒ 后果（实测推演，不是猜测）：老用户数据目录里那份旧文件
///   仍会被扫到并注册，与用户后来装的新插件**并存**，
///   出现两个同类源，且**没有任何报错**（两个 id 不同，不触发覆盖）。
///
/// # 为什么删在这里、且**无条件删**
/// ```text
/// ① 删在扫描之前 —— 否则这一次仍会扫到旧文件。
/// ② ★ 无条件删（不判标记、不判版本）：那个文件名**只可能是我们发过的
///    旧版**（用户手写的插件用自己的文件名/id），
///    所以删它是安全的；判据越简单越不会漏（"每个用户目录都清理一次"）。
/// ③ 幂等：文件不存在时 `exists()` 为假，直接跳过（下次启动还会再试）。
/// ```
///
/// ⚠️ 只删这一个具体文件名，**不做**"删掉所有同类前缀的 .js" ——
///    那会误删用户可能存在的其它自定义文件（保守优先）。
fn remove_legacy_live_plugin(data_dir: &std::path::Path) {
    // ★ 这是**历史文件名**，必须逐字保留（只在"清理老用户残留文件"时匹配）：
    //   见本函数文档的「它删什么」。
    let legacy = plugins_dir(data_dir).join("bilibili-live.js");
    if legacy.exists() {
        // 它是我们发过的旧版残留 —— 留着会与用户的新插件重复注册
        match std::fs::remove_file(&legacy) {
            Ok(()) => {
                log::info!("已删除遗留的旧版直播插件 {:?}（能力已被新版插件取代）", legacy);
                eprintln!(
                    "[PLUGIN] ★ 已删除遗留的旧版直播插件（能力已被新版插件取代）-> {}",
                    legacy.display()
                );
            }
            // 删不掉不致命（下次启动再试），但要让用户能看到原因
            Err(e) => log::warn!("删除遗留的旧版直播插件失败（保持原样）: {e}"),
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  数据目录迁移
// ═══════════════════════════════════════════════════════════════════════

/// 旧的应用数据目录名（Tauri 按 identifier 算出来的）
const LEGACY_DIR_NAMES: &[&str] = &[
    "com.dsh.mediaclient", // 最初的名字
    "app.sourin.player",   // 改名「源影 Sourin」后的
];

/// 从旧 identifier 目录迁移数据
///
/// # 为什么必须做
///
/// 数据目录是应用框架按 **identifier** 算出来的：
/// ```text
/// identifier: com.dsh.mediaclient
///   → %APPDATA%\com.dsh.mediaclient\
/// ```
/// 一改 identifier，目录就变了 —— 用户**所有**东西都会「消失」：
/// ```text
/// · plugins\        （JS 插件源码）
/// · dsh-media.db    （收藏、追更、播放历史、片头片尾）
/// · provider-order.json / disabled-providers.json
/// · device-id       （决定「按设备分文件」的平台历史镜像）
/// ```
/// 实测旧目录有 4.73MB 数据。**不能就这么丢了。**
///
/// # 策略：只在「新目录是空的、旧目录有货」时迁移一次
///
/// ⚠️ 三个条件都必须满足，否则会覆盖用户新装后的数据：
/// ```text
/// 1. 新目录**没有**数据库（说明是全新安装，没被用过）
/// 2. 旧目录**有**数据库（说明确实是老用户升级）
/// 3. 旧目录 != 新目录（避免自己搬自己）
/// ```
///
/// # 为什么是复制而不是移动
///
/// 保留旧目录 —— 万一新版本有问题，用户还能退回去。
fn migrate_from_legacy_dir(new_dir: &std::path::Path) {
    // 条件 1：新目录已经有数据库 → 不动
    if new_dir.join("dsh-media.db").exists() {
        return;
    }

    // 找到候选的旧目录（新目录的父目录下，按 identifier 命名）
    let Some(parent) = new_dir.parent() else { return };
    let new_name = new_dir.file_name().and_then(|s| s.to_str()).unwrap_or("");

    for legacy in LEGACY_DIR_NAMES {
        // 条件 3：别搬自己
        if *legacy == new_name {
            continue;
        }
        let old_dir = parent.join(legacy);

        // 条件 2：旧目录必须有数据库
        if !old_dir.join("dsh-media.db").exists() {
            continue;
        }

        log::info!(
            "发现旧数据目录，开始迁移: {} → {}",
            old_dir.display(),
            new_dir.display()
        );

        if let Err(e) = copy_dir_recursive(&old_dir, new_dir) {
            log::warn!("迁移失败（不影响新装使用）: {e}");
        } else {
            log::info!("迁移完成（旧目录已保留，可回退）");
        }
        return; // 只迁一次
    }
}

/// 递归复制目录
///
/// # 为什么不用 fs::copy 一次搞定
///
/// `std::fs::copy` 只处理单个文件。目录要自己递归。
/// 不引 `fs_extra` 之类的依赖 —— 这个场景很简单，手写 30 行够了，
/// 而每多一个依赖就多一份编译时间和攻击面。
fn copy_dir_recursive(from: &std::path::Path, to: &std::path::Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let dest = to.join(entry.file_name());
        if ty.is_dir() {
            copy_dir_recursive(&entry.path(), &dest)?;
        } else if ty.is_file() {
            // 已存在就不覆盖 —— 保证不破坏新装后的数据
            if !dest.exists() {
                std::fs::copy(entry.path(), &dest)?;
            }
        }
    }
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════
//  本机标识
// ═══════════════════════════════════════════════════════════════════════

/// 读取或生成本机标识
///
/// # 用途
///
/// 「按设备分文件」的平台历史镜像 —— 不同设备各有自己的历史，
/// 但同步到同一份远端 manifest 里。
///
/// # 为什么是 uuid 而不是机器码
///
/// 机器码（MAC / 主板序列号）涉及隐私，而且要处理各种平台差异。
/// 应用自己生成一个随机 id 存本地就够 —— 它只需要在本应用内唯一。
fn load_or_create_device_id(dir: &std::path::Path) -> String {
    let p = dir.join("device-id");
    if let Ok(s) = std::fs::read_to_string(&p) {
        let s = s.trim().to_string();
        if !s.is_empty() {
            return s;
        }
    }
    // 用时间戳 + 进程 id 拼一个 —— 不需要密码学强度
    let id = format!(
        "{:x}-{:x}",
        chrono::Utc::now().timestamp_millis(),
        std::process::id()
    );
    let _ = std::fs::write(&p, &id);
    id
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 临时数据目录（时间戳保证唯一）
    fn tmp_dir(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "sourin-state-test-{tag}-{}",
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// 写一份无 BOM 的第三方源清单
    ///
    /// ⚠️ 必须无 BOM：`load_persisted` 对解析失败是**静默忽略**的，
    ///    带 BOM 的 JSON 会让它悄悄返回空列表（表现是"源全丢了"却不报错）。
    ///    实测踩过这个坑，所以这里显式用 bytes 写。
    fn write_persisted(dir: &std::path::Path, list: &[PersistedProvider]) {
        let body = serde_json::to_string_pretty(list).unwrap();
        std::fs::write(crate::persist::providers_file(dir), body.as_bytes()).unwrap();
    }

    /// 合法声明式源的 JSON
    fn good_spec(id: &str) -> String {
        format!(
            r#"{{"id":"{id}","name":"测试源 {id}","base":"https://api.example.com",
                "endpoints":{{"list":{{"path":"/list","params":{{"ac":"videolist"}},
                "map":{{"items":"$.list","id":"$.vod_id","title":"$.vod_name"}}}}}}}}"#
        )
    }

    /// ★★★ 回归测试：**重启后第三方源必须回到 registry**
    ///
    /// # 这个测试防的是什么（一个真实发布过的 bug）
    ///
    /// `bootstrap` 原来只做 `load_persisted()`，把清单塞进 `AppState.third_party`
    /// 就结束了 —— 而 `registry.manifests()` 只遍历 `registry.providers`，
    /// 两个字段之间**没有桥**。
    ///
    /// 症状：用户导入的源重启后从界面消失（文件还在磁盘上，但列表里没有、
    /// 删不掉、也点不到「编辑」）。
    ///
    /// # 为什么这个断言是有效的
    ///
    /// 它断言的是**用户可见的结果**（`registry.manifests()` 里有这个源），
    /// 而不是"某个函数被调用了"。只 load 不 register 的写法会直接失败。
    #[tokio::test]
    async fn third_party_declarative_is_registered_on_boot() {
        let dir = tmp_dir("tp-decl");
        write_persisted(
            &dir,
            &[PersistedProvider::Declarative {
                id: "tp-demo".into(),
                json: good_spec("tp-demo"),
            }],
        );

        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        let ids: Vec<String> = st.registry.manifests().into_iter().map(|m| m.id).collect();
        assert!(
            ids.iter().any(|x| x == "tp-demo"),
            "第三方声明式源重启后必须回到 registry（这正是那个 bug）；实际: {ids:?}"
        );
        // 同时清单也要留着 —— 否则用户「编辑」时读不到原始配置
        let cfg = crate::commands_provider::get_provider_config(&st, "tp-demo").unwrap();
        assert!(cfg.is_some(), "third_party 清单里必须还有这条，供「编辑」回填");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★★★ 迁移门禁：遗留的旧版直播插件文件必须被**删除**
    ///
    /// # 为什么必须有这条（这是真实迁移问题，不是形式）
    ///
    /// 插件扫描器判据是"扩展名是 .js 就加载"（`plugins/mod.rs::load_plugins`），
    /// 而注册去重按插件内部 `@id`（`Registry::register`）——
    /// ⇒ 老用户目录里遗留的旧版文件会与用户自己后来装的插件
    ///   **同时注册**，同类源出现两份（列表翻倍），且无报错。
    ///
    /// ⇒ `remove_legacy_live_plugin()` 必须**显式删除**旧文件。
    ///   本测试模拟"老用户升级"：先手工放一份旧文件，再 bootstrap，
    ///   断言它**消失**（且不会作为源留在 registry 里）。
    ///
    /// ⚠️ 我们**不再随程序释放任何具体网站插件** —— 本测试断言的是
    ///   "旧文件被清掉"，**不是**"某个内置源被释放/注册"。
    #[tokio::test]
    async fn legacy_live_plugin_file_is_removed_on_bootstrap() {
        let dir = tmp_dir("legacy-live");

        /*
         * ① 铺好"老用户"的现场：插件目录里有一份遗留的旧版文件。
         *    内容不重要（删的依据是**文件名**，不是内容）——
         *    但给一个最小合法的旧版骨架，贴近真实形态。
         */
        let pdir = crate::state::plugins_dir(&dir);
        std::fs::create_dir_all(&pdir).unwrap();
        let legacy = pdir.join("bilibili-live.js");
        std::fs::write(
            &legacy,
            "/* @id bilibili-live @name legacy-live @version 1.0.0 */\n\
             globalThis.plugin = { id: 'bilibili-live', capabilities: { live: true } };\n",
        )
        .unwrap();
        assert!(legacy.exists(), "前置条件：旧文件必须先存在");

        // ② bootstrap —— 内部会删除遗留的旧文件
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        // ③ 旧文件必须被删掉（否则会与用户的插件并存、重复注册）
        assert!(
            !legacy.exists(),
            "★ 遗留的旧版直播插件文件必须被删除，否则会与用户自己的插件并存（列表翻倍）"
        );

        // ④ 而且注册表里不该有这个遗留的源
        let ids: Vec<String> = st.registry.manifests().into_iter().map(|m| m.id).collect();
        assert!(
            !ids.iter().any(|x| x == "bilibili-live"),
            "★ 遗留的旧版源不该出现（文件已删），实际: {ids:?}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ 隔离失败：坏源只跳过自己，不能拖垮后面的好源
    ///
    /// 布局刻意**交错**（好-坏-好）—— 若实现是"遇到坏的就中断"，
    /// 第二个好源就不会在册，本测试失败。
    #[tokio::test]
    async fn broken_source_does_not_block_the_next_one() {
        let dir = tmp_dir("tp-iso");
        write_persisted(
            &dir,
            &[
                PersistedProvider::Declarative {
                    id: "ok-1".into(),
                    json: good_spec("ok-1"),
                },
                // JSON 语法坏 —— from_json 必失败
                PersistedProvider::Declarative {
                    id: "bad-json".into(),
                    json: "{ this is not json ".into(),
                },
                PersistedProvider::Declarative {
                    id: "ok-2".into(),
                    json: good_spec("ok-2"),
                },
                // base 不是 http(s) —— 也会被 from_json 拒
                PersistedProvider::Declarative {
                    id: "bad-base".into(),
                    json: r#"{"id":"bad-base","name":"B","base":"ftp://x","endpoints":{}}"#.into(),
                },
                PersistedProvider::Declarative {
                    id: "ok-3".into(),
                    json: good_spec("ok-3"),
                },
            ],
        );

        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");
        let ids: Vec<String> = st.registry.manifests().into_iter().map(|m| m.id).collect();

        for good in ["ok-1", "ok-2", "ok-3"] {
            assert!(
                ids.iter().any(|x| x == good),
                "{good} 应该被注册（坏源不能拖垮它后面的源）；实际: {ids:?}"
            );
        }
        for bad in ["bad-json", "bad-base"] {
            assert!(
                !ids.iter().any(|x| x == bad),
                "{bad} 是坏源，不该进 registry"
            );
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ 注册必须早于「应用停用状态」，否则停用的源会自己「活」过来
    ///
    /// 这是 ⑧ 那条注释记的坑：注册会把 handle 的 `enabled` 重置回 true。
    ///
    /// ⚠️ 断言必须用 `enabled_manifests()` 而不是 `manifests()`：
    ///    `manifests()` 直接 clone 了 provider 自己的 manifest，而那份的
    ///    `enabled` 恒为 `None` —— 真正的启用标志在 `ProviderHandle.enabled` 上
    ///    （`provider.rs:468`）。用错 API 会得到一个**永远失败**的测试。
    ///    （命令层的 `list_providers` 是拿 disabled 文件覆盖 manifest 的，
    ///      所以它看到的 enabled 是对的。）
    #[tokio::test]
    async fn disabled_third_party_source_stays_disabled_after_boot() {
        let dir = tmp_dir("tp-disabled");
        write_persisted(
            &dir,
            &[PersistedProvider::Declarative {
                id: "tp-off".into(),
                json: good_spec("tp-off"),
            }],
        );
        crate::commands::save_disabled(&dir, &["tp-off".to_string()]).unwrap();

        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        // ① 停用的源仍然要在 registry 里（只是关掉）—— 否则设置页看不到它，
        //    用户就没法再把它打开
        let all: Vec<String> = st.registry.manifests().into_iter().map(|m| m.id).collect();
        assert!(
            all.iter().any(|x| x == "tp-off"),
            "停用的第三方源也该在 registry 里（enabled=false），否则用户无法再启用它"
        );

        // ② 它必须是**停用**状态
        let on: Vec<String> = st
            .registry
            .enabled_manifests()
            .into_iter()
            .map(|m| m.id)
            .collect();
        assert!(
            !on.iter().any(|x| x == "tp-off"),
            "用户上次停用的第三方源重启后不该自己「活」过来"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 清单文件损坏 → 启动仍然成功（一份坏 JSON 不该让应用起不来）
    #[tokio::test]
    async fn corrupt_manifest_does_not_break_boot() {
        let dir = tmp_dir("tp-corrupt");
        std::fs::write(crate::persist::providers_file(&dir), b"{ not json at all").unwrap();

        let st = AppState::bootstrap(dir.clone()).await;
        assert!(st.is_ok(), "清单损坏时启动必须仍然成功");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
