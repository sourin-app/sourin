//! TVBox AppDrama facade. The registered constructor executes the public
//! dispatch, bootstrap, catalog and selected-episode protocol through one
//! proxy-aware transport. Legacy pure crypto helpers remain for compatibility.
//! Note: runtime behavior is covered through this facade, not a second registry.

#[cfg(test)]
use std::time::Duration;

use async_trait::async_trait;
use serde_json::Value;

use super::{CspDetail, CspHome, CspList, CspPlay, CspSite};

/// 浏览器 UA（取 `site` 配置下发的 txt 用；那些是 CDN 上的静态文件）
#[cfg(test)]
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 单次请求预算
#[cfg(test)]
const REQ_BUDGET: Duration = Duration::from_secs(20);

#[path = "app_drama_protocol.rs"]
mod protocol;

pub struct AppDrama {
    protocol: protocol::ProtocolAppDrama,
    // Only the legacy explicitly ignored dispatch diagnostic uses this client.
    #[cfg(test)]
    client: super::http_context::CspHttpContext,
}

impl AppDrama {
    pub const CLASS: &'static str = "AppDrama";

    pub fn new() -> Self {
        #[cfg(test)]
        let client = super::http_context::CspHttpContext::new(|| reqwest::Client::builder()
            .user_agent(UA)
            .timeout(REQ_BUDGET)
            // Unbound sites remain direct; the context applies the current app policy.
            .no_proxy()
        );
        Self { protocol: protocol::ProtocolAppDrama::new(), #[cfg(test)] client }
    }

    /// ext → 本次请求所需的要素（**缺一个都如实报错，不填默认值糊过去**）
    ///
    /// 返回 `ExtCfg`；字段名全部逐字来自 DEX（见文件头"ext 键"）。
    pub fn ext_of(ext: &str) -> Result<ExtCfg, String> {
        // ⚠️ 用 `serde_json::from_str` 而不是 `tvbox::parse_loose_json`：
        //   同包其它 csp 类（app_ly/app99）都是这个写法 —— 那才是本包的既有口径。
        //   `parse_loose_json` 属 `tvbox` 模块（TVBox 配置的宽松解析），
        //   csp 类**不依赖它**（会多一条跨模块耦合，与"类不许依赖宿主细节"同向）。
        let j: Value =
            serde_json::from_str(ext.trim()).map_err(|e| format!("ext 不是合法 JSON：{e}"))?;
        let get = |k: &str| {
            j.get(k)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string()
        };
        let cfg = ExtCfg {
            app_name: get("appName"),
            public_key: get("publicKey"),
            data_key: get("dataKey"),
            data_iv: get("dataIv"),
            pkg: get("pkg"),
            site: get("site"),
            version: get("version"),
            decrypt: get("decrypt"),
        };
        // ★ 逐项校验：**缺哪个报哪个**（本仓纪律：不许"看起来支持"）
        for (k, v) in [
            ("publicKey", &cfg.public_key),
            ("dataKey", &cfg.data_key),
            ("site", &cfg.site),
        ] {
            if v.is_empty() {
                return Err(format!(
                    "ext 缺少 `{k}`（AppDrama 的协议必须要它；配置里删掉就没法用）"
                ));
            }
        }
        Ok(cfg)
    }
}

/// ext 里与本类协议相关的字段（全部逐字来自 DEX 的 const-string）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtCfg {
    pub app_name: String,
    pub public_key: String,
    pub data_key: String,
    pub data_iv: String,
    pub pkg: String,
    pub site: String,
    pub version: String,
    /// `decrypt` 旗标（天堂 `"0"` / 橘汁 `"1"` / 华谊 `"1"`）
    ///
    /// # ⚠️ 本卡**只解析、未使用**（如实登记，不许静默）
    /// ```text
    /// 三站的值**不同**（0 vs 1）⇒ 它必然控制某个**条件分支**。
    /// DEX 常量里有 `paramsData` / `publicParams` / `sig` / `random_str` / `timestamp`
    /// ⇒ 最可能的语义是「**请求体/出站参数是否加密**」（= 与那把 RSA publicKey 相配的方向），
    ///    **不是**"dataKey 从哪来"（那已由勘误证明：dataKey 是明文 AES 密钥）。
    /// ⚠️ 但这是**推断**，没有端到端证据（门是 302）⇒ **本卡不用它**。
    /// ```
    /// ★ 为什么仍要把它解析出来：**不静默丢字段**。
    ///   留在这里 + 这段说明，下一个人打通登录段时能直接看到"这个旗标还没接"。
    pub decrypt: String,
}

