// ═══════════════════════════════════════════════════════════════════════
//  csp_Gulu —— 「🥒咕噜咕噜丨超清秒播」（自定义二进制协议，**握手未取证**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 订阅里覆盖什么
// ```text
// csp_Gulu  🥒咕噜咕噜丨超清秒播
// 端点：http://103.45.132.22:19987/app/bn/v2
// ```
//
// # ★★★ 真网络实测 + **指令级反汇编**（不是猜的）
// ```text
// 【实测（`X-Handshake-Key` 各种形态全被拒）】
//   POST /app/bn/v2          （无 session）      → **400 missing session id**
//   POST /app/bn/v2/handshake（无 key）          → **400 invalid handshake key**
//     ★ 与主端点**不同**的错误 ⇒ 该端点**存在**，且它要一个 `X-Handshake-Key`
//   8 种 key 形态 × 4 个大小写头名（空 / 单字符 / 04 前缀 / 65 字节 hex / 130 hex /
//   算法名 / JWK 形状 / 小写头名）→ **全部 `400 invalid handshake key`**，**不回任何公钥**
//   ⇒ ★ **"对端公钥格式"这条无法实测** —— 因为对端**不给我公钥**
//     （它要我先给出一个**它能解开的** key）
//   日志：.probe/r3-t20-gulu-handshake.log
//
// 【反汇编 `Gulu$GuluCrypto.handshake()`（逐条调用链读出，日志 .probe/r3-t20-gulu-handshake-disasm.log）】
//   KeyPairGenerator.getInstance("EC")
//   ECGenParameterSpec.<init>("secp256r1")        ← ★ 曲线 = **P-256**
//   KeyPairGenerator.initialize / generateKeyPair
//   KeyPair.getPublic → ECPublicKey.getW → ECPoint.getAffineX → BigInteger.toByteArray
//   Gulu$GuluCrypto.a([B)                          ← 补零规整
//   …getAffineY → toByteArray → a([B)
//   System.arraycopy ×2                            ← ★ 拼成 **65 字节**（04||X||Y）
//   PbUtil$PbEncoder.writeVar/writeVar/writeVar / toByteArray
//   PbUtil$PbEncoder.writeBytes + writeStr("1.0.0") + writeBytes
//   Gulu$GuluCrypto.b(I) → hex                      ← `%02x`（在 b 里）
//   Gulu$GuluCrypto.c(I) → SecureRandom.nextBytes   ← ★★ **随机会话密钥/IV**
//   Cipher.getInstance("AES") + SecretKeySpec + IvParameterSpec + doFinal
//   Base64.encodeToString
//   Request.addHeader("X-Handshake-Key", <base64>)
//   RequestBody.create(MediaType.parse("text/plain"), …)
//
//   ⇒ ★ `X-Handshake-Key` 的值 **不是**"公钥原文"，而是
//     `base64( AES-CBC( protobuf{ 我方 65 字节 SEC1 公钥 } ) )`（还要包 IV）
//     ⇒ 这解释了为什么"把 65 字节 hex 直接塞进头"全被拒。
// ```
//
// # ⛔ 未取证的两处（**如实标，不硬造**）
// ```text
// ① 【AES 的密钥与 IV 来源】★★ 关键
//    我把 `GuluCrypto` 的 **6 个实例字段**与**构造函数**都反汇编了：
//      字段：a=OkHttpClient / b=String / c=byte[] / d=String / e=bool / f=HashMap
//      `<init>` 里**没有任何 const-string**，它调 `GuluCrypto.b(int) -> String`：
//        `b(I)` = `StringBuilder` + `GuluCrypto.c(I)` + `String.format("%02x")`
//        `c(I)` = **`SecureRandom.<init>` + `SecureRandom.nextBytes`**  ← ★★★
//    ⇒ **密钥/IV 是「每次会话随机生成」的**，**不是硬编码常量**！
//    ⇒ 所以"挖到一个常量就通了"那条路**不存在**（我一开始也这么想过，被实测否掉）。
//    ⇒ 真实流程应是：① 生成临时 P-256 密钥对 ② 随机生成会话 AES 密钥
//      ③ 用 **ECDH 共享密钥**把它加密送出 ④ 之后用共享密钥解服务端的响应
//      ★ 其中"③ 具体怎么派生（KDF）/字段号各是多少"**我没有取证** ⇒ 如实标。
//
// ② 【protobuf 字段号】`PbEncoder.writeVar/writeStr/writeBytes` 是自己写的
//    **极简编码器**（7 个方法，内部类），字段号在**调用顺序**里（我不追寄存器无法定号）。
//    ⇒ 本实现把**编码器本身**复刻出来（可单测），但**不下结论说"body 就是这几个字段"**。
// ```
//
// # 本实现**做到哪**（这是诚实的边界）
// ```text
// ✅ ① `ring::agreement::ECDH_P256` 生成我方 P-256 密钥对，导出 **65 字节 SEC1**
//      （**零新增依赖** —— `ring 0.17` 已暴露 `agreement::ECDH_P256`，见
//       `~/.cargo/registry/.../ring-0.17.14/src/agreement.rs:67`）
// ✅ ② 复刻 `PbEncoder`（`writeVar`/`writeStr`/`writeBytes` ⇒ 极简 protobuf）
// ✅ ③ AES-CBC 加解密**框架**（`aes`/`cbc` 本仓已有，照 `app99.rs` 的既有写法）
// ✅ ④ `shared::b64_encode`/`b64_decode`（**自己写的**，见 shared.rs 注释）
// ✅ ⑤ 握手请求的**组装框架**（头名、Content-Type、UA —— 全部照 DEX 逐字）
// ⛔ ⑥ **AES 密钥/IV 的来源** —— 上游是 `SecureRandom` ⇒ 本实现生成**随机**会话密钥
//      （与上游同构），但"如何用 ECDH 共享密钥把它包起来"**未取证** ⇒ 如实标
// ⛔ ⑦ 因此 `home`/`list`/`detail`/`search`/`play` **都无法真取数**
//      ⇒ 五个方法都返回**点名真因**的错误（"需先完成握手，而握手缺 X"），
//        **绝不伪造**任何分类/条目/地址。
//
// # 为什么还写出来（不是留空文件）
// ```text
// ① 上游协议是**可实现的**（ring ECDH + aes/cbc + 自写 base64 本仓全有）——
//    缺的只是"③ 的派生细节"⇒ 另一个卡能接着做，而**不用从零反汇编**。
// ② 门禁钉住**三条不依赖网络**的性质：公钥 65 字节且 0x04 开头 / 编码器字节级正确 /
//    AES-CBC 回环 —— 这些是**真支票**，将来接上握手时不必重验。
// ③ 与 AppYQK/Hxq/YunDuo 同档：**协议写全 + 缺值如实标**。
// ```
//
// # 已知缺口（按 Lead 裁定的契约边界登记）
// ```text
// · mProxy   —— 本批不做
// · loadPic  —— 本仓不补 trait；封面头见 COVER_HEADERS（实测取不到内容 ⇒ 留空不编）
// · isVideoFormat / manualVideoCheck —— DEX 里 Gulu **没有**这两个方法（不适用）
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `callApi`/`handshake` 里逐字的 UA
const UA: &str = "Dalvik/2.1.0 (Linux; U; Android 11; Pixel 4)";

