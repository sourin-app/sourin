// ═══════════════════════════════════════════════════════════════════════
//  csp_SouJu —— 「🔍搜聚」（`api.souju.ai`，HmacSHA256 签名，**密钥未取证**）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★ 先说清一件事：这个类**与别的类都不同**
// ```text
// ① 父类是 `Pan`（**盘类**），不是 `Spider` ⇒ 语义上它偏"网盘/播放解析"
// ② 订阅里的条目**没有 ext**：`"api":"csp_SouJu","type":3,"searchable":1,"quickSearch":1`
//    ⇒ **没有任何配置可读**
// ③ 它的 host **不在 DEX 常量里** —— 是 `site()` 算出来的：
//       `site()` → `XC.s(SITE_A)`
//     而 `XC.s(String)` 是**一个字符串解密器**：
//       `com.github.catvod.spider.merge.XC.s` → `com.github.catvod.spider.merge.Z.A.run`
//       （混淆链：`XC.s` → `Z.A.run` → `e.g` / `c.c` + `B.a`）
//    ⇒ ★ **`SITE_A`/`SEC_A`/`K` 这些常量的真值我解不出来**（见"未取证"）
// ④ 真网络实测到的 host 是 `https://api.souju.ai`（**从站点行为反推**，不是从 DEX）
// ```
//
// # ★★★ 签名算法：**完整读出来了**（这部分是真的）
//
// ```text
// 反汇编 `SouJu.sign(HashMap, String, String)`（266 条指令，逐条读出）：
//   ① 待签串 = `method + "\n" + path + "\n" + ts + "\n" + nonce`（分隔符是 `\n`）
//      —— 逐字证据：常量 `'UTF-8'` / `'HmacSHA256'` / `'/'` / `'\n'`
//         + `StringBuilder.append ×N` + `String.indexOf`/`substring`
//         （在把 `/v1/xxx?query` 里的 **query 部分切掉**，只签 path）
//   ② 时间戳 = `String.valueOf(System.currentTimeMillis())`      ← 毫秒
//   ③ nonce   = `String.format("%02x", Random.nextInt(...))` × N，再 `.toUpperCase()`
//               —— ★ 是**大写 hex**（`%02x` + `toUpperCase` 两步都被我读到了）
//   ④ `Mac.getInstance("HmacSHA256")` + `SecretKeySpec(SouJu.secret().getBytes("UTF-8"))`
//      + `Mac.init` + `Mac.doFinal(待签串.getBytes("UTF-8"))`
//   ⑤ 结果同样 `String.format("%02x")` 拼成 **hex**
//   ⑥ 三个头（**逐字**）：
//        `x-ai-movie-timestamp`  = ②
//        `x-ai-movie-nonce`      = ③
//        `x-ai-movie-signature`  = ⑤
//   ⑦ 另外 `sign` 里还有 `?` + `append` ⇒ 把签名拼进 query
//   ⇒ ★ 这套**可以纯 Rust 复刻**（`ring::hmac::HMAC_SHA256`，**零新增依赖**）
//     —— 见本文件的 `canonical_string` / `hmac_sha256_hex` / `Signer`，**均已单测**。
// ```
//
// # ⛔ 未取证（**唯一的一处，也是致命的一处**）
// ```text
// `secret()` 的实现只有 9 条指令：
//     `field SouJu.SEC_A` + `invoke XC.s` + 返回
//   ⇒ 密钥 = `XC.s(SEC_A)`，而 **`SEC_A` 的真值在混淆后的字符串解密器里**
//     （`XC.s` → `Z.A.run` → `e.g` / `c.c` / `B.a` 多层间接）
//
// ★ 我**没有**去暴力解那个解密器，因为：
//   ① `Z.A.run` 是 `java.lang.Object` 的子类、字段全是同类引用（`A.a`/`A.b`）、
//      还引用 `e.g` / `c.c` / `B.a` —— 典型的**多层间接混淆**；
//      逐层手解的成本**远超**本批"有界工作"的口径。
//   ② 更关键：**`secret()` 是这套签名的唯一密钥来源**，而它**不是 ext 配置**
//      （订阅里 SouJu **没有 ext**）⇒ 就算我把算法全写对，
//      **没有密钥就签不出上游认的签名** ⇒ 请求仍会 `401`。
//   ③ 真网络实测已证明这一点（**独立证据，不是推断**）：
//        `/v1/feed/home`、`/v1/suggest`、`/v1/catalog/` → 全部
//        `401 Missing request signature`（`invalid_request_signature`）
//      ⇒ 上游**确实在校验签名**，而我**没有密钥** ⇒ 无法通过。
//
// ⇒ 本实现：**算法侧写全且已单测**（这是真支票），
//      **密钥侧如实标"未取证"**，`play()`/五个取数方法都点名真因。
//      **绝不**随便猜一个密钥去撞（那会得到"看起来通了"的假象）。
// ```
//
// # 为什么还写出来
// ```text
// ① 算法侧（待签串拼法 / nonce / 头名 / hex 大小写）**全部是真信息** ——
//    哪天拿到 `SEC_A` 的真值（或上游换成不校验签名的入口），**接上即可用**。
// ② 门禁钉住三条**不依赖网络**的性质：待签串形状 / HMAC 与标准向量一致 / 头名逐字。
// ③ 与 Hxq（缺 `srefer`）、YunDuo（缺 wasm）、Gulu（缺派生）同档：
//    **协议写全 + 缺值如实标**。
// ```
//
// # 已知缺口（按 Lead 裁定的契约边界登记）
// ```text
// · mProxy   —— 本批不做
// · loadPic  —— 本仓不补 trait；封面头见 COVER_HEADERS（取不到内容 ⇒ 留空不编）
// · `doLogin()`（`/v1/users/password/login`，`ai_movie_session=ums_…`）——
//   DEX 里有一套登录流程（账号/密码），但**账号密码也在 `ACC_A`/`PWD_A`（同样未取证）**
//   ⇒ 如实不做（不是"忘了"）
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX 里的 UA（`head()` / `getWithSession()` 逐字）
const UA: &str = "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// ★ 真网络实测到的 host（**不是**从 DEX 读的 —— DEX 里它是 `site()` 算出来的）
///
/// ```text
/// 我先前实测：`/v1/feed/home` / `/v1/suggest` / `/v1/catalog/` 都回
///   `401 Missing request signature`（`invalid_request_signature`）
/// ⇒ 该 host 上**确实挂着这套接口**（否则会是 404/别的错误）
/// ⇒ 保留为常量（若将来 `SITE_A` 被解密出来，用它替换即可）
/// ```
pub const OBSERVED_HOST: &str = "https://api.souju.ai";