impl Default for AppDrama {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数部分（可离线测 —— 不碰网络）
// ═══════════════════════════════════════════════════════════════════════

/// 站点**配置下发地址**（`ext.site`）的响应 → 真实 API 域
///
/// # 形态（2026-10-27 实网实测，三站一致）
/// ```text
/// GET ext.site  → 200 / 65~66 B → `{"domain": "https://juziapp.hzhcbkj.cn", "enabled": true}`
/// ```
///
/// # ★ `enabled` 为 false 时必须**如实报**，不许当"没内容"
/// ```text
/// 上游用它表达"这个站当前停用"。若把它当"空列表"，用户会以为"源没资源"，
/// 而真相是"上游自己关了" —— 那是把上游状态说成我们的解析结果（本项目最忌讳的形态）。
/// ```
pub fn parse_domain_dispatch(body: &str) -> Result<String, String> {
    let j: Value = serde_json::from_str(body.trim())
        .map_err(|e| format!("配置下发地址返回的不是合法 JSON（{e}）：{}", head(body)))?;
    let enabled = j.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
    let domain = j
        .get("domain")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if domain.is_empty() {
        return Err(format!(
            "配置下发地址里没有 `domain` 字段（上游可能改了格式）：{}",
            head(body)
        ));
    }
    if !enabled {
        return Err(format!("上游把该站标为 enabled=false（站点自己停用）：{domain}"));
    }
    Ok(domain)
}

fn head(s: &str) -> String {
    let t: String = s.chars().take(120).collect();
    t.replace('\n', " ")
}

/// ext URL 的**百分号编码**（本文件内部使用，**不动公共路径**）
///
/// # 为什么必须做（Lead 2026-10-27 裁定 (a)）
/// ```text
/// 真订阅里 XBPQ 的 ext 是
///   `https://wget.la/raw.githubusercontent.com/…/XBPQ/永乐影视.json`
/// 实测 → **HTTP 404**；而把中文路径**百分号编码**后打原站 → **HTTP 200**。
/// ⇒ 原因：路径含中文、那个代理**不做编码**。
///   ⇒ **这是我方的 bug，必须修**（不是"订阅方写错了"就算了）：
///      ext URL 由**用户订阅内容**提供，中文路径在中文站点里非常常见
///      ⇒ 不编码 = 任何带中文路径的 ext 都必然 404，**影响面远大于 XBPQ**。
/// ```
/// # 为什么只在本文件内部做（不抽到公共路径）
/// ```text
/// Lead 裁定：公共 ext 解析（`tvbox.rs`）归别人 ⇒ 我只在自己的类里编码，
/// 根治点由 Lead 另开卡。⇒ 这里**不改** `tvbox.rs`。
/// ```
/// # 只编码**路径**部分（不碰 scheme/host/query 的既有分隔符）
/// ```text
/// 整串无脑编码会把 `https://` 的 `:` `/` 也编掉 ⇒ 直接坏。
/// ⇒ 策略：**只对路径里"非 ASCII 且非保留字符"的字节做 %XX**；
///   ASCII 与保留字符（含 `/`、`:`、`?`、`&`、`=`、`#` 等）原样保留。
/// ```
pub fn encode_ext_url(url: &str) -> String {
    let mut out = String::with_capacity(url.len() + 16);
    for b in url.as_bytes() {
        // 保留/安全字符：原样（含 RFC3986 的 unreserved + gen-delims/sub-delims）
        let keep = b.is_ascii_alphanumeric()
            || matches!(
                *b,
                b'-' | b'_' | b'.' | b'~' | b'/' | b':' | b'?' | b'&' | b'=' | b'#' | b'%' | b'+' | b'@' | b'$' | b',' | b';' | b'!' | b'*' | b'\'' | b'(' | b')'
            );
        if keep {
            out.push(*b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// `dataKey` → AES 密钥字节
///
/// # ★ 为什么是"32 字符原样 32 字节"，不是"先 base64 再解"
/// ```text
/// 实测（`.probe/r3-appdrama-keys.log`）：
///   `D2KREWRIBVNAUJJYEDL4VFHOY2Q0PQ==` 按 base64 解 → **22 字节**
///   ⇒ 22 **不是**任何合法 AES 密钥长度（16/24/32）⇒ base64 读法**自证不成立**。
/// 而该串恰好 **32 字符** ⇒ 与 app99 的 `uuid.replace("-","")`（32 hex ⇒ AES-256）**同形**：
///   上游把密钥材料做成"固定 32 字符"，直接当 32 字节用。
/// ⇒ 取原串 UTF-8 字节（32 字节 = AES-256）。
/// ```
/// ⚠️ 这是**行为级推断**（由"base64 解不出合法长度"反推），不是从常量"读起来像"。
///    真网络若证明不对（例如上游其实用 base64 且密钥另有来源）⇒ 改这里，并更新注释。
pub fn data_key_raw(s: &str) -> Result<Vec<u8>, String> {
    let t = s.trim();
    if t.is_empty() {
        return Err("ext 的 dataKey 是空串".to_string());
    }
    let b = t.as_bytes().to_vec();
    // 给"不是 32 字节"的情况一个**明确**的话（而不是默默用长度不对的密钥，
    // 那会在解密阶段报出莫名其妙的 padding 错，把排查方向带偏）
    if !matches!(b.len(), 16 | 24 | 32) {
        return Err(format!(
            "ext 的 dataKey 形态不符：原串 {} 字符（{} 字节），不是 16/24/32 的 AES 密钥长度，\
也不是 base64（base64 解出来也不是合法长度）",
            t.chars().count(),
            b.len()
        ));
    }
    Ok(b)
}

/// `dataIv` → 字节（**首位 O/0 混淆容错**）
///
/// # ★★ 判别实验（Lead 2026-10-27 要求"别急着怪上游"—— 核完发现**是我们的读法**）
/// ```text
/// 原文（真订阅，三站**同一个值**）：`OC1A06E197EF10CF3F6058CA7A803B5E`
///   ① 三站完全同值 ⇒ "上游随手写坏"的概率极低；
///   ② 逐字符扫：**只有第 0 位**不是 hex 字符（越界字符 = [(0,'O')]），其余 31 位全合法；
///   ③ 把首位当 `0` 读 → `0c1a06e1…` = **16 字节** ⇒ **正好是 AES 块长** ✅
///      而按 base64 解 → 24 字节，**不是** 16/24/32 ⇒ base64 假设**被排除**。
/// ⇒ 三条合起来：这是**经典的 O/0 视觉同形混淆**，我们的解析应当**容错**。
///   ⚠️ **不报"上游数据有问题"** —— 本批已栽过好几次"把我们的问题当成对方的"。
/// ```
///
/// # ⚠️ 而且这条**可能根本不影响功能**
/// ```text
/// DEX 扫出的 AES 变换名逐字是 `AES/ECB/PKCS7Padding` —— **ECB 不使用 IV**。
/// ⇒ 若走的真是 ECB，`dataIv` 只是**多余字段**，O/0 之争**对结果无影响**。
///   本函数保留解析，只是**不静默丢弃字段**（"看起来支持"的反面）。
/// ```
pub fn data_iv(s: &str) -> Result<Vec<u8>, String> {
    let t = s.trim();
    if t.is_empty() {
        return Err("ext 的 dataIv 是空串".to_string());
    }
    // ① 原样试（若上游给的是标准 hex）
    if let Ok(b) = hex_decode(t) {
        return Ok(b);
    }
    // ② 首位 O/o → 0 的容错（判别实验支持的读法，见上）
    let mut fixed = t.to_string();
    if let Some(first) = fixed.chars().next() {
        if first == 'O' || first == 'o' {
            fixed.replace_range(0..1, "0");
            if let Ok(b) = hex_decode(&fixed) {
                return Ok(b);
            }
        }
    }
    Err(format!(
        "ext 的 dataIv 形态不符：{t}（既不是合法 hex，也不是「首位 O/o 当 0」可修的形态）"
    ))
}

/// 最小 hex 解码（不引依赖；只接受偶数长度 + 全 hex 字符）
fn hex_decode(s: &str) -> Result<Vec<u8>, String> {
    let b = s.as_bytes();
    if b.len() % 2 != 0 {
        return Err("奇数长度".to_string());
    }
    let mut out = Vec::with_capacity(b.len() / 2);
    let mut i = 0;
    while i < b.len() {
        let hi = hex_val(b[i]).ok_or_else(|| format!("非 hex 字符 '{}'", b[i] as char))?;
        let lo = hex_val(b[i + 1]).ok_or_else(|| format!("非 hex 字符 '{}'", b[i + 1] as char))?;
        out.push((hi << 4) | lo);
        i += 2;
    }
    Ok(out)
}

fn hex_val(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  AES/ECB/PKCS7 —— **本段不需要 RSA**（2026-10-27 勘误后确认）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★ 勘误（`.probe/r3-appdrama-rsa-not-the-key.log`）
// ```text
// 我此前报「RSA 是钥匙，卡它就是卡全部」 —— **错了**。三条独立证据：
//   ① 长度几何：publicKey 是 1024-bit RSA ⇒ 密文 128 字节 ⇒ base64 ~172 字符；
//      而 ext.dataKey 三站都是 **32 字符** ⇒ **装不下** RSA 密文。
//   ② 32 字符 = 32 字节 = **合法 AES-256 密钥**。
//   ③ 三站 ext **只有 publicKey、没有私钥** ⇒ 公钥**只能加密不能解密**
//      ⇒ 客户端不可能 RSA 解 dataKey。
// ⇒ dataKey = **明文 AES 密钥，直接用**；RSA 的用途在**出站加密**（publicParams/paramsData/sig）。
// ⇒ **AES 段不需要 RSA 就能开工** —— 所以本段是**可验证的真实现**，不是占位。
// ```
//
// # 变换名（DEX 逐字）
// ```text
// `AES/ECB/PKCS7Padding`
//   · ECB **不使用 IV** ⇒ `dataIv` 在本段**不参与**（这也是 O/0 之争无关紧要的原因）。
//   · 分组 16 字节；PKCS7 填充（= 本仓 aes/cbc 那套 `cipher` 里的 Pkcs7）。
// ```
//
// # ⚠️ 但**变换名是动态拼接的** —— 模式可能不止一种（如实标出不确定性）
// ```text
// DEX 里 AppDrama 的常量同时有这三条**分开**的串：
//   `AES/` + `ECB` + `/PKCS7Padding`   ⇒ 拼起来正好是 `AES/ECB/PKCS7Padding`
// ⇒ 那是"**模式来自变量**"的形态（`"AES/" + mode + "/" + padding`），
//   而不是每处都写字面常量。
//
// 结合 ext 的 `decrypt` 旗标（天堂 `"0"` / 橘汁 `"1"` / 华谊 `"1"`，三站**值不同**）
// ⇒ **存在这种可能**：`decrypt` 选的就是 mode/padding 组合
//   ⇒ 天堂（`0`）与另两站（`1`）**可能走不同变换**。
//
// ⚠️ 本卡**无法验证**（门是 302，见不到真实请求/响应）⇒ **不据此改实现**
//   （那会是"凭共现推因果" —— 正是本批已错过两次的那个错法）。
//   本文件实现 `ECB/PKCS7` 的**有据之处**：它是 AppDrama 常量里**唯一完整的** AES 变换字面串。
//   详见 `.probe/r3-appdrama-aes-transform-dynamic.log`。
// ⇒ ★ 打通登录段的人请注意：**模式可能不止一种**，别看到这里实现了 ECB 就以为已定死。
// ```
//
// # 为什么用 `cipher` 的 block API 手写 ECB（而不是引 `ecb` crate）
// ```text
// 本仓依赖表里**没有** `ecb` crate，而 `aes` 0.8 已经 `pub use cipher`。
// ECB = "每个 16 字节分组各自 `encrypt_block`"，**无需**引任何新依赖。
// ```
//
// # 为什么把加解密都写出来
// ```text
// · `decrypt` 是**上游响应用**的（浏览链路真正需要的方向）；
// · `encrypt` 是**我方请求加密**用的 —— 它与 DEX 常量 `paramsData/publicParams/sig`
//   相符（那些是"发上去"的）。
// 两个方向都实现，是为了**单测能自证一致性**（encrypt 后 decrypt 必须回到原文
// —— 这是可在离线单测里钉死的**真验证**，不靠"端点通了"）。
// ```

/// AES-256-**ECB**/PKCS7 加密（上游请求方向）
pub fn aes256_ecb_encrypt(key: &[u8], plain: &[u8]) -> Result<Vec<u8>, String> {
    use aes::cipher::{BlockEncrypt, KeyInit};
    if key.len() != 32 {
        return Err(format!(
            "AES-256 需要 32 字节密钥，给了 {} 字节",
            key.len()
        ));
    }
    let cipher = <aes::Aes256 as KeyInit>::new_from_slice(key)
        .map_err(|e| format!("构造 AES-256 失败：{e}"))?;
    let padded = pkcs7_pad(plain)?;
    let mut out = Vec::with_capacity(padded.len());
    for chunk in padded.chunks(16) {
        // chunks() 保证 16 的整数倍（pkcs7_pad 已补齐），这里直接拷进 Block
        let mut block = aes::cipher::Block::<aes::Aes256>::clone_from_slice(chunk);
        cipher.encrypt_block(&mut block);
        out.extend_from_slice(&block);
    }
    Ok(out)
}

/// AES-256-**ECB**/PKCS7 解密（上游响应方向）
pub fn aes256_ecb_decrypt(key: &[u8], cipher_text: &[u8]) -> Result<Vec<u8>, String> {
    use aes::cipher::{BlockDecrypt, KeyInit};
    if key.len() != 32 {
        return Err(format!(
            "AES-256 需要 32 字节密钥，给了 {} 字节",
            key.len()
        ));
    }
    if cipher_text.is_empty() || cipher_text.len() % 16 != 0 {
        return Err(format!(
            "密文长度必须是 16 的正整数倍（给了 {} 字节）—— 不是 AES 分组密文",
            cipher_text.len()
        ));
    }
    let cipher = <aes::Aes256 as KeyInit>::new_from_slice(key)
        .map_err(|e| format!("构造 AES-256 失败：{e}"))?;
    let mut out = Vec::with_capacity(cipher_text.len());
    for chunk in cipher_text.chunks(16) {
        let mut block = aes::cipher::Block::<aes::Aes256>::clone_from_slice(chunk);
        cipher.decrypt_block(&mut block);
        out.extend_from_slice(&block);
    }
    // 去 PKCS7 填充；填充不合法 ⇒ **如实报**（通常是密钥不对 —— 别掩盖成"空内容"）
    pkcs7_unpad(&out)
}

/// PKCS7 填充（分组 16）
fn pkcs7_pad(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = data.to_vec();
    let pad = 16 - (data.len() % 16);
    // pad ∈ 1..=16（正好整块时补满 16）
    out.extend(std::iter::repeat(pad as u8).take(pad));
    Ok(out)
}

/// 去 PKCS7 填充；**不合法时如实报"密钥可能不对"**
///
/// ⚠️ 这一条很重要：密钥错时解出的填充几乎必然不合法。
///    若这里"悄悄返回空"或"忽略填充"，用户会看到"这个源没内容"，
///    而真相是"我们密钥错了" —— 那是本项目最忌讳的形态。
fn pkcs7_unpad(data: &[u8]) -> Result<Vec<u8>, String> {
    let Some(&last) = data.last() else {
        return Err("解密结果为空".to_string());
    };
    let pad = last as usize;
    if pad == 0 || pad > 16 || pad > data.len() {
        return Err(format!(
            "PKCS7 填充不合法（末字节 {pad}）⇒ 多半是「密钥不对」，不是上游没内容"
        ));
    }
    let cut = data.len() - pad;
    if data[cut..].iter().any(|&b| b as usize != pad) {
        return Err(format!(
            "PKCS7 填充字节不一致（应为 {pad}）⇒ 多半是「密钥不对」，不是上游没内容"
        ));
    }
    Ok(data[..cut].to_vec())
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

/// 「本类还没打通的段」的**统一如实报错**（不许返回空列表假装没内容）
///
/// # 为什么单独一个函数
/// ```text
/// 这个文案会被 `home/list/search/detail/play` **共用** ⇒ 提出来只有一处真相。
/// ★ 而且它必须**点名卡在哪**（RSA 钥匙 / 登录握手 / proto 段），
///   不许笼统写"未实现" —— 笼统文案会让下一个人重新排查一遍。
/// ```
#[async_trait]
impl CspSite for AppDrama {
    fn class(&self) -> &'static str { Self::CLASS }
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.protocol.set_http_context(proxy.clone(), provider);
        #[cfg(test)]
        self.client.set_proxy(proxy, provider);
    }
    fn accepts_selected_episode_id(&self, id: &str) -> bool {
        self.protocol.accepts_selected_episode_id(id)
    }
    fn supports_search(&self) -> bool { self.protocol.supports_search() }
    fn needs_ext(&self) -> bool { self.protocol.needs_ext() }
    async fn home(&self, ext: &str) -> Result<CspHome, String> { self.protocol.home(ext).await }
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        self.protocol.list(tid, page, ext).await
    }
    async fn search(&self, keyword: &str, page: u32, ext: &str) -> Result<CspList, String> {
        self.protocol.search(keyword, page, ext).await
    }
    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> { self.protocol.detail(id, ext).await }
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        self.protocol.play(flag, id, ext).await
    }
}

#[cfg(test)]
impl AppDrama {
    /// Legacy ignored dispatch diagnostic; not the production protocol owner.
    /// 取文本（带 UA；错误里**保留 URL**，否则排查时不知道打的哪个域）
    async fn get_text(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .client()?
            .get(url)
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        if !status.is_success() {
            return Err(format!("站点返回 HTTP {status}（{url}）"));
        }
        resp.text()
            .await
            .map_err(|e| format!("读取响应失败（{url}）：{e}"))
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★ 本仓**无等价位**的上游行为（登记，不许静默丢掉）
// ═══════════════════════════════════════════════════════════════════════
//
// DEX 里 AppDrama 重写了 Spider 的 **全部 11 个标准 API**，其中三条在本仓**没有等价位**：
//
// ```text
// · `mProxy(Map) -> Object[]`        ⇒ 本批**明确不做**（Lead 裁定）。
//   上游语义：让类**自己接管某条流的本地代理响应**（返回本地代理端点的响应）。
//   为什么本仓不做：那是**宿主职责**（本仓有 `streamproxy`），
//   且与我们刚下的"类不许依赖宿主细节（crate::streamproxy/proxy）"**直接冲突**。
//   ⇒ 登记为**已知缺口**（不是"忘了"，是"有意不做，理由在此"）。
//
// · `loadPic(Map) -> Object[]`       ⇒ 本仓**不补契约位**（Lead 裁定）。
//   上游语义：让类**自己接管图片请求**（防盗链 Referer / 带 cookie 取图）。
//   本仓的等价位：**声明式** —— 把该站取图需要的头写进该源的 `cover_headers`，
//   由宿主 `home.rs` 的 `proxy_covers` **统一代取**。
//   ★ 这比"类自己接管"更好：类不该碰宿主代理细节（正是 Owner 要避免的耦合）。
//   ⚠️ 若某站取图**不只是固定头**（需要签名 / 多跳）⇒ **报 Lead**，不自己造。
//
// · `initApi(SpiderApi)`              ⇒ 本仓等价位 = **`ext` 机制**（`home(ext)/list(ext)`），不补。
//
// · `isVideoFormat(String) -> bool`  /  `manualVideoCheck() -> bool`
//   ⇒ 本仓**没有**对应行为位（播放器侧的格式判定/手工校验不在 `CspSite` 契约里）。
//     ⇒ 按 Lead 裁定："没有就**如实写未实现**，别自己造" ⇒ **登记在此，未实现**。
// ```
//
// # 为什么这些必须写在这里（而不是"反正用不到就不提"）
// ```text
// 本仓最忌讳"看起来支持"。上游有的行为我方没有 ⇒ 必须**留下痕迹**，
// 否则下一个人会以为"这个类已经全量对齐上游了"。
// ```

crate::csp::register_site!(AppDrama);

#[cfg(test)]
#[path = "app_drama_proxy_tests.rs"]
mod proxy_tests;

#[cfg(test)]
mod tests {
    use super::*;

    // ═══════════════════════════════════════════════════════════════
    //  ★ 反空真（铁律 149）：候选集为空时全称断言恒真
    //  ⇒ 本组每条"不许/全都"式断言，都先证明它的**候选集非空**。
    // ═══════════════════════════════════════════════════════════════

    #[test]
    fn ext_parses_real_subscription_ext() {
        // ★ 逐字取自真订阅（🏵️天堂｜蓝光秒播）
        let ext = r#"{"appName": "电影天堂",
            "publicKey": "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCduNEnfxGaLuQRk5ABzXHhPV43",
            "dataKey": "D2KREWRIBVNAUJJYEDL4VFHOY2Q0PQ==",
            "dataIv": "OC1A06E197EF10CF3F6058CA7A803B5E",
            "pkg": "com.dytiantang.one", "host": "",
            "site": "https://dyttandroid04-1372779881.cos.ap-shanghai.myqcloud.com/app_dyttandroid.txt",
            "version": "3.0.0.7", "decrypt": "0"}"#;
        let c = AppDrama::ext_of(ext).expect("真订阅的 ext 必须解得出来");
        assert_eq!(c.app_name, "电影天堂");
        assert_eq!(c.pkg, "com.dytiantang.one");
        assert_eq!(c.decrypt, "0");
        assert!(c.site.starts_with("https://dyttandroid04"));
    }

    #[test]
    fn ext_missing_key_names_the_missing_one() {
        // ★ 缺哪个报哪个（不许笼统"ext 不合法"）
        let err = AppDrama::ext_of(r#"{"appName":"x","dataKey":"k","site":"s"}"#).unwrap_err();
        assert!(err.contains("publicKey"), "必须点名缺的是 publicKey：{err}");
        let err2 = AppDrama::ext_of(r#"{"publicKey":"p","dataKey":"k"}"#).unwrap_err();
        assert!(err2.contains("site"), "必须点名缺的是 site：{err2}");
    }

    #[test]
    fn domain_dispatch_parses_real_body() {
        // ★ 逐字取自实网（`https://juziapp.hzhcbkj.cn` 那条下发）
        let body = r#"{
  "domain": "https://juziapp.hzhcbkj.cn",
  "enabled": true
}"#;
        assert_eq!(
            parse_domain_dispatch(body).unwrap(),
            "https://juziapp.hzhcbkj.cn"
        );
        // 另两站的真实下发（橘汁 / 华谊）也要能解
        assert_eq!(
            parse_domain_dispatch(r#"{"domain":"http://122.228.193.211:18008","enabled":true}"#)
                .unwrap(),
            "http://122.228.193.211:18008"
        );
    }

    #[test]
    fn domain_dispatch_disabled_is_reported_not_empty() {
        // ★ `enabled:false` 必须**如实报"上游停用"**，不许当"空列表"（那会把上游状态说成我们的解析结果）
        let err = parse_domain_dispatch(r#"{"domain":"https://x.example","enabled":false}"#)
            .unwrap_err();
        assert!(err.contains("enabled=false"), "要点名是上游停用：{err}");
        assert!(err.contains("停用"), "要说清是站点自己关了：{err}");
    }

    #[test]
    fn domain_dispatch_without_domain_reports_reason() {
        let err = parse_domain_dispatch(r#"{"enabled":true}"#).unwrap_err();
        assert!(err.contains("domain"), "缺 domain 要报明确原因：{err}");
    }

    // ── dataKey / dataIv：两条都由**判别实验**得出，不是猜 ──────────

    #[test]
    fn data_key_is_32_chars_as_bytes_not_base64() {
        // ★ 反空真：先证明这个串**确实存在且是 32 字符**
        let raw = "D2KREWRIBVNAUJJYEDL4VFHOY2Q0PQ==";
        assert_eq!(raw.chars().count(), 32, "前置：真订阅的 dataKey 就是 32 字符");

        let k = data_key_raw(raw).expect("32 字符应当可用");
        assert_eq!(k.len(), 32, "⇒ 32 字节 = AES-256");
        assert_eq!(&k[..3], b"D2K");

        // ★ 反证：base64 读法**不成立**（解出 22 字节，不是合法 AES 长度）
        //   —— 这条把"为什么不用 base64"钉成可验证的事实，而不是注释里的说法
        let b64_len = base64_decode_len_rough(raw);
        assert_eq!(b64_len, 22, "前置：base64 解出来是 22 字节");
        assert!(
            !matches!(b64_len, 16 | 24 | 32),
            "★ 22 不是任何合法 AES 密钥长度 ⇒ base64 读法自证不成立（这就是选 32 字节原样的依据）"
        );
    }

    /// 只算 base64 解码后的长度（够用即可 —— 用于上面那条"排除 base64 读法"的断言）
    fn base64_decode_len_rough(s: &str) -> usize {
        let t = s.trim_end_matches('=');
        t.len() * 3 / 4
    }

    #[test]
    fn data_key_rejects_non_aes_length() {
        // ★ 长度不对时给**明确**的话（不许默默用错长度密钥 ⇒ 会在解密阶段报 padding 错，带偏排查方向）
        let err = data_key_raw("short").unwrap_err();
        assert!(err.contains("不是 16/24/32"), "要点明长度不符：{err}");
        assert!(err.contains("形态不符"), "要说这是**形态**问题：{err}");
    }

    #[test]
    fn data_iv_accepts_letter_o_as_zero() {
        // ★ 判别实验（Lead 要求"别急着怪上游"，核完是我们的读法）：
        //   真订阅三站**同一个值** `OC1A…`，只有第 0 位不是 hex 字符 ⇒ O/0 视觉同形
        let raw = "OC1A06E197EF10CF3F6058CA7A803B5E";
        assert_eq!(raw.chars().count(), 32, "前置：真订阅的 dataIv 是 32 字符");

        let bad: Vec<usize> = raw
            .char_indices()
            .filter(|(_, c)| !c.is_ascii_hexdigit())
            .map(|(i, _)| i)
            .collect();
        assert_eq!(bad, vec![0], "★ 前置：**只有第 0 位**不是 hex 字符（这是判别的关键）");

        let iv = data_iv(raw).expect("首位 O 当 0 应能解出来");
        assert_eq!(iv.len(), 16, "★ 16 字节 = 正好 AES 块长（这是'读法对'的证据）");
        assert_eq!(iv[0], 0x0c, "0C1A… 的首字节应是 0x0c");
    }

    #[test]
    fn data_iv_plain_hex_still_works() {
        // 不能为了容错把**标准 hex** 弄坏（上游将来换成规范值也必须能读）
        let iv = data_iv("0C1A06E197EF10CF3F6058CA7A803B5E").expect("标准 hex 必须可用");
        assert_eq!(iv.len(), 16);
        assert_eq!(iv[0], 0x0c);
    }

    #[test]
    fn data_iv_rejects_garbage_without_blaming_upstream() {
        let err = data_iv("zzzz").unwrap_err();
        assert!(err.contains("形态不符"), "要说形态不符：{err}");
        // ★ 不许把自己的读法问题说成"上游数据有问题"（本批已栽过好几次）
        assert!(
            !err.contains("上游数据"),
            "★ 不许把'我方读法'说成'上游数据有问题'：{err}"
        );
    }

    // ── ext URL 编码（Lead 裁定 (a)：本文件内部实现）────────────────

    #[test]
    fn ext_url_encodes_chinese_path() {
        // ★ 真实案例（真订阅里 XBPQ 的那条，实测未编码 → 404）
        let raw = "https://wget.la/raw.githubusercontent.com/tushen6/Tomorrow/master/XBPQ/永乐影视.json";
        let enc = encode_ext_url(raw);
        // 前置：原文**确实含非 ASCII**（否则本测试是在验一个不需要编码的串）
        assert!(
            raw.bytes().any(|b| b >= 0x80),
            "前置：这条 URL 必须含非 ASCII 字节"
        );
        assert!(
            !enc.bytes().any(|b| b >= 0x80),
            "★ 编码后必须**全 ASCII**（否则还是会 404）：{enc}"
        );
        assert!(
            enc.contains("%E6%B0%B8%E4%B9%90%E5%BD%B1%E8%A7%86"),
            "中文必须被逐字节 %XX 编码：{enc}"
        );
    }

    #[test]
    fn ext_url_keeps_structure_intact() {
        // ★ 反证：不能把 scheme/host/query 的分隔符也编掉（那就直接坏了）
        let enc = encode_ext_url("https://a.example/x?k=v&p=1#f");
        assert!(enc.starts_with("https://"), "scheme 不许被破坏：{enc}");
        assert!(enc.contains("a.example/x"), "host/path 的 ASCII 部分原样：{enc}");
        assert!(enc.contains("?k=v&p=1#f"), "query/fragment 的分隔符原样：{enc}");
    }

    #[test]
    fn ext_url_ascii_url_is_unchanged() {
        // ★ 对**本来就没问题**的 URL 不许改动（否则是引入回归）
        let u = "https://example.com/plain/path.json";
        assert_eq!(encode_ext_url(u), u);
    }

    // ── 卡点必须**如实报**（Lead 交付目标的那一条）──────────────────

    #[tokio::test]
    async fn malformed_configuration_and_unsigned_selection_fail_without_empty_success() {
        let site = AppDrama::new();
        for result in [
            site.home("{}").await.map(|_| ()),
            site.list("cat", 1, "{}").await.map(|_| ()),
            site.search("query", 1, "{}").await.map(|_| ()),
            site.detail("1001", "{}").await.map(|_| ()),
        ] {
            let error = result.expect_err("invalid configuration cannot become empty content");
            assert!(error.starts_with("parse:"), "{error}");
            assert!(!error.contains("尚未打通"));
        }
        let error = site.play("", "unissued-recipe", "{}").await.unwrap_err();
        assert!(error.starts_with("unsupported:"));
    }

    #[test]
    fn implemented_search_and_required_configuration_match_default_protocol() {
        let site = AppDrama::new();
        assert!(site.supports_search());
        assert!(site.needs_ext());
        assert!(site.accepts_selected_episode_id("app-drama:v2|issued-opaque-token"));
        assert!(!site.accepts_selected_episode_id("1001"));
    }

    #[test]
    fn class_name_matches_api_literal() {
        // 注册键必须与配置里 `api` 的后半段**逐字**一致（大小写敏感）
        assert_eq!(AppDrama::CLASS, "AppDrama");
    }

    #[test]
    fn decrypt_flag_is_parsed_and_known_unused() {
        // ★ 这条守"**不静默丢字段**"：decrypt 被解析出来（值逐字保留），
        //   但本卡**没有用它** —— 用一个断言把这个事实钉住，
        //   免得下一个人以为"它已经接上了"。
        let zero = AppDrama::ext_of(
            r#"{"publicKey":"p","dataKey":"D2KREWRIBVNAUJJYEDL4VFHOY2Q0PQ==","site":"s","decrypt":"0"}"#,
        )
        .unwrap();
        assert_eq!(zero.decrypt, "0", "逐字保留（含字符串形态，不是 bool）");
        let one = AppDrama::ext_of(
            r#"{"publicKey":"p","dataKey":"D2KREWRIBVNAUJJYEDL4VFHOY2Q0PQ==","site":"s","decrypt":"1"}"#,
        )
        .unwrap();
        assert_eq!(one.decrypt, "1");
        // ★ 前置：三站**确实取值不同** ⇒ 它一定是条件分支，不是一个可忽略的装饰
        assert_ne!(zero.decrypt, one.decrypt, "前置：0 与 1 必须不同");
        // ⚠️ 本卡**未使用**它（见 ExtCfg::decrypt 的注释）。这条断言不检查"用了没有"
        //   ——那是编译期事实（当前全仓无其它读取点），写成运行时断言会是恒真。
        //   这里只钉"解析正确"，把"未使用"写在字段注释里留痕。
    }

    // ── AES-256-ECB（★ 本段**不需要 RSA** ⇒ 是**可离线验证的真实现**）────

    #[test]
    fn aes_ecb_roundtrip_is_self_consistent() {
        // ★ 这是本卡最强的"真验证"：加解密**互逆**，完全离线可钉
        //   （不依赖"端点通了"——那是端到端，这里验的是**原语正确性**）
        let key = data_key_raw("D2KREWRIBVNAUJJYEDL4VFHOY2Q0PQ==").unwrap();
        assert_eq!(key.len(), 32, "前置：AES-256 密钥必须 32 字节");

        for plain in [
            &b""[..],
            b"a",
            b"exactly16bytes!!",           // 正好一块
            b"a longer payload that spans several AES blocks",
        ] {
            let ct = aes256_ecb_encrypt(&key, plain).expect("加密必须成功");
            assert_eq!(ct.len() % 16, 0, "密文必须是 16 的整数倍");
            assert!(ct.len() > plain.len(), "PKCS7 总会补至少 1 字节");
            let back = aes256_ecb_decrypt(&key, &ct).expect("解密必须成功");
            assert_eq!(back, plain.to_vec(), "★ 加解密必须互逆（原语正确性的硬证据）");
        }
    }

    #[test]
    fn aes_ecb_matches_known_vector() {
        // ★ 反空真 + **外部标准向量**：用 NIST AES-256 已知答案（KAT）钉住实现
        //   ---- AES-256, key=0x00*32, plaintext=0x00*16, ECB 模式 ----
        //   FIPS-197 / NIST SP800-38A 的标准答案：
        let key = [0u8; 32];
        let pt = [0u8; 16];
        let ct = aes256_ecb_encrypt(&key, &pt).expect("加密");
        // 注意：ECB 无填充时不会补；这里明文正好一块 ⇒ PKCS7 会**补满 16 字节**，
        // 所以密文是 2 块。取**第一块**与 NIST 向量比（第一块就是纯 ECB(零块)）。
        let first_block = &ct[..16];
        let want = [
            0xdc, 0x95, 0xc0, 0x78, 0xa2, 0x40, 0x89, 0x89, 0xad, 0x48, 0xa2, 0x14, 0x92, 0x84,
            0x20, 0x87,
        ];
        assert_eq!(
            first_block,
            &want,
            "★ 第一块必须等于 NIST AES-256 零块 KAT（这是**外部标准**，不是我自证的）"
        );
    }

    #[test]
    fn aes_rejects_wrong_key_length() {
        let err = aes256_ecb_encrypt(&[0u8; 16], b"x").unwrap_err();
        assert!(err.contains("32"), "AES-256 要 32 字节：{err}");
        let err2 = aes256_ecb_decrypt(&[0u8; 8], &[0u8; 16]).unwrap_err();
        assert!(err2.contains("32"), "{err2}");
    }

    #[test]
    fn aes_decrypt_rejects_non_block_ciphertext() {
        let key = [0u8; 32];
        let err = aes256_ecb_decrypt(&key, &[0u8; 15]).unwrap_err();
        assert!(err.contains("16"), "密文长度必须是 16 的倍数：{err}");
        assert!(err.contains("不是 AES 分组密文"), "要点明这不是分组密文：{err}");
    }

    #[test]
    fn aes_wrong_key_reports_key_problem_not_empty() {
        // ★★ 关键纪律：**密钥错**时解出的填充几乎必然不合法。
        //   若这里"悄悄返回空"，用户会看到"这个源没内容"，而真相是"我们密钥错了"。
        let right = data_key_raw("D2KREWRIBVNAUJJYEDL4VFHOY2Q0PQ==").unwrap();
        let wrong = data_key_raw("OW1WBLFZCLJ0WTNJCDMYEGXWYVP3PT0=").unwrap();
        // 前置：两把钥匙**确实不同**（否则这条测不出东西）
        assert_ne!(right, wrong, "前置：两把不同源的 dataKey 必须不同");

        let ct = aes256_ecb_encrypt(&right, b"some upstream json payload").unwrap();
        match aes256_ecb_decrypt(&wrong, &ct) {
            // 极小概率填充恰好合法（16 字节块随机通过率 ~1/256 的上界）——
            // 那时**必须**是"内容乱码"而不是"干净原文"，下面 assert 会抓到
            Ok(v) => assert_ne!(v, b"some upstream json payload".to_vec(), "★ 错钥匙不许解出正确原文"),
            Err(e) => {
                assert!(
                    e.contains("密钥不对"),
                    "★ 错钥匙的报错必须**指向密钥**，不许含糊：{e}"
                );
                assert!(
                    !e.contains("上游") || e.contains("不是上游没内容"),
                    "★ 不许把'我们密钥错'说成'上游没内容'：{e}"
                );
            }
        }
    }

    #[test]
    fn aes_key_from_each_site_differs() {
        // ★ 反空真：三站的 dataKey **确实不同** ⇒ 前面"各站共用一份实现、差异只在 ext"成立
        let a = data_key_raw("D2KREWRIBVNAUJJYEDL4VFHOY2Q0PQ==").unwrap();
        let b = data_key_raw("OW1WBLFZCLJ0WTNJCDMYEGXWYVP3PT0=").unwrap();
        let c = data_key_raw("NDBYSZR1DMRRZ05NSUCWEJNIYWLBPT0=").unwrap();
        assert_eq!((a.len(), b.len(), c.len()), (32, 32, 32), "三站都是 AES-256");
        assert_ne!(a, b, "天堂 ≠ 橘汁");
        assert_ne!(b, c, "橘汁 ≠ 华谊");
    }

    /// ★★★ 真网络：**两跳取域端到端**（本卡唯一"真打通"的那一段）
    ///
    /// # 跑法
    /// ```text
    /// CSP_LIVE=1 cargo test --lib app_drama_live_domain --release --offline \
    ///   -- --ignored --nocapture
    /// ```
    /// # 为什么这条重要（Lead 交付目标）
    /// ```text
    /// 本卡的交付目标是「把取域+RSA/AES+v3 JSON 打通，并**如实报出卡在登录握手**」。
    /// 这一段（取域）是**真的通**的 ⇒ 用真网络把它钉住；
    /// 而"分类段卡在哪"由 `unwired_sections_report_reason_not_empty` 钉住。
    /// ```
    /// ⚠️ 三站里**华谊**的第二跳实测 **502**（上游自己不可用）——
    ///    所以本探针**逐站报**，一处失败不影响另两处（也别把一处失败说成"都坏了"）。
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib app_drama_live_domain --release -- --ignored --nocapture"]
    async fn app_drama_live_domain() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        // 三站的真 ext（逐字取自真订阅；publicKey 截断只为可读，取域用不到它）
        let sites = [
            (
                "天堂",
                "https://dyttandroid04-1372779881.cos.ap-shanghai.myqcloud.com/app_dyttandroid.txt",
            ),
            ("橘汁", "https://123-1349250429.cos.ap-shanghai.myqcloud.com/app.txt"),
            ("华谊", "https://vip.123pan.cn/1851089669/oss/az5.txt"),
        ];
        let z = AppDrama::new();
        let mut ok = 0usize;
        for (name, site) in sites {
            let ext = format!(
                r#"{{"appName":"{name}","publicKey":"x","dataKey":"D2KREWRIBVNAUJJYEDL4VFHOY2Q0PQ==","dataIv":"OC1A06E197EF10CF3F6058CA7A803B5E","site":"{site}"}}"#
            );
            // ① 配置下发地址（第一跳）
            match z.get_text(&encode_ext_url(&site)).await {
                Err(e) => {
                    println!("LIVE|hop1|{name}|ERR|{e}");
                    continue;
                }
                Ok(body) => {
                    println!("LIVE|hop1|{name}|OK|{}", head(&body));
                    match parse_domain_dispatch(&body) {
                        Err(e) => println!("LIVE|parse|{name}|ERR|{e}"),
                        Ok(domain) => {
                            println!("LIVE|domain|{name}|{domain}");
                            // ② 真实 API 域（第二跳：只探根可达性，不预判内容）
                            match z.get_text(&encode_ext_url(&domain)).await {
                                Ok(_) => {
                                    ok += 1;
                                    println!("LIVE|hop2|{name}|OK|{domain}");
                                }
                                Err(e) => println!("LIVE|hop2|{name}|ERR|{e}"),
                            }
                        }
                    }
                }
            }
            let _ = ext;
        }
        println!("LIVE|sum|两跳都通={ok}/3");
        // ⚠️ 不断言 ok==3：**华谊上游实测 502**，那是上游状态，不是我们失败。
        //    本探针的作用是**如实报读数**，不是"必须全通才算过"。
        assert!(ok >= 1, "至少要有站点两跳可通（否则更像是我方网络/编码出了问题）");
    }
}

#[cfg(test)]
#[path = "app_drama_protocol_behavior_tests.rs"]
mod protocol_behavior_tests;
