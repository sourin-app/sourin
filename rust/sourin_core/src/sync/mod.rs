//! 同步引擎 —— 把「两个平面」落到实处
//!
//! # 两个平面（Owner 确认的边界，勿混）
//!
//! | 平面 | 数据 | 方向 | 冲突策略 |
//! |---|---|---|---|
//! | **独立平面** | 我们的收藏 + 追更 + 进度 | 多设备**双向** | LWW（`updated_at`）+ 墓碑 |
//! | **备份平面** | 第三方站点自带的历史 | 平台 → 云盘**单向镜像** | 按平台时间戳覆盖 |
//!
//! 混在一起会互相打架：平台改了历史 vs 本地改了进度，谁是真相？
//! 分开后各自简单。
//!
//! # 远端布局
//!
//! ```text
//! {webdav_root}/
//! ├─ manifest.json                      # 索引：schema 版本 / 最后同步时间 / 设备
//! ├─ data/
//! │  ├─ favorites.jsonl                 # 独立平面：收藏 + 追更
//! │  └─ progress.jsonl                  # 独立平面：进度
//! └─ backup/
//!    └─ {provider}/history-{device}.jsonl   # 备份平面：按设备分文件
//! ```
//!
//! **为什么收藏/进度用「整文件覆盖」而不是追加**：
//! 我们要的是 LWW 合并结果，追加会让文件无限增长且要每次全读。
//! 单文件 + ETag 乐观锁在数据量（几百条）下完全够用，
//! 且「读-合并-写」的语义清晰。JSONL 只是便于人工查看/增量解析。

use crate::store::{Db, Favorite, Normalize, Progress, progress_key};
use crate::sync::webdav::{SyncBackend, WebdavBackend};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

pub mod webdav;

/// 凭据平面 —— 登录态随云同步（加密 + 缓存 key 黑名单）
///
/// ★ 单独一个模块而不是塞进本文件：加密与黑名单是一组自洽的逻辑，
///   有自己的单元测试；混进 1000 多行的 `mod.rs` 会让它更难单独审查。
pub mod credentials;

/*
 * ★ 把 WebdavConfig 以 `pub use` 引入（2026-09-22）
 *
 * 原本写的是 `use ...::{..., WebdavConfig}` —— 那是**私有导入**，
 * 模块外写 `crate::sync::WebdavConfig` 会报
 * "struct import `WebdavConfig` is private"。
 *
 * 命令层的 `configure_webdav` 需要构造它，所以必须对外可见。
 *
 * ⚠️ 注意**不能**既 `use` 又 `pub use` 同一个名字 ——
 *    会报 `E0252: the name is defined multiple times`。
 *    正确做法是把那一项从私有 use 里**移出来**，只留这条 pub use。
 *    （`pub use` 本身也把名字引入了当前作用域，内部照常能用。）
 */
pub use crate::sync::webdav::WebdavConfig;

/// 远端目录条目（`list()` 的返回元素）—— 命令层要构造它的 JSON，故对外可见
pub use crate::sync::webdav::RemoteEntry;

/// 云盘凭据：与登录令牌同策略，走系统钥匙串，**不落库、不进导出**
pub mod webdav_credential {
    /// keyring 服务名
    ///
    /// ⚠️ **不要跟着应用改名一起改** —— 见 `proxy.rs` 里
    /// `KEYRING_SERVICE` 上方的详细说明。
    /// 改了会让用户已保存的 WebDAV 密码读不到。
    const SERVICE: &str = "dsh-media-client-sync";

    fn entry(key: &str) -> Result<keyring::Entry, String> {
        keyring::Entry::new(SERVICE, key).map_err(|e| format!("钥匙串不可用: {e}"))
    }

    /// 写入并回传（便于调用方立即使用，避免再读一次）
    pub fn set(key: &str, password: &str) -> Result<String, String> {
        let e = entry(key)?;
        if password.is_empty() {
            let _ = e.delete_credential();
            return Ok(String::new());
        }
        e.set_password(password)
            .map_err(|err| format!("写入钥匙串失败: {err}"))?;
        Ok(password.to_string())
    }

    pub fn get(key: &str) -> Option<String> {
        entry(key).ok()?.get_password().ok()
    }

    pub fn clear(key: &str) -> Result<(), String> {
        let e = entry(key)?;
        let _ = e.delete_credential();
        Ok(())
    }
}

/// ★ 凭据同步的**口令**（加密密钥的来源）—— 系统钥匙串，**绝不落盘**
///
/// # 为什么口令不能进 `sync-settings.json`
///
/// ```text
/// 那个文件是**明文 JSON**，注释里写着「用户可能同步到网盘/发给人看」。
/// 把口令写进去 = 把"加密的凭据包"的钥匙和锁放在同一个信封里。
/// 整件事就白做了（攻击者拿到设置文件 ⇒ 解开设文件旁边的 credentials.enc）。
/// ```
///
/// # 为什么口令也**不进**导出包
///
/// 备份包是用户主动分发的东西（U 盘、聊天软件、网盘）。
/// 口令在里面 = 加密等于没加密。⇒ 导入时必须**重新输入口令**。
///
/// # 为什么单独一个钥匙串服务名（而不是复用 `webdav_credential`）
///
/// ```text
/// webdav 服务名下的 "webdav" 键 = 连网盘的密码
/// 这里存的是**另一个东西**：加密登录态用的口令
/// ⇒ 混用会让「改网盘密码」和「改加密口令」互相覆盖（静默、且很难查）
/// ```
pub mod credentials_passphrase {
    /// keyring 服务名
    ///
    /// ⚠️ 与 `webdav_credential` / `proxy` 一样：**不要跟着应用改名一起改**，
    ///    改了用户已保存的口令就读不到（表现为"明明设过，却提示未设"）。
    const SERVICE: &str = "dsh-media-client-credential-key";

    /// 本服务名下只有一个条目，键名固定
    const KEY: &str = "credentials";

    fn entry() -> Result<keyring::Entry, String> {
        keyring::Entry::new(SERVICE, KEY).map_err(|e| format!("钥匙串不可用: {e}"))
    }

    /// 写入口令；空口令 = 删除（不是存空串）
    pub fn set(passphrase: &str) -> Result<(), String> {
        let e = entry()?;
        if passphrase.is_empty() {
            let _ = e.delete_credential();
            return Ok(());
        }
        e.set_password(passphrase)
            .map_err(|err| format!("写入钥匙串失败: {err}"))
    }

    /// 读口令；没设过返回 `None`
    ///
    /// ⚠️ 读失败也返回 `None`（而不是 `Err`）—— 与 `webdav_credential::get`
    ///    同做法。理由：钥匙串在某些 Linux 桌面环境下根本没后端，
    ///    这时「读不到」与「没设过」对调用方的**行动**是同一件事：
    ///    要么让用户设一个，要么显示"凭据未同步"。
    pub fn get() -> Option<String> {
        entry().ok()?.get_password().ok().filter(|s| !s.is_empty())
    }

    /// 是否设过口令
    pub fn is_set() -> bool {
        get().is_some()
    }

    pub fn clear() -> Result<(), String> {
        let e = entry()?;
        let _ = e.delete_credential();
        Ok(())
    }
}

// ═══════════════════════ 云盘同步设置（持久化）═══════════════════════

/// 设置文件名（在 `$data_dir` 下）
pub const SYNC_SETTINGS_FILE: &str = "sync-settings.json";

/// ★ 整体备份快照在**远端**的目录（契约 §5）
///
/// 用子目录而不是 `backup/` 根：根下已有 `backup/{provider}/history-*.jsonl`，
/// 混在一起会让「列出备份」把平台历史也列出来。
pub const SNAPSHOT_DIR: &str = "backup/snapshots";

/// 备份文件名前缀 —— 保留清理的**安全护栏**：只删我们自己写的文件
pub const SNAPSHOT_PREFIX: &str = "dsh-backup-";
/// 备份文件名后缀（同样是护栏的一部分）
pub const SNAPSHOT_SUFFIX: &str = ".zip";

/// ★ 云盘同步的设置 —— **持久化在磁盘上**（2026-09-29，task-75）
///
/// # 为什么必须落盘（修的是一个硬阻塞）
///
/// 改之前 `WebdavConfig` **只在内存**里（`state.rs` 的
/// `sync: RwLock::new(None)`），于是：
/// ```text
/// 用户配好云盘 → 能用
/// 重启        → sync_status() 必然 connected:false
///             ⇒ 每次开机都要重新配一遍，自动备份根本无从谈起
/// ```
///
/// # 字段命名：文件里是 camelCase
///
/// Dart 侧直接读这份 JSON（`sync_settings_get`），所以**两边的名字必须一致**。
/// `#[serde(rename_all = "camelCase")]` 让 Rust 侧照常写 snake_case，
/// 存盘/出参自动变成 `baseUrl` / `retainCount` / `autoEnabled` …
///
/// # `#[serde(default)]`（容器级）是**容错**的关键
///
/// 它让「字段缺失」回退到 [`Default`] 而不是解析失败。契约 §3.1 要求
/// `sync_settings_get` **永不失败** —— 用户可能有一个上个版本写的、
/// 只有一半字段的文件，或者手改坏了。缺字段给默认值，坏 JSON 也给默认值。
///
/// ⚠️ **密码绝不写进这个文件** —— 它仍只在系统钥匙串
///    （服务名 `dsh-media-client-sync`，键 `webdav`）。
///    这个文件是明文 JSON，用户可能同步到网盘/发给人看。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct SyncSettings {
    /// WebDAV 基址（连接字段）
    pub base_url: String,
    /// 账号（连接字段）
    pub username: String,
    /// 远端目录（连接字段）
    pub remote_dir: String,
    /// 云端最多保留几份整体备份（默认 10）—— **偏好字段**
    pub retain_count: u32,
    /// 自动同步**总开关**（默认 false）—— **偏好字段**
    pub auto_enabled: bool,
    /// 增量同步节奏：多久看一眼云端（分钟，默认 30）—— **偏好字段**
    pub auto_interval_minutes: u32,
    /// 数据变动就同步（默认 true）—— **偏好字段**
    pub auto_on_change: bool,
    /// ★ 整体备份节奏（分钟，默认 1440 = 1 天，**0 = 关**）—— **偏好字段**
    ///
    /// 与 `auto_interval_minutes` **刻意分开**：增量同步传的是几 KB 的
    /// JSONL，整体备份传的是整包 zip。用同一个间隔会让用户开自动同步后
    /// 每 30 分钟整包上传一次 —— 正是 Owner 说的「耗流量」。
    /// 阅读 App（Legado）也是这么分的：进度 5 分钟 debounce，zip 24 小时一次。
    pub auto_backup_interval_minutes: u32,
    /// 上次整体备份时间（毫秒）—— 内部水位
    pub last_backup_at: i64,
    /// 上次增量同步时间（毫秒）—— 内部水位
    pub last_sync_at: i64,
    /// 上次同步时的本地数据签名 —— 内部字段，**不出现在 `sync_settings_get` 里**
    pub last_signature: String,
    /// 上次备份时的本地数据签名 —— 内部字段，**不出现**在返回里
    pub last_backup_signature: String,
    /*
     * ★ 凭据同步总开关（CS-1，2026-10-19）—— **偏好字段**
     *
     * # 为什么要有这个开关（而不是"设了口令就自动同步"）
     *
     * ```text
     * 口令存在钥匙串里 ⇒ 用户设过一次就一直在
     * ⇒ 没有开关的话，用户**永远**在同步登录态，而他可能根本不想要
     *   （共用电脑、或只想同步收藏）
     * ```
     *
     * ⚠️ **开关为 true 但没设口令 ⇒ 不得算同步成功**。
     *    那是本仓反复出现的"假绿"同类：用户看到"同步完成"，
     *    登录态其实一个字节都没走。见 `commands_backup::sync_now` 的判据。
     */
    #[serde(default)]
    pub credentials_enabled: bool,
}

impl Default for SyncSettings {
    fn default() -> Self {
        Self {
            base_url: String::new(),
            username: String::new(),
            remote_dir: String::new(),
            retain_count: 10,
            auto_enabled: false,
            auto_interval_minutes: 30,
            auto_on_change: true,
            auto_backup_interval_minutes: 1440,
            last_backup_at: 0,
            last_sync_at: 0,
            last_signature: String::new(),
            last_backup_signature: String::new(),
            credentials_enabled: false,
        }
    }
}

impl SyncSettings {
    /// ★ 给 Dart 侧看的 JSON（契约 §2 的字段表）
    ///
    /// ⚠️ **刻意不含** `lastSignature` / `lastBackupSignature` ——
    ///    那是我们内部的判据（数据指纹），对 UI 无意义，
    ///    露出去反而容易被误当成"状态"去显示。
    ///
    /// # 参数 `passphrase_set`
    ///
    /// 口令本身**不在设置文件里**（明文 JSON，绝不能放），而在系统钥匙串。
    /// 所以「有没有设过口令」这个**布尔**必须由调用方读钥匙串后传进来 ——
    /// 本方法只负责拼 JSON，不碰钥匙串（保持纯函数、可单测）。
    ///
    /// ★ UI 硬要求：`credentialsEnabled == true` 但 `passphraseSet == false`
    ///   时，状态行必须显示「凭据未同步」，**不许**显示「同步完成」。
    pub fn to_public_json(&self, connected: bool, passphrase_set: bool) -> serde_json::Value {
        serde_json::json!({
            "connected": connected,
            "baseUrl": self.base_url.clone(),
            "username": self.username.clone(),
            "remoteDir": self.remote_dir.clone(),
            "retainCount": self.retain_count,
            "autoEnabled": self.auto_enabled,
            "autoIntervalMinutes": self.auto_interval_minutes,
            "autoOnChange": self.auto_on_change,
            "autoBackupIntervalMinutes": self.auto_backup_interval_minutes,
            "lastBackupAt": self.last_backup_at,
            "lastSyncAt": self.last_sync_at,
            "credentialsEnabled": self.credentials_enabled,
            "credentialsPassphraseSet": passphrase_set,
        })
    }
}