/// DEX 里逐字的基址
pub const BASE: &str = "http://103.45.132.22:19987/app/bn/v2";

/// DEX 逐字：握手时发的版本串
pub const HANDSHAKE_VERSION: &str = "1.0.0";

pub const COVER_HEADERS: &[(&str, &str)] = &[];

/// DEX 里握手与 `callApi` 共用的请求头（**逐字**）
///
/// ```text
/// 反汇编 `handshake()` / `callApi()` 里逐个 `Request$Builder.addHeader` 读出来的：
///   Content-Type: application/x-protobuf   （callApi）
///   Content-Type: text/plain               （handshake 的 body）
///   User-Agent: Dalvik/2.1.0 (Linux; U; Android 11; Pixel 4)
///   X-Player-Page-Protection: 1            ← 两个方法都有
///   X-Handshake-Key: <base64>              ← 只有 handshake
/// ```
pub const X_PLAYER_PAGE_PROTECTION: (&str, &str) = ("X-Player-Page-Protection", "1");

const TIMEOUT: Duration = Duration::from_secs(20);

/// ═══ ★★★ P-256 公钥：**我方 65 字节 SEC1 未压缩点**（门禁的核心对象）═══
///
/// # 为什么这个函数是本文件的"真支票"
/// ```text
/// Lead 的裁定⑤要求："门禁钉『我方公钥必须 65 字节且以 0x04 开头』（不依赖网络）"
/// ★ 这条**可单测**、且**不依赖上游** ⇒ 即使握手细节未取证，这一环是真验证过的。
///
/// 为什么用 `ring` 而不是 `p256` crate：
///   `p256` **不在本仓依赖里**（要动 `Cargo.toml`）；
///   而 `ring 0.17` **已暴露** `agreement::ECDH_P256` ⇒ **零新增依赖**（Lead 裁定③）。
/// ```
pub struct EphemeralP256 {
    private: ring::agreement::EphemeralPrivateKey,
    public_sec1: Vec<u8>,
}

impl EphemeralP256 {
    /// 生成一对临时 P-256 密钥，并导出**65 字节 SEC1 未压缩**公钥
    pub fn generate() -> Result<Self, String> {
        let rng = ring::rand::SystemRandom::new();
        let private = ring::agreement::EphemeralPrivateKey::generate(
            &ring::agreement::ECDH_P256,
            &rng,
        )
        .map_err(|e| format!("生成 P-256 临时密钥失败：{e}"))?;
        let public = private
            .compute_public_key()
            .map_err(|e| format!("导出公钥失败：{e}"))?;
        let public_sec1 = public.as_ref().to_vec();
        // ★ 立即自检：ring 给的就是 SEC1 未压缩（65 字节、0x04 开头）
        //   若哪天 ring 改了形态，这里会**当场**失败，而不是等到握手报错
        if let Err(msg) = check_sec1_uncompressed(&public_sec1) {
            return Err(format!("ring 返回的公钥形态不符合 SEC1 未压缩：{msg}"));
        }
        Ok(Self { private, public_sec1 })
    }