pub const COVER_HEADERS: &[(&str, &str)] = &[];

const TIMEOUT: Duration = Duration::from_secs(20);

/// ★ DEX `sign` 里逐字的**三个签名头**（`HashMap.put` 的三个键）
pub const SIG_HEADERS: &'static [&'static str] = &[
    "x-ai-movie-timestamp",
    "x-ai-movie-nonce",
    "x-ai-movie-signature",
];

/// ★ DEX 里逐字的算法名与编码
pub const HMAC_ALGORITHM: &str = "HmacSHA256";
pub const CHARSET: &str = "UTF-8";

/// nonce 的字节数（DEX 里 `String.format("%02x", Random.nextInt(...))` 循环 N 次）
///
/// ```text
/// ★ 我数了 `sign` 里那段 `StringBuilder.append ×N` + `format` 的**重复次数**，
///   读出是 **16 个 hex 字符**（= 8 字节）—— 但我不把这条当"契约"，
///   因为它只影响"和上游撞不撞得上"，而**密钥才是决定性的**。
///   ⇒ 写成常量并单测其长度；错误文案里说明"这一点不影响密码学正确性"。
/// ```
pub const NONCE_HEX_LEN: usize = 16;

/// ★ 拼**待签串**（DEX `sign` 里逐字读出的形状）
///
/// # 形状（这是本文件最有价值的真信息）
/// ```text
///   `method + "\n" + path + "\n" + timestamp + "\n" + nonce`
/// 其中：
///   · `method` 大写（`GET`/`POST` —— DEX 里有这两个字面量）
///   · `path`  是 **不含 query** 的路径 ——
///     证据：DEX 里有 `String.indexOf("?")` + `String.substring`（切掉 query）
///     ⚠️ 若没有 `?`（`indexOf` 回 -1），DEX 走的是"整串"分支
///   · `timestamp` 是毫秒字符串
///   · `nonce` 是大写 hex
/// ⇒ ★ 抽成**纯函数** ⇒ 门禁可直接断言（不必联网）
/// ```
pub fn canonical_string(method: &str, path: &str, timestamp: &str, nonce: &str) -> String {
    // ★ 先切掉 query（DEX：`indexOf('?')` 之后 `substring(0, idx)`）
    let pure_path = match path.find('?') {
        Some(i) => &path[..i],
        None => path,
    };
    format!("{method}\n{pure_path}\n{timestamp}\n{nonce}")
}

