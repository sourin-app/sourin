//! 凭据平面 —— 登录态随云同步（CS-1 最小可行版）
//!
//! # 这个模块解决什么
//!
//! 现有同步有两个平面（收藏/进度、平台历史备份），**都不含登录态**。
//! 后果：换一台机器，收藏和进度都在，但每个源要重新登一遍。
//!
//! # 凭据到底存在哪（已查实，不是推断）
//!
//! ```text
//! 站点登录态  ⇒  plugins/.data/<id>.json   ← ★ 在**插件私有存储**里
//! WebDAV 密码 ⇒  系统钥匙串（webdav_credential）
//! 代理密码    ⇒  系统钥匙串（proxy）
//! ```
//!
//! 依据：`commands_backup.rs` 的注释「插件把自己的凭据存在插件私有存储里
//! （`plugins/.data/<id>.json`），而不是应用的系统钥匙串」。
//!
//! ⚠️ 所以本模块**不碰钥匙串** —— 钥匙串里那两条（WebDAV / 代理密码）
//!    **不该同步**：
//!      · 同步 WebDAV 密码到 WebDAV = 自举悖论
//!      · 代理密码是机器本地设施，换机后本来就不该带过去
//!
//! # 为什么是「黑名单」而不是「白名单」
//!
//! ```text
//! 白名单（只传认识的凭据 key）⇒ 插件新增凭据 key 时**默认漏掉**
//!                            ⇒ 用户以为同步了，实际登录态没过去（假绿）
//! 黑名单（只排除确认是缓存的）⇒ 未知 key **默认传**
//!                            ⇒ 最多多传几个字节，不会漏
//! ```
//!
//! **在凭据场景，「漏」比「多」严重得多** ⇒ 必须用黑名单。
//!
//! # 加密
//!
//! ```text
//! 口令 --PBKDF2-HMAC-SHA256(600000, salt)--> 32 字节密钥
//! 明文 --AES-256-GCM(key, nonce)--> 密文 + 16 字节 tag
//! ```
//!
//! 详细理由见 `ITERATIONS` 与文件格式注释。

use ring::aead;
use ring::pbkdf2;
use ring::rand::{SecureRandom, SystemRandom};
use std::num::NonZeroU32;

// ═══════════════════════ 参数 ═══════════════════════

/// 加密文件魔数 —— 用于识别「这是我们的凭据包」，并尽早拒绝乱喂的文件
const MAGIC: &[u8; 8] = b"SRCRED01";

/// 文件格式版本
///
/// ★ 独立于 `SCHEMA_VERSION`：那个是同步清单的版本，这个是**密文容器**的版本。
///   两者演进节奏不同 —— 换加密算法时不该动同步清单的版本号。
const FORMAT_VERSION: u8 = 1;

/// PBKDF2 迭代次数
///
/// # 为什么是 600000
///
/// ```text
/// · OWASP 2023 对 PBKDF2-HMAC-SHA256 的建议值是 600000
/// · 实测本机：600k 次约 200~400ms（release），这场景是**低频解密**
///   （开机解一次、换机解一次），用户无感
/// ```
///
/// # 为什么不是 Argon2
///
/// ```text
/// ring **没有** argon2，只有 pbkdf2。
/// 而 ring 已在依赖树里（reqwest → rustls → ring）⇒ 零新增供应链风险。
/// 若坚持 Argon2 要新增 argon2 crate + 约 4 个传递依赖。
/// ⇒ 取舍：用 PBKDF2 + 高迭代次数，换取零新增依赖。
/// ```
///
/// ⚠️ 迭代次数**写进文件头**，所以将来调高不会让旧文件解不开。
const ITERATIONS: u32 = 600_000;

/// 盐长度（16 字节 = 128 bit，足够）
const SALT_LEN: usize = 16;

/// AES-256-GCM nonce 长度
const NONCE_LEN: usize = 12;

/// GCM 认证标签长度
const TAG_LEN: usize = 16;

/// 密钥长度（AES-256）
const KEY_LEN: usize = 32;

/*
 * 文件格式（全部是 `MAGIC` 之后的内容）：
 *
 *   ┌──────────┬─────────┬──────────┬───────────┬──────────────┬─────────┐
 *   │ MAGIC(8) │ ver(1)  │ iter(4)  │ salt(16)  │ nonce(12)    │ 密文+tag │
 *   └──────────┴─────────┴──────────┴───────────┴──────────────┴─────────┘
 *                                                               ↑ 末尾 16 字节是 GCM tag
 *
 * ★ 为什么 iter 和 salt 要写进文件头（而不是写死）：
 *   ① 调高迭代次数后，**旧文件仍能解开**（用它自己头里的值）
 *   ② 同一口令在不同文件里产生不同密钥 ⇒ 无法跨文件比对密文
 * ★ 为什么 nonce 也要存：
 *   GCM 的 nonce **绝不能复用**（同一密钥下复用 = 灾难性泄露）。
 *   每次加密生成新随机 nonce 并存进文件头。
 */

/// 明文长度上限（防解压炸弹/超大文件把内存吃满）
///
/// 实测凭据总量：剔除缓存后约 938 字节。给 8 MiB 已是极大余量。
const MAX_PLAINTEXT: usize = 8 * 1024 * 1024;

// ═══════════════════════ 错误类型 ═══════════════════════

/// 加密/解密失败原因
///
/// ★ 刻意做成枚举而不是 `String`：调用方需要**区分**
///   「口令错」与「文件坏了」—— 前者让用户重输，后者该报数据损坏。
///   混成一句"解密失败"会让用户反复重输正确口令。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CryptoError {
    /// 不是我们的文件（魔数不对）
    NotOurFile,
    /// 版本不认识（将来降级运行时遇到新格式）
    UnsupportedVersion(u8),
    /// 文件被截断（长度不够）
    Truncated { need: usize, got: usize },
    /// 明文超过上限
    TooLarge(usize),
    /// **口令错或被篡改** —— AES-GCM 无法区分这两者，如实说明
    WrongPasswordOrTampered,
    /// 系统随机数不可用
    RngUnavailable,
}