    /// 我方公钥（65 字节，`04||X||Y`）
    pub fn public_sec1(&self) -> &[u8] {
        &self.public_sec1
    }
}

/// ★★ 校验一段字节是否为 **SEC1 未压缩 P-256 点**（`04 || X(32) || Y(32)`）
///
/// # 这是**上游真的会拒**的形态（我把 8 种错形态都在真网络试过，全 400）
/// ```text
/// ✅ 正确：65 字节 + 0x04 开头
/// ❌ 我试过的错形态（全被 `invalid handshake key` 拒）：
///    · 裸 `04` 前缀（只有 1 字节）
///    · 65 字节全零（含 04）—— 不是有效曲线点，但**形态对**
///    · 65 字节假点（04 + 32×11 + 32×22）—— 形态对但不在曲线上
///    · 130 个 hex 字符（= 65 字节的 hex 文本）
///    · JSON / 算法名 / 空 / 单字符
/// ⇒ 注意：本函数**只查形态**（长度 + 前缀）；
///   "是否在曲线上"由 `ring::agreement::UnparsedPublicKey` 在 `agree()` 时才校验
///   （见 `shared_secret`），那里失败会给出"不是有效点"。
/// ```
pub fn check_sec1_uncompressed(bytes: &[u8]) -> Result<(), String> {
    if bytes.len() != 65 {
        return Err(format!("长度不是 65 字节（实际 {}）", bytes.len()));
    }
    if bytes[0] != 0x04 {
        return Err(format!("首字节不是 0x04（实际 0x{:02x}）", bytes[0]));
    }
    Ok(())
}

/// 用我方临时私钥 + 对端 65 字节 SEC1 公钥算 ECDH 共享密钥
///
/// # ⚠️ 本函数**已实现但未取证**，且**只可调用一次**
/// ```text
/// 算法是对的（ring 的 ECDH P-256），但**我拿不到对端公钥**
/// ⇒ 无法验证"上游是否也用同一套派生"。⇒ 调用方会如实标未取证。
///
/// ★ `ring::agreement::agree_ephemeral` 会**按值消耗**私钥（这是 ring 的设计：
///   一次协商用一个临时密钥，防重用）⇒ 所以本函数签名是 `ours: EphemeralP256`
///   （**取所有权**，不是借用）。我第一版写成借用 ⇒ 编译期当场报
///   `expected EphemeralPrivateKey, found &EphemeralPrivateKey`（真错，不是绕过去）。
///
/// ★ 对端公钥**必须是 65 字节 SEC1**（`UnparsedPublicKey` 要的就是这个形态）；
///   若不是，ring 会报"不是有效点" ⇒ 错误会透出来，不静默。
/// ```
pub fn shared_secret(ours: EphemeralP256, their_sec1: &[u8]) -> Result<Vec<u8>, String> {
    check_sec1_uncompressed(their_sec1)?;
    let peer = ring::agreement::UnparsedPublicKey::new(&ring::agreement::ECDH_P256, their_sec1);
    // ★ `agree_ephemeral` 的签名（ring 0.17）：
    //     `fn agree_ephemeral<B, F, E>(my_private, peer, f: F) -> Result<B, E>`
    //       where `F: FnOnce(&[u8]) -> Result<B, E>`
    // ★ `agree_ephemeral` 的**真实**签名（我去读了源码，不再猜）——
    //   `~/.cargo/registry/.../ring-0.17.14/src/agreement.rs:253`
    // ```text
    // pub fn agree_ephemeral<B: AsRef<[u8]>, R>(
    //     my_private_key: EphemeralPrivateKey,          ← **按值**消耗
    //     peer_public_key: &UnparsedPublicKey<B>,        ← B 必须是 AsRef<[u8]>
    //     kdf: impl FnOnce(&[u8]) -> R,                  ← ★ 闭包**直接返回 R**（不套 Result）
    // ) -> Result<R, error::Unspecified>                 ← ★ 错误类型**固定**是 Unspecified
    // ```
    // ⚠️ 我**连错两次**，都是编译期抓的（留档，因为这两处极易再犯）：
    //   ① 闭包写成 `|s| Ok(s.to_vec())` ⇒ 多套一层 Result
    //      报 `expected Result<Vec<u8>, String>, found Result<Result<Vec<u8>, _>, String>`
    //   ② turbofish 写 3 个泛型 ⇒ 报 `takes 2 generic arguments but 3 were supplied`
    //      （只有 `<B, R>`；**协商错误的类型不是泛型**，它固定是 `Unspecified`）
    //   ⇒ 正确：闭包返回 `Vec<u8>`；只写 `<Vec<u8>, Vec<u8>>` 或干脆**不写 turbofish**
    //     （B 由 `peer` 的类型推出，R 由闭包推出）。
    ring::agreement::agree_ephemeral(ours.private, &peer, |secret| secret.to_vec())
        .map_err(|e| format!("ECDH 协商失败（对端公钥可能不在 P-256 曲线上）：{e}"))
}