/// ★ HmacSHA256 → **小写 hex**（DEX 里 `String.format("%02x", Byte.valueOf(...))`）
///
/// # 用 `ring`（**零新增依赖**）
/// ```text
/// `hmac` / `sha2` **都不是本仓直接依赖**；
/// 而 `ring 0.17` 已暴露 `hmac::HMAC_SHA256` + `hmac::Key` / `hmac::sign`
///   ⇒ 与 Gulu 用 `ring::agreement` 同一策略：**不新增依赖**。
/// ```
pub fn hmac_sha256_hex(key: &[u8], msg: &[u8]) -> String {
    let k = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, key);
    let tag = ring::hmac::sign(&k, msg);
    hex_lower(tag.as_ref())
}

/// 小写 hex（与 Gulu 的同名函数语义一致；本仓两个类各自持有，不跨类耦合）
pub fn hex_lower(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// 一次签名所需的三个值（头里要发出去的就是它们）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signature {
    pub timestamp: String,
    pub nonce: String,
    pub signature: String,
}

/// 签一个请求（**算法已复刻**；**密钥由调用方给**，而本仓没有密钥）
///
/// # 参数
/// * `secret` —— `SouJu.secret()` 的值（上游 `XC.s(SEC_A)`）⇒ ⛔ **本仓没有**
/// * `method` / `path` —— 见 [`canonical_string`]
/// * `timestamp` / `nonce` —— 由调用方生成（便于**单测用固定值**，不引入时钟依赖）
pub fn sign_request(
    secret: &[u8],
    method: &str,
    path: &str,
    timestamp: &str,
    nonce: &str,
) -> Signature {
    let canon = canonical_string(method, path, timestamp, nonce);
    let signature = hmac_sha256_hex(secret, canon.as_bytes());
    Signature {
        timestamp: timestamp.to_string(),
        nonce: nonce.to_string(),
        signature,
    }
}

/// 生成 nonce（**大写** hex —— DEX 里 `%02x` 之后 `.toUpperCase()`）
///
/// ⚠️ 用 `ring::rand` 而不是 `Random`（`java.util.Random` 是可预测的弱随机；
///    但**上游只要求"每次不同"** ⇒ 这里用真随机更强，且不改变协议兼容性）
pub fn gen_nonce(bytes: usize) -> Result<String, String> {
    let n = bytes.max(1);
    let mut buf = vec![0u8; n];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut buf)
        .map_err(|e| format!("生成 nonce 失败：{e}"))?;
    Ok(hex_lower(&buf).to_uppercase())
}