impl std::fmt::Display for CryptoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotOurFile => write!(f, "不是凭据包（文件头不匹配）"),
            Self::UnsupportedVersion(v) => {
                write!(f, "凭据包版本 {v} 不受支持（当前版本 {}", FORMAT_VERSION)
            }
            Self::Truncated { need, got } => {
                write!(f, "凭据包被截断（需要至少 {need} 字节，实际 {got} 字节）")
            }
            Self::TooLarge(n) => write!(f, "凭据包过大（{n} 字节，上限 {MAX_PLAINTEXT}）"),
            // ⚠️ 措辞必须带上"或已被篡改"—— GCM 认证失败就是这两种可能，不能只报口令错
            Self::WrongPasswordOrTampered => {
                write!(f, "口令不正确，或凭据包已被篡改")
            }
            Self::RngUnavailable => write!(f, "系统随机数不可用"),
        }
    }
}

impl std::error::Error for CryptoError {}

// ═══════════════════════ 加密 / 解密 ═══════════════════════

/// 用口令加密一段明文
///
/// # 参数
/// - `password`：用户口令。**空口令直接拒绝** —— 空口令等于不加密。
/// - `plaintext`：要加密的字节
///
/// # 返回
/// 可直接落盘/上云的**自包含**字节块（含 salt / nonce / 迭代次数）
pub fn encrypt(password: &str, plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
    /*
     * ★ 空口令必须拒绝，不能"当成没设口令"静默放行。
     *
     * 原因：如果空口令能加密，调用方一旦把用户没设的口令传进来，
     * 就会产出**能被任何人解开**的文件 —— 而文件名叫"加密的凭据"。
     * 这是最危险的一种"看起来做了安全措施"。
     */
    if password.is_empty() {
        return Err(CryptoError::WrongPasswordOrTampered);
    }
    if plaintext.len() > MAX_PLAINTEXT {
        return Err(CryptoError::TooLarge(plaintext.len()));
    }

    let rng = SystemRandom::new();

    // ① 随机盐
    let mut salt = [0u8; SALT_LEN];
    rng.fill(&mut salt).map_err(|_| CryptoError::RngUnavailable)?;

    // ② 随机 nonce（★ 绝不复用：同一密钥下 GCM nonce 复用会泄露明文异或）
    let mut nonce = [0u8; NONCE_LEN];
    rng.fill(&mut nonce).map_err(|_| CryptoError::RngUnavailable)?;

    // ③ 口令 → 密钥
    let key = derive_key(password, &salt, ITERATIONS)?;

    // ④ AES-256-GCM 加密（密文末尾自带 16 字节 tag）
    let unbound = aead::UnboundKey::new(&aead::AES_256_GCM, &key)
        .map_err(|_| CryptoError::RngUnavailable)?;
    let sealing = aead::LessSafeKey::new(unbound);
    let mut in_out = plaintext.to_vec();
    sealing
        .seal_in_place_append_tag(
            aead::Nonce::assume_unique_for_key(nonce),
            aead::Aad::empty(),
            &mut in_out,
        )
        .map_err(|_| CryptoError::RngUnavailable)?;

    // ⑤ 拼装：MAGIC | ver | iter | salt | nonce | 密文+tag
    let mut out = Vec::with_capacity(MAGIC.len() + 1 + 4 + SALT_LEN + NONCE_LEN + in_out.len());
    out.extend_from_slice(MAGIC);
    out.push(FORMAT_VERSION);
    out.extend_from_slice(&ITERATIONS.to_be_bytes());
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&in_out);
    Ok(out)
}

/// 用口令解开一个凭据包
///
/// # 错误语义（调用方依赖这个区分）
/// - `WrongPasswordOrTampered` ⇒ 让用户**重新输入口令**
/// - 其它 ⇒ 文件本身有问题，重输口令没用
pub fn decrypt(password: &str, blob: &[u8]) -> Result<Vec<u8>, CryptoError> {
    if password.is_empty() {
        return Err(CryptoError::WrongPasswordOrTampered);
    }

    const HEAD_LEN: usize = 8 /*magic*/ + 1 /*ver*/ + 4 /*iter*/;
    if blob.len() < HEAD_LEN {
        return Err(CryptoError::Truncated { need: HEAD_LEN, got: blob.len() });
    }
    if &blob[..MAGIC.len()] != MAGIC {
        return Err(CryptoError::NotOurFile);
    }
    let ver = blob[MAGIC.len()];
    if ver != FORMAT_VERSION {
        return Err(CryptoError::UnsupportedVersion(ver));
    }

    let mut iter_bytes = [0u8; 4];
    iter_bytes.copy_from_slice(&blob[MAGIC.len() + 1..HEAD_LEN]);
    let iterations = u32::from_be_bytes(iter_bytes);

    /*
     * ★ 迭代次数是攻击者可控的（在文件头里）。
     *
     * 如果直接用它派生密钥，攻击者可以放一个 `iter = u32::MAX` 的文件
     * ⇒ 我们算几万年 ⇒ **拒绝服务**。
     * ⇒ 这里设一个上界，超过就当文件坏了。
     */
    const MAX_ITERATIONS: u32 = 10_000_000;
    if iterations == 0 || iterations > MAX_ITERATIONS {
        return Err(CryptoError::NotOurFile);
    }

    let body_start = HEAD_LEN;
    let need = body_start + SALT_LEN + NONCE_LEN + TAG_LEN;
    if blob.len() < need {
        return Err(CryptoError::Truncated { need, got: blob.len() });
    }

    let salt = &blob[body_start..body_start + SALT_LEN];
    let nonce_bytes = &blob[body_start + SALT_LEN..body_start + SALT_LEN + NONCE_LEN];
    let ciphertext = &blob[body_start + SALT_LEN + NONCE_LEN..];

    let key = derive_key(password, salt, iterations)?;

    let unbound = aead::UnboundKey::new(&aead::AES_256_GCM, &key)
        .map_err(|_| CryptoError::WrongPasswordOrTampered)?;
    let opening = aead::LessSafeKey::new(unbound);

    let mut nonce = [0u8; NONCE_LEN];
    nonce.copy_from_slice(nonce_bytes);

    let mut in_out = ciphertext.to_vec();
    let plain = opening
        .open_in_place(
            aead::Nonce::assume_unique_for_key(nonce),
            aead::Aad::empty(),
            &mut in_out,
        )
        /*
         * ★ GCM 认证失败只有两种可能：口令错、或密文被改过。
         *   密码学上**无法区分**（tag 就是为此设计的）⇒ 如实报两者都可能。
         */
        .map_err(|_| CryptoError::WrongPasswordOrTampered)?;

    if plain.len() > MAX_PLAINTEXT {
        return Err(CryptoError::TooLarge(plain.len()));
    }
    Ok(plain.to_vec())
}