/// 读设置 —— ★ **永不失败**（契约 §3.1）
///
/// 文件不存在 / JSON 坏 / 字段缺 ⇒ 一律回退默认值。
/// 理由：Dart 侧**首次进设置页就会调它**（比用户配云盘早得多），
/// 它一报错 UI 就得走降级分支。
pub fn load_settings(data_dir: &std::path::Path) -> SyncSettings {
    let path = data_dir.join(SYNC_SETTINGS_FILE);
    let Ok(text) = std::fs::read_to_string(&path) else {
        // 首次使用：文件还不存在，这**不是**错误
        return SyncSettings::default();
    };
    match serde_json::from_str::<SyncSettings>(&text) {
        Ok(s) => s,
        Err(e) => {
            log::warn!("sync-settings.json 解析失败（已回退默认值，不影响其它功能）: {e}");
            SyncSettings::default()
        }
    }
}

/// 写设置（只有真正写盘失败才返回 `Err`）
pub fn save_settings(data_dir: &std::path::Path, s: &SyncSettings) -> Result<(), String> {
    let path = data_dir.join(SYNC_SETTINGS_FILE);
    let body = serde_json::to_vec_pretty(s).map_err(|e| format!("序列化设置失败: {e}"))?;
    std::fs::write(&path, &body).map_err(|e| format!("写入 {} 失败: {e}", path.display()))
}

/// ★ 本地数据签名 —— 「有数据变动就保存」的判据（契约 §6）
///
/// ```text
/// favorites: 条数 + max(updated_at)
/// following: 同
/// progress:  同
/// ```
/// 数据没动 ⇒ 签名不变 ⇒ **一次请求都不发**。这就是 Owner 要的
/// 「耗很低的流量」—— 靠的是"没变就不传"，而不是"传得小"。
///
/// ⚠️ 用「条数 + 最大时间戳」而不是逐条哈希：前者 O(n) 且不分配，
///    后者要拼一整个字符串再算摘要。签名只需要**区分"变了没"**，
///    不需要抗碰撞 —— 两处都变了但条数与最大时间戳都相同的概率极低，
///    而万一撞上，代价只是「这一轮少同步一次」，下一轮数据再动就会补上。
pub fn data_signature(db: &Db) -> Result<String, String> {
    let favs = db.list_favorites(true)?;
    let foll = db.list_following()?;
    let progs = db.list_all_progress()?;

    fn one<T, F: Fn(&T) -> i64>(items: &[T], at: F) -> (usize, i64) {
        (items.len(), items.iter().map(at).max().unwrap_or(0))
    }

    let (fc, ft) = one(&favs, |f| f.updated_at);
    let (lc, lt) = one(&foll, |f| f.updated_at);
    let (pc, pt) = one(&progs, |p| p.updated_at);

    Ok(format!(
        "favorites:{fc}:{ft}|following:{lc}:{lt}|progress:{pc}:{pt}"
    ))
}

/// 一次整体备份的结果（`sync_backup_now` 的返回，契约 §1）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupOutcome {
    /// 文件名（`dsh-backup-<device>-<yyyyMMdd-HHmmss>.zip`）
    pub name: String,
    /// 上传字节数
    pub bytes: u64,
    /// 远端完整路径（`backup/snapshots/<name>`）
    pub path: String,
    /// 本次被清理掉的旧备份名（可能为空）
    pub pruned: Vec<String>,
    /// ★ 清理**之后**云端还剩下几份
    ///
    /// 契约 §1 只写了 `total:int` 没说含义，这里取「剩下的份数」——
    /// UI 上「云端现有 N 份 / 最多保留 M 份」是最能说明状态的数字。
    /// （另一个候选「列出时共几份」等于 `total + pruned.len()`，可由 UI 自算。）
    pub total: usize,
}

/// 这个名字是不是**我们自己写的**整体备份？
///
/// ★ 这是保留清理的**安全护栏**（契约 §5②）：云盘目录里可能有用户自己
/// 放的文件、别的 App 的备份、我们早期的 `backup/<provider>/history-*.jsonl`。
/// 只要有一个不符合前缀/后缀就不删 —— 「少删」最多浪费点空间，
/// 「多删」是删用户的数据。
pub fn is_snapshot_name(name: &str) -> bool {
    name.starts_with(SNAPSHOT_PREFIX) && name.ends_with(SNAPSHOT_SUFFIX) && name.len() > SNAPSHOT_PREFIX.len() + SNAPSHOT_SUFFIX.len()
}

/// 从「云端现有的备份」里挑出**该删掉的**（纯函数，便于单测）
///
/// 规则（契约 §5）：
/// 1. 只考虑 [`is_snapshot_name`] 为真的（别人的文件一律不动）
/// 2. 按名字**降序**（`yyyyMMdd-HHmmss` 定长 ⇒ 字典序即时间序）
/// 3. 保留前 `max(1, retain_count)` 个，其余都删
///
/// ★ 下限为什么是 1 而不是 0：用户把「最多保留」设成 0 时，
///   若按字面执行就会**把刚上传的那份也删掉** —— 备份功能原地失效，
///   而且是静默的（UI 还显示"备份成功"）。所以下限锁死 1。
pub fn snapshots_to_prune(entries: &[RemoteEntry], retain_count: u32) -> Vec<String> {
    let keep = std::cmp::max(1, retain_count) as usize;
    let mut names: Vec<&str> = entries
        .iter()
        .map(|e| e.name.as_str())
        .filter(|n| is_snapshot_name(n))
        .collect();
    names.sort_unstable_by(|a, b| b.cmp(a)); // 降序：新的在前
    names.into_iter().skip(keep).map(|s| s.to_string()).collect()
}

/// 同步结果摘要（给 UI 展示「拉了多少 / 推了多少 / 多少冲突」）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncSummary {
    /// 平面名：favorites | progress | providers
    pub plane: String,
    /// 从远端拉取的新条目数
    pub pulled: usize,
    /// 推送到远端的条目数
    pub pushed: usize,
    /// 因远端更新而被覆盖的条数
    pub conflicts: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// ★ 内容源配置的**云备份载荷**（第 3 个平面）
///
/// 为什么要单独备份：用户手写的声明式 JSON / HTTP 插件地址
/// 是**纯本地数据** —— 换机器、重装、清数据就全没了，
/// 而它们往往比收藏更难重建（要重新去站点抓接口、写 JSONPath 映射）。
///
/// # 合并策略：整文件 LWW（**不是**逐条合并）
///
/// 与收藏/进度不同，源配置**不做逐条合并**，理由：
/// 1. 它是**结构性配置**，不是可累加的记录 ——
///    两台设备各改一半再合并，可能拼出一个谁都没测过的配置
/// 2. 条目数很少（通常几个到几十个），整文件覆盖的代价可以忽略
/// 3. 「哪台设备最后改的」就是用户的真实意图
///
/// 所以按 `updated_at` 整体取新的一份，旧的那份直接丢弃。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProviderConfigBundle {
    /// 内容最后修改时间（毫秒）—— LWW 的判据
    pub updated_at: i64,
    /// 写入设备（诊断用）
    #[serde(default)]
    pub device: String,
    /// 第三方源配置（内置源不参与 —— 它们是程序的一部分，无需备份）
    pub providers: Vec<crate::PersistedProvider>,
}

/// 远端 manifest —— 结构版本 + 水位
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub schema_version: u32,
    /// 最后一次同步完成时间（毫秒）
    #[serde(default)]
    pub last_sync_at: i64,
    /// 写入过数据的设备（便于诊断「哪台设备改的」）
    #[serde(default)]
    pub devices: Vec<String>,
}

pub const SCHEMA_VERSION: u32 = 1;

impl Default for Manifest {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            last_sync_at: 0,
            devices: Vec::new(),
        }
    }
}

/// 同步引擎（持有当前后端）
pub struct SyncEngine {
    backend: Arc<dyn SyncBackend>,
    db: Arc<Db>,
    /// 本机标识（写进 manifest，便于诊断）
    device_id: String,
    /// 应用数据目录 —— 凭据平面要从 `<data_dir>/plugins/.data/` 读插件私有存储
    ///
    /// ★ 为什么是 `Option`（而不是构造时必需）：
    ///   5 个构造点里只有 2 个（`commands_backup` / `state`）手上有 `data_dir`，
    ///   其余（含 3 处测试）没有。做成必需参数会牵动全部 5 处 + 3 个测试，
    ///   而**没有 data_dir 时凭据平面本来就该跳过**（它读不到插件存储）。
    ///   ⇒ 用 builder 补挂，缺省 `None` = 没有凭据平面。
    data_dir: Option<std::path::PathBuf>,
}

impl SyncEngine {
    pub fn new_webdav(cfg: WebdavConfig, db: Arc<Db>, device_id: String) -> Result<Self, String> {
        let backend = WebdavBackend::new(cfg)?;
        Ok(Self {
            backend: Arc::new(backend),
            db,
            device_id,
            data_dir: None,
        })
    }

    pub fn new(backend: Arc<dyn SyncBackend>, db: Arc<Db>, device_id: String) -> Self {
        Self {
            backend,
            db,
            device_id,
            data_dir: None,
        }
    }

    /// 挂上应用数据目录 —— 凭据平面需要它才能读 `plugins/.data/`
    ///
    /// ★ 用 builder 而不是改构造签名：见 `data_dir` 字段上的说明。
    ///
    /// ⚠️ **不挂 = 凭据平面永远不同步**。调用方（`commands_backup` / `state`）
    ///    必须调它，否则用户会发现"同步完成"但登录态没过去 ——
    ///    这正是提案 UI 那条要防的假绿。
    pub fn with_data_dir(mut self, dir: std::path::PathBuf) -> Self {
        self.data_dir = Some(dir);
        self
    }

    pub fn backend_name(&self) -> &str {
        self.backend.name()
    }

    /// 连通性自检（设置页「测试连接」）
    pub async fn test(&self) -> Result<String, String> {
        self.backend.ping().await
    }

    /// ★ 准备远端目录（配置云盘时先调用，再调 `test()`）
    ///
    /// 顺序很重要：`test()` 会 PROPFIND **含 `remote_dir` 的完整路径**，
    /// 目录还不存在时会返回 404，被误报成
    /// 「路径不存在：请确认 WebDAV 地址包含目标目录」——
    /// 用户明明填对了地址。
    ///
    /// 所以配置流程是：**先 `prepare()` 建目录 → 再 `test()` 验凭据**。
    pub async fn prepare(&self) -> Result<(), String> {
        self.ensure_layout().await
    }

    /// 确保远端目录结构存在
    ///
    /// ⚠️ 必须**逐级**创建 —— 坚果云对多级 MKCOL 返回 409（见 `webdav.rs` 说明）。
    /// `ensure_dir` 内部已做了逐级拆分。
    ///
    /// ★ 2026-09-15 修：**根目录（`remote_dir`）自己也要建**
    ///
    /// 原先只建了 `data/` 与 `backup/`，但 `manifest.json` 写在**根目录下** ——
    /// 而 WebDAV 的 MKCOL 要求父目录已存在，根目录不存在时：
    ///   · 建 `data/` 会失败（父目录没有）
    ///   · 写 `manifest.json` 报 **HTTP 404**
    ///
    /// 实测踩到：配置好云盘后第一次同步直接失败
    /// （`PUT manifest.json 失败: HTTP 404 The resource of this location does not exist`）。
    /// 手动对该目录发一次 MKCOL 后立刻恢复正常。
    ///
    /// 用空路径 `""` 表示根目录（`WebdavBackend::url` 会拼成 `{root}/`）。
    async fn ensure_layout(&self) -> Result<(), String> {
        // 根目录优先 —— 它是其余一切的前提
        self.backend.ensure_dir("").await?;
        self.backend.ensure_dir("data").await?;
        self.backend.ensure_dir("backup").await?;
        /*
         * ★ 整体备份的专属子目录（2026-09-29，task-75）
         *
         * 刻意**不用** `backup/` 根目录：那底下已经有
         * `backup/{provider}/history-{device}.jsonl`（平台历史镜像）。
         * 混在一起会让「列出备份」把平台历史也列出来当成一份备份 ——
         * 而保留清理是按份数删的，数错就会删错。
         */
        self.backend.ensure_dir(SNAPSHOT_DIR).await?;
        Ok(())
    }

    // ─────────────────── 独立平面：双向同步 ───────────────────