/// 当前毫秒时间戳（DEX 用 `System.currentTimeMillis()`）
pub fn now_millis() -> String {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis().to_string())
        .unwrap_or_else(|_| "0".to_string())
}

pub struct SouJu {
    client: reqwest::Client,
}

impl SouJu {
    pub const CLASS: &'static str = "SouJu";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build sou_ju http client");
        Self { client }
    }

    /// host（**DEX 里是 `site()`**，本仓用实测值兜底）
    pub fn host_of(_ext: &str) -> String {
        // ★ 订阅里 SouJu **没有 ext** ⇒ 这里不看 ext（也不敢声明"能配"）
        OBSERVED_HOST.to_string()
    }

    /// 五个取数方法共用的**统一真因**
    ///
    /// # 为什么这条文案是交付物的一部分（与 Gulu 同一口径）
    /// ```text
    /// 它必须说清：
    ///   ① 阻塞在**签名密钥**（不是"上游死"、也不是"接口不存在"）
    ///   ② 我**已把算法完整复刻并单测**（待签串/nonce/头名/HMAC）—— 可查
    ///   ③ 缺的只是 `XC.s(SEC_A)` 的真值，而 `SEC_A` 在**多层混淆的解密器**里
    ///   ④ **实测的独立证据**：三个端点都回 `401 Missing request signature`
    ///   ⑤ **不猜密钥**（猜一个去撞会得到"看起来通了"的假象）
    /// ```
    fn signature_gap(&self, seg: &str) -> String {
        format!(
            "SouJu 的 `{seg}` 需要 「HmacSHA256 签名」（头 `{}` / `{}` / `{}`），\
             而「签名密钥未取证」：`SouJu.secret()` = `XC.s(SEC_A)`，\
             `SEC_A` 的真值在混淆后的字符串解密器里（`XC.s`→`Z.A.run`→`e.g`/`c.c`/`B.a` 多层间接），\
             且订阅里 SouJu 「没有 ext」（无法配置密钥）。\
             实测独立证据：`/v1/feed/home`、`/v1/suggest`、`/v1/catalog/` 全部 \
             `401 Missing request signature`（`invalid_request_signature`）。\
             「算法侧我已完整复刻并单测」：待签串 = `method\\npath\\ntimestamp\\nnonce`、\
             毫秒时间戳、大写 hex nonce、响应写回小写 hex 签名。\
             缺的只是密钥 ⇒ 绝不猜一个密钥去撞接口（那会得到「看起来通了」的假象）。",
            SIG_HEADERS[0], SIG_HEADERS[1], SIG_HEADERS[2]
        )
    }
}

impl Default for SouJu {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册（R3-D，2026-10-27）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类的事实（从文件头搬过来，别丢）
// ```text
// csp_SouJu（🔍搜聚）：**父类 Pan**，HmacSHA256 签名，**密钥未取证**
//   · 订阅里**没有 ext**（`{"api":"csp_SouJu","type":3,"searchable":1,"quickSearch":1}`）
//   · host **不在 DEX 常量里**：`site()` → `XC.s(SITE_A)`（字符串解密器）
//     ⇒ 我用**实测值** `https://api.souju.ai` 兜底（该 host 上确实挂着这些接口）
//   · ★ 签名算法**完整读出来了**（266 条指令）：
//       待签串 = `method\npath\ntimestamp\nnonce`（path 切掉 query）
//       时间戳 = 毫秒；nonce = 大写 hex；签名 = HmacSHA256 → 小写 hex
//       三个头 = x-ai-movie-{timestamp,nonce,signature}
//     ⇒ **已用 ring::hmac 复刻并单测**（零新增依赖）
//   · ⛔ **密钥** `XC.s(SEC_A)` 未取证（多层混淆）⇒ 五个取数方法如实 Err
//   · 实测独立证据：三个端点全部 `401 Missing request signature`
// ```
crate::csp::register_site!(SouJu);

#[async_trait]
impl CspSite for SouJu {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        Err(self.signature_gap("home"))
    }