/// PBKDF2-HMAC-SHA256 派生 32 字节密钥
fn derive_key(password: &str, salt: &[u8], iterations: u32) -> Result<[u8; KEY_LEN], CryptoError> {
    let mut key = [0u8; KEY_LEN];
    // `iterations` 已在上游校验过非 0（encrypt 用常量，decrypt 用校验过的值）
    let n = NonZeroU32::new(iterations).ok_or(CryptoError::NotOurFile)?;
    pbkdf2::derive(
        pbkdf2::PBKDF2_HMAC_SHA256,
        n,
        salt,
        password.as_bytes(),
        &mut key,
    );
    Ok(key)
}

// ═══════════════════════ 缓存 key 黑名单 ═══════════════════════

/// 已知是**缓存**的 key —— 同步时剔除
///
/// # 为什么是黑名单（而不是白名单）
///
/// ```text
/// 白名单 ⇒ 插件新增凭据 key 时默认漏掉 ⇒ 用户以为同步了但没同步（假绿）
/// 黑名单 ⇒ 未知 key 默认传 ⇒ 最多多传几字节，不会漏
/// ```
///
/// # 每条都要有证据
///
/// 判据统一是：`host.store.set(key, JSON.stringify({ at: Date.now(), ... }))`
/// —— 带时间戳，且有配对的 TTL 常量。
///
/// ⚠️ 可见性为 `pub(crate)`：`mod.rs` 的接线测试要拿真缓存 key 造夹具
///    （从真源派生，而不是在测试里重抄一遍插件名 —— 见那边的注释）。
pub(crate) const CACHE_KEYS: &[(&str, &str)] = &[
    // 频道列表缓存，`CACHE_TTL = 10 * 60 * 1000`
    ("douyu-live", "list_v1"),
    // 频道列表缓存，`CACHE_TTL = 10 * 60 * 1000`（真机上 246KB，是 .data 里最大的）
    ("huya-live", "list_v1"),
    // 播放列表缓存，`CACHE_TTL_MS = 6 * 60 * 60 * 1000`
    ("iptv", "cache_v3"),
    // 专辑/搜索缓存（读侧解析失败就返回 `{}`，说明丢了无所谓）
    ("iqiyi", "albums"),
    // 宿主内置 legacy 桩写的频道缓存（不是用户插件）
    ("bilibili-live", "rooms_v1"),
];

/// 判断某个插件的某个 key 是否该在同步时剔除
pub fn is_cache_key(provider: &str, key: &str) -> bool {
    CACHE_KEYS
        .iter()
        .any(|(p, k)| *p == provider && *k == key)
}

/// 从一个插件数据对象里剔除缓存 key
///
/// # 返回
/// - `Some(map)`：还有内容，需要同步
/// - `None`：剔除后为空 —— **整个文件都别传**
///
/// ★ 这个 `None` 是「黑名单方案」的自动收益：
///   26 个插件根本不用 `host.store`，4 个只存缓存
///   ⇒ 它们自然不产生任何上传，不需要额外维护一份"哪些插件有凭据"的名单。
pub fn strip_cache_keys(
    provider: &str,
    data: serde_json::Map<String, serde_json::Value>,
) -> Option<serde_json::Map<String, serde_json::Value>> {
    let kept: serde_json::Map<String, serde_json::Value> = data
        .into_iter()
        .filter(|(k, _)| !is_cache_key(provider, k))
        .collect();
    if kept.is_empty() {
        None
    } else {
        Some(kept)
    }
}

// ═══════════════════════ 收集 / 还原（与同步、备份共用同一套）═══════════════════════

/*
 * ★★★ 为什么收集/还原要放在**本文件**，而不是同步和备份各写一份
 *
 * ```text
 * 同步（sync_all）与备份导出（backup_export）必须产出**同一份**凭据载荷。
 * 各写一份的必然结局：两个格式慢慢漂开 —— 同步能解开的包，备份解不开；
 * 或者一处加了缓存黑名单、另一处忘了加（把 246KB 的频道缓存也塞进备份）。
 * ⇒ 收集、加密、解密、还原**只在这里实现一次**，上层两条路都调它。
 * ```
 */

/// 收集结果（一个插件一个条目）
#[derive(Debug, Clone, Default)]
pub struct Bundle {
    /// `provider id → 该插件剔除缓存后的键值对`
    pub providers: serde_json::Map<String, serde_json::Value>,
    /// 有凭据、需要同步的插件数
    pub kept: usize,
    /// 只剩缓存、整文件跳过的插件数
    pub skipped: usize,
    /// ★ 明文存了账号+密码的插件 id（导出前要单独提示的那类）
    pub plaintext_password_providers: Vec<String>,
}

impl Bundle {
    pub fn is_empty(&self) -> bool {
        self.kept == 0
    }

    /// 转成要加密的 JSON 对象
    pub fn to_value(&self) -> serde_json::Value {
        serde_json::Value::Object(self.providers.clone())
    }
}