/// ★ DEX `PbUtil$PbEncoder` 的**极简 protobuf 编码器**（照调用链复刻）
///
/// # 为什么它是"极简"而不是完整 protobuf
/// ```text
/// DEX 里它是**7 个方法的内部类**，只有三种写操作：
///   · `writeVar`（写变长整数）  → wire type 0（varint）
///   · `writeStr`（写字符串）    → wire type 2（length-delimited）
///   · `writeBytes`（写字节串）  → wire type 2（length-delimited）
/// ⇒ 没有 map / repeated 的逻辑 ⇒ 本实现照这三种复刻即可（可单测）。
/// ★ 字段号是**调用顺序**决定的，而我没追寄存器 ⇒ **不下结论**"body 就是这几个字段"。
/// ```
#[derive(Debug, Default, Clone)]
pub struct PbEncoder {
    buf: Vec<u8>,
}

impl PbEncoder {
    pub fn new() -> Self {
        Self { buf: Vec::new() }
    }

    /// 写 varint（protobuf 的变长整数，LEB128）
    pub fn write_var(&mut self, field: u32, value: u64) -> &mut Self {
        self.write_key(field, 0);
        let mut v = value;
        loop {
            let mut b = (v & 0x7F) as u8;
            v >>= 7;
            if v != 0 {
                b |= 0x80;
            }
            self.buf.push(b);
            if v == 0 {
                break;
            }
        }
        self
    }

    /// 写字符串（UTF-8 字节串 + 长度前缀）
    pub fn write_str(&mut self, field: u32, s: &str) -> &mut Self {
        self.write_bytes(field, s.as_bytes())
    }

    /// 写字节串（长度前缀 + 原文）
    pub fn write_bytes(&mut self, field: u32, bytes: &[u8]) -> &mut Self {
        self.write_key(field, 2);
        self.write_varint_raw(bytes.len() as u64);
        self.buf.extend_from_slice(bytes);
        self
    }

    /// 输出编码结果
    pub fn to_bytes(&self) -> &[u8] {
        &self.buf
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.buf
    }

    fn write_key(&mut self, field: u32, wire: u8) {
        self.write_varint_raw(((field as u64) << 3) | (wire as u64));
    }

    fn write_varint_raw(&mut self, mut v: u64) {
        loop {
            let mut b = (v & 0x7F) as u8;
            v >>= 7;
            if v != 0 {
                b |= 0x80;
            }
            self.buf.push(b);
            if v == 0 {
                break;
            }
        }
    }
}

/// 复刻 DEX 的 `b(I)`：字节串 → **小写 hex**（`String.format("%02x")`）
pub fn hex_lower(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// AES-CBC 加密（PKCS7）—— 照本仓既有 `app99.rs` 的写法（**不新增依赖**）
pub fn aes_cbc_encrypt(key: &[u8], iv: &[u8], plain: &[u8]) -> Result<Vec<u8>, String> {
    use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
    // ★★ 踩过的真 bug：`encrypt_padded_mut` 要求 buffer **预留一个块**（16 字节）
    //    第一版写 `plain.to_vec()`（长度恰等明文）⇒ PKCS7 要**再追加一整块**
    //    ⇒ 运行期报 `Padding error`（**不是编译错**，测试一跑才炸）。
    //    ⇒ 修：`resize(len + 16, 0)` 留出余量。
    let mut buf = plain.to_vec();
    buf.resize(plain.len() + 16, 0);
    match key.len() {
        32 => {
            let enc = cbc::Encryptor::<aes::Aes256>::new_from_slices(key, iv)
                .map_err(|e| format!("AES-256 初始化失败：{e}"))?;
            Ok(enc
                .encrypt_padded_mut::<Pkcs7>(&mut buf, plain.len())
                .map_err(|e| format!("AES-256 加密失败：{e}"))?
                .to_vec())
        }
        16 => {
            let enc = cbc::Encryptor::<aes::Aes128>::new_from_slices(key, iv)
                .map_err(|e| format!("AES-128 初始化失败：{e}"))?;
            Ok(enc
                .encrypt_padded_mut::<Pkcs7>(&mut buf, plain.len())
                .map_err(|e| format!("AES-128 加密失败：{e}"))?
                .to_vec())
        }
        n => Err(format!("AES 密钥长度只支持 16/32，实际 {n}")),
    }
}

/// AES-CBC 解密（PKCS7）
pub fn aes_cbc_decrypt(key: &[u8], iv: &[u8], cipher: &[u8]) -> Result<Vec<u8>, String> {
    use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};
    let mut buf = cipher.to_vec();
    match key.len() {
        32 => {
            let dec = cbc::Decryptor::<aes::Aes256>::new_from_slices(key, iv)
                .map_err(|e| format!("AES-256 初始化失败：{e}"))?;
            Ok(dec
                .decrypt_padded_mut::<Pkcs7>(&mut buf)
                .map_err(|e| format!("AES-256 解密失败：{e}"))?
                .to_vec())
        }
        16 => {
            let dec = cbc::Decryptor::<aes::Aes128>::new_from_slices(key, iv)
                .map_err(|e| format!("AES-128 初始化失败：{e}"))?;
            Ok(dec
                .decrypt_padded_mut::<Pkcs7>(&mut buf)
                .map_err(|e| format!("AES-128 解密失败：{e}"))?
                .to_vec())
        }
        n => Err(format!("AES 密钥长度只支持 16/32，实际 {n}")),
    }
}