    /// ★ 收藏 + 追更 双向同步
    pub async fn sync_favorites(&self) -> Result<SyncSummary, String> {
        self.ensure_layout().await?;
        let path = "data/favorites.jsonl";

        // 1) 拉远端
        let remote_raw = self.backend.get(path).await?;
        let (remote_had, remote_etag) = match &remote_raw {
            Some((bytes, etag)) => {
                let text = String::from_utf8_lossy(bytes);
                (parse_jsonl::<Favorite>(&text)?, etag.clone())
            }
            None => (Vec::new(), None),
        };
        // 留一份「合并前远端的快照」，用于精确统计 pushed
        let remote_had_keys: Vec<String> = remote_had.iter().map(|f| f.key.clone()).collect();
        let remote_had = remote_had.clone();

        // 2) 拉本地
        let local = self.db.list_favorites(true)?;

        // 3) LWW 合并
        let merged = merge_lww(local, remote_had.clone(), |f| f.key.clone(), |f| f.updated_at);

        // 4) 写回本地（合并结果落库），并统计**真正来自远端的新增**
        let mut pulled = 0usize;
        let local_keys: std::collections::HashSet<String> =
            self.db.list_favorites(true)?.into_iter().map(|f| f.key).collect();
        for f in &merged.items {
            if f.deleted {
                // 墓碑：同步进来的删除也要落成本地墓碑
                self.db.tombstone_favorite(&f.key, f.updated_at)?;
            } else {
                self.db.upsert_favorite(f)?;
            }
            if !local_keys.contains(&f.key) {
                pulled += 1;
            }
        }

        // 5) 写回远端（带回退重试：冲突则重拉再合并）
        let body = to_jsonl(&merged.items)?;
        /*
         * ★★ 低流量改造（契约 §7，2026-09-29 task-75）
         *
         * # 改之前是什么样
         *
         * 每次都无条件 `PUT` 全文 —— 哪怕一个字节都没变。
         * 用户开着自动同步（默认 30 分钟）时，一天就是 48 次
         * 白白上传同样的内容。这正是 Owner 说的「耗流量」的根源。
         *
         * # 判据必须拿**远端原始字节**比
         *
         * `remote_raw` 是 `get()` 返回的**原样**字节。若拿
         * `to_jsonl()` 重新序列化再跟 `body` 比，那是自己跟自己比
         * （同一个函数、同一份数据）⇒ **恒等** ⇒ 永远跳过 PUT，
         * 连首次上传都不会发生。这是这条改动最容易写错的地方。
         *
         * # `remote_had == false` 必须照常 PUT
         *
         * 远端还没有这个文件（首次上传，或用户在云端删了它）
         * ⇒ 必须写上去，否则本地数据永远同步不出去。
         *
         * ⚠️ 跳过 PUT **不影响**上面的第 4 步：pull 到的远端变更
         *    已经落进本地 DB 了，只是不回传而已。
         *    `SyncSummary.pushed` 也照常算 —— 它表达的是
         *    「本轮真正需要推送的量」，跳过时天然为 0。
         */
        // 远端**原始字节**（None = 远端还没有这个文件）
        let remote_bytes: Option<&[u8]> = remote_raw.as_ref().map(|(b, _)| b.as_slice());
        if remote_bytes == Some(body.as_bytes()) {
            log::debug!("sync: {path} 内容与远端逐字节相同，跳过 PUT（省一次上传）");
        } else {
            // 内容不同，或远端还没有（首次上传）⇒ 必须写
            self.put_with_remerge(path, body.as_bytes(), remote_etag.as_deref(), |local_again, remote_again| {
                merge_lww(local_again, remote_again, |f: &Favorite| f.key.clone(), |f: &Favorite| f.updated_at)
            }, || -> Result<Vec<Favorite>, String> { self.db.list_favorites(true) },
               |items: &[Favorite]| -> Result<(), String> {
                   for f in items { self.db.upsert_favorite(f)?; }
                   Ok(())
               })
            .await?;
        }

        // ★ `pushed` 必须是「本轮真正需要推送的量」，而不是「文件里总共有多少条」。
        //   否则每次同步都报同样的数字，用户会以为一直在重传。
        //   真正需要推送 = 本地侧存在、且远端没有或比本地旧。
        let remote_keys: std::collections::HashSet<String> =
            remote_had_keys.iter().cloned().collect();
        let remote_updated: std::collections::HashMap<String, i64> = remote_had
            .iter()
            .map(|f| (f.key.clone(), f.updated_at))
            .collect();
        let pushed = merged
            .items
            .iter()
            .filter(|m| match remote_keys.contains(&m.key) {
                false => true, // 远端没有 → 需要推送
                true => remote_updated.get(&m.key).copied().unwrap_or(i64::MIN) < m.updated_at,
            })
            .count();

        Ok(SyncSummary {
            plane: "favorites".into(),
            pulled,
            pushed,
            conflicts: merged.conflicts,
            note: None,
        })
    }

    /// ★ 播放进度 双向同步
    pub async fn sync_progress(&self) -> Result<SyncSummary, String> {
        self.ensure_layout().await?;
        let path = "data/progress.jsonl";

        let remote_raw = self.backend.get(path).await?;
        let (remote_had, remote_etag) = match &remote_raw {
            Some((bytes, etag)) => {
                let text = String::from_utf8_lossy(bytes);
                (parse_jsonl::<Progress>(&text)?, etag.clone())
            }
            None => (Vec::new(), None),
        };
        /*
         * ★★★ 2026-10-12 按集扩容：合并/计数的 key 一律用
         * **由三列推导**的按集键（[`progress_sync_key`]），**不用** `p.key` 那个字段。
         *
         * # 为什么（老设备兼容，这是本节的关键）
         *
         * `upsert_progress` 落库时**从 (provider,native_id,episode_id) 重算**主键，
         * 不信任传进来的 `key`。若合并这里却按 `p.key` 去重，就会出现：
         * ```text
         * 老设备的 jsonl: key = "srca:3611"        （老口径，没第三段）
         * 本机新库那条:   key = "srca:3611:48884"  （新口径）
         * ⇒ 按 p.key 去重 ⇒ 当成**两条不同**的记录
         * ⇒ merged.items 里两份都会被 upsert，落在**同一个**表主键上
         * ⇒ 谁后写谁赢（HashMap 顺序不定）⇒ 可能把**较旧**的一条写上去
         *   ⇒ 进度倒退（正是同步最不能出的错）
         * ```
         * ⇒ 改成按**字段推导**的键去重：老行 `(srca,3611,48884)` 与本机那条
         *   推导出**同一个** key ⇒ 正确走 LWW 取新的那条。
         *
         * ⚠️ 这也让「老设备同步过来」天然兼容：老 key 字段被**忽略**，按三列
         *   重算 ⇒ 老数据自动升级成按集口径（数据不丢、语义正确）。
         */
        let key_of = progress_sync_key;

        let remote_had_keys: std::collections::HashSet<String> =
            remote_had.iter().map(key_of).collect();
        /*
         * ⚠️ 必须取**每个键的最大** updated_at，不能直接 `.collect()`
         *
         * `.collect::<HashMap<_,_>>()` 对同一个键是 **last-write-wins**
         * （后遍历到的覆盖先前的），而下面 `pushed` 的比较基准需要的是
         * **该键最新的**那个时间戳 —— `merge_lww` 正是按 max 选的赢家。
         *
         * ⇒ 远端 jsonl 里若出现**同键重复行**（并发写没去干净 / 手工合并过），
         *   且较旧的那条**排在后面**：
         * ```text
         * 远端: [ (k, 2000), (k, 1000) ]   本机: (k, 1500)
         * merge_lww 选 (k,2000) 为赢家     ✓ 数据是对的
         * 但 .collect() 让 remote_updated[k] = 1000（最后遍历到的）
         * ⇒ pushed 判据 1000 < 2000 ⇒ **多算一条"需要推送"**
         * ```
         * ★ 影响面：只影响 `pushed` 这个**统计数字**（SyncSummary 的读数），
         *   落库路径由 `merge_lww` 决定、仍然正确。
         *   但统计数字错了会误导诊断（"怎么每次都推这么多"）。
         */
        let mut remote_updated: std::collections::HashMap<String, i64> =
            std::collections::HashMap::new();
        for p in &remote_had {
            let ts = remote_updated.entry(key_of(p)).or_insert(p.updated_at);
            if p.updated_at > *ts {
                *ts = p.updated_at;
            }
        }

        let local = self.db.list_all_progress()?;
        let merged = merge_lww(local, remote_had, key_of, |p| p.updated_at);

        let local_keys: std::collections::HashSet<String> = self
            .db
            .list_all_progress()?
            .iter()
            .map(key_of)
            .collect();
        let mut pulled = 0usize;
        for p in &merged.items {
            if !local_keys.contains(&key_of(p)) {
                pulled += 1;
            }
            self.db.upsert_progress(p)?;
        }

        let body = to_jsonl(&merged.items)?;
        // ★★ 低流量改造（契约 §7）—— 与 sync_favorites 同构，理由见那里的长注释：
        //   ① 判据必须拿 `get()` 返回的**远端原始字节**比，不能拿 `to_jsonl()` 再序列化一遍（恒等）；
        //   ② `remote_bytes == None`（远端还没有这个文件）**必须照常 PUT**，否则永远同步不出去；
        //   ③ 跳过 PUT 不影响上面的落库：pull 到的远端变更已经写进本地 DB 了。
        let remote_bytes: Option<&[u8]> = remote_raw.as_ref().map(|(b, _)| b.as_slice());
        if remote_bytes == Some(body.as_bytes()) {
            log::debug!("sync: {path} 内容与远端逐字节相同，跳过 PUT（省一次上传）");
        } else {
            self.put_with_remerge(path, body.as_bytes(), remote_etag.as_deref(), |l, r| {
                merge_lww(l, r, progress_sync_key, |p: &Progress| p.updated_at)
            }, || self.db.list_all_progress(),
               |items: &[Progress]| -> Result<(), String> {
                   for p in items { self.db.upsert_progress(p)?; }
                   Ok(())
               })
            .await?;
        }

        // 同 favorites：pushed 只算**本轮真正要推的**（远端缺失或更旧）
        let pushed = merged
            .items
            .iter()
            .filter(|m| match remote_had_keys.contains(&key_of(m)) {
                false => true,
                true => remote_updated.get(&key_of(m)).copied().unwrap_or(i64::MIN) < m.updated_at,
            })
            .count();

        Ok(SyncSummary {
            plane: "progress".into(),
            pulled,
            pushed,
            conflicts: merged.conflicts,
            note: None,
        })
    }

    /// 写远端，遇 412（别的设备抢先写了）就重拉+重新合并+再写
    ///
    /// 这是「多设备同时同步」不至于丢数据的关键：
    /// 冲突不报错给用户，而是**自动重合并**（LWW 是可交换的，重合并是安全的）。
    async fn put_with_remerge<T, FMerge, FLoad, FApply>(
        &self,
        path: &str,
        body: &[u8],
        etag: Option<&str>,
        remrege: FMerge,
        load_local: FLoad,
        apply_merged: FApply,
    ) -> Result<(), String>
    where
        // ★ `Normalize` 是 `parse_jsonl` 的约束（旧格式行的不变量修正）
        T: Serialize + for<'de> Deserialize<'de> + Clone + Normalize,
        FMerge: Fn(Vec<T>, Vec<T>) -> MergeOutcome<T>,
        FLoad: Fn() -> Result<Vec<T>, String>,
        FApply: Fn(&[T]) -> Result<(), String>,
    {
        match self.backend.put(path, body, etag).await {
            Ok(()) => Ok(()),
            Err(e) if e.contains("412") || e.contains("已被其他设备") => {
                // 别人抢先了：重拉远端，与本地重新合并后再写一次
                log::info!("sync: {path} 发生并发写，自动重新合并");
                let fresh = self.backend.get(path).await?;
                let remote: Vec<T> = match fresh {
                    Some((b, _)) => parse_jsonl(&String::from_utf8_lossy(&b))?,
                    None => Vec::new(),
                };
                let local = load_local()?;
                let merged = remrege(local, remote);
                apply_merged(&merged.items)?;

                let new_body = to_jsonl(&merged.items)?;
                let new_etag = self.backend.etag(path).await?;
                self.backend
                    .put(path, new_body.as_bytes(), new_etag.as_deref())
                    .await
            }
            Err(e) => Err(e),
        }
    }

    // ─────────────────── 备份平面：单向镜像 ───────────────────

    /// ★ 把某平台的「自带历史」镜像到远端（**只读备份，绝不回写平台**）
    ///
    /// 按设备分文件，避免多设备互相覆盖各自的视角。
    pub async fn backup_platform_history(
        &self,
        provider: &str,
        records: &[crate::provider::UserRecord],
    ) -> Result<usize, String> {
        self.backend.ensure_dir(&format!("backup/{provider}")).await?;

        let path = format!("backup/{provider}/history-{}.jsonl", self.device_id);
        // 快照语义：平台历史是「当前状态」，直接覆盖即可（无需 LWW）
        let body = to_jsonl(records)?;
        self.backend.put(&path, body.as_bytes(), None).await?;

        log::info!("已镜像 {} 条 {provider} 历史到 {path}", records.len());
        Ok(records.len())
    }

    // ─────────────── 整体备份快照（契约 §5，2026-09-29）───────────────