/// 从 `<data_dir>/plugins/.data/` 收集全部登录态（**剔除缓存 key**）
///
/// # 读失败/坏文件一律跳过，不报错
///
/// 一个插件的数据文件坏了不该让整次同步失败 —— 与
/// `plugins::store_load` 的「坏文件兜底成空 map」同一个方向：
/// 宁可少同步一个源，不要一个源坏掉就全同步不了。
/// **但目录本身读不了要报错**（那说明数据目录有问题，静默跳过等于假绿）。
pub fn collect(data_dir: &std::path::Path) -> Result<Bundle, String> {
    let data_path = crate::state::plugins_dir(data_dir).join(".data");
    let mut out = Bundle::default();
    if !data_path.is_dir() {
        // 还没登录过任何源 —— 合法状态，不是错误
        return Ok(out);
    }
    let entries =
        std::fs::read_dir(&data_path).map_err(|e| format!("读取插件数据目录失败: {e}"))?;
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Some(provider) = p.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(serde_json::Value::Object(map)) = serde_json::from_str(&text) else {
            continue;
        };
        if looks_like_plaintext_password(&serde_json::Value::Object(map.clone())) {
            out.plaintext_password_providers.push(provider.to_string());
        }
        // ★ 剔除缓存 key；`None` = 只剩缓存 ⇒ 整个插件跳过
        match strip_cache_keys(provider, map) {
            Some(kept) => {
                out.kept += 1;
                out.providers
                    .insert(provider.to_string(), serde_json::Value::Object(kept));
            }
            None => out.skipped += 1,
        }
    }
    Ok(out)
}

/// 还原结果
#[derive(Debug, Clone, Default)]
pub struct RestoreOutcome {
    /// 真正写回 `.data/` 的插件数
    pub providers: usize,
    /// 写失败的插件（`(id, 原因)`）—— **不阻断**其它插件
    pub failed: Vec<(String, String)>,
}

/// 把一份解密后的凭据 JSON 写回 `<data_dir>/plugins/.data/`
///
/// # ★ 合并，不是覆盖
///
/// 本机可能还有云端没有的键（比如某插件新增的字段、或本机独有的缓存）。
/// 直接覆盖会**删掉**它们 ⇒ 用户的登录态看起来"回到了三天前"。
/// 所以：先读本机那一份，再用远端来的键**逐个覆盖**，其余保留。
///
/// # 为什么写临时文件再 rename
///
/// 与 `plugins::store_write_atomic` 同一手法：插件随时可能在读这个文件，
/// 半截写入会让它读到坏 JSON ⇒ 被当成"没有凭据" ⇒ 用户被登出。
pub fn restore(
    data_dir: &std::path::Path,
    bundle: &serde_json::Value,
) -> Result<RestoreOutcome, String> {
    let Some(obj) = bundle.as_object() else {
        return Err("凭据包格式不对（顶层不是对象）".into());
    };
    let data_path = crate::state::plugins_dir(data_dir).join(".data");
    std::fs::create_dir_all(&data_path).map_err(|e| format!("创建插件数据目录失败: {e}"))?;

    let mut out = RestoreOutcome::default();
    for (provider, value) in obj {
        // 防御：provider id 只能是普通文件名，不许带路径分隔符
        if provider.is_empty()
            || provider.contains('/')
            || provider.contains('\\')
            || provider.contains("..")
        {
            out.failed
                .push((provider.clone(), "插件 id 非法，已跳过".into()));
            continue;
        }
        let Some(incoming) = value.as_object() else {
            out.failed
                .push((provider.clone(), "内容不是对象，已跳过".into()));
            continue;
        };
        let target = data_path.join(format!("{provider}.json"));
        let mut merged = std::fs::read_to_string(&target)
            .ok()
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default();
        for (k, v) in incoming {
            merged.insert(k.clone(), v.clone());
        }
        let body = serde_json::to_vec(&serde_json::Value::Object(merged))
            .map_err(|e| format!("序列化 {provider} 的凭据失败: {e}"))?;
        let tmp = data_path.join(format!(".{provider}.json.tmp"));
        if let Err(e) = std::fs::write(&tmp, &body) {
            out.failed.push((provider.clone(), format!("写临时文件失败: {e}")));
            continue;
        }
        if let Err(e) = std::fs::rename(&tmp, &target) {
            let _ = std::fs::remove_file(&tmp);
            out.failed.push((provider.clone(), format!("替换失败: {e}")));
            continue;
        }
        out.providers += 1;
    }
    Ok(out)
}

/// 用口令把收集结果加密成自包含字节块
pub fn encrypt_bundle(password: &str, bundle: &Bundle) -> Result<Vec<u8>, CryptoError> {
    let plain = serde_json::to_vec(&bundle.to_value())
        .map_err(|_| CryptoError::TooLarge(0))?;
    encrypt(password, &plain)
}

/// 解开一个凭据包并解析成 JSON
///
/// ★ 解析失败**不是** `WrongPasswordOrTampered` —— 那是「口令对、但内容不是
///   我们认识的 JSON」，属于数据损坏。混起来用户会反复重输正确口令。
pub fn decrypt_bundle(password: &str, blob: &[u8]) -> Result<serde_json::Value, CryptoError> {
    let plain = decrypt(password, blob)?;
    serde_json::from_slice(&plain).map_err(|_| CryptoError::NotOurFile)
}

// ═══════════════════════ 明文口令检测（导出提示用）═══════════════════════

/// 形如「密码」的键名
///
/// ⚠️ 只认**明确的**密码键：`password` / `passwd` / `pwd` / `pass`。
///    **不认** `token` / `cookie` —— 那两个是令牌/会话，泄露形态与影响面
///    都不同（令牌可撤销、密码不能），混在一起说会让用户分不清风险。
const PASSWORD_KEYS: &[&str] = &["password", "passwd", "pwd", "pass"];