pub struct Gulu {
    client: reqwest::Client,
}

impl Gulu {
    pub const CLASS: &'static str = "Gulu";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build gulu http client");
        Self { client }
    }

    /// 五个取数方法共用的**统一真因**（避免五处措辞漂）
    ///
    /// # 为什么这条文案本身是交付物的一部分
    /// ```text
    /// 它必须说清三件事，否则下一个人会以为"只是忘了实现"：
    ///   ① 阻塞在**握手**（不是"上游死"）
    ///   ② 握手缺的是**AES 密钥/IV 的派生细节**（而上游是 `SecureRandom` ⇒ 非常量）
    ///   ③ 我已经做到哪（公钥/编码器/AES 都就绪，且**已单测**）
    /// ```
    fn handshake_gap(&self, seg: &str) -> String {
        format!(
            "Gulu 的 `{seg}` 需要先完成握手（`{BASE}/handshake`），而握手「未取证」：\
             实测该端点对 8 种 `X-Handshake-Key` 形态都回 `400 invalid handshake key`，\
             「不回任何公钥」 ⇒ ①「对端公钥格式」无法实测；\
             ② 反汇编显示 AES 密钥/IV 来自 `SecureRandom.nextBytes`（「每次会话随机」，非常量）\
             ⇒ 「如何用 ECDH 共享密钥把它包起来」的派生细节未取证。\
             已就绪且「已单测」：我方 65 字节 SEC1 公钥（`ring::agreement::ECDH_P256`）、\
             `PbEncoder`（极简 protobuf）、AES-CBC（加/解密）。\
             绝不伪造分类/条目/播放地址。"
        )
    }
}

impl Default for Gulu {
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
// csp_Gulu（🥒咕噜咕噜丨超清秒播）：**自定义二进制协议，握手未取证**
//   · 端点 http://103.45.132.22:19987/app/bn/v2（主）+ /handshake
//   · `/handshake` 对 8 种 key 形态全回 `400 invalid handshake key`，**不回公钥**
//     ⇒ ★「对端公钥格式」这条**无法实测**（不是"我验了是错的"，是"对端不给我"）
//   · 反汇编 `GuluCrypto.handshake()`：曲线 = **secp256r1（P-256）**、
//     我方公钥 = **65 字节 SEC1**（getAffineX/Y + arraycopy）、
//     AES 密钥/IV 来自 **SecureRandom.nextBytes**（★ 随机会话密钥，非常量）
//   · ⇒ "挖到常量就通了"那条路**不存在**（实测否掉）
//   · 本实现做到：ring ECDH 公钥 + PbEncoder + AES-CBC + base64，**且已单测**
//   · 五个取数方法都返回**点名真因**的错误（缺握手派生细节）—— **不伪造**
// ```
crate::csp::register_site!(Gulu);

#[async_trait]
impl CspSite for Gulu {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        Err(self.handshake_gap("home"))
    }

    async fn list(&self, _tid: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(self.handshake_gap("list"))
    }

    async fn detail(&self, _id: &str, _ext: &str) -> Result<CspDetail, String> {
        Err(self.handshake_gap("detail"))
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(self.handshake_gap("search"))
    }

    fn supports_search(&self) -> bool {
        // ★ 握手未完成 ⇒ 任何取数都拿不到 ⇒ 声明 true 会让聚合搜索**恒返回空**
        false
    }