    /// ★ 传一份整体备份到云端，然后跑一遍保留清理
    ///
    /// # 与「增量同步」是**两条不相干的通道**
    ///
    /// 增量同步传的是几 KB 的 JSONL（`data/*.jsonl`），这里传的是
    /// 整个 zip（用户数据 + 源配置 + 插件）。Owner 说的
    /// 「整体备份和别的备份是拆分开的」就是这个意思 ——
    /// 阅读 App（Legado）亦然。所以本函数的节奏由
    /// `autoBackupIntervalMinutes` 单独控制，**不跟** `autoIntervalMinutes`。
    ///
    /// # `bytes` 由调用方打好包传进来
    ///
    /// 打包要读 `AppState`（registry / 插件目录），那是命令层的事；
    /// 这里只管「传上去 + 清理旧的」。
    pub async fn backup_snapshot(
        &self,
        name: &str,
        bytes: &[u8],
        retain_count: u32,
    ) -> Result<BackupOutcome, String> {
        self.ensure_layout().await?;
        if !is_snapshot_name(name) {
            // 文件名是我们自己生成的（`default_backup_name`），
            // 走到这里说明调用方拼错了 —— 早报错，别把脏名字写进云端
            return Err(format!("备份文件名不合规: {name}"));
        }
        let path = format!("{SNAPSHOT_DIR}/{name}");
        // 名字带秒级时间戳 ⇒ 不会撞；也无所谓覆盖谁，所以无条件写
        self.backend.put(&path, bytes, None).await?;

        let entries = self.list_snapshots_inner().await?;
        let doomed = snapshots_to_prune(&entries, retain_count);
        let mut pruned: Vec<String> = Vec::new();
        for old in doomed {
            let p = format!("{SNAPSHOT_DIR}/{old}");
            /*
             * 删不掉**不算备份失败**（契约 §5④）。
             *
             * 常见情形：坚果云对某些扩展名/配额有限制，或网络抖了一下。
             * 备份本体已经传上去了 —— 那是用户真正要保存的东西；
             * 为了「腾地方」失败而把整次备份报成失败，是主次颠倒
             * （用户会以为数据没备上，其实已经备上了）。
             */
            match self.backend.delete(&p).await {
                Ok(()) => {
                    log::info!("已清理旧备份 {p}");
                    pruned.push(old);
                }
                Err(e) => log::warn!("删除旧备份 {p} 失败（不影响本次备份，下次再试）: {e}"),
            }
        }
        let total = entries.len().saturating_sub(pruned.len());
        log::info!(
            "整体备份已上传：{path}（{} 字节），清理 {} 份，云端现有 {} 份",
            bytes.len(),
            pruned.len(),
            total
        );
        Ok(BackupOutcome {
            name: name.to_string(),
            bytes: bytes.len() as u64,
            path,
            pruned,
            total,
        })
    }

    /// 列出云端的整体备份（**已过滤**成我们自己的 `dsh-backup-*.zip`，新的在前）
    pub async fn list_snapshots(&self) -> Result<Vec<RemoteEntry>, String> {
        self.ensure_layout().await?;
        self.list_snapshots_inner().await
    }

    /// 内部版：不跑 `ensure_layout`（`backup_snapshot` 已经跑过了）
    async fn list_snapshots_inner(&self) -> Result<Vec<RemoteEntry>, String> {
        let mut entries: Vec<RemoteEntry> = self
            .backend
            .list(SNAPSHOT_DIR)
            .await?
            .into_iter()
            .filter(|e| is_snapshot_name(&e.name))
            .collect();
        // 名字里是定长的 `yyyyMMdd-HHmmss` ⇒ 字典序即时间序；降序 = 新的在前
        entries.sort_by(|a, b| b.name.cmp(&a.name));
        Ok(entries)
    }

    /// 删除云端某一份备份；返回「是否真的删了」
    ///
    /// ★ **安全护栏**：只认 `dsh-backup-*.zip`。这个函数的名字由 UI 传进来，
    /// 若不加护栏，一个拼错的/恶意的名字就能删掉用户云盘里**别的**文件。
    /// 名字不合规 ⇒ 返回 `Ok(false)`（没删），而不是报错 ——
    /// 让 UI 自己决定怎么提示。
    pub async fn delete_snapshot(&self, name: &str) -> Result<bool, String> {
        if !is_snapshot_name(name) {
            log::warn!("拒绝删除非备份文件: {name}");
            return Ok(false);
        }
        self.ensure_layout().await?;
        let path = format!("{SNAPSHOT_DIR}/{name}");
        match self.backend.delete(&path).await {
            Ok(()) => Ok(true),
            Err(e) => {
                log::warn!("删除备份 {path} 失败: {e}");
                Err(e)
            }
        }
    }

    // ─────────────────── manifest ───────────────────

    pub async fn read_manifest(&self) -> Result<Manifest, String> {
        match self.backend.get("manifest.json").await? {
            Some((b, _)) => {
                let text = String::from_utf8_lossy(&b);
                serde_json::from_str(&text).map_err(|e| format!("manifest 解析失败: {e}"))
            }
            None => Ok(Manifest::default()),
        }
    }

    pub async fn write_manifest(&self, m: &Manifest) -> Result<(), String> {
        let body = serde_json::to_vec_pretty(m).map_err(|e| e.to_string())?;
        let etag = self.backend.etag("manifest.json").await?;
        match self.backend.put("manifest.json", &body, etag.as_deref()).await {
            Ok(()) => Ok(()),
            // manifest 只是索引，冲突了就直接覆盖，不值得为它做重合并
            Err(e) if e.contains("412") || e.contains("已被其他设备") => {
                self.backend.put("manifest.json", &body, None).await
            }
            Err(e) => Err(e),
        }
    }

    /// ★ 内容源配置双向同步（第 3 个平面）
    ///
    /// `local` 是调用方（lib.rs）从 `state.third_party` 取出的当前配置快照。
    /// 返回**合并后应当生效的配置**，由调用方负责写回 registry 与磁盘。
    ///
    /// 合并策略见 [`ProviderConfigBundle`] 的说明：**整文件 LWW**，
    /// 不做逐条合并。
    pub async fn sync_provider_configs(
        &self,
        local: Vec<crate::PersistedProvider>,
        local_updated_at: i64,
    ) -> Result<(Vec<crate::PersistedProvider>, SyncSummary), String> {
        self.ensure_layout().await?;
        let path = "data/providers.json";

        // 1) 拉远端
        let remote_raw = self.backend.get(path).await?;
        let remote: Option<ProviderConfigBundle> = match &remote_raw {
            Some((bytes, _)) => {
                let text = String::from_utf8_lossy(bytes);
                // 远端格式坏了不该让同步整体失败 —— 当成「没有远端」，
                // 本地那份会重新推上去（自愈）
                match serde_json::from_str::<ProviderConfigBundle>(&text) {
                    Ok(b) => Some(b),
                    Err(e) => {
                        log::warn!("远端 providers.json 解析失败（将用本地覆盖）: {e}");
                        None
                    }
                }
            }
            None => None,
        };

        let local_bundle = ProviderConfigBundle {
            updated_at: local_updated_at,
            device: self.device_id.clone(),
            providers: local.clone(),
        };

        // 2) 整文件 LWW：谁新用谁
        let (winner, conflicts, pulled, pushed) = match &remote {
            Some(r) if r.updated_at > local_bundle.updated_at => {
                // 远端更新 → 采用远端
                (r.clone(), 1usize, r.providers.len(), 0usize)
            }
            Some(_) => {
                // 本地更新或相同 → 采用本地
                (local_bundle.clone(), 0, 0, local.len())
            }
            None => {
                // 远端还没有 → 推送本地
                (local_bundle.clone(), 0, 0, local.len())
            }
        };

        // 3) 写回远端（冲突则重试一次，直接覆盖 —— 整文件语义下重合并没有意义）
        let body = serde_json::to_vec_pretty(&winner).map_err(|e| e.to_string())?;
        /*
         * ★★ 低流量改造（契约 §7，2026-09-29 task-75）—— 与 sync_favorites / sync_progress 同构
         *
         * 判据 = 「即将写上去的字节」与「远端**原始**字节」逐字节相同
         *        ⇒ 这次 PUT 纯属浪费，跳过。
         *
         * `remote_raw` 是 `get()` 的**原样**返回（上面第 1 步拿到的），
         * 不是重新序列化的结果 —— 拿 `to_vec_pretty(&winner)` 跟它自己比是恒等，
         * 会连首次上传都跳过。
         *
         * `remote_bytes == None`（远端还没有 providers.json）⇒ 必须照常 PUT。
         */
        let remote_bytes: Option<&[u8]> = remote_raw.as_ref().map(|(b, _)| b.as_slice());
        if remote_bytes == Some(body.as_slice()) {
            log::debug!("sync: {path} 内容与远端逐字节相同，跳过 PUT（省一次上传）");
        } else {
            let etag = self.backend.etag(path).await?;
            match self.backend.put(path, &body, etag.as_deref()).await {
                Ok(()) => {}
                Err(e) if e.contains("412") || e.contains("已被其他设备") => {
                    log::info!("providers.json 被其他设备抢先写入，用本地版本覆盖");
                    self.backend.put(path, &body, None).await?;
                }
                Err(e) => return Err(e),
            }
        }

        let summary = SyncSummary {
            plane: "providers".into(),
            pulled,
            pushed,
            conflicts,
            note: Some(format!("共 {} 个第三方源", winner.providers.len())),
        };

        Ok((winner.providers, summary))
    }

    /// 凭据平面 —— 把 `plugins/.data/` 里的登录态加密后同步
    ///
    /// # 三个关键设计（都对应 Lead 提的问题）
    ///
    /// ```text
    /// ① passphrase = None ⇒ **不静默跳过**，返回一条 note="凭据未同步" 的摘要
    ///    理由：提案 UI 那条硬要求 —— 显示"同步完成"但凭据没走就是假绿。
    ///    调用方拿到这条 note 就该显示"凭据未同步"，而不是把整次同步报成功。
    ///
    /// ② 剔除缓存后为空的插件 ⇒ 整文件跳过上传
    ///    这一条是黑名单方案的自动收益：
    ///    26 个插件不用 host.store，4 个只存缓存 ⇒ 它们零上传，
    ///    不需要额外维护"哪些插件有凭据"的名单。
    ///
    /// ③ 本方法**不返回 Err 给 sync_all**（失败隔离）
    ///    凭据失败不该让收藏/进度也同步不了 —— 见 `sync_all` 里的处理。
    /// ```
    ///
    /// # 远端路径
    /// `data/credentials.enc` —— 单个加密文件，**不做多设备分文件**
    ///
    /// 理由：凭据是「后写覆盖」语义（提案第 5 条），合并没有意义。
    /// 分文件会让"哪台设备的最新"变成一个要额外解决的问题。
    pub async fn sync_credentials(
        &self,
        passphrase: Option<&str>,
    ) -> Result<SyncSummary, String> {
        use crate::sync::credentials as cred;

        /*
         * ① 没有口令 ⇒ 明确报"未同步"，**不是**静默成功
         */
        let Some(pass) = passphrase.filter(|p| !p.is_empty()) else {
            return Ok(SyncSummary {
                plane: "credentials".into(),
                pulled: 0,
                pushed: 0,
                conflicts: 0,
                note: Some("凭据未同步：尚未设置口令".into()),
            });
        };

        /*
         * 没挂 data_dir ⇒ 读不到插件存储。
         * 这也是"未同步"，但要说明原因不同（不是没设口令，是引擎没配好）。
         */
        let Some(data_dir) = self.data_dir.as_ref() else {
            return Ok(SyncSummary {
                plane: "credentials".into(),
                pulled: 0,
                pushed: 0,
                conflicts: 0,
                note: Some("凭据未同步：同步引擎未挂载数据目录".into()),
            });
        };

        // ② 收集各插件的 .data，剔除缓存 key
        //
        // ★ 收集逻辑抽在 `credentials::collect` —— 备份导出走**同一个函数**，
        //   两处各写一份必然漂开（一处加黑名单另一处忘了 ⇒ 缓存被塞进备份）。
        let bundle = cred::collect(data_dir)?;
        let providers_with_creds = bundle.kept;
        let providers_skipped = bundle.skipped;

        /*
         * ③ 一个凭据都没有 ⇒ 不上传空文件
         *
         * ★ 这是"空文件跳过"的实现点。注意它**也**覆盖了"用户刚装好还没登录"的场景。
         */
        if bundle.is_empty() {
            return Ok(SyncSummary {
                plane: "credentials".into(),
                pulled: 0,
                pushed: 0,
                conflicts: 0,
                note: Some("凭据未同步：没有任何已保存的登录态".into()),
            });
        }

        /*
         * ④ 序列化 + 加密
         *
         * ★ 超过 `MAX_PLAINTEXT` 时 `encrypt` 会返回 `TooLarge` ——
         *   这里**不吞掉**，如实返回错误（见 Lead 要求的"必须报错，不许静默"）。
         */
        let blob = cred::encrypt_bundle(pass, &bundle).map_err(|e| format!("凭据加密失败: {e}"))?;

        // ⑤ 上传（覆盖写 —— 后写覆盖，符合提案第 5 条）
        let path = "data/credentials.enc";
        self.backend.put(path, &blob, None).await?;

        Ok(SyncSummary {
            plane: "credentials".into(),
            pulled: 0,
            pushed: providers_with_creds,
            conflicts: 0,
            note: Some(format!(
                "已加密上传 {} 个源的登录态（{} 个源的缓存已排除）",
                providers_with_creds, providers_skipped
            )),
        })
    }

    /// 一次完整同步（独立平面两个文件 + 内容源配置 + manifest）
    ///
    /// ⚠️ 等价于 [`sync_all_with_passphrase`]`(None)` ——
    ///    **不传口令**，凭据平面只会返回「凭据未同步：尚未设置口令」。
    ///
    /// ★ 为什么保留这个无参版本（而不是直接改签名）：
    ///   它是既有契约，`tests/t76_webdav_e2e.rs` 等集成测试按无参调用。
    ///   为了让凭据能真的同步去改签名，会把**六处**调用点（含集成测试）
    ///   一起拖下水 —— 而那些测试根本不关心口令。
    ///   ⇒ 加一个**带口令的新方法**，旧方法转调它。语义更清楚，改动面更小。
    pub async fn sync_all(&self) -> Result<Vec<SyncSummary>, String> {
        self.sync_all_with_passphrase(None).await
    }