/// 这份插件数据里是否有**明文的**账号密码
///
/// # 为什么需要它（导出前的单独提示）
///
/// 有些插件不走"存会话 Cookie"，而是**把账号密码原样存进插件私有存储**
/// （已查实：某第三方插件 `credentials` 键的值就是 `{username, password}`）。
/// 这类数据即使我们给整包加了密，语义上也比 Cookie 敏感一档：
/// ```text
/// Cookie 泄露 → 可以撤销 / 过期就失效
/// 密码泄露   → 用户别处若复用同一密码，影响范围远超出本站
/// ```
/// ⇒ 导出前必须**单独**告诉用户"这个文件里有明文密码"，
///   而不是笼统地说"含登录态"。
pub fn looks_like_plaintext_password(v: &serde_json::Value) -> bool {
    match v {
        serde_json::Value::Object(m) => m.iter().any(|(k, val)| {
            let kl = k.to_ascii_lowercase();
            let is_pw_key = PASSWORD_KEYS.iter().any(|p| kl == *p);
            // 键是密码类 且 值是非空字符串 ⇒ 明文密码
            (is_pw_key && val.as_str().map(|s| !s.is_empty()).unwrap_or(false))
                // 值本身可能是 JSON 字符串，里面还嵌着对象 ⇒ 递归看一眼
                || val
                    .as_str()
                    .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
                    .map(|inner| looks_like_plaintext_password(&inner))
                    .unwrap_or(false)
                || looks_like_plaintext_password(val)
        }),
        serde_json::Value::Array(a) => a.iter().any(looks_like_plaintext_password),
        _ => false,
    }
}

// ═══════════════════════ base64（把密文塞进 JSON 用）══════════════════════

/*
 * ★ 为什么手写而不是引入 `base64` crate
 *
 * 与 `provider.rs` 里那份 base64url 解码同一个理由：需求只有
 * 「把一段二进制编成 JSON 里能放的文本」，标准 base64 表 64 个字符、
 * 加解码不到 40 行。为此新增一个 crate = 新增供应链面 + 编译单元，
 * 而本仓库的依赖已经够多了。
 *
 * ⚠️ 只在**导出/导入备份**这条路上用：它要经过 JSON（`settings.json`），
 *    而 JSON 放不了裸字节。
 */

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// 标准 base64 编码（带 `=` 填充）
pub fn b64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            B64[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            B64[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// 标准 base64 解码；非法输入返回 `None`（**不 panic**）
///
/// ★ 解码**不做"尽力而为"**：任何一个非法字符都返回 `None`。
///   这条路上解码失败意味着备份包坏了，静默返回半截字节会让
///   「口令对但包损坏」看起来像「口令错」—— 用户会反复重输口令。
pub fn b64_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        Some(match c {
            b'A'..=b'Z' => (c - b'A') as u32,
            b'a'..=b'z' => (c - b'a') as u32 + 26,
            b'0'..=b'9' => (c - b'0') as u32 + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        })
    }
    let bytes: Vec<u8> = s.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    if bytes.len() % 4 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let blocks = bytes.len() / 4;
    for (bi, chunk) in bytes.chunks(4).enumerate() {
        let last = bi + 1 == blocks;
        let mut n: u32 = 0;
        let mut pads = 0usize;
        for (i, &c) in chunk.iter().enumerate() {
            if c == b'=' {
                // 填充只允许出现在**最后一组**的最后两个位置
                if !last || i < 2 {
                    return None;
                }
                pads += 1;
                n <<= 6;
            } else {
                if pads > 0 {
                    return None; // `=` 之后又出现数据字符
                }
                n = (n << 6) | val(c)?;
            }
        }
        out.push((n >> 16) as u8);
        if pads < 2 {
            out.push((n >> 8) as u8);
        }
        if pads < 1 {
            out.push(n as u8);
        }
    }
    Some(out)
}