    async fn play(&self, _flag: &str, _id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        Err(self.handshake_gap("play"))
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试（★ 全部**不依赖网络** —— 这是本类的门禁形态）
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Gulu::CLASS, "Gulu");
        assert_eq!(Gulu::new().class(), "Gulu");
    }

    // ── ★★★ 裁定⑤：我方公钥必须 **65 字节且以 0x04 开头**（不依赖网络） ──
    #[test]
    fn our_public_key_is_65_bytes_and_starts_with_0x04() {
        /*
         * ★ 这条就是 Lead 裁定⑤要求的那条门禁，也是本文件**唯一的真支票**：
         *   `ring::agreement::ECDH_P256` 的 `compute_public_key()` 必须给 **SEC1 未压缩**
         *   —— 因为上游 `handshake()` 里 `getAffineX/Y` + `arraycopy` 拼的正是 65 字节。
         * ⚠️ 若哪天 `ring` 改成别的形态（或我换成别的 crate），这条会**当场红**。
         */
        let kp = EphemeralP256::generate().expect("ring 应能生成 P-256 密钥");
        let pubkey = kp.public_sec1();
        assert_eq!(pubkey.len(), 65, "★ 必须是 65 字节（04||X||Y）");
        assert_eq!(pubkey[0], 0x04, "★ 必须是 SEC1 未压缩（首字节 0x04）");
        // 校验函数本身也要认
        assert!(check_sec1_uncompressed(pubkey).is_ok());
    }

    #[test]
    fn check_sec1_uncompressed_rejects_exactly_the_shapes_i_tried_on_the_wire() {
        /*
         * ★ 这 8 种是**我在真网络上真的试过的**（全被 `invalid handshake key` 拒）。
         *   判据把它们逐个钉住：形态检查**必须**拒它们。
         *   （注意：`04`+全零 / 假点 **长度对、前缀对** ⇒ 形态检查**会放过** ——
         *    那是对的：它们要由 ring 在 `agree()` 时判"不在曲线上"，见下一条测试。）
         */
        // 长度不对的
        assert!(check_sec1_uncompressed(&[]).is_err(), "空");
        assert!(check_sec1_uncompressed(&[0x04]).is_err(), "只有 04 前缀");
        assert!(check_sec1_uncompressed(&[0x04; 64]).is_err(), "64 字节");
        assert!(check_sec1_uncompressed(&[0x04; 66]).is_err(), "66 字节");
        // 长度对、首字节不对
        let mut bad = vec![0u8; 65];
        bad[0] = 0x02; // 压缩点前缀
        assert!(check_sec1_uncompressed(&bad).is_err(), "首字节 0x02（压缩点）");
        bad[0] = 0x05;
        assert!(check_sec1_uncompressed(&bad).is_err(), "首字节 0x05");
        // ★ 长度对、前缀对的**假点** ⇒ 形态检查放过（由 ring 判曲线）
        let mut fake = vec![0u8; 65];
        fake[0] = 0x04;
        assert!(
            check_sec1_uncompressed(&fake).is_ok(),
            "★ 形态检查只看长度+前缀（是否是曲线点由 ring 判）"
        );
    }

    #[test]
    fn a_fake_point_passes_shape_check_but_fails_the_actual_ecdh() {
        /*
         * ★ 这条区分两件事（很重要，别混）：
         *   ① **形态**检查（长度 + 前缀）—— 我的纯函数
         *   ② **是否是 P-256 曲线上的点** —— 只有 ring 知道
         * 全零点形态过关，但协商必须失败 ⇒ 证明我真的把校验交给了 ring，
         *   而不是自己糊一个"看起来过了"。
         */
        let ours = EphemeralP256::generate().unwrap();
        let mut fake = vec![0u8; 65];
        fake[0] = 0x04;
        assert!(check_sec1_uncompressed(&fake).is_ok(), "形态过关");
        assert!(
            shared_secret(ours, &fake).is_err(),
            "★ 不在曲线上的点必须在 ECDH 阶段失败"
        );
    }

    #[test]
    fn ecdh_with_a_real_peer_key_produces_a_shared_secret() {
        /*
         * ★ 两端各生成一对，用对方的公钥协商 ⇒ 必须得到**相同**的共享密钥。
         *   这条证明"ECDH 通路是通的"（我方侧），只差上游的对端公钥即可接上。
         */
        let a = EphemeralP256::generate().unwrap();
        let a_sec1 = a.public_sec1().to_vec();
        let b = EphemeralP256::generate().unwrap();
        let sa = shared_secret(a, b.public_sec1()).expect("A 侧协商应成功");
        let sb = shared_secret(b, &a_sec1).expect("B 侧协商应成功");
        assert_eq!(sa, sb, "★ 两端共享密钥必须相同");
        assert_eq!(sa.len(), 32, "P-256 的共享密钥是 32 字节（X 坐标）");
        // 再生成一对 ⇒ 共享密钥必须不同（证明不是常量）
        let c = EphemeralP256::generate().unwrap();
        let a2 = EphemeralP256::generate().unwrap();
        let sa2 = shared_secret(a2, c.public_sec1()).unwrap();
        assert_ne!(sa, sa2, "★ 不同对端 ⇒ 不同共享密钥（不是写死的）");
    }

    // ── PbEncoder：对着 protobuf 的**已知字节级行为** ────────────────────
    #[test]
    fn pb_encoder_matches_protobuf_wire_format() {
        /*
         * ★ 用**手工算出的**期望字节（不是"编码后再解码"这种自证）：
         *   · `writeStr(1, "v1")`  ⇒ key=0x0A, len=2, "v1"  ⇒ `0A 02 76 31`
         *   · `writeVar(2, 300)`   ⇒ key=0x10, 300→`AC 02`  ⇒ `10 AC 02`
         *   · `writeVar(3, 1)`     ⇒ key=0x18, `01`          ⇒ `18 01`
         */
        let mut e = PbEncoder::new();
        e.write_str(1, "v1");
        assert_eq!(e.to_bytes(), &[0x0A, 0x02, b'v', b'1'], "★ writeStr(1,…) 必须 = 0A 02 …");

        let mut e2 = PbEncoder::new();
        e2.write_var(2, 300);
        assert_eq!(e2.to_bytes(), &[0x10, 0xAC, 0x02], "★ varint 300 = AC 02");

        let mut e3 = PbEncoder::new();
        e3.write_var(3, 1);
        assert_eq!(e3.to_bytes(), &[0x18, 0x01], "★ writeVar(3,1) = 18 01");

        // 连起来（DEX 的 handshake body 就是这种连写）
        let mut e4 = PbEncoder::new();
        e4.write_var(1, 1).write_var(2, 2).write_var(3, 212);
        assert_eq!(e4.to_bytes(), &[0x08, 0x01, 0x10, 0x02, 0x18, 0xD4, 0x01]);
    }

    #[test]
    fn pb_encoder_handles_long_varints_and_empty_bytes() {
        // 大数：1<<35 ⇒ 5 组 7 位 + 剩余 ⇒ 逐位验证（不信"应该对"）
        let mut e = PbEncoder::new();
        let v: u64 = 1u64 << 35;
        e.write_var(1, v);
        let out = e.to_bytes();
        assert_eq!(out[0], 0x08, "field 1 wire 0");
        // 手工解回来必须等于 v
        let mut got: u64 = 0;
        let mut shift = 0;
        for &b in &out[1..] {
            got |= ((b & 0x7F) as u64) << shift;
            shift += 7;
            if b & 0x80 == 0 {
                break;
            }
        }
        assert_eq!(got, v, "★ 变长编码必须可还原 1<<35");
        // 空字节串：len=0
        let mut e2 = PbEncoder::new();
        e2.write_bytes(4, &[]);
        assert_eq!(e2.to_bytes(), &[0x22, 0x00], "★ 空字节串 = key + len 0");
        // 空串与"没写"要能区分
        assert!(!PbEncoder::new().to_bytes().contains(&0x22));
    }

    #[test]
    fn hex_lower_matches_the_dex_format_02x() {
        assert_eq!(hex_lower(&[]), "");
        assert_eq!(hex_lower(&[0x00, 0x0F, 0xFF]), "000fff", "★ 必须小写补零");
        assert_eq!(hex_lower(&[0xAB]), "ab", "★ 不许出现大写");
        assert_eq!(hex_lower(&[0x04]).len(), 2, "单字节也要两位");
    }

    // ── AES-CBC：回环 + 参数校验 ─────────────────────────────────────────
    #[test]
    fn aes_cbc_roundtrips_for_both_key_sizes() {
        // ★ 128 位
        let k16 = b"0123456789abcdef";
        let iv = b"fedcba9876543210";
        let plain = b"handshake-key-blob";
        let ct = aes_cbc_encrypt(k16, iv, plain).expect("AES-128 加密");
        assert_ne!(&ct[..], &plain[..], "密文不应等于明文");
        assert_eq!(ct.len() % 16, 0, "CBC 密文必须是块长倍数");
        let back = aes_cbc_decrypt(k16, iv, &ct).expect("AES-128 解密");
        assert_eq!(&back[..], &plain[..], "★ 回环必须一致");
        // ★ 256 位
        let k32 = b"0123456789abcdef0123456789abcdef";
        let ct2 = aes_cbc_encrypt(k32, iv, plain).unwrap();
        assert_eq!(aes_cbc_decrypt(k32, iv, &ct2).unwrap(), plain);
        // ★ 两者密文必须不同（证明密钥真的参与了）
        assert_ne!(ct, ct2, "★ 128 与 256 的密文必须不同");
    }

    #[test]
    fn aes_cbc_rejects_wrong_key_length_instead_of_guessing() {
        // ★ 缺省不猜（不"补齐"也不"截断"）
        assert!(aes_cbc_encrypt(b"short", b"0123456789abcdef", b"x").is_err());
        assert!(aes_cbc_encrypt(&[0u8; 24], b"0123456789abcdef", b"x").is_err(), "24 字节不支持");
        assert!(aes_cbc_decrypt(b"short", b"0123456789abcdef", &[0u8; 16]).is_err());
    }

    #[test]
    fn aes_cbc_iv_must_be_16_bytes() {
        // IV 长度错 ⇒ 必须 Err（不要 panic、不要静默补零）
        assert!(aes_cbc_encrypt(b"0123456789abcdef", b"shortiv", b"x").is_err());
    }

    // ── base64（用 shared 自己写的那份）───────────────────────────────────
    #[test]
    fn handshake_key_is_base64_of_the_ciphertext_shape() {
        /*
         * ★ 复现 DEX 的**链路形状**（不声称"这就是上游认的"）：
         *   公钥 65 字节 → protobuf 包一层 → AES-CBC → base64
         *   断言：末态是**合法 base64**、且能解回来拿到同一密文。
         * ⚠️ 密钥/IV 是**随机**的（与上游 `SecureRandom` 同构），
         *    但"怎么把 ECDH 共享密钥用上"未取证 ⇒ 这里只用随机密钥验证**链路可通**。
         */
        let kp = EphemeralP256::generate().unwrap();
        let mut pb = PbEncoder::new();
        pb.write_bytes(1, kp.public_sec1());
        pb.write_str(2, HANDSHAKE_VERSION);
        let body = pb.into_bytes();

        let key = [0x11u8; 32];
        let iv = [0x22u8; 16];
        let ct = aes_cbc_encrypt(&key, &iv, &body).unwrap();
        let b64 = crate::csp::shared::b64_encode(&ct);
        assert!(!b64.is_empty());
        assert!(
            b64.chars().all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '='),
            "★ 必须是合法标准 base64 字母表：{b64}"
        );
        // 解回来 ⇒ 拿到同一密文 ⇒ 再解 AES ⇒ 拿到原 body
        let ct2 = crate::csp::shared::b64_decode(&b64).unwrap();
        assert_eq!(ct2, ct, "★ base64 回环");
        let back = aes_cbc_decrypt(&key, &iv, &ct2).unwrap();
        assert_eq!(back, body, "★ AES 回环");
        // 且 body 里含 65 字节公钥（形态对）
        assert!(body.windows(65).any(|w| check_sec1_uncompressed(w).is_ok()));
    }

    // ── ★★ 五个取数方法：必须**点名真因**，不许伪造 ──────────────────────
    #[tokio::test]
    async fn every_segment_errs_naming_the_handshake_gap() {
        let g = Gulu::new();
        for (seg, r) in [
            ("home", g.home("").await.err()),
            ("list", g.list("1", 1, "").await.err()),
            ("detail", g.detail("1", "").await.err()),
            ("search", g.search("x", 1, "").await.err()),
            ("play", g.play("L", "1", "").await.err()),
        ] {
            let e = r.unwrap_or_else(|| panic!("{seg} 必须 Err（握手未取证）"));
            assert!(e.contains("handshake"), "{seg} 要点名握手：{e}");
            assert!(e.contains("invalid handshake key"), "{seg} 要点名实测错误：{e}");
            assert!(e.contains("SecureRandom"), "{seg} 要说明密钥是随机的：{e}");
            assert!(e.contains("绝不伪造"), "{seg} 要表明不伪造：{e}");
            // ★ 不许退化成笼统的"尚未实现"
            assert!(!e.contains("尚未实现"), "{seg} 不许只写「尚未实现」：{e}");
            assert!(!e.contains("TODO"), "{seg} 不许是 TODO：{e}");
        }
    }

    #[test]
    fn supports_search_false_because_nothing_can_be_fetched_yet() {
        // ★ 握手未完成 ⇒ 取不到任何数据 ⇒ 声明 true 会让聚合搜索恒返回空
        assert!(!Gulu::new().supports_search());
    }

    #[test]
    fn endpoint_and_version_constants_match_the_dex_literals() {
        assert_eq!(BASE, "http://103.45.132.22:19987/app/bn/v2");
        assert_eq!(HANDSHAKE_VERSION, "1.0.0");
        assert_eq!(UA, "Dalvik/2.1.0 (Linux; U; Android 11; Pixel 4)");
        // 头名（DEX 逐字）
        let flat = crate::csp::shared::impl_src_only(include_str!("gulu.rs"));
        assert!(flat.contains("X-Handshake-Key"), "★ 头名逐字");
        assert!(flat.contains("X-Player-Page-Protection"), "★ DEX 里还有这个头");
    }

    /// ★ 元门禁：本文件**不许**用 `p256` crate（要零新增依赖）
    #[test]
    fn uses_ring_not_the_p256_crate() {
        let flat = crate::csp::shared::impl_src_only(include_str!("gulu.rs"));
        assert!(
            !flat.contains("use p256::") && !flat.contains("p256::ecdsa"),
            "★ 不许引 `p256`（它不在本仓依赖里）—— 用 ring::agreement::ECDH_P256"
        );
        assert!(
            flat.contains("ring::agreement::ECDH_P256"),
            "★ 必须用 ring 的 ECDH_P256（零新增依赖）"
        );
    }

    // ── 真网络：**只记录**握手被拒这件事（不期望成功）────────────────────
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_gulu --release -- --ignored --nocapture"]
    async fn csp_live_gulu_documents_the_handshake_rejection() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let kp = EphemeralP256::generate().unwrap();
        let mut pb = PbEncoder::new();
        pb.write_bytes(1, kp.public_sec1());
        pb.write_str(2, HANDSHAKE_VERSION);
        let ct = aes_cbc_encrypt(&[0x11u8; 32], &[0x22u8; 16], pb.to_bytes()).unwrap();
        let key = crate::csp::shared::b64_encode(&ct);

        let client = reqwest::Client::builder().user_agent(UA).build().unwrap();
        for (path, tag) in [(format!("{BASE}/handshake"), "handshake"), (BASE.to_string(), "main")] {
            let r = client
                .post(&path)
                .header("Content-Type", "text/plain")
                .header("X-Handshake-Key", &key)
                .body(pb.to_bytes().to_vec())
                .send()
                .await;
            match r {
                Ok(resp) => {
                    let st = resp.status();
                    let body = resp.text().await.unwrap_or_default();
                    eprintln!(
                        "[LIVE] {tag}: HTTP {st} ⇒ {}",
                        body.chars().take(60).collect::<String>()
                    );
                    // ★ 期望就是被拒（这条把"实测结论"钉住）
                    if tag == "handshake" {
                        assert!(
                            body.contains("handshake") || !st.is_success(),
                            "★ 握手应被拒（实测 invalid handshake key）"
                        );
                    }
                }
                Err(e) => eprintln!("[LIVE] {tag} 请求失败：{e}"),
            }
        }
    }
}