    /// 一次完整同步，**并带上凭据平面的口令**
    ///
    /// # 参数 `passphrase`
    ///
    /// `Some(p)` ⇒ 凭据平面真的加密上传；`None` ⇒ 返回一条
    /// 「凭据未同步」的摘要（**不是**静默跳过）。
    ///
    /// ★ 为什么口令由参数传进来、而不是 `SyncEngine` 自己去读钥匙串：
    ///   `SyncEngine` 是纯同步逻辑（单测直接构造它），
    ///   让它碰钥匙串会让单测依赖本机钥匙串状态 —— 那是不可复现的测试。
    ///   读钥匙串是**命令层**的事（`commands_backup::sync_now`）。
    pub async fn sync_all_with_passphrase(
        &self,
        passphrase: Option<&str>,
    ) -> Result<Vec<SyncSummary>, String> {
        let mut out = Vec::new();
        out.push(self.sync_favorites().await?);
        out.push(self.sync_progress().await?);

        /*
         * ★★★ 凭据平面：**失败隔离**
         *
         * ```text
         * 凭据失败（加密错 / 上传错 / 口令错）**不该**让收藏和进度也同步不了。
         * 理由：用户最在意的是收藏和进度；凭据坏了可以重新登，
         *       但一次同步把三者全部失败，用户会觉得"同步彻底坏了"。
         * ⇒ 这里把 Err **转成**一条带 note 的摘要，而不是 `?` 冒泡。
         * ```
         *
         * ⚠️ 口令由**调用方**从钥匙串读出来传进来（见参数说明）。
         *    `None` ⇒ 这里返回"凭据未同步：尚未设置口令"，
         *    UI 据此必须显示"凭据未同步"，不许显示"同步完成"。
         */
        out.push(
            self.sync_credentials(passphrase)
                .await
                .unwrap_or_else(|e| SyncSummary {
                    plane: "credentials".into(),
                    pulled: 0,
                    pushed: 0,
                    conflicts: 0,
                    note: Some(format!("凭据同步失败（不影响其它平面）: {e}")),
                }),
        );

        let mut m = self.read_manifest().await.unwrap_or_default();
        m.schema_version = SCHEMA_VERSION;
        m.last_sync_at = chrono::Utc::now().timestamp_millis();
        if !m.devices.contains(&self.device_id) {
            m.devices.push(self.device_id.clone());
        }
        self.write_manifest(&m).await?;

        Ok(out)
    }
}

// ─────────────────────────── LWW 合并 ───────────────────────────

/// 合并结果
#[derive(Debug, Clone)]
pub struct MergeOutcome<T> {
    pub items: Vec<T>,
    /// 被另一侧覆盖的条数（诊断用）
    pub conflicts: usize,
}

/// `progress` 同步时的**合并键** —— 由三列推导的按集键
///
/// # ★★★ 为什么不用 `Progress.key` 字段（2026-10-12 按集扩容）
///
/// `upsert_progress` 落库时**从 (provider,native_id,episode_id) 重算**主键，
/// 不信任传进来的 `key`。**合并/去重也必须用同一个推导**，否则：
/// ```text
/// 老设备 jsonl: key = "srca:3611"        （老口径，没第三段）
/// 本机新库那条: key = "srca:3611:48884"  （新口径）
/// ⇒ 按 p.key 去重 ⇒ 当成两条不同记录
/// ⇒ 两份都 upsert 到**同一个**表主键 ⇒ HashMap 顺序不定 ⇒ 可能写进较旧的一条
/// ⇒ 进度倒退（同步最不能出的错）
/// ```
/// ⇒ 用**同一口径**推导 ⇒ 老行 `(srca,3611,48884)` 与本机那条推出同一个键
///   ⇒ 正确走 LWW 取新的。老设备同步过来的数据也据此**自动升级**成按集口径
///   （它 jsonl 里的 `key` 字段被忽略，只看三列）。
///
/// ⚠️ 保持与 `store::progress_key` 的**同一形状**（`provider:native_id:ep`
///    或 `provider:native_id:`）。它是 `pub(crate)` 的 —— 但本模块在
///    `crate::sync`，可以直接复用 `crate::store` 的那个函数；
///    这里**刻意复用它**而不是抄一份（两套真相必然漂）。
fn progress_sync_key(p: &Progress) -> String {
    crate::store::progress_key(&p.provider, &p.native_id, p.episode_id.as_deref())
}

/// ★ Last-Write-Wins 合并
///
/// 规则（严格按方案文档 2.2）：
/// 1. 同一 key，`updated_at` 大者胜
/// 2. **删除写墓碑**（`deleted=true`），否则会被其他设备的旧数据复活
/// 3. 时间戳完全相同时，本地优先（保证幂等：重复同步结果一致）
///
/// 关键性质：**可交换**（local/remote 换序结果相同，除同时刻的平手），
/// 因此并发冲突时「重拉+重合并」是安全的。
pub fn merge_lww<T, K, U>(local: Vec<T>, remote: Vec<T>, key_of: K, updated_of: U) -> MergeOutcome<T>
where    T: Clone,
    K: Fn(&T) -> String,
    U: Fn(&T) -> i64,
{
    use std::collections::HashMap;

    let mut map: HashMap<String, (T, bool)> = HashMap::new(); // (item, from_local)
    let mut conflicts = 0usize;

    for it in local {
        map.insert(key_of(&it), (it, true));
    }

    for r in remote {
        let k = key_of(&r);
        match map.get(&k) {
            None => {
                map.insert(k, (r, false));
            }
            Some((l, _)) => {
                let lt = updated_of(l);
                let rt = updated_of(&r);
                if rt > lt {
                    // 远端更新 → 远端胜（这是一次「被覆盖」）
                    conflicts += 1;
                    map.insert(k, (r, false));
                } else if rt == lt {
                    // 平手：本地优先，保证可重复执行结果稳定
                } else {
                    // 本地更新 → 本地胜，保持不动
                }
            }
        }
    }

    MergeOutcome {
        items: map.into_values().map(|(v, _)| v).collect(),
        conflicts,
    }
}

// ─────────────────────────── JSONL 读写 ───────────────────────────

/// 序列化为 JSONL（每行一个 JSON 对象）
///
/// 用 JSONL 而非单个 JSON 数组：**便于人工查看与增量解析**，
/// 出问题时能直接 tail 看最后几条。
pub fn to_jsonl<T: Serialize>(items: &[T]) -> Result<String, String> {
    let mut out = String::new();
    for it in items {
        let line = serde_json::to_string(it).map_err(|e| format!("序列化失败: {e}"))?;
        out.push_str(&line);
        out.push('\n');
    }
    Ok(out)
}