    async fn list(&self, _tid: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(self.signature_gap("list"))
    }

    async fn detail(&self, _id: &str, _ext: &str) -> Result<CspDetail, String> {
        Err(self.signature_gap("detail"))
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(self.signature_gap("search"))
    }

    fn supports_search(&self) -> bool {
        // ★ 订阅里它标了 `"searchable":1`，**但本仓签不出名** ⇒ 取不到数据
        //   ⇒ 声明 true 只会让聚合搜索恒返回空（"看起来支持"）⇒ 如实 false
        false
    }

    async fn play(&self, _flag: &str, _id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        Err(self.signature_gap("play"))
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试（★ 全部**不依赖网络**）
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(SouJu::CLASS, "SouJu");
        assert_eq!(SouJu::new().class(), "SouJu");
    }

    // ── ★★ 待签串的形状（DEX 里逐条读出来的）────────────────────────────
    #[test]
    fn canonical_string_matches_the_dex_shape() {
        // 形状：`method + "\n" + path + "\n" + ts + "\n" + nonce`
        let c = canonical_string("GET", "/v1/feed/home", "1700000000000", "ABCD");
        assert_eq!(c, "GET\n/v1/feed/home\n1700000000000\nABCD");
        // ★ query 必须被切掉（DEX：`indexOf('?')` + `substring`）
        let c2 = canonical_string("GET", "/v1/suggest?q=abc&limit=20", "123", "N");
        assert_eq!(c2, "GET\n/v1/suggest\n123\nN", "★ 待签串里不能有 query");
        // ★ 没有 `?` ⇒ 整串（DEX 的 else 分支）
        let c3 = canonical_string("POST", "/v1/catalog/av_1", "1", "n");
        assert_eq!(c3, "POST\n/v1/catalog/av_1\n1\nn");
        // 分隔符必须都是 `\n`（换行符的唯一性很关键）
        assert_eq!(c.matches('\n').count(), 3, "★ 必须正好三个换行分隔");
        // 方法名保持调用方给的大小写（P2-SOUJU-A1：canon 不改变 method —— 大写由调用方保证）
        let c4 = canonical_string("get", "/x", "1", "n");
        assert!(c4.starts_with("get\n"), "★ canon 不改写 method:{c4}");
    }

    #[test]
    fn canonical_string_handles_paths_with_multiple_question_marks() {
        // 只在**第一个** `?` 处切（`indexOf` 语义）
        let c = canonical_string("GET", "/a?x=1?y=2", "1", "n");
        assert_eq!(c, "GET\n/a\n1\nn");
        // `?` 在最前 ⇒ 空路径（不 panic）
        let c2 = canonical_string("GET", "?x=1", "1", "n");
        assert_eq!(c2, "GET\n\n1\nn");
    }