// ═══════════════════════ 单元测试 ═══════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    const PW: &str = "correct horse battery staple";
    const DATA: &[u8] = b"{\"bili_cookie\":\"SESSDATA=xxx; bili_jct=yyy\"}";

    /* ── ② 加解密往返 ── */

    #[test]
    fn roundtrip_byte_identical() {
        let blob = encrypt(PW, DATA).expect("加密应成功");
        let back = decrypt(PW, &blob).expect("解密应成功");
        // ★ 逐字节相等（不是"内容差不多"）
        assert_eq!(back, DATA, "往返后必须逐字节相同");
    }

    #[test]
    fn roundtrip_empty_plaintext() {
        // 空明文也要能往返（剔除后可能只剩 `{}` 这种极小内容）
        let blob = encrypt(PW, b"").expect("空明文加密应成功");
        let back = decrypt(PW, &blob).expect("空明文解密应成功");
        assert_eq!(back, b"");
    }

    #[test]
    fn roundtrip_large_plaintext() {
        let big = vec![7u8; 1024 * 1024]; // 1 MiB
        let blob = encrypt(PW, &big).expect("1MiB 加密应成功");
        let back = decrypt(PW, &blob).expect("1MiB 解密应成功");
        assert_eq!(back, big);
    }

    /* ── 同一明文两次加密必须不同（salt + nonce 随机）── */

    #[test]
    fn same_plaintext_different_ciphertext() {
        let a = encrypt(PW, DATA).unwrap();
        let b = encrypt(PW, DATA).unwrap();
        assert_ne!(a, b, "同一明文两次加密必须产生不同密文（随机 salt/nonce）");
        // 但两者都能解开
        assert_eq!(decrypt(PW, &a).unwrap(), DATA);
        assert_eq!(decrypt(PW, &b).unwrap(), DATA);
    }

    /* ── ③ 口令错必须明确失败，不许静默返回空 ── */

    #[test]
    fn wrong_password_fails_loudly() {
        let blob = encrypt(PW, DATA).unwrap();
        let err = decrypt("wrong password", &blob).expect_err("错口令必须失败");
        // ★ 必须是这个错误 —— 调用方靠它提示"请重新输入口令"
        assert_eq!(err, CryptoError::WrongPasswordOrTampered);
        /*
         * ★★ 关键断言：**不许**返回 Ok(空 vec)。
         *    如果实现里吞掉错误返回空，用户会得到"同步成功但凭据是空的"。
         */
        assert_ne!(
            decrypt("wrong password", &blob).ok(),
            Some(Vec::new()),
            "错口令绝不能返回空明文"
        );
    }

    #[test]
    fn empty_password_rejected_on_both_sides() {
        // 加密侧：空口令拒绝（否则产出"谁都能解"的文件）
        assert!(encrypt("", DATA).is_err(), "空口令不许加密");
        // 解密侧：空口令拒绝
        let blob = encrypt(PW, DATA).unwrap();
        assert_eq!(decrypt("", &blob), Err(CryptoError::WrongPasswordOrTampered));
    }

    #[test]
    fn tampered_ciphertext_detected() {
        let mut blob = encrypt(PW, DATA).unwrap();
        let last = blob.len() - 1;
        blob[last] ^= 0xFF; // 改密文最后一个字节
        let err = decrypt(PW, &blob).expect_err("篡改必须被发现");
        assert_eq!(err, CryptoError::WrongPasswordOrTampered);
    }

    #[test]
    fn tampered_nonce_detected() {
        let mut blob = encrypt(PW, DATA).unwrap();
        // nonce 在 MAGIC(8)+ver(1)+iter(4)+salt(16) 之后
        let nonce_off = 8 + 1 + 4 + SALT_LEN;
        blob[nonce_off] ^= 0x01;
        assert!(decrypt(PW, &blob).is_err(), "改 nonce 必须解密失败");
    }

    #[test]
    fn not_our_file_detected() {
        let junk = b"this is not a credential blob at all, just some bytes";
        assert_eq!(decrypt(PW, junk), Err(CryptoError::NotOurFile));
    }

    #[test]
    fn truncated_detected() {
        let blob = encrypt(PW, DATA).unwrap();
        for cut in [0usize, 4, 8, 12, 20, 28, 35] {
            let part = &blob[..cut.min(blob.len())];
            let r = decrypt(PW, part);
            assert!(r.is_err(), "截断到 {cut} 字节必须报错，实际: {r:?}");
        }
    }

    #[test]
    fn version_mismatch_detected() {
        let mut blob = encrypt(PW, DATA).unwrap();
        blob[8] = 99; // FORMAT_VERSION 位置
        assert_eq!(decrypt(PW, &blob), Err(CryptoError::UnsupportedVersion(99)));
    }

    /* ── 黑名单 ── */
    //
    // ★★★ 这一组**不硬编码任何具体插件 id**，全部从 `CACHE_KEYS` 派生。
    //
    // # 为什么（这不是风格偏好，是判据强度问题）
    // ```text
    // 硬编码写法： assert!(is_cache_key("某插件", "list_v1"))
    //   ⇒ 只覆盖**当时记得写下的那几条**
    //   ⇒ CACHE_KEYS 新增一条缓存时，测试不会跟着覆盖（要靠人记得来加）
    //   ⇒ 而"新增的那条没被剔除"恰恰是真正会出事的地方（缓存被传上云）
    // 派生写法：  for (p, k) in CACHE_KEYS { … }
    //   ⇒ 覆盖**全部**条目，包括将来新增的 —— 永不脱节
    // ```
    // ★ 顺带的好处：夹具里不出现任何具体站点名（本仓有一条门禁管这个）。

    /// 一个**中性的**插件 id（不是任何真实站点的名字）
    const FAKE_PROVIDER: &str = "fake-provider-a";

    #[test]
    fn every_cache_key_is_recognised() {
        // ★ 遍历真源：CACHE_KEYS 增删条目时本测试自动跟随
        for (p, k) in CACHE_KEYS {
            assert!(
                is_cache_key(p, k),
                "CACHE_KEYS 里每条都必须被判为缓存: {p}/{k}"
            );
        }
        assert!(!CACHE_KEYS.is_empty(), "黑名单不该是空的（否则本测试恒真）");
    }

    #[test]
    fn credential_keys_are_not_in_blacklist() {
        // 这些是**凭据**，绝不能在黑名单里。
        // ⚠️ 用中性 id：判据是"凭据 key 不被排除"，与具体哪个站无关。
        assert!(!is_cache_key(FAKE_PROVIDER, "bili_cookie"));
        assert!(!is_cache_key(FAKE_PROVIDER, "session"));
        assert!(!is_cache_key(FAKE_PROVIDER, "credentials"));
        // 显示用，也不该排除（不然换机后用户名显示为空）
        assert!(!is_cache_key(FAKE_PROVIDER, "bili_uname"));
    }

    #[test]
    fn same_key_different_provider_not_confused() {
        /*
         * ★ 黑名单是 (provider, key) 二元组，不是单纯 key 名。
         *   否则将来某个插件的凭据 key 恰好与某条缓存同名就会被误排除。
         *
         * ★★ 这一条**必须**用真实的 (provider, key) 组合 —— 它测的就是
         *    "同一个 key 在不同 provider 下判定不同"。所以从 CACHE_KEYS 取，
         *    而不是写死某个站名。
         */
        let (p, k) = CACHE_KEYS[0];
        assert!(is_cache_key(p, k));
        assert!(
            !is_cache_key("some-new-plugin", k),
            "同一个 key `{k}` 换个 provider 就不该被判为缓存"
        );
    }

    /* ── ④ 黑名单排除生效 ── */

    #[test]
    fn strip_removes_only_cache_keys() {
        let (cp, ck) = CACHE_KEYS[0];
        // 用真缓存 key 与中性凭据 key 拼一份"混存"数据
        // ⚠️ 动态键名要手工建 map（`json!` 的键必须是字面量）
        let mut map = serde_json::Map::new();
        map.insert(
            ck.to_string(),
            serde_json::json!("{\"at\":1792333932301,\"list\":[...]}"), // 缓存，应剔除
        );
        map.insert("session".into(), serde_json::json!("SESSDATA=abc; TOKEN=def")); // 凭据，应保留
        map.insert("some_future_key".into(), serde_json::json!("unknown")); // 未知，应保留
        let kept = strip_cache_keys(cp, map).expect("还有内容，不该返回 None");

        assert!(!kept.contains_key(ck), "缓存 key 必须被剔除");
        assert!(kept.contains_key("session"), "凭据必须保留");
        assert!(
            kept.contains_key("some_future_key"),
            "未知 key 必须保留 —— 这是黑名单的核心语义，否则新凭据会静默丢失"
        );
        assert_eq!(kept.len(), 2);
    }

    #[test]
    fn strip_returns_none_when_only_cache() {
        // ★ 只放一条真缓存 key ⇒ 剔除后必须为空
        let (cp, ck) = CACHE_KEYS[0];
        let mut map = serde_json::Map::new();
        map.insert(ck.to_string(), serde_json::json!("cached"));
        assert!(
            strip_cache_keys(cp, map).is_none(),
            "只剩缓存时必须返回 None（调用方据此整文件跳过上传）"
        );
    }

    #[test]
    fn strip_on_unknown_provider_keeps_everything() {
        // 26 个插件不用 host.store；万一将来用了，未知 provider 应原样保留
        //
        // ★ 用**真缓存 key** 配**未知 provider**：这条才真正证明
        //   "判定是 (provider,key) 二元组"—— 若实现写成只看 key，这里会红。
        let (_, ck) = CACHE_KEYS[0];
        let mut map = serde_json::Map::new();
        map.insert(ck.to_string(), serde_json::json!("x"));
        map.insert("a".to_string(), serde_json::json!(1));
        let kept = strip_cache_keys("brand-new-plugin", map).unwrap();
        assert_eq!(
            kept.len(),
            2,
            "未知 provider 下即使是缓存 key 也不该被剔除（否则会误删用户数据）"
        );
    }

    /* ── 端到端：剔除 → 加密 → 解密 → 还原 ── */

    #[test]
    fn end_to_end_strip_then_encrypt_then_decrypt() {
        let (cp, ck) = CACHE_KEYS[0];
        let mut data = serde_json::Map::new();
        data.insert(ck.to_string(), serde_json::json!("big cache blob"));
        data.insert("session".into(), serde_json::json!("SESSDATA=abc"));
        let kept = strip_cache_keys(cp, data).unwrap();
        let plain = serde_json::to_vec(&kept).unwrap();

        let blob = encrypt(PW, &plain).unwrap();
        let back = decrypt(PW, &blob).unwrap();
        let restored: serde_json::Value = serde_json::from_slice(&back).unwrap();

        assert_eq!(restored["session"], "SESSDATA=abc");
        assert!(restored.get(ck).is_none(), "缓存不该出现在还原结果里");
    }

    /* ══════════════════ ⑦ 收集 / 还原（同步与备份共用）══════════════════ */

    /// 造一个临时 data_dir，在 `plugins/.data/` 下写指定文件
    fn temp_data_dir(tag: &str, files: &[(&str, &str)]) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "sourin-cred-{tag}-{}-{}",
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

    #[test]
    fn collect_strips_cache_and_counts_skipped() {
        /*
         * ★ 缓存夹具**从 `CACHE_KEYS` 里取**，不在这里重抄一遍插件名。
         *
         * 理由有两条，都不是风格问题：
         * ① 重抄一遍 = 同一份真相两处维护，黑名单改了这里不会跟着改
         *    （测试继续绿，但它测的已经不是线上的那份名单）；
         * ② 本仓有一条门禁（`test/t98_no_site_names_test.dart`）要求
         *    仓库文本里不出现具体站点名 —— 夹具从常量派生就自然不新增命中。
         */
        let (only_cache_provider, only_cache_key) = CACHE_KEYS[0];
        let (mixed_provider, mixed_key) = CACHE_KEYS[2];

        let dir = temp_data_dir(
            "collect",
            &[
                ("p-a.json", r#"{"session":"TOKEN-A"}"#),
                (
                    &format!("{only_cache_provider}.json"),
                    &format!(r#"{{"{only_cache_key}":"cached"}}"#),
                ),
                (
                    &format!("{mixed_provider}.json"),
                    &format!(r#"{{"{mixed_key}":"c","session":"TOKEN-M"}}"#),
                ),
                // 坏 JSON：应跳过而不是让整次收集失败
                ("p-broken.json", "{not json"),
            ],
        );
        let b = collect(&dir).expect("收集应成功");

        assert_eq!(b.kept, 2, "p-a 与 mixed 两个有凭据");
        assert_eq!(b.skipped, 1, "只有缓存的插件应整文件跳过");
        assert_eq!(b.providers["p-a"]["session"], "TOKEN-A");
        assert_eq!(b.providers[mixed_provider]["session"], "TOKEN-M");
        assert!(
            b.providers[mixed_provider].get(mixed_key).is_none(),
            "缓存 key 必须被剔除"
        );
        assert!(
            b.providers.get(only_cache_provider).is_none(),
            "只剩缓存的插件不该出现在载荷里"
        );
        assert!(b.providers.get("p-broken").is_none(), "坏文件应跳过");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn collect_on_missing_dir_is_empty_not_error() {
        // 还没登录过任何源 —— 合法状态
        let dir = std::env::temp_dir().join(format!(
            "sourin-cred-none-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let b = collect(&dir).expect("目录不存在不该报错");
        assert!(b.is_empty());
        assert_eq!(b.kept, 0);
    }

    #[test]
    fn restore_merges_and_keeps_local_only_keys() {
        let dir = temp_data_dir(
            "restore",
            &[(
                "p-a.json",
                // 本机独有的键（云端没有）—— 还原**不许**把它删掉
                r#"{"local_only":"KEEP","session":"OLD"}"#,
            )],
        );
        let bundle = serde_json::json!({ "p-a": { "session": "NEW" }, "p-b": { "s": "B" } });

        let out = restore(&dir, &bundle).expect("还原应成功");
        assert_eq!(out.providers, 2);
        assert!(out.failed.is_empty());

        let a: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(dir.join("plugins/.data/p-a.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(a["session"], "NEW", "远端来的键应覆盖");
        assert_eq!(a["local_only"], "KEEP", "★ 本机独有的键不许被删掉");

        let b: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(dir.join("plugins/.data/p-b.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(b["s"], "B", "本机没有的插件应新建");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn restore_rejects_path_traversal_ids() {
        // 备份包可能是别人给的 —— id 里带 ../ 绝不能写出 .data 目录
        let dir = temp_data_dir("traversal", &[]);
        let bundle = serde_json::json!({ "../../evil": { "a": 1 } });
        let out = restore(&dir, &bundle).expect("不该 panic");
        assert_eq!(out.providers, 0);
        assert_eq!(out.failed.len(), 1, "必须如实报告被拒的条目");
        assert!(
            !dir.parent().unwrap().join("evil.json").exists(),
            "★ 不许在 .data 目录之外写文件"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn bundle_roundtrip_encrypt_decrypt_restore() {
        let src = temp_data_dir("rt-src", &[("p-a.json", r#"{"session":"TOKEN-A"}"#)]);
        let b = collect(&src).expect("收集");

        let blob = encrypt_bundle(PW, &b).expect("加密");
        // 密文里不许有明文
        assert!(
            !String::from_utf8_lossy(&blob).contains("TOKEN-A"),
            "密文里不许出现明文凭据"
        );

        let v = decrypt_bundle(PW, &blob).expect("解密");
        let dst = temp_data_dir("rt-dst", &[]);
        let out = restore(&dst, &v).expect("还原");
        assert_eq!(out.providers, 1);
        let a = std::fs::read_to_string(dst.join("plugins/.data/p-a.json")).unwrap();
        assert!(a.contains("TOKEN-A"), "还原后应能读到原凭据");

        let _ = std::fs::remove_dir_all(&src);
        let _ = std::fs::remove_dir_all(&dst);
    }

    #[test]
    fn decrypt_bundle_wrong_password_is_explicit() {
        let b = Bundle {
            providers: serde_json::json!({"p": {"s": "X"}})
                .as_object()
                .unwrap()
                .clone(),
            kept: 1,
            ..Default::default()
        };
        let blob = encrypt_bundle(PW, &b).unwrap();
        assert_eq!(
            decrypt_bundle("wrong", &blob),
            Err(CryptoError::WrongPasswordOrTampered)
        );
    }

    #[test]
    fn decrypt_bundle_garbage_is_not_our_file() {
        // 口令对、内容不是我们的 JSON ⇒ 报 NotOurFile（不是"口令错"）
        let blob = encrypt(PW, b"not json at all").unwrap();
        assert_eq!(decrypt_bundle(PW, &blob), Err(CryptoError::NotOurFile));
    }

    /* ══════════════════ ⑧ 明文密码检测（导出前单独提示）══════════════════ */

    #[test]
    fn detects_plaintext_username_password() {
        // 已查实的形态：某插件把账号密码原样存进私有存储
        let v = serde_json::json!({ "credentials": { "username": "u", "password": "p" } });
        assert!(looks_like_plaintext_password(&v));

        // 值是被 JSON 序列化成字符串的情况（插件常见写法）
        let nested = serde_json::json!({
            "credentials": "{\"username\":\"u\",\"password\":\"p\"}"
        });
        assert!(looks_like_plaintext_password(&nested));
    }

    #[test]
    fn session_cookie_is_not_flagged_as_password() {
        // 会话令牌不是密码 —— 不触发"明文密码"那条更强的提示
        let v = serde_json::json!({ "session": "SESSDATA=abc", "token": "xyz" });
        assert!(!looks_like_plaintext_password(&v));
        // 空密码也不算（用户没填）
        let empty = serde_json::json!({ "password": "" });
        assert!(!looks_like_plaintext_password(&empty));
    }

    /* ══════════════════ ⑨ base64（密文进 JSON 用）══════════════════ */

    #[test]
    fn base64_roundtrip_including_all_lengths() {
        for n in 0..=32usize {
            let raw: Vec<u8> = (0..n).map(|i| (i * 37 % 256) as u8).collect();
            let enc = b64_encode(&raw);
            assert_eq!(
                b64_decode(&enc),
                Some(raw.clone()),
                "长度 {n} 的 base64 往返失败（编码结果: {enc}）"
            );
        }
    }

    #[test]
    fn base64_matches_known_vectors() {
        // RFC 4648 的标准样例 —— 手写实现最容易在这几个边界上错
        assert_eq!(b64_encode(b""), "");
        assert_eq!(b64_encode(b"f"), "Zg==");
        assert_eq!(b64_encode(b"fo"), "Zm8=");
        assert_eq!(b64_encode(b"foo"), "Zm9v");
        assert_eq!(b64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(b64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(b64_encode(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn base64_rejects_invalid_input() {
        assert_eq!(b64_decode("A"), None, "长度不是 4 的倍数");
        assert_eq!(b64_decode("****"), None, "非法字符");
        assert_eq!(b64_decode("Zg=A"), None, "填充位置不对");
        assert_eq!(b64_decode("===="), None, "全是填充");
    }

    /// ★ 二进制密文必须能原样穿过 base64（导出/导入走 JSON 的唯一通道）
    #[test]
    fn encrypted_blob_survives_base64() {
        let blob = encrypt(PW, DATA).unwrap();
        let enc = b64_encode(&blob);
        let back = b64_decode(&enc).expect("解码");
        assert_eq!(back, blob, "密文字节必须逐字节还原");
        assert_eq!(decrypt(PW, &back).unwrap(), DATA);
    }
}