/// 解析 JSONL；**跳过空行与坏行**而不是整体失败
///
/// 为什么容错：云端文件可能被其他工具手动编辑过，
/// 因为一行坏数据就整份同步失败，用户体验很差。
///
/// ★ 解析成功后对每条调用 [`Normalize::normalize`]（2026-09-21 补）：
///   这是**所有**远端/备份读取的唯一入口（`sync_favorites`、
///   `sync_progress`、`put_with_remerge` 都走它），
///   把"旧格式行的缺省字段可能违反不变量"这件事
///   集中在一个点上修掉，而不是指望每个调用方记得。
pub fn parse_jsonl<T>(text: &str) -> Result<Vec<T>, String>
where
    T: for<'de> Deserialize<'de> + Normalize,
{
    let mut out = Vec::new();
    let mut bad = 0usize;
    for (i, line) in text.lines().enumerate() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        match serde_json::from_str::<T>(t) {
            Ok(mut v) => {
                v.normalize();
                out.push(v);
            }
            Err(e) => {
                bad += 1;
                log::warn!("JSONL 第 {} 行解析失败（已跳过）: {e}", i + 1);
            }
        }
    }
    if bad > 0 && out.is_empty() {
        return Err(format!("JSONL 全部 {bad} 行都无法解析，可能不是本应用的备份"));
    }
    Ok(out)
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn fav(key: &str, updated: i64, deleted: bool) -> Favorite {
        Favorite {
            key: key.into(),
            provider: "p".into(),
            native_id: key.into(),
            title: format!("t-{key}"),
            cover: None,
            group_name: None,
            kind: "series".into(),
            /*
             * 不变量（见 store.rs 的 `favorited` 文档）：
             *     deleted=1  ⇔  !favorited && !following
             *
             * 写成从 `deleted` 推导而不是写死，是为了让这个 fixture
             * 在两种墓碑状态下都自洽 —— 否则 merge 用例会拿到
             * 「墓碑却还开着收藏」这种真实数据里不该出现的组合。
             */
            favorited: !deleted,
            following: false,
            last_episode_count: 0,
            last_episode_title: None,
            unread_count: 0,
            last_checked_at: 0,
            last_update_at: 0,
            note: None,
            created_at: 0,
            updated_at: updated,
            deleted,
        }
    }

    fn prog(key: &str, updated: i64, pos: u64) -> Progress {
        Progress {
            key: key.into(),
            provider: "p".into(),
            native_id: key.into(),
            title: format!("t-{key}"),
            cover: None,
            episode_id: None,
            episode_title: None,
            position: pos,
            duration: 100,
            finished: false,
            updated_at: updated,
        }
    }

    /// 远端更新 → 远端胜
    #[test]
    fn newer_remote_wins() {
        let out = merge_lww(
            vec![fav("a", 100, false)],
            vec![fav("a", 200, false)],
            |f| f.key.clone(),
            |f| f.updated_at,
        );
        assert_eq!(out.items.len(), 1);
        assert_eq!(out.items[0].updated_at, 200, "更新的远端应获胜");
        assert_eq!(out.conflicts, 1);
    }

    /// 本地更新 → 本地胜
    #[test]
    fn newer_local_wins() {
        let out = merge_lww(
            vec![fav("a", 300, false)],
            vec![fav("a", 200, false)],
            |f| f.key.clone(),
            |f| f.updated_at,
        );
        assert_eq!(out.items[0].updated_at, 300);
        assert_eq!(out.conflicts, 0);
    }

    /// ★ 墓碑必须能压过旧的「未删除」记录，否则删除会被复活
    #[test]
    fn tombstone_beats_older_alive_record() {
        // 本地：已删除（墓碑，时间戳新）
        // 远端：还以为存在（旧的）
        let out = merge_lww(
            vec![fav("a", 500, true)],
            vec![fav("a", 100, false)],
            |f| f.key.clone(),
            |f| f.updated_at,
        );
        assert!(out.items[0].deleted, "墓碑必须获胜，否则删除会被复活");

        // 反向：远端墓碑更新 → 也要压过本地存活记录
        let out2 = merge_lww(
            vec![fav("a", 100, false)],
            vec![fav("a", 500, true)],
            |f| f.key.clone(),
            |f| f.updated_at,
        );
        assert!(out2.items[0].deleted, "远端墓碑同样要压过本地旧记录");
    }

    /// 平手时本地优先 → 保证重复同步结果稳定（幂等）
    #[test]
    fn tie_prefers_local_and_is_idempotent() {
        let local = vec![fav("a", 100, false)];
        let remote = vec![fav("a", 100, false)];
        let out1 = merge_lww(local.clone(), remote.clone(), |f| f.key.clone(), |f| f.updated_at);
        let out2 = merge_lww(out1.items.clone(), remote, |f| f.key.clone(), |f| f.updated_at);
        assert_eq!(out1.items.len(), 1);
        assert_eq!(out2.items.len(), 1);
        assert_eq!(out1.items[0].updated_at, out2.items[0].updated_at);
    }

    /// 两边独有项都要保留（并集）
    #[test]
    fn union_of_both_sides() {
        let out = merge_lww(
            vec![fav("local-only", 100, false), fav("shared", 100, false)],
            vec![fav("remote-only", 100, false), fav("shared", 50, false)],
            |f| f.key.clone(),
            |f| f.updated_at,
        );
        assert_eq!(out.items.len(), 3, "并集：3 个不同 key");
        let keys: std::collections::HashSet<_> = out.items.iter().map(|f| f.key.clone()).collect();
        assert!(keys.contains("local-only"));
        assert!(keys.contains("remote-only"));
        assert!(keys.contains("shared"));
    }

    /// 合并可交换（除同时刻平手），这是「冲突后重合并」安全的前提
    #[test]
    fn merge_is_commutative_for_distinct_timestamps() {
        let a = vec![fav("x", 100, false), fav("y", 500, false)];
        let b = vec![fav("x", 300, false), fav("z", 200, false)];

        let ab = merge_lww(a.clone(), b.clone(), |f| f.key.clone(), |f| f.updated_at);
        let ba = merge_lww(b, a, |f| f.key.clone(), |f| f.updated_at);

        let mut m1: Vec<(String, i64)> = ab.items.iter().map(|f| (f.key.clone(), f.updated_at)).collect();
        let mut m2: Vec<(String, i64)> = ba.items.iter().map(|f| (f.key.clone(), f.updated_at)).collect();
        m1.sort();
        m2.sort();
        assert_eq!(m1, m2, "不同时间戳下合并必须可交换");
    }

    /// 进度合并（同一套 LWW，验证泛型可用）
    #[test]
    fn progress_uses_same_lww() {
        let out = merge_lww(
            vec![prog("k", 100, 10)],
            vec![prog("k", 900, 500)],
            |p| p.key.clone(),
            |p| p.updated_at,
        );
        assert_eq!(out.items[0].position, 500, "较新的进度应获胜");
    }

    /// ★★★ 老设备（老 key 口径）同步过来 ⇒ 与本机新口径那条归到**同一个槽**
    ///
    /// # 为什么要这条（云同步兼容，2026-10-12 按集扩容）
    ///
    /// 老设备的 jsonl 里 `key = "provider:native_id"`（没第三段），
    /// 本机新库那条是 `"provider:native_id:episode_id"`。
    /// 若合并按 `p.key` 去重 ⇒ 当成两条 ⇒ 两份都 upsert 到**同一个**表主键
    /// ⇒ HashMap 顺序不定 ⇒ 可能写进**较旧**的一条 ⇒ **进度倒退**。
    /// ⇒ 用 `progress_sync_key`（由三列推导）去重 ⇒ 归到同一个槽 ⇒ LWW 正确。
    #[test]
    fn progress_merge_uses_field_derived_key_for_old_devices() {
        // 本机（新口径）：episode_id = Some("48884")，position 500（较新）
        let local = Progress {
            key: "srca:3611:48884".into(),
            provider: "srca".into(),
            native_id: "3611".into(),
            title: "长剧".into(),
            cover: None,
            episode_id: Some("48884".into()),
            episode_title: Some("第03集".into()),
            position: 500,
            duration: 9285,
            finished: false,
            updated_at: 2000,
        };
        // 老设备同步过来（老 key 口径，无第三段），position 100（较旧）
        let remote_old = Progress {
            key: "srca:3611".into(),
            ..local.clone()
        };
        let remote_old = Progress { position: 100, updated_at: 1000, ..remote_old };

        let out = merge_lww(
            vec![local],
            vec![remote_old],
            progress_sync_key,
            |p| p.updated_at,
        );

        assert_eq!(
            out.items.len(),
            1,
            "★★ 老 key 口径那条必须与本机新口径那条**归到同一个槽** —— \
             否则会被当成两条，双双 upsert 到同一个表主键，顺序不定 ⇒ 进度可能倒退"
        );
        assert_eq!(
            out.items[0].position, 500,
            "★★ 归到同一个槽后 LWW 取较新的（本机 500），老设备的旧数据不许把它顶回去"
        );
    }

    /// ★ 老设备 jsonl 里的 `key` 字段被**忽略**：同三列推导同一个 key
    #[test]
    fn sync_key_ignores_stored_key_field() {
        let a = Progress {
            key: "srca:3611".into(), // 老口径
            provider: "srca".into(),
            native_id: "3611".into(),
            title: "t".into(),
            cover: None,
            episode_id: Some("48884".into()),
            episode_title: None,
            position: 0,
            duration: 0,
            finished: false,
            updated_at: 0,
        };
        let mut b = a.clone();
        b.key = "srca:3611:48884".into(); // 新口径
        assert_eq!(
            progress_sync_key(&a),
            progress_sync_key(&b),
            "★ 无论 jsonl 里 key 写的是老口径还是新口径，推导结果必须相同"
        );
        assert_eq!(progress_sync_key(&a), "srca:3611:48884");
    }

    // ─────────── 假后端：把整条 `sync_progress()` 跑起来 ───────────

    /// 内存里的假 WebDAV：够 `sync_progress` 走完「拉 → 合并 → 落库 → 推」
    ///
    /// ★ 为什么值得写：上面那些 `merge_lww` 单测只钉住**纯函数**，
    ///   而 `sync_progress` 里的**合并键来源**（`p.key` 还是字段推导）
    ///   只有走完整条链路才看得出来。实测：把 `let key_of =
    ///   progress_sync_key;` 改回 `|p: &Progress| p.key.clone()`，
    ///   纯函数单测**照样全绿**（就是下面这两条把它钉住的）。
    #[derive(Default)]
    struct FakeBackend {
        files: std::sync::Mutex<std::collections::HashMap<String, (Vec<u8>, Option<String>)>>,
    }

    impl FakeBackend {
        fn new() -> Self {
            Self::default()
        }

        fn seed(&self, path: &str, body: &str) {
            self.files.lock().unwrap().insert(
                path.to_string(),
                (body.as_bytes().to_vec(), Some("etag-1".into())),
            );
        }

        /// 当前远端文件的文本（测试用来数行数）
        fn body_of(&self, path: &str) -> String {
            self.files
                .lock()
                .unwrap()
                .get(path)
                .map(|(b, _)| String::from_utf8_lossy(b).into_owned())
                .unwrap_or_default()
        }
    }

    #[async_trait::async_trait]
    impl SyncBackend for FakeBackend {
        fn name(&self) -> &str {
            "fake"
        }

        async fn get(&self, path: &str) -> Result<Option<(Vec<u8>, Option<String>)>, String> {
            Ok(self.files.lock().unwrap().get(path).cloned())
        }

        async fn put(&self, path: &str, data: &[u8], if_match: Option<&str>) -> Result<(), String> {
            let mut files = self.files.lock().unwrap();
            let cur = files.get(path).and_then(|(_, e)| e.clone());
            /*
             * 契约里的两种条件写（见 `SyncBackend::put` 文档）：
             *   Some("")   = 仅当**不存在**时创建
             *   Some(etag) = 必须与当前 ETag 匹配
             * 不实现的话，本测试就绕过了「并发写触发重合并」那条路径 ——
             * 虽然本测试不触发它，但假后端失真会变成日后误判的来源。
             */
            match if_match {
                Some("") => {
                    if cur.is_some() {
                        return Err("412 远端已存在".into());
                    }
                }
                Some(m) => {
                    if cur.as_deref() != Some(m) {
                        return Err("412 已被其他设备修改".into());
                    }
                }
                None => {}
            }
            files.insert(
                path.to_string(),
                (data.to_vec(), Some(format!("etag-{}", data.len()))),
            );
            Ok(())
        }

        async fn etag(&self, path: &str) -> Result<Option<String>, String> {
            Ok(self.files.lock().unwrap().get(path).and_then(|(_, e)| e.clone()))
        }

        async fn ensure_dir(&self, _path: &str) -> Result<(), String> {
            Ok(())
        }

        async fn ping(&self) -> Result<String, String> {
            Ok("fake".into())
        }

        async fn list(&self, _dir: &str) -> Result<Vec<crate::sync::webdav::RemoteEntry>, String> {
            Ok(Vec::new())
        }

        async fn delete(&self, path: &str) -> Result<(), String> {
            self.files.lock().unwrap().remove(path);
            Ok(())
        }
    }

    /// 造一个进度行（老设备的 jsonl 用 `to_jsonl` 生成，避免手写转义）
    fn prog_row(key: &str, position: u64, updated_at: i64) -> Progress {
        Progress {
            key: key.into(),
            provider: "srca".into(),
            native_id: "3611".into(),
            title: "长剧".into(),
            cover: None,
            episode_id: Some("48884".into()),
            episode_title: Some("第03集".into()),
            position,
            duration: 9285,
            finished: false,
            updated_at,
        }
    }

    /// ★★★ **行为级**钉子：老设备 jsonl 的 `key` 是老口径，
    ///     合并后同一条进度在**云端与本地都只许占一个槽**
    ///
    /// # 为什么纯函数单测不够
    ///
    /// 上面 `progress_merge_uses_field_derived_key_for_old_devices` 是
    /// **自己把 `progress_sync_key` 传进** `merge_lww` 的 —— 它钉住的是
    /// 那个函数本身，而不是 `sync_progress` **用不用**它。
    /// 实测：把 `sync_progress` 里的 `let key_of = progress_sync_key;`
    /// 改回 `|p: &Progress| p.key.clone()`：
    /// ```text
    /// 本机库:     key = "srca:3611:48884"  position 500  较新
    /// 远端 jsonl: key = "srca:3611"        position 100  较旧
    /// ⇒ 按 p.key 去重 ⇒ 当成**两条**记录 ⇒ merged.items 变 2 条
    /// ⇒ ① 推回云端的 JSONL 也是 2 行（同一条记录存两份）
    /// ⇒ ② 两条都 upsert 到**同一个**表主键，HashMap 顺序不定
    ///      ⇒ 有 50% 概率把较旧的 100 写上去 ⇒ 用户进度倒退
    /// ```
    /// 上面那个纯函数单测对此**全绿** —— 所以这里必须走完整链路。
    ///
    /// ⚠️ 判据刻意选「推回去的**行数**」而不是只断 DB 的值：
    ///   ② 是 HashMap 顺序决定的**随机**结果，只断它会有 50% 假绿；
    ///   ① 是确定的（2 条 vs 1 条），先断它，再断用户可见的那个值。
    #[tokio::test]
    async fn sync_progress_keeps_one_slot_for_old_device_jsonl() {
        let db = Arc::new(Db::in_memory().unwrap());
        // 本机（新口径，较新）
        db.upsert_progress(&prog_row("srca:3611:48884", 500, 2000)).unwrap();

        // 老设备推上来的那行：老口径 key（没第三段），且较旧
        let backend = Arc::new(FakeBackend::new());
        backend.seed(
            "data/progress.jsonl",
            &to_jsonl(&[prog_row("srca:3611", 100, 1000)]).unwrap(),
        );
        let engine = SyncEngine::new(backend.clone(), db.clone(), "dev-a".into());
        engine.sync_progress().await.unwrap();

        assert_eq!(
            backend.body_of("data/progress.jsonl").lines().count(),
            1,
            "★★★ 同一条进度（同 provider+native_id+episode_id）推回远端只许有 **1** 行 —— \
             按 `p.key` 去重时老口径那条会被当成独立记录，merged.items 变 2 条，\
             推回去的 JSONL 就是 2 行（云端同一条记录存两份，且互相覆盖）"
        );
        let rows = db.list_all_progress().unwrap();
        assert_eq!(rows.len(), 1, "★ 同一条记录在本地库也只许占一行");
        assert_eq!(
            rows[0].position, 500,
            "★★★ 老设备的**旧**数据不许把本机较新的进度顶回去 —— \
             这正是 sync_progress 用 progress_sync_key 而不是 p.key 的理由"
        );
        assert_eq!(rows[0].updated_at, 2000, "★ 时间戳也该是较新那条");
    }

    /// ★ 反向控制：远端**确实更新**时，进度必须推上来
    ///   （键改了口径 ≠ 只认本地 —— 少了这条，把合并键写成常量也能绿）
    #[tokio::test]
    async fn sync_progress_pulls_newer_remote_progress_for_old_device_jsonl() {
        let db = Arc::new(Db::in_memory().unwrap());
        db.upsert_progress(&prog_row("srca:3611:48884", 100, 1000)).unwrap();

        let backend = Arc::new(FakeBackend::new());
        backend.seed(
            "data/progress.jsonl",
            &to_jsonl(&[prog_row("srca:3611", 700, 2000)]).unwrap(),
        );
        let engine = SyncEngine::new(backend.clone(), db.clone(), "dev-a".into());
        engine.sync_progress().await.unwrap();

        assert_eq!(
            backend.body_of("data/progress.jsonl").lines().count(),
            1,
            "★ 同样只许 1 行（两条记录归到同一个槽）"
        );
        let rows = db.list_all_progress().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].position, 700,
            "★ 远端更新的那条必须推上来（老口径 key 也要认得出来是同一集）"
        );
    }

    #[test]
    fn jsonl_roundtrip() {
        let items = vec![fav("a", 1, false), fav("b", 2, true)];
        let text = to_jsonl(&items).unwrap();
        assert_eq!(text.lines().count(), 2, "应为两行");
        let back: Vec<Favorite> = parse_jsonl(&text).unwrap();
        assert_eq!(back.len(), 2);
        assert_eq!(back[1].key, "b");
    }

    /// 坏行应被跳过，而不是让整份同步失败
    #[test]
    fn jsonl_skips_bad_lines_but_keeps_good() {
        let text = "{\"key\":\"a\"}\nNOT_JSON\n\n{\"key\":\"b\"}\n";
        // 这两行缺少必填字段，会解析失败 → 全部坏 → 报错
        let r: Result<Vec<Favorite>, _> = parse_jsonl(text);
        assert!(r.is_err(), "全部坏行时应报错，提示不是本应用的备份");

        // 混合场景：好行保留，坏行跳过
        let good = to_jsonl(&[fav("ok", 1, false)]).unwrap();
        let mixed = format!("{good}BADLINE\n");
        let ok: Vec<Favorite> = parse_jsonl(&mixed).unwrap();
        assert_eq!(ok.len(), 1);
        assert_eq!(ok[0].key, "ok");
    }

    #[test]
    fn jsonl_ignores_blank_lines() {
        let text = "\n\n{\"key\":\"a\",\"provider\":\"p\",\"native_id\":\"a\",\"title\":\"t\",\"kind\":\"series\",\"following\":false,\"last_episode_count\":0,\"unread_count\":0,\"last_checked_at\":0,\"created_at\":0,\"updated_at\":1,\"deleted\":false}\n\n";
        let v: Vec<Favorite> = parse_jsonl(text).unwrap();
        assert_eq!(v.len(), 1);
    }

    /// ★★ 升级前的旧 JSONL 必须仍能解析，且语义被正确翻译
    ///
    /// # 这个用例是实测逼出来的（2026-09-21）
    ///
    /// `favorited` / `last_update_at` 是 2026-09-20 新加的字段，
    /// 加完没给 `#[serde(default)]`，于是**升级前写到云盘的
    /// `data/favorites.jsonl` 整份解析失败**，报
    /// `JSONL 全部 N 行都无法解析，可能不是本应用的备份`，
    /// 而 `sync_favorites` 会让这个错误**向上传播 → 整个同步中断**。
    ///
    /// 上面的 `jsonl_ignores_blank_lines` 正是踩到这个才失败的
    /// （它的字面量就是一条旧格式行）。
    ///
    /// # 断言的三件事
    ///
    /// 1. 旧行能解析（不抛错）
    /// 2. `deleted=0` 的旧行 → `favorited=true`（收藏不会凭空消失）
    /// 3. `deleted=1` 的旧行 → `favorited=false`（★ 墓碑不许复活）
    ///
    /// 第 3 条最关键：`list_favorites` **只按 `favorited=1` 过滤**
    /// （不带 `deleted` 条件），所以墓碑若被缺省成 `favorited=true`，
    /// 用户删掉的收藏会重新出现在列表里。
    #[test]
    fn legacy_jsonl_without_new_fields_still_parses() {
        // 升级前的格式：没有 favorited / last_update_at
        let visible = "{\"key\":\"a\",\"provider\":\"p\",\"native_id\":\"a\",\"title\":\"t\",\
                       \"kind\":\"series\",\"following\":false,\"last_episode_count\":0,\
                       \"unread_count\":0,\"last_checked_at\":0,\"created_at\":0,\
                       \"updated_at\":1,\"deleted\":false}";
        let tombstone = "{\"key\":\"b\",\"provider\":\"p\",\"native_id\":\"b\",\"title\":\"t\",\
                         \"kind\":\"series\",\"following\":false,\"last_episode_count\":0,\
                         \"unread_count\":0,\"last_checked_at\":0,\"created_at\":0,\
                         \"updated_at\":2,\"deleted\":true}";
        let text = format!("{visible}\n{tombstone}\n");

        let v: Vec<Favorite> = parse_jsonl(&text).expect("旧格式必须仍可解析");
        assert_eq!(v.len(), 2, "两行都应解析出来");

        // ② 可见收藏：缺省 favorited 必须为 true，否则收藏会消失
        assert!(v[0].favorited, "旧格式的可见收藏应被视为已收藏");
        assert!(!v[0].deleted);
        assert_eq!(v[0].last_update_at, 0, "缺失的新时间字段应缺省为 0");

        // ③ ★ 墓碑：必须被 normalize 清成 !favorited，否则删除会复活
        assert!(v[1].deleted, "墓碑应保持 deleted");
        assert!(
            !v[1].favorited,
            "墓碑绝不能是 favorited —— 否则 list_favorites 会让它复活"
        );
        assert!(!v[1].following, "墓碑不应开着追更");
    }

    /// `Normalize` 的不变量：`deleted=1 ⇔ !favorited && !following`
    #[test]
    fn normalize_enforces_tombstone_invariant() {
        use crate::store::Normalize as _;

        // 墓碑却开着两个状态 → 必须都被清掉
        let mut f = fav("x", 1, true);
        f.favorited = true;
        f.following = true;
        f.unread_count = 5;
        f.normalize();
        assert!(!f.favorited && !f.following && f.unread_count == 0);

        // 两个状态都关、又不是墓碑 → 补成墓碑（该行无意义）
        let mut g = fav("y", 1, false);
        g.favorited = false;
        g.following = false;
        g.normalize();
        assert!(g.deleted, "两个状态都没了的行应当成为墓碑");

        // ★ 「只追更不收藏」是**合法**状态，不许被 normalize 改动
        let mut h = fav("z", 1, false);
        h.favorited = false;
        h.following = true;
        h.normalize();
        assert!(!h.deleted, "只追更不收藏必须保持存活");
        assert!(h.following && !h.favorited);
    }

    /// ★ `pushed` 的语义必须是「本轮真正要推的量」，而不是「合并结果的条数」。
    ///
    /// 否则每次同步都报同一个数字（文件里总共多少条），
    /// 用户会以为一直在重传 —— 这正是实测中发现并修掉的问题。
    #[test]
    fn pushed_counts_only_genuinely_new_or_newer() {
        // 复现 sync_favorites 里 pushed 的计算口径
        fn count_pushed(merged: &[Favorite], remote_had: &[Favorite]) -> usize {
            let remote_keys: std::collections::HashSet<String> =
                remote_had.iter().map(|f| f.key.clone()).collect();
            let remote_updated: std::collections::HashMap<String, i64> =
                remote_had.iter().map(|f| (f.key.clone(), f.updated_at)).collect();
            merged
                .iter()
                .filter(|m| match remote_keys.contains(&m.key) {
                    false => true,
                    true => remote_updated.get(&m.key).copied().unwrap_or(i64::MIN) < m.updated_at,
                })
                .count()
        }

        // 场景一：本地无新增，远端已全部有且一样旧 → 应推 0
        let remote = vec![fav("a", 100, false), fav("b", 200, false)];
        let merged = merge_lww(remote.clone(), remote.clone(), |f| f.key.clone(), |f| f.updated_at);
        assert_eq!(count_pushed(&merged.items, &remote), 0, "无变化时不应报告推送");

        // 场景二：本地新增一条 → 应推 1
        let local2 = vec![fav("a", 100, false), fav("b", 200, false), fav("c", 300, false)];
        let merged2 = merge_lww(local2, remote.clone(), |f| f.key.clone(), |f| f.updated_at);
        assert_eq!(count_pushed(&merged2.items, &remote), 1);

        // 场景三：本地把 a 改新了 → 也应推 1
        let local3 = vec![fav("a", 999, false), fav("b", 200, false)];
        let merged3 = merge_lww(local3, remote.clone(), |f| f.key.clone(), |f| f.updated_at);
        assert_eq!(count_pushed(&merged3.items, &remote), 1);

        // 场景四：全空远端 → 全部都要推
        let merged4 = merge_lww(remote.clone(), vec![], |f| f.key.clone(), |f| f.updated_at);
        assert_eq!(count_pushed(&merged4.items, &[]), 2);
    }

    /// `pulled` 只算「本地原本没有」的条目
    #[test]
    fn pulled_counts_only_new_to_local() {
        let local = vec![fav("a", 100, false)];
        let remote = vec![fav("a", 100, false), fav("b", 200, false), fav("c", 300, false)];
        let merged = merge_lww(local.clone(), remote, |f| f.key.clone(), |f| f.updated_at);

        let local_keys: std::collections::HashSet<String> =
            local.iter().map(|f| f.key.clone()).collect();
        let pulled = merged.items.iter().filter(|f| !local_keys.contains(&f.key)).count();
        assert_eq!(pulled, 2, "只有 b、c 是本地新增");
    }

    // ══════════════ 保留清理（契约 §5）：这里错一次就是删用户的文件 ══════════════

    fn snap(name: &str) -> RemoteEntry {
        RemoteEntry {
            name: name.into(),
            bytes: 100,
            modified_ms: 0,
        }
    }

    /// ★★ 安全护栏：**非** `dsh-backup-*.zip` 的文件永远不进待删名单
    ///
    /// # 这是整个任务里最危险的一段代码
    ///
    /// `snapshots_to_prune` 的返回值会被逐条 `delete` 到**用户的云盘**上。
    /// 用户在同一个目录里放别的东西是完全正常的 —— 自述文件、别的软件的
    /// 备份、随手同步上去的照片。一旦名字过滤写松了，那些文件会被**静默删除**，
    /// 而用户根本不会把「云盘少了个文件」和「播放器自动备份」联系起来。
    ///
    /// 所以护栏**两侧都测**：正例可删、反例永不出现。
    #[test]
    fn prune_never_touches_non_snapshot_names() {
        let entries = vec![
            snap("dsh-backup-pc-20260929-101112.zip"),      // 快照（新）
            snap("dsh-backup-pc-20260928-090000.zip"),      // 快照（旧）
            snap("README.txt"),                             // 别人的文件
            snap("my-photos.zip"),                          // 别人的 zip
            snap("dsh-backup-pc-20260929-101112.zip.bak"),  // 后缀多了一截
            snap("old-dsh-backup-x.zip"),                   // 前缀不对
            snap("dsh-backup-.zip"),                        // 空名字（见下面的边界用例）
            snap("dsh-backup-x.ZIP"),                       // 大小写不同
        ];

        // 无论保留几份，待删名单里**只能**出现合规快照名
        for retain in [0u32, 1, 2, 3, 10, 100] {
            for name in snapshots_to_prune(&entries, retain) {
                assert!(
                    is_snapshot_name(&name),
                    "retain={retain} 时待删名单混进了非快照文件: {name}"
                );
            }
        }

        // retain=1 ⇒ 只删旧的那份快照，其余 6 个文件一个都不动
        assert_eq!(
            snapshots_to_prune(&entries, 1),
            vec!["dsh-backup-pc-20260928-090000.zip".to_string()],
            "除最新快照外只应删旧快照"
        );

        // retain=2 ⇒ 两份都在保留范围内 ⇒ 什么都不删
        assert!(
            snapshots_to_prune(&entries, 2).is_empty(),
            "两份快照都在保留范围内时不该删任何东西"
        );
    }

    /// ★ `retainCount = 0` 的下限：**至少留 1 份**
    ///
    /// # 为什么不做成「0 = 一份都不留」
    ///
    /// 字面实现（`skip(0)`）会把这**刚刚上传成功**的那份也删掉：
    /// ```text
    /// 用户点「立即备份」 → 上传成功 → 清理顺手删掉 → 提示「备份成功」
    /// 云盘上却一份都没有 —— 而且自动备份每小时跑一次，
    /// 每次都删得干干净净，用户直到需要恢复时才发现
    /// ```
    /// 所以下限取 1：设 0 等价于设 1，**永不出现零份**。
    /// 想关掉自动整包备份应该用 `autoBackupIntervalMinutes = 0`（契约 §6）。
    #[test]
    fn prune_keeps_at_least_one_even_with_zero_retain() {
        let entries = vec![
            snap("dsh-backup-a-20260929-010101.zip"),
            snap("dsh-backup-a-20260928-010101.zip"),
            snap("dsh-backup-a-20260927-010101.zip"),
        ];

        // 0 与 1 必须**完全等价** —— 这就是「下限」的定义
        assert_eq!(
            snapshots_to_prune(&entries, 0),
            snapshots_to_prune(&entries, 1)
        );

        let doomed = snapshots_to_prune(&entries, 0);
        assert_eq!(doomed.len(), 2, "3 份里应只留 1 份");
        assert!(
            !doomed.contains(&"dsh-backup-a-20260929-010101.zip".to_string()),
            "留下的必须是**最新**的那份（名字降序的第一条）: {doomed:?}"
        );
        assert!(doomed.contains(&"dsh-backup-a-20260928-010101.zip".to_string()));
        assert!(doomed.contains(&"dsh-backup-a-20260927-010101.zip".to_string()));

        // 空的远端目录 ⇒ 删不掉任何东西（首次使用）
        assert!(snapshots_to_prune(&[], 0).is_empty());
    }

    /// `is_snapshot_name` 的边界：前缀 + **非空名字** + 后缀
    ///
    /// `dsh-backup-.zip` 这种壳必须被判为**不是**快照 —— 否则保留清理
    /// 会真的去 `DELETE` 一个不存在（或更糟：别人正好叫这个名）的文件。
    #[test]
    fn is_snapshot_name_requires_non_empty_middle() {
        // 正例
        assert!(is_snapshot_name("dsh-backup-pc-20260929-101112.zip"));
        assert!(
            is_snapshot_name("dsh-backup-20260929-101112.zip"),
            "device_id 为空时 backup::default_backup_name 会产出这种退化名，它仍是快照"
        );
        assert!(is_snapshot_name("dsh-backup-\u{5ba2}\u{5385}.zip"), "中文设备名合法");

        // 反例
        assert!(!is_snapshot_name("dsh-backup-.zip"), "中间是空的，不是文件名");
        assert!(!is_snapshot_name("dsh-backup-"));
        assert!(!is_snapshot_name(".zip"));
        assert!(!is_snapshot_name("dsh-backup-x.zip.tmp"));
        assert!(!is_snapshot_name("dsh-backup-x.ZIP"), "后缀大小写敏感");
        assert!(!is_snapshot_name("backup-x.zip"));
        assert!(!is_snapshot_name(""));
    }

    /// ★ 内部签名**绝不能**出现在设置页拿到的 JSON 里（契约 §2）
    ///
    /// `lastSignature` / `lastBackupSignature` 是自动循环判断「本地变了没有」
    /// 的内部状态。它们漏出去的**症状极轻**：Dart 侧只是多两个没人读的键，
    /// 不报错、不崩 —— 所以只能靠这个单测锁住（人工 review 很容易看漏）。
    #[test]
    fn public_json_hides_internal_signatures() {
        let mut s = SyncSettings::default();
        s.base_url = "https://dav.example.com/dav/x".into();
        s.username = "me@example.com".into();
        s.last_signature = "favorites:3:99|following:0:0|progress:1:5".into();
        s.last_backup_signature = "favorites:3:100|following:0:0|progress:1:5".into();

        let v = s.to_public_json(true, false);
        let text = v.to_string();
        assert!(!text.contains("lastSignature"), "内部字段漏出: {text}");
        assert!(!text.contains("lastBackupSignature"), "内部字段漏出: {text}");
        assert!(!text.contains("favorites:3:99"), "内部签名的**值**也漏出了: {text}");

        // 该有的字段一个都不能少 —— Dart 侧 `SyncSettings.fromJson` 按名字读
        for k in [
            "connected",
            "baseUrl",
            "username",
            "remoteDir",
            "retainCount",
            "autoEnabled",
            "autoIntervalMinutes",
            "autoOnChange",
            "autoBackupIntervalMinutes",
            "lastBackupAt",
            "lastSyncAt",
            "credentialsEnabled",
            "credentialsPassphraseSet",
        ] {
            assert!(v.get(k).is_some(), "缺少字段 {k}: {text}");
        }
        assert_eq!(v["connected"], serde_json::json!(true));
        assert_eq!(v["retainCount"], serde_json::json!(10), "默认保留 10 份");
        assert_eq!(v["autoIntervalMinutes"], serde_json::json!(30));
        assert_eq!(v["autoBackupIntervalMinutes"], serde_json::json!(1440));
    }

    /// `load_settings` 对**任何**输入都不能失败（契约 §3.1）
    ///
    /// 一旦它返回 Err，设置页就打不开了 —— 用户连「重新配置」都做不到，
    /// 只能去删文件。三种坏输入各测一次。
    #[test]
    fn load_settings_never_fails_on_broken_input() {
        let dir = std::env::temp_dir().join(format!("dsh-sync-cfg-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let f = dir.join(SYNC_SETTINGS_FILE);

        // ① 文件不存在 → 全默认
        let _ = std::fs::remove_file(&f);
        let s = load_settings(&dir);
        assert_eq!(s.retain_count, 10);
        assert_eq!(s.auto_interval_minutes, 30);
        assert!(s.auto_on_change, "默认应在数据变动时同步");
        assert_eq!(s.auto_backup_interval_minutes, 1440, "默认一天整包一次");
        assert!(!s.auto_enabled, "自动同步默认关（要用户明确打开）");
        assert!(s.base_url.is_empty() && s.username.is_empty());

        // ② 内容不是 JSON → 回退默认（不 panic、不 Err）
        std::fs::write(&f, b"not json at all").unwrap();
        assert_eq!(load_settings(&dir).retain_count, 10, "坏文件必须回退默认值");

        // ③ 是 JSON 但缺字段 → 缺的取默认，**已有的必须保住**
        std::fs::write(
            &f,
            br#"{"baseUrl":"https://dav.example.com/dav/x","retainCount":3}"#,
        )
        .unwrap();
        let s3 = load_settings(&dir);
        assert_eq!(
            s3.base_url, "https://dav.example.com/dav/x",
            "已有字段不能被默认值冲掉"
        );
        assert_eq!(s3.retain_count, 3);
        assert_eq!(s3.auto_interval_minutes, 30, "缺的字段取默认");

        // ④ 存回来再读，值必须一模一样（重启后要能接着用）
        let mut s4 = load_settings(&dir);
        s4.auto_enabled = true;
        s4.auto_interval_minutes = 45;
        s4.last_backup_signature = "sig-1".into();
        save_settings(&dir, &s4).expect("写盘");
        let back = load_settings(&dir);
        assert!(back.auto_enabled);
        assert_eq!(back.auto_interval_minutes, 45);
        assert_eq!(back.last_backup_signature, "sig-1");
        assert_eq!(back.base_url, s4.base_url);

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ══════════════════ 凭据平面的接线验证 ══════════════════
    //
    // ★ 这一组测的是「**接线**」，不是加密算法（算法在 credentials.rs 里测过）。
    //   核心判据：`sync_all` 里那条 `out.push(sync_credentials(...))` **真的存在**。
    //   做法：删掉它 ⇒ 下面 `sync_all_includes_credentials_plane` 必须红。

    /// 造一个临时 data_dir，在 `plugins/.data/` 下写指定文件
    fn temp_data_dir(files: &[(&str, &str)]) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "sourin-cred-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let data = dir.join("plugins").join(".data");
        std::fs::create_dir_all(&data).expect("建临时目录");
        for (name, body) in files {
            std::fs::write(data.join(name), body).expect("写临时文件");
        }
        dir
    }

    fn new_db() -> Arc<Db> {
        Arc::new(Db::in_memory().expect("内存库"))
    }

    /* ── ① passphrase=None ⇒ 不进凭据平面，且**明确标记未同步** ── */

    #[tokio::test]
    async fn none_passphrase_reports_not_synced() {
        let backend = Arc::new(FakeBackend::new());
        let dir = temp_data_dir(&[("fake-provider-a.json", r#"{"session":"SESSDATA=abc"}"#)]);
        let engine = SyncEngine::new(backend.clone(), new_db(), "dev-a".into())
            .with_data_dir(dir.clone());

        let s = engine.sync_credentials(None).await.expect("不该报错");

        assert_eq!(s.plane, "credentials");
        assert_eq!(s.pushed, 0, "没口令时不该上传任何东西");
        // ★★ 关键：必须**明确说未同步**，不是静默成功
        let note = s.note.unwrap_or_default();
        assert!(
            note.contains("未同步"),
            "没口令时必须明确标记未同步，实际 note: {note}"
        );
        // 且远端确实没有文件
        assert!(
            backend.body_of("data/credentials.enc").is_empty(),
            "没口令时不该在远端留下文件"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /* ── ② passphrase=Some ⇒ 加密上传，且不含黑名单 key ── */

    #[tokio::test]
    async fn some_passphrase_uploads_encrypted_without_cache_keys() {
        let backend = Arc::new(FakeBackend::new());
        /*
         * 造三个插件（**全用中性 id**）：
         *   fake-provider-a.json —— 只有凭据 ⇒ 应上传
         *   <仅缓存插件>.json    —— 只有缓存 ⇒ 应整文件跳过
         *   fake-provider-b.json —— 凭据 + 缓存混存 ⇒ 只上传凭据部分
         *
         * ★ 缓存那两条的 provider/key **从 `CACHE_KEYS` 派生**，不写死：
         *   本测试要证明的是"缓存会被剔除"这个**机制**，不是"某个具体插件"。
         *   写死会让测试与 CACHE_KEYS 脱节（名单改了测试不跟着改 = 另一种假绿）。
         */
        let (cache_p, cache_k) = crate::sync::credentials::CACHE_KEYS[0];
        let (cache2_p, cache2_k) = crate::sync::credentials::CACHE_KEYS[1];
        let only_cache_name = format!("{cache_p}.json");
        let only_cache_body = format!(r#"{{"{cache_k}":"{{\\"at\\":1,\\"list\\":[]}}"}}"#);
        /*
         * ★ 混存那条**必须**用真缓存 provider 当文件名 —— 剔除判据是
         *   `(provider, key)` 二元组，换个 provider 名它就不是缓存了。
         *   ⚠️ 但**源码里不出现站名**：文件名与 key 都是运行时拼出来的。
         */
        let mixed_name = format!("{cache2_p}.json");
        let mixed_body = format!(r#"{{"{cache2_k}":"cached","session":"SHOULD_STAY"}}"#);
        let dir = temp_data_dir(&[
            ("fake-provider-a.json", r#"{"session":"SESSDATA=abc"}"#),
            (&only_cache_name, &only_cache_body),
            (&mixed_name, &mixed_body),
        ]);
        let engine = SyncEngine::new(backend.clone(), new_db(), "dev-a".into())
            .with_data_dir(dir.clone());

        let s = engine
            .sync_credentials(Some("pass-123"))
            .await
            .expect("应成功");

        assert_eq!(s.plane, "credentials");
        assert_eq!(s.pushed, 2, "a + b 两个有凭据，只有缓存的那个整文件跳过");

        // 远端文件存在
        let blob_text = backend.body_of("data/credentials.enc");
        assert!(!blob_text.is_empty(), "必须真的上传了");

        /*
         * ★★ 关键断言：密文里**不许出现明文凭据**。
         *    这里读的是**远端字节**，不是我们手里那个 plaintext ——
         *    这才是"真的加密了"的证据。
         */
        let raw = {
            let files = backend.files.lock().unwrap();
            files
                .get("data/credentials.enc")
                .map(|(b, _)| b.clone())
                .expect("远端应有文件")
        };
        let as_text = String::from_utf8_lossy(&raw);
        assert!(
            !as_text.contains("SESSDATA"),
            "明文凭据不许出现在远端密文里"
        );
        assert!(
            !as_text.contains("SHOULD_STAY"),
            "明文凭据不许出现在远端密文里"
        );

        // 用同口令能解开，且内容正确
        let plain = crate::sync::credentials::decrypt("pass-123", &raw).expect("应能解开");
        let v: serde_json::Value = serde_json::from_slice(&plain).expect("应是 JSON");
        assert_eq!(v["fake-provider-a"]["session"], "SESSDATA=abc");
        assert_eq!(v[cache2_p]["session"], "SHOULD_STAY");
        // 缓存 key 必须已被剔除
        assert!(
            v[cache2_p].get(cache2_k).is_none(),
            "缓存 key `{cache2_k}` 必须被剔除，实际: {}",
            v[cache2_p]
        );
        // 只有缓存的插件整个不出现
        assert!(
            v.get(cache_p).is_none(),
            "只有缓存的插件应整文件跳过"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /* ── ③ 无凭据 ⇒ 不上传空文件 ── */

    #[tokio::test]
    async fn no_credentials_uploads_nothing() {
        let backend = Arc::new(FakeBackend::new());
        // 只有缓存文件（provider/key 从 CACHE_KEYS 派生，见上面 ② 的说明）
        let (c0p, c0k) = crate::sync::credentials::CACHE_KEYS[0];
        let (c1p, c1k) = crate::sync::credentials::CACHE_KEYS[1];
        let f0 = format!("{c0p}.json");
        let b0 = format!(r#"{{"{c0k}":"x"}}"#);
        let f1 = format!("{c1p}.json");
        let b1 = format!(r#"{{"{c1k}":"y"}}"#);
        let dir = temp_data_dir(&[(&f0, &b0), (&f1, &b1)]);
        let engine = SyncEngine::new(backend.clone(), new_db(), "dev-a".into())
            .with_data_dir(dir.clone());

        let s = engine.sync_credentials(Some("p")).await.expect("应成功");

        assert_eq!(s.pushed, 0);
        assert!(
            backend.body_of("data/credentials.enc").is_empty(),
            "没有凭据时不该上传空文件"
        );
        assert!(s.note.unwrap_or_default().contains("没有任何"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /* ── ④ 凭据失败不拖垮其它平面 ── */

    #[tokio::test]
    async fn credentials_failure_does_not_break_other_planes() {
        /*
         * 造一个必然失败的凭据场景：**不挂 data_dir**。
         * 此时 sync_credentials 返回"未同步"（不是 Err），
         * 但我们要验的是 sync_all 里**收藏/进度仍然成功**。
         */
        let backend = Arc::new(FakeBackend::new());
        let db = new_db();
        {
            let conn_db = db.clone();
            // 塞一条收藏，确保 favorites 平面有内容可推
            let _ = conn_db.upsert_favorite(&fav("k1", 100, false));
        }
        let engine = SyncEngine::new(backend.clone(), db, "dev-a".into());

        let out = engine.sync_all().await.expect("sync_all 不该因凭据失败而整体失败");

        let planes: Vec<&str> = out.iter().map(|s| s.plane.as_str()).collect();
        assert!(planes.contains(&"favorites"), "收藏平面必须在");
        assert!(planes.contains(&"progress"), "进度平面必须在");
        assert!(planes.contains(&"credentials"), "凭据平面必须在（那怕只是未同步）");

        let _ = backend;
    }

    /* ── ⑤ ★ 接线判据：sync_all 的输出里必须真有 credentials 这一项 ── */

    #[tokio::test]
    async fn sync_all_includes_credentials_plane() {
        /*
         * ★★★ 本用例是「删掉 out.push(sync_credentials) ⇒ 必须红」的那条。
         *
         * 它**只**断言一件事：sync_all 的返回里有 plane == "credentials"。
         * ⇒ 任何让接线消失的改动（注释掉 push、早退、条件分支写错）都会让它红。
         */
        let backend = Arc::new(FakeBackend::new());
        let engine = SyncEngine::new(backend, new_db(), "dev-a".into());

        let out = engine.sync_all().await.expect("应成功");
        let cred = out.iter().find(|s| s.plane == "credentials");
        assert!(
            cred.is_some(),
            "sync_all 必须包含 credentials 平面 —— 没有它说明「写了但没接线」。\
             实际平面: {:?}",
            out.iter().map(|s| s.plane.as_str()).collect::<Vec<_>>()
        );
    }

    /* ── ⑥ 超过 MAX_PLAINTEXT ⇒ 报错，不许静默 ── */

    #[tokio::test]
    async fn oversized_credentials_errors_loudly() {
        let backend = Arc::new(FakeBackend::new());
        // 造一个超过 8 MiB 的凭据值
        let big = "x".repeat(9 * 1024 * 1024);
        let body = format!(r#"{{"session":"{big}"}}"#);
        let dir = temp_data_dir(&[("fake-provider-a.json", &body)]);
        let engine = SyncEngine::new(backend.clone(), new_db(), "dev-a".into())
            .with_data_dir(dir.clone());

        let r = engine.sync_credentials(Some("p")).await;

        // ★ 必须 Err，不许 Ok（静默跳过会让人以为同步成功）
        assert!(
            r.is_err(),
            "超过 MAX_PLAINTEXT 必须报错；实际: {:?}",
            r.map(|s| s.note)
        );
        let msg = r.unwrap_err();
        assert!(
            msg.contains("过大") || msg.contains("加密失败"),
            "错误信息应能看出原因，实际: {msg}"
        );
        // 失败时不该留下文件
        assert!(backend.body_of("data/credentials.enc").is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
