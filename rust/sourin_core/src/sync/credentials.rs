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
const CACHE_KEYS: &[(&str, &str)] = &[
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

    #[test]
    fn cache_keys_are_recognised() {
        assert!(is_cache_key("douyu-live", "list_v1"));
        assert!(is_cache_key("huya-live", "list_v1"));
        assert!(is_cache_key("iptv", "cache_v3"));
        assert!(is_cache_key("iqiyi", "albums"));
        assert!(is_cache_key("bilibili-live", "rooms_v1"));
    }

    #[test]
    fn credential_keys_are_not_in_blacklist() {
        // 这三个是**凭据**，绝不能在黑名单里
        assert!(!is_cache_key("bilibili", "bili_cookie"));
        assert!(!is_cache_key("cycani", "session"));
        assert!(!is_cache_key("cycani", "credentials"));
        // 显示用，也不该排除（不然换机后用户名显示为空）
        assert!(!is_cache_key("bilibili", "bili_uname"));
    }

    #[test]
    fn same_key_different_provider_not_confused() {
        /*
         * ★ 黑名单是 (provider, key) 二元组，不是单纯 key 名。
         *   否则将来某个插件的凭据 key 恰好叫 `list_v1` 就会被误排除。
         */
        assert!(is_cache_key("douyu-live", "list_v1"));
        assert!(!is_cache_key("some-new-plugin", "list_v1"));
    }

    /* ── ④ 黑名单排除生效 ── */

    #[test]
    fn strip_removes_only_cache_keys() {
        let data = serde_json::json!({
            "list_v1": "{\"at\":1792333932301,\"list\":[...]}",  // 缓存，应剔除
            "bili_cookie": "SESSDATA=abc; bili_jct=def",          // 凭据，应保留
            "some_future_key": "unknown"                          // 未知，应保留（黑名单语义）
        });
        let map = data.as_object().unwrap().clone();
        let kept = strip_cache_keys("douyu-live", map).expect("还有内容，不该返回 None");

        assert!(!kept.contains_key("list_v1"), "缓存 key 必须被剔除");
        assert!(kept.contains_key("bili_cookie"), "凭据必须保留");
        assert!(
            kept.contains_key("some_future_key"),
            "未知 key 必须保留 —— 这是黑名单的核心语义，否则新凭据会静默丢失"
        );
        assert_eq!(kept.len(), 2);
    }

    #[test]
    fn strip_returns_none_when_only_cache() {
        let data = serde_json::json!({ "list_v1": "cached" });
        let map = data.as_object().unwrap().clone();
        assert!(
            strip_cache_keys("douyu-live", map).is_none(),
            "只剩缓存时必须返回 None（调用方据此整文件跳过上传）"
        );
    }

    #[test]
    fn strip_on_unknown_provider_keeps_everything() {
        // 26 个插件不用 host.store；万一将来用了，未知 provider 应原样保留
        let data = serde_json::json!({ "a": 1, "b": 2 });
        let map = data.as_object().unwrap().clone();
        let kept = strip_cache_keys("brand-new-plugin", map).unwrap();
        assert_eq!(kept.len(), 2);
    }

    /* ── 端到端：剔除 → 加密 → 解密 → 还原 ── */

    #[test]
    fn end_to_end_strip_then_encrypt_then_decrypt() {
        let raw = serde_json::json!({
            "list_v1": "big cache blob",
            "bili_cookie": "SESSDATA=abc"
        });
        let kept = strip_cache_keys("douyu-live", raw.as_object().unwrap().clone()).unwrap();
        let plain = serde_json::to_vec(&kept).unwrap();

        let blob = encrypt(PW, &plain).unwrap();
        let back = decrypt(PW, &blob).unwrap();
        let restored: serde_json::Value = serde_json::from_slice(&back).unwrap();

        assert_eq!(restored["bili_cookie"], "SESSDATA=abc");
        assert!(restored.get("list_v1").is_none(), "缓存不该出现在还原结果里");
    }
}