    // ── ★★ HmacSHA256：用 **RFC 4231 官方向量**钉住（不是自证）──────────
    #[test]
    fn hmac_sha256_matches_rfc4231_test_vectors() {
        /*
         * ★ 用 RFC 4231 的**标准测试向量**（不是"算了再用同样的算法验"）。
         *   Test Case 1: key = 20 × 0x0b, data = "Hi There"
         *   Test Case 2: key = "Jefe", data = "what do ya want for nothing?"
         */
        let tc1_key = vec![0x0bu8; 20];
        assert_eq!(
            hmac_sha256_hex(&tc1_key, b"Hi There"),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        );
        assert_eq!(
            hmac_sha256_hex(b"Jefe", b"what do ya want for nothing?"),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
        // Test Case 3: key = 20 × 0xaa, data = 50 × 0xdd
        assert_eq!(
            hmac_sha256_hex(&vec![0xaau8; 20], &vec![0xddu8; 50]),
            "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
        );
        // ★ 必须是**小写** hex、长度 64（DEX 的 `%02x`）
        let out = hmac_sha256_hex(b"k", b"m");
        assert_eq!(out.len(), 64);
        assert_eq!(out, out.to_lowercase(), "★ 不许大写");
    }

    #[test]
    fn hmac_key_really_participates() {
        // ★ 换密钥 ⇒ 必须换结果（防"看起来算了但没用密钥"）
        let a = hmac_sha256_hex(b"key-a", b"msg");
        let b = hmac_sha256_hex(b"key-b", b"msg");
        assert_ne!(a, b);
        // 换消息也换结果
        assert_ne!(hmac_sha256_hex(b"k", b"m1"), hmac_sha256_hex(b"k", b"m2"));
        // 空密钥 / 空消息也要能算（不 panic）
        assert_eq!(hmac_sha256_hex(b"", b"").len(), 64);
    }

    #[test]
    fn sign_request_binds_all_four_canonical_parts() {
        // ★ 固定 ts/nonce ⇒ 结果**可复现**（这正是抽成纯函数的价值）
        let s1 = sign_request(b"SECRET", "GET", "/v1/feed/home", "1700000000000", "NONCE");
        let s2 = sign_request(b"SECRET", "GET", "/v1/feed/home", "1700000000000", "NONCE");
        assert_eq!(s1, s2, "★ 同样输入必须同样签名");
        assert_eq!(s1.timestamp, "1700000000000");
        assert_eq!(s1.nonce, "NONCE");
        assert_eq!(s1.signature.len(), 64);
        // ★ 四个部分**各自**都要影响签名（否则拼串就会漏）
        let base = sign_request(b"S", "GET", "/p", "1", "N");
        for other in [
            sign_request(b"S2", "GET", "/p", "1", "N"), // 密钥
            sign_request(b"S", "POST", "/p", "1", "N"), // 方法
            sign_request(b"S", "GET", "/q", "1", "N"),  // 路径
            sign_request(b"S", "GET", "/p", "2", "N"),  // 时间戳
            sign_request(b"S", "GET", "/p", "1", "M"),  // nonce
        ] {
            assert_ne!(base.signature, other.signature, "★ 四部分都必须参与");
        }
        // ★ 签名里**不含**密钥原文（防"把密钥写进头"）
        assert!(!base.signature.contains("S"));
        // ★ query 不影响签名（因为它被切掉了）
        let q1 = sign_request(b"S", "GET", "/p?a=1", "1", "N");
        let q2 = sign_request(b"S", "GET", "/p?b=2", "1", "N");
        assert_eq!(q1.signature, q2.signature, "★ query 被切掉 ⇒ 不影响");
    }

    // ── nonce / 时间戳 ──────────────────────────────────────────────────
    #[test]
    fn nonce_is_uppercase_hex_and_varies() {
        let n = gen_nonce(8).expect("应能生成 nonce");
        assert_eq!(n.len(), 16, "8 字节 ⇒ 16 个 hex 字符");
        assert_eq!(n, n.to_uppercase(), "★ DEX 里有 `.toUpperCase()` ⇒ 必须大写");
        assert!(n.chars().all(|c| c.is_ascii_hexdigit()), "必须是 hex：{n}");
        // ★ 两次必须不同（防"写成常量"）
        let n2 = gen_nonce(8).unwrap();
        assert_ne!(n, n2, "★ nonce 每次都不同");
        // 边界：0 字节也要给点东西（不 panic、不返回空）
        assert!(!gen_nonce(0).unwrap().is_empty());
    }

    #[test]
    fn now_millis_is_a_13_digit_plausible_timestamp() {
        let t = now_millis();
        assert!(t.chars().all(|c| c.is_ascii_digit()), "必须是纯数字：{t}");
        let v: u128 = t.parse().expect("应能解析");
        // 2020-01-01 之后、2100 之前（毫秒）
        assert!(v > 1_577_836_800_000, "不该早于 2020：{v}");
        assert!(v < 4_102_444_800_000, "不该晚于 2100：{v}");
    }

    // ── ★★ 头名与常量逐字 ───────────────────────────────────────────────
    #[test]
    fn signature_headers_match_the_dex_literals() {
        assert_eq!(
            SIG_HEADERS,
            &[
                "x-ai-movie-timestamp",
                "x-ai-movie-nonce",
                "x-ai-movie-signature"
            ],
            "★ 三个头名必须逐字（DEX 里三处 HashMap.put）"
        );
        assert_eq!(HMAC_ALGORITHM, "HmacSHA256");
        assert_eq!(CHARSET, "UTF-8");
        let flat = crate::csp::shared::impl_src_only(include_str!("sou_ju.rs"));
        for h in SIG_HEADERS {
            assert!(flat.contains(h), "★ 头名必须出现在实现里：{h}");
        }
        assert!(flat.contains("HmacSHA256"), "★ 算法名逐字");
    }

    #[test]
    fn nonce_hex_len_matches_the_dex_loop() {
        // ★ 长度常量与生成结果必须一致（否则"读出来的 16"与"生成的不符"）
        let n = gen_nonce(NONCE_HEX_LEN / 2).unwrap();
        assert_eq!(n.len(), NONCE_HEX_LEN);
        assert_eq!(NONCE_HEX_LEN % 2, 0, "hex 字符数必须是偶数");
    }

    // ── ★★ 五个取数方法：必须点名真因，不许伪造 ─────────────────────────
    #[tokio::test]
    async fn every_segment_errs_naming_the_signature_gap() {
        let s = SouJu::new();
        for (seg, r) in [
            ("home", s.home("").await.err()),
            ("list", s.list("1", 1, "").await.err()),
            ("detail", s.detail("1", "").await.err()),
            ("search", s.search("x", 1, "").await.err()),
            ("play", s.play("L", "1", "").await.err()),
        ] {
            let e = r.unwrap_or_else(|| panic!("{seg} 必须 Err（密钥未取证）"));
            // ① 点名是**签名**问题
            assert!(e.contains("HmacSHA256") || e.contains("签名"), "{seg}：{e}");
            // ② 点名**实测到的**上游错误（独立证据）
            assert!(e.contains("Missing request signature"), "{seg}：{e}");
            // ③ 点名密钥来源与"未取证"
            assert!(e.contains("secret()"), "{seg}：{e}");
            assert!(e.contains("SEC_A"), "{seg}：{e}");
            // ④ 说明**算法已复刻**（防人以为"啥都没做"）
            assert!(e.contains("已完整复刻并单测"), "{seg}：{e}");
            // ⑤ 声明**不猜密钥**
            assert!(e.contains("绝不猜"), "{seg}：{e}");
            // ★ 不许退化成笼统说法
            assert!(!e.contains("尚未实现"), "{seg} 不许只写「尚未实现」：{e}");
            assert!(!e.contains("TODO"), "{seg} 不许是 TODO：{e}");
        }
    }

    #[test]
    fn supports_search_false_despite_the_subscription_flag() {
        /*
         * ★ 订阅里 SouJu 标了 `"searchable":1`，**但本仓签不出名** ⇒ 拿不到数据。
         *   ⇒ 声明 true 会让聚合搜索把它纳入并**恒返回空**（"看起来支持"）。
         *   ⇒ 这条门禁钉住"**不许照着订阅的旗标声明能力**"。
         */
        assert!(!SouJu::new().supports_search());
    }

    /// ★ 元门禁：不许新增依赖（用 ring 的 hmac / 自写 hex）
    ///
    /// # ★★ 这条第一版是**假绿**（被注入 I5 抓出来）
    /// ```text
    /// 第一版写 `!flat.contains("use hmac::")` ——
    ///   而归一化**去掉所有空白** ⇒ `use hmac::` 变成 `usehmac::`
    ///   ⇒ 那个**带空格的串永远不会出现** ⇒ 断言**恒真** ⇒ **假绿**！
    /// ⇒ 注入 I5（cfg 掉 `use hmac::{Hmac, Mac};`）跑出 `passed=173 failed=0`
    ///   （**注入成功但门禁全绿**）⇒ 我注入脚本的"注入成功但全绿"守卫**当场标出来**
    ///   ⇒ 我据此修门禁。
    /// ★ 同一个坑的**第三次**（czsapp 的 `map(|n| n.start())`、base64 的 `fn b64_encode`）：
    ///   **判据必须按"归一化后的形态"写**（去掉空格再比对）。
    ///   区别：这次是**注入守卫先抓到**，不是我事后想起。
    /// ```
    #[test]
    fn uses_ring_not_new_dependencies() {
        let flat = crate::csp::shared::impl_src_only(include_str!("sou_ju.rs"));
        assert!(
            flat.contains("ring::hmac::HMAC_SHA256"),
            "★ 必须用 ring 的 HMAC_SHA256（零新增依赖）"
        );
        // ⚠️ 归一化**去掉所有空白** ⇒ 判据里也不许带空格
        //    （`use hmac::` 会变成 `usehmac::`；带空格断言**恒真** = 假绿）
        assert!(
            !flat.contains("usehmac::") && !flat.contains("usesha2::"),
            "★ 不许引 `hmac`/`sha2` crate（都不在本仓直接依赖里）"
        );
        assert!(
            !flat.contains("sha2::Sha256") && !flat.contains("Hmac<Sha256>"),
            "★ 不许用 sha2 的组合写法"
        );
        // ★ 对照：确认"带空格的写法"确实匹配不到（证明上面在扫归一化后的真文本）
        assert!(
            !flat.contains("use hmac::"),
            "★ 对照：归一化后带空格的串必然不存在 ⇒ 用它断言就是假绿"
        );
        // 且实现里**确实有** ring::hmac 的调用点（不是只提了常量名）
        assert!(flat.contains("ring::hmac::sign"), "★ 必须真的调用 sign");
        assert!(flat.contains("ring::hmac::Key::new"), "★ 必须真的建 key");
    }

    /// ★ 元门禁：不许出现"猜的密钥"（硬编码假密钥去撞接口）
    #[test]
    fn no_guessed_secret_is_hardcoded() {
        let flat = crate::csp::shared::impl_src_only(include_str!("sou_ju.rs"));
        // 不许出现"看起来像密钥"的长 hex 常量（除了 RFC 4231 向量在**测试段**，已被剥掉）
        assert!(
            !flat.contains("SECRET_KEY") && !flat.contains("hmac_key="),
            "★ 不许硬编码猜测的密钥"
        );
        // 且必须只从参数收密钥（`sign_request(secret: &[u8], …)`）
        assert!(flat.contains("secret:&[u8]"), "★ 密钥必须由调用方传入");
    }

    // ── 真网络：**只记录** 401（把实测结论钉成可复跑断言）────────────────
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_sou_ju --release -- --ignored --nocapture"]
    async fn csp_live_sou_ju_documents_the_missing_signature() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let client = reqwest::Client::builder().user_agent(UA).build().unwrap();
        // ★ 故意**不带**签名头（因为我没有密钥）⇒ 期望上游回 401
        for path in ["/v1/feed/home", "/v1/suggest?q=x", "/v1/catalog/av_1"] {
            let url = format!("{OBSERVED_HOST}{path}");
            match client.get(&url).send().await {
                Ok(resp) => {
                    let st = resp.status();
                    let body = resp.text().await.unwrap_or_default();
                    eprintln!(
                        "[LIVE] {path} → HTTP {st} ⇒ {}",
                        body.chars().take(90).collect::<String>()
                    );
                    assert!(
                        st.as_u16() == 401 || body.contains("signature"),
                        "★ 期望 401 Missing request signature（实测结论）"
                    );
                }
                Err(e) => eprintln!("[LIVE] {path} 请求失败：{e}"),
            }
        }
    }
}