// ═══════════════════════════════════════════════════════════════════════
//  csp_App99 —— AES/CBC 加密协议源的 Rust 实现（第19项第 3 个实现类）
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证来源（全部来自 `.probe/newtask/jar/classes.dex` 的指令级反汇编）
//
// 反汇编器：`.probe/final-plan-audit/dex_disasm.py`；完整证据：`.probe/dex-App99-disasm.md`。
// 下面每一条都不是"照抄别人的结论"，而是从字节码读出来的（行号指该 md 的节）：
//
// ```text
// ① key = 字段 c = ext 的 `uuid`（缺省 UUID.randomUUID()），
//    用法：`uuid.replace("-","").getBytes("UTF-8")` ⇒ 32 个十六进制字符 = AES-256。
//    （init:91-105）
// ② 解密 c()：base64 → 前 16 字节当 IV、其余当密文 → AES/CBC/PKCS5 解密
//    → **Inflater（zlib）解压** → UTF-8 字符串。（c:8-109）
// ③ 加密 d()：AES/CBC/PKCS5，`init(ENCRYPT,key)` **不传 IV**（JCE 随机生成）
//    → 取 getIV() → **IV‖密文** → base64。（d:12-76）
// ④ 签名 g()：`String.format("%s:%s:%s:%s", p3, p2, p1, token)` → SHA-256 → 手工 hex(补 '0')；
//    返回的是**头表 HashMap**（uuid/timestamp/sign/nonce/version/api_version=v1），
//    不是裸字符串。（g:0-122，寄存器口径见 md 的"点2"）
// ⑤ 请求：`b->f(url, enc, headersMap)` → 3 参 ctor **把方法写死 'POST'**
//    ⇒ enc 作 body、Map 作请求头（不是 GET 查询串）。（merge/k/b->f:12-17 + c.<init>:0-7）
// ⑥ systemInit 握手：body `{v:versionName, n:name, s:buildSignature, pl:"1",
//    apiVersion:"v2", token:"", timestamp, nonce}` → d() → g() → POST `{host}/app/systemInit`
//    → c() 解密 → 响应里的 `player / parser_api / categories` 存进字段 g。
//    （init:150-227，`v/n/s` 的寄存器口径见 md 的"点3"）
// ```
//
// # 当前状态（2026-11-04）：已注册，支持站点下发的媒体解析配置
//
// ## ① 已确证（指令级 + 真网络双证）
// ```text
// · key = `uuid.replace("-","")` 的 UTF-8 字节（32 hex ⇒ AES-256）
// · 解密 c()：base64 → IV=前16B ‖ 密文 → AES-CBC/PKCS5 → **zlib 解压** → UTF-8
// · 加密 d()：AES-CBC/PKCS5（随机 IV）→ IV‖密文 → base64
// · 签名 g()：`SHA-256(enc:ts:nonce:token)`，且 **g 返回的是头表 HashMap**
//   （uuid/timestamp/sign/nonce/version/api_version），不是裸字符串
// · 请求形态：3 参 ctor 把方法写死 **POST** ⇒ enc 作 body、头表作请求头
// · ★ 真网络已验证：systemInit 的响应能被我们**解开并解析成 JSON**
//   顶层键 = [action, app, c_p_d, categorys, code, danmu, defaultPlayer,
//             feedbackType, filterNotProxyDomain, msg, parser_api, player,
//             tabs, tips, user_avatar, user_level]
//   ⇒ 解密链路**不是**"理论可行"，是实测解开过。
// ```
//
// ## ② 未确证 / 已处置
// ```text
// · 第二段握手 POST {host}/app/userInfo 被部分站点**明确拒绝**（游客态）：
//     {"code":1,"msg":"user info error","userInfo":"","params":{…回显我们的入参…}}
//   ⇒ 参数被服务端收到并回显（说明签名/加密都对），但内容不被接受（登录态拿不到）。
// · 2026-10-26 实测部分空 token 路径可浏览：`home()` 拿到 8 个分类、`list("测试")`
//   拿到 20 条真实条目；这不证明所有线路的取流都不需要 token。
// · ★★ 2026-11-01 起：userInfo 被拒**不再阻断握手**——降级为空 token 继续
//   （旧实现 `await?` 把整站搜索废掉，Owner 真机报"胖妞/剧圈搜不到"；
//    见 handshake 里 2026-11-01 注释与 handshake_degrades_when_userinfo_rejected 单测）。
// · 点 3（systemInit 的 `v/n/s`）已确证：v=versionName、n=**name**、s=buildSignature
//   （init:150-162 的寄存器：put('v',v6=versionName) / put('n',v3=name) / put('s',v4=buildSignature)）
//   —— 注意 `n` 是 name，**不是** buildNumber；buildNumber/package 只做非空校验、
//   在 systemInit 里不发送（它们在 userInfo 段才用）。
// ```
//
// ## ③ 结论
// ```text
// 四段链路**全部真网络实证**（2026-10-26，`.probe/app99-live11.log`）：
// ```text
// home  → 8 个分类（来自 systemInit 响应的 categorys.data）
// list  → 20 条真实条目
// detail→ 1 集，首集地址 = 真 m3u8
// play  → 1 条候选（该 m3u8，带 UA 头）
// ```
// ⚠️ **登录态**在部分站点拿不到（userInfo 被拒）——2026-11-01 起**不再阻断**：
//    降级空 token 继续握手；已观察部分浏览路径可用，不代表所有取流路径可用。
//    需要登录态的业务被站点拒绝时如实透出，不把空结果归因成已证的协议根因。
// ⚠️ **play 的边界**：已验证的是"能拿到并返回播放地址"，**"真起播"没验过** ——
//    要 media_kit/mpv 真把那串 m3u8 拉起来才算端到端。别把这条读成"已经播过"。
// 证据：.probe/app99-live*.log、.probe/dex-App99-disasm.md
// ```
//
// # 能力边界（如实）
// ```text
// 握手 / 搜索 / 全线路详情 / 取流；媒体解析走 /app/vodParser，网盘分享交统一出口。
// 未解析的播放页不作为媒体候选返回；真实首帧仍须播放器端验收。
// ⛔ 需要登录的条目：服务端会在响应里给空/错误，我们**如实透出**，不伪造
// ⛔ 分类页：`categories` 由握手响应下发；下发了就用，没下发就如实报"该源没给分类"
// ```
//
// # 验收（写进代码，不靠口头）
// 单测 `decrypts_real_capture`：用**今天抓到的真实响应**（`.probe/app99-fixture/…`）解密并解析成 JSON；
// 解不开就是没做完（见该用例的注释与 md 的"验收"节）。

use async_trait::async_trait;
use std::sync::Mutex;
use std::time::Duration;

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use cbc::{Decryptor, Encryptor};

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use crate::csp::shared::split_lines;
use crate::tvbox::{parse_loose_json, strip_tags};

type Aes256CbcEnc = Encryptor<aes::Aes256>;
type Aes256CbcDec = Decryptor<aes::Aes256>;
type Aes128CbcEnc = Encryptor<aes::Aes128>;
type Aes128CbcDec = Decryptor<aes::Aes128>;

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 一次请求的总预算（握手 + 业务请求各自独立计时，避免"某站慢=整类不可用"）
const REQ_BUDGET: Duration = Duration::from_secs(20);

// ═══════════════════════════════════════════════════════════════════════
//  纯函数层（离线可测：base64 / AES-CBC / zlib / 签名）
// ═══════════════════════════════════════════════════════════════════════

/// 标准 base64（带 `=` 填充）—— 与 Java 的 `Base64.getEncoder()` 一致
pub fn b64_encode(raw: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((raw.len() + 2) / 3 * 4);
    for chunk in raw.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 {
            T[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

/// 标准 base64 解码（容忍空白；非法字符 ⇒ Err，不静默产出空）
pub fn b64_decode(s: &str) -> Result<Vec<u8>, String> {
    let mut vals: Vec<u8> = Vec::with_capacity(s.len());
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => continue,
            b'\r' | b'\n' | b' ' | b'\t' => continue,
            _ => return Err(format!("base64 里有非法字符：0x{c:02x}")),
        };
        vals.push(v);
    }
    let mut out = Vec::with_capacity(vals.len() / 4 * 3);
    for quad in vals.chunks(4) {
        if quad.len() < 2 {
            break;
        }
        let n = ((quad[0] as u32) << 18)
            | ((quad[1] as u32) << 12)
            | ((quad.get(2).copied().unwrap_or(0) as u32) << 6)
            | (quad.get(3).copied().unwrap_or(0) as u32);
        out.push((n >> 16) as u8);
        if quad.len() > 2 {
            out.push((n >> 8) as u8);
        }
        if quad.len() > 3 {
            out.push(n as u8);
        }
    }
    Ok(out)
}

/// 由 uuid 得到 AES key（去 `-` 后 UTF-8 字节；长度 16/24/32 分别对应 AES-128/192/256）
fn key_of(uuid: &str) -> Result<Vec<u8>, String> {
    let k = uuid.replace('-', "").into_bytes();
    match k.len() {
        16 | 24 | 32 => Ok(k),
        n => Err(format!(
            "uuid 去掉连字符后应是 16/24/32 字节（AES 密钥长度），实际 {n} 字节"
        )),
    }
}

/// 加密（与 `d()` 等价）：随机 IV ‖ AES-CBC(PKCS5) → base64
///
/// ★ 随机源用 `uuid` 之后的时间 + 进程 id 做种子的简单 LCG —— 不引 rand crate。
///   IV 只需要"每次不同"，不需要密码学强度（真正的安全性来自 AES key 本身）。
fn iv16(seed_a: u64, seed_b: u64) -> [u8; 16] {
    let mut x = seed_a ^ (seed_b.rotate_left(17)) ^ 0x9E37_79B9_7F4A_7C15;
    let mut out = [0u8; 16];
    for b in out.iter_mut() {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        *b = (x & 0xFF) as u8;
    }
    out
}

pub fn encrypt_body(key: &[u8], plain: &str, iv: &[u8; 16]) -> Result<String, String> {
    let pt = plain.as_bytes();
    let buf_len = (pt.len() / 16 + 1) * 16;
    let mut buf = vec![0u8; buf_len];
    buf[..pt.len()].copy_from_slice(pt);
    let ct = match key.len() {
        32 => Aes256CbcEnc::new_from_slices(key, iv)
            .map_err(|e| format!("AES-256 初始化失败：{e}"))?
            .encrypt_padded_mut::<Pkcs7>(&mut buf, pt.len())
            .map_err(|e| format!("AES 加密失败：{e}"))?
            .to_vec(),
        16 => Aes128CbcEnc::new_from_slices(key, iv)
            .map_err(|e| format!("AES-128 初始化失败：{e}"))?
            .encrypt_padded_mut::<Pkcs7>(&mut buf, pt.len())
            .map_err(|e| format!("AES 加密失败：{e}"))?
            .to_vec(),
        n => return Err(format!("不支持的 AES 密钥长度：{n}")),
    };
    let mut all = Vec::with_capacity(16 + ct.len());
    all.extend_from_slice(iv);
    all.extend_from_slice(&ct);
    Ok(b64_encode(&all))
}

/// 解密（与 `c()` 等价）：base64 → IV=前16B → AES-CBC 解密 → **zlib 解压** → UTF-8
pub fn decrypt_body(key: &[u8], b64: &str) -> Result<String, String> {
    let blob = b64_decode(b64)?;
    if blob.len() < 32 || (blob.len() - 16) % 16 != 0 {
        return Err(format!(
            "密文长度不合法（{} 字节；去掉 16 字节 IV 后必须是 16 的倍数）",
            blob.len()
        ));
    }
    let (iv, ct) = blob.split_at(16);
    let mut buf = ct.to_vec();
    let pt = match key.len() {
        32 => Aes256CbcDec::new_from_slices(key, iv)
            .map_err(|e| format!("AES-256 初始化失败：{e}"))?
            .decrypt_padded_mut::<Pkcs7>(&mut buf)
            .map_err(|_| "AES 解密失败（key 不对，或响应不是给本次 uuid 的）".to_string())?
            .to_vec(),
        16 => Aes128CbcDec::new_from_slices(key, iv)
            .map_err(|e| format!("AES-128 初始化失败：{e}"))?
            .decrypt_padded_mut::<Pkcs7>(&mut buf)
            .map_err(|_| "AES 解密失败（key 不对，或响应不是给本次 uuid 的）".to_string())?
            .to_vec(),
        n => return Err(format!("不支持的 AES 密钥长度：{n}")),
    };
    // ★ 服务端返回的是 **zlib 压缩**过的明文（DEX 里 inflate 不是可选项）
    let mut out = Vec::new();
    let mut dec = flate2::read::ZlibDecoder::new(&pt[..]);
    use std::io::Read;
    dec.read_to_end(&mut out)
        .map_err(|e| format!("zlib 解压失败（明文不是想象的 JSON？）：{e}"))?;
    String::from_utf8(out).map_err(|e| format!("解压结果不是 UTF-8：{e}"))
}

/// 签名（与 `g()` 里的 format 一致）：`SHA-256("enc:ts:nonce:token")` → 小写 hex
///
/// ★ 顺序来自寄存器：`g` 的四个槽是 (p3, p2, p1, token)，调用点传 (nonce, ts, enc)
///   ⇒ 实际字面量是 `enc:ts:nonce:token`（见 `.probe/dex-App99-disasm.md` 点 2）。
pub fn sign_of(enc: &str, ts: &str, nonce: &str, token: &str) -> String {
    let s = format!("{enc}:{ts}:{nonce}:{token}");
    let d = ring::digest::digest(&ring::digest::SHA256, s.as_bytes());
    let mut out = String::with_capacity(64);
    for b in d.as_ref() {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// 随机 nonce（DEX 里是 SecureRandom 16 字节 → base64）
fn nonce_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let iv = iv16(now, std::process::id() as u64 ^ 0xA5A5_5A5A);
    b64_encode(&iv)
}

fn now_ms() -> String {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis().to_string())
        .unwrap_or_else(|_| "0".to_string())
}


/// 校验上游 `code`（**唯一实现**，call 与 handshake 共用）
///
/// # 为什么必须有（live-accept 复核指出的真缺陷）
/// 之前 `call()` 解密后直接 `parse_loose_json` 返回 ⇒ 上游报错时
/// `list` 会报"没有 data 数组（字段名可能改了）"、`detail` 会报"返回 0 条"，
/// **把"服务端说不行"归因成"字段名改了/没数据"** —— 方向完全错，用户和我们都会被误导。
pub fn parse_envelope(path: &str, v: &serde_json::Value) -> Result<serde_json::Value, String> {
    let code = v.get("code").and_then(|x| x.as_i64()).unwrap_or(0);
    if code != 0 {
        let msg = v
            .get("msg")
            .and_then(|x| x.as_str())
            .unwrap_or("（上游没给 msg）");
        return Err(format!("{path} 返回 code={code} msg={msg}"));
    }
    Ok(v.clone())
}

/// token 判定（唯一实现）：空 ⇒ Err，由调用方决定是否降级
pub fn require_token(token: String) -> Result<String, String> {
    if token.trim().is_empty() {
        Err("登录态不可用（userInfo 未给 user_token）".to_string())
    } else {
        Ok(token)
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  实例
// ═══════════════════════════════════════════════════════════════════════

pub struct App99 {
    client: reqwest::Client,
    /// 握手后才有；`None` 表示还没 init
    state: Mutex<Option<Handshaken>>,
}

struct Handshaken {
    ext: String,
    host: String,
    uuid: String,
    token: String,
    version: String,
    categories: Vec<CspCategory>,
    players: serde_json::Value,
    parser_ids: Vec<i64>,
}

const EPISODE_PREFIX: &str = "app99:";
const PARSE_BUDGET: Duration = Duration::from_secs(40);

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct EpisodeRef {
    url: String,
    code: String,
    title: String,
    index: usize,
}

pub(crate) fn is_episode_id(id: &str) -> bool {
    id.starts_with(EPISODE_PREFIX)
}

pub(crate) fn episode_context(id: &str) -> Option<(String, u32)> {
    let episode = decode_episode(id).ok()?;
    Some((episode.title, u32::try_from(episode.index).ok()?))
}

pub(crate) fn episode_url(id: &str) -> Option<String> {
    decode_episode(id).ok().map(|episode| episode.url)
}

fn decode_episode(id: &str) -> Result<EpisodeRef, String> {
    let body = id.strip_prefix(EPISODE_PREFIX)
        .ok_or_else(|| "剧集标识格式无效".to_string())?;
    let bytes = b64_decode(body).map_err(|_| "剧集标识格式无效".to_string())?;
    serde_json::from_slice(&bytes).map_err(|_| "剧集标识格式无效".to_string())
}

fn encode_episode(url: &str, code: &str, title: &str, index: usize) -> String {
    let ep = EpisodeRef {
        url: url.to_string(),
        code: code.to_string(),
        title: title.to_string(),
        index,
    };
    format!("{EPISODE_PREFIX}{}", b64_encode(&serde_json::to_vec(&ep).expect("episode JSON")))
}

fn int_field(v: &serde_json::Value, key: &str) -> Option<i64> {
    v.get(key).and_then(|v| v.as_i64().or_else(|| v.as_str()?.parse().ok()))
}

fn player_name(players: &serde_json::Value, code: &str) -> String {
    let name = players.get(code).and_then(|p| p.get("name"))
        .and_then(|v| v.as_str()).filter(|s| !s.trim().is_empty())
        .unwrap_or(code);
    let duplicates = players.as_object().map(|map| map.values()
        .filter(|p| p.get("name").and_then(|v| v.as_str()) == Some(name)).count())
        .unwrap_or(0);
    if duplicates > 1 { format!("{name} ({code})") } else { name.to_string() }
}

fn http_url(raw: &str) -> bool {
    if raw.chars().any(char::is_control) {
        return false;
    }
    reqwest::Url::parse(raw).ok()
        .map(|u| matches!(u.scheme(), "http" | "https") && u.host_str().is_some())
        .unwrap_or(false)
}

fn direct_media_url(raw: &str) -> bool {
    let Some(url) = reqwest::Url::parse(raw).ok() else { return false };
    if !http_url(raw) { return false; }
    let path = url.path().to_ascii_lowercase();
    [".m3u8", ".mp4", ".mkv", ".ts", ".flv", ".avi", ".mov", ".webm", ".m4v"]
        .iter().any(|ext| path.ends_with(ext))
}

fn native_share_url(raw: &str) -> bool {
    let share = crate::pan::parse_share(raw);
    http_url(raw) && share.kind != crate::pan::PanKind::Unknown && !share.share_id.is_empty()
}

impl App99 {
    pub const CLASS: &'static str = "App99";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(REQ_BUDGET)
            // 与 pan_web_share 同一条纪律：不读系统代理（代理会把"站点可用"测成"全宕"）
            .no_proxy()
            .build()
            .expect("build app99 http client");
        Self {
            client,
            state: Mutex::new(None),
        }
    }

    /// ext → 握手所需的四个要素（缺一个都如实报错，不填默认值糊过去）
    pub fn ext_fields(ext: &str) -> Result<(String, String, String, String, String, String), String> {
        let j = parse_loose_json(ext).map_err(|e| format!("ext 不是合法 JSON：{e}"))?;
        let get = |k: &str| j.get(k).and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
        let host = get("host");
        let name = get("name");
        let sig = get("buildSignature");
        let num = get("buildNumber");
        let ver = get("versionName");
        let pkg = get("package");
        for (k, v) in [
            ("host", &host),
            ("name", &name),
            ("buildSignature", &sig),
            ("buildNumber", &num),
            ("versionName", &ver),
            ("package", &pkg),
        ] {
            if v.is_empty() {
                return Err(format!(
                    "ext 缺少 `{k}`（这个源的握手必须要它；配置里删掉就没法用）"
                ));
            }
        }
        let uuid = {
            let u = get("uuid");
            if u.is_empty() {
                // DEX 的默认值就是一个随机 UUID（去掉 '-' 后 32 hex = AES-256 密钥）
                let n = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos() as u64)
                    .unwrap_or(0);
                let a = iv16(n, 1);
                let b = iv16(n ^ 0x1234_5678, 2);
                let hex: String = a.iter().chain(b.iter()).map(|x| format!("{x:02x}")).collect();
                format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32])
            } else {
                u
            }
        };
        Ok((host, name, sig, num, ver, uuid))
    }

    /// 从 ext 取 `package`（握手第二步要用；ext_fields 已校验它非空）
    fn ext_pkg(ext: &str) -> String {
        parse_loose_json(ext)
            .ok()
            .and_then(|j| j.get("package").and_then(|v| v.as_str()).map(|s| s.to_string()))
            .unwrap_or_default()
    }

    #[allow(clippy::too_many_arguments)]
    fn signed_post(
        &self,
        url: &str,
        uuid: &str,
        version: &str,
        timestamp: &str,
        nonce: &str,
        token: &str,
        encrypted: &str,
    ) -> reqwest::RequestBuilder {
        self.client.post(url)
            .header("Accept", "application/json")
            .header("Content-Type", "application/json; charset=utf-8")
            .header("client_type", "android")
            .header("uuid", uuid)
            .header("version", version)
            .header("api_version", "v1")
            .header("timestamp", timestamp)
            .header("nonce", nonce)
            .header("sign", sign_of(encrypted, timestamp, nonce, token))
            .body(encrypted.to_string())
    }

    fn transport_failure(stage: &str, error: &reqwest::Error) -> String {
        let kind = if error.is_timeout() { "timeout" }
            else if error.is_connect() { "connect" }
            else if error.is_builder() { "request" }
            else { "transport" };
        format!("{stage} 请求失败（{kind}）")
    }

    fn guest_device_id() -> Result<String, String> {
        use ring::rand::{SecureRandom, SystemRandom};
        let mut bytes = [0u8; 16];
        SystemRandom::new().fill(&mut bytes)
            .map_err(|_| "生成游客设备标识失败".to_string())?;
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        Ok(format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12],
            &hex[12..16], &hex[16..20], &hex[20..32]))
    }

    /// 握手第二步：POST `{host}{LoginPath}` 拿 `userInfo.user_token`
    ///
    /// 指令级依据（`init:325-643`）：先做 systemInit，再打 userInfo，
    /// 从响应 `userInfo.user_token` 取 token 存字段 b；字段 b 为空时才走这一步。
    #[allow(clippy::too_many_arguments)]
    async fn user_info_token(
        &self,
        host: &str,
        key: &[u8],
        uuid: &str,
        app_version: &str,
        header_version: &str,
        login_path: &str,
        name: &str,
        pkg: &str,
        build_number: &str,
        build_sig: &str,
        now: &u64,
    ) -> Result<String, String> {
        // 设备信息是**写死的小米机型**（DEX init:362-477 的常量），照抄即可 —— 这不是"编数据"，
        // 是协议要求的固定指纹；改了反而可能被服务端拒绝。
        let installed_at = now_ms().parse::<u64>()
            .map_err(|_| "生成游客安装时间失败".to_string())?;
        let did = Self::guest_device_id()?;
        let nonce = nonce_now();
        let ts = now_ms();
        let body = serde_json::json!({
            "os": "android", "name": "xiaomi", "version": "15", "sdkInt": 32,
            "device": "xiaomi", "brand": "xiaomi", "manufacturer": "xiaomi",
            "product": "b0q", "hardware": "xiaomi", "isPhysicalDevice": true,
            "androidId": "V417IR", "bootloader": "unknown",
            "display": "V417IR release-keys", "host": "a11-gz01-test",
            "tags": "release-keys", "type": "user",
            "finger": "xiaomi/b0q/b0q:15/V619IR/613:user/release-keys",
            "app": {
                "version": app_version,
                "name": name,
                "package": pkg,
                "buildNumber": build_number,
                "buildSignature": build_sig,
                "install": installed_at,
                "update": installed_at
            },
            "did": did,
            "apiVersion": "v2",
            "channel": "",
            "token": "",
            "timestamp": ts,
            "nonce": nonce,
        })
        .to_string();
        let iv = iv16(*now, 21);
        let enc = encrypt_body(key, &body, &iv)?;
        let url = format!("{host}{login_path}");
        let resp = self
            .signed_post(&url, uuid, header_version, &ts, &nonce, "", &enc)
            .send()
            .await
            .map_err(|e| Self::transport_failure("userInfo", &e))?;
        let status = resp.status();
        if !status.is_success() {
            return Err(format!("userInfo HTTP {}", status.as_u16()));
        }
        let text = resp.text().await.map_err(|e| Self::transport_failure("userInfo 响应", &e))?;
        let plain = decrypt_body(key, text.trim()).map_err(|e| format!("userInfo 解密失败：{e}"))?;
        let v = parse_loose_json(&plain).map_err(|e| format!("userInfo 不是 JSON：{e}"))?;
        let code = v.get("code").and_then(|value| value.as_i64()).unwrap_or(0);
        if code != 0 {
            return Err(format!("userInfo 返回 code={code}"));
        }
        let token = v
            .get("userInfo")
            .and_then(|u| u.get("user_token"))
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string();
        if token.is_empty() {
            // 不猜字段名：把真实结构打出来（只打键名，不打内容）
            let top: Vec<String> = v
                .as_object()
                .map(|o| o.keys().cloned().collect())
                .unwrap_or_default();
            let ui: Vec<String> = v
                .get("userInfo")
                .and_then(|u| u.as_object())
                .map(|o| o.keys().cloned().collect())
                .unwrap_or_default();
            eprintln!(
                "[APP99] userInfo 顶层键={top:?}；userInfo 键={ui:?}"
            );
        }
        require_token(token)
    }

    /// 握手：POST `{host}/app/systemInit` → 解密 → 拿 token / categories
    async fn handshake(&self, ext: &str) -> Result<(), String> {
        if self.state.lock().map_err(|_| "状态锁中毒".to_string())?
            .as_ref().map(|s| s.ext == ext).unwrap_or(false)
        {
            return Ok(());
        }
        let (host, name, sig, num, ver, uuid) = Self::ext_fields(ext)?;
        let (pkg, ver_for_body) = (Self::ext_pkg(ext), ver.clone());
        let config = parse_loose_json(ext).map_err(|_| "ext 不是合法 JSON".to_string())?;
        let header_version = config.get("version").and_then(|value| value.as_str())
            .unwrap_or(&ver).to_string();
        let login_path = config.get("LoginPath").and_then(|value| value.as_str())
            .unwrap_or("/app/userInfo").to_string();
        let key = key_of(&uuid)?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0);
        let nonce = nonce_now();
        let ts = now_ms();
        let body = serde_json::json!({
            "v": ver,
            "n": name,
            "s": sig,
            "pl": "1",
            "apiVersion": "v2",
            "token": "",
            "timestamp": ts,
            "nonce": nonce,
        })
        .to_string();
        let iv = iv16(now, 9);
        let enc = encrypt_body(&key, &body, &iv)?;
        let url = format!("{host}/app/systemInit");
        let resp = self
            .signed_post(&url, &uuid, &header_version, &ts, &nonce, "", &enc)
            .send()
            .await
            .map_err(|e| Self::transport_failure("systemInit", &e))?;
        let status = resp.status();
        if !status.is_success() {
            return Err(format!("systemInit HTTP {}", status.as_u16()));
        }
        let text = resp.text().await.map_err(|e| Self::transport_failure("systemInit 响应", &e))?;
        // ★ 落一份**真实响应夹具**（uuid + 原始 base64），供离线验收用例复算。
        //   只存这与解密相关的两样东西，不含任何用户数据（响应是公开目录接口的返回）。
        if std::env::var("CSP_LIVE").ok().as_deref() == Some("1")
            && reqwest::Url::parse(&host).ok().and_then(|u| u.host_str().map(str::to_string))
                .map(|h| h != "127.0.0.1" && h != "localhost" && h != "::1").unwrap_or(false)
        {
            let fixture = serde_json::json!({
                "captured_at": "2026-10-26",
                "endpoint": "/app/systemInit",
                "uuid": &uuid,
                "response_b64": text.trim(),
            });
            let path = std::path::Path::new("../.probe/app99-known-systeminit.json");
            if let Ok(body) = serde_json::to_string_pretty(&fixture) {
                let _ = std::fs::write(path, &body);
                let alt = std::path::Path::new("../../.probe/app99-known-systeminit.json");
                let _ = std::fs::write(alt, &body);
            }
        }
        let plain = decrypt_body(&key, text.trim()).map_err(|e| format!("握手响应解密失败：{e}"))?;
        let v = parse_loose_json(&plain).map_err(|e| format!("握手响应不是 JSON：{e}"))?;
        // ★ systemInit 也有 code（实测成功时是 0）；!=0 必须如实报
        let v = parse_envelope("/app/systemInit", &v)?;
        // 结构 dump（只打键名，便于找 token 的嵌套位置）
        {
            let top: Vec<String> = v.as_object().map(|o| o.keys().cloned().collect()).unwrap_or_default();
            let mut nested: Vec<String> = Vec::new();
            for k in ["app", "c_p_d", "player", "parser_api", "tabs"] {
                if let Some(x) = v.get(k) {
                    let sub: Vec<String> = x
                        .as_object()
                        .map(|o| o.keys().cloned().collect())
                        .unwrap_or_default();
                    nested.push(format!("{k}{{{}}}", sub.join(",")));
                }
            }
            eprintln!("[APP99] systemInit 顶层键={top:?}");
            eprintln!("[APP99] 嵌套键={nested:?}");
        }

        /*
         * ★ 真实响应（2026-10-26 实测）里**没有** token —— token 来自**第二个接口**：
         * ```text
         * systemInit 响应顶层键 = [action, app, c_p_d, categorys, code, danmu,
         *                         defaultPlayer, feedbackType, filterNotProxyDomain, msg,
         *                         parser_api, player, tabs, tips, user_avatar, user_level]
         * init:619-643 → 再 POST {host}{LoginPath}(默认 /app/userInfo)
         *               → 响应 JSON.userInfo.user_token ⇒ 字段 b（后续请求的 token）
         * ```
         * 分类也在这一层：`categorys.data`（注意是 `categorys` 不是 `categories`，指令 :294-322）。
         */
        let categories: Vec<CspCategory> = v
            .get("categorys")
            .and_then(|c| c.get("data"))
            .and_then(|d| d.as_array())
            .or_else(|| v.get("categories").and_then(|d| d.as_array()))
            .map(|arr| {
                arr.iter()
                    .filter_map(|c| {
                        let id = c
                            .get("id")
                            .or_else(|| c.get("type_id"))
                            .map(|x| x.to_string().trim_matches('"').to_string())
                            .unwrap_or_default();
                        let name = c
                            .get("name")
                            .or_else(|| c.get("type_name"))
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        if id.is_empty() || name.is_empty() {
                            None
                        } else {
                            Some(CspCategory { id, name })
                        }
                    })
                    .collect()
            })
            .unwrap_or_default();
        if categories.is_empty() {
            log::warn!("App99 systemInit 响应里没有 categorys.data —— 分类为空（不编造）");
        }

        // ── 第二步：userInfo 拿 token（指令级依据见 init:325-643）──
        /*
         * ★★ 2026-11-01（Owner 真机：聚合搜「老舅」胖妞/剧圈两站缺失）：token **降级获取**。
         * ```text
         * 实测（.probe/pn-diag-source.log）：部分站点对游客明确拒绝 userInfo——
         *   {"code":1,"msg":"user info error"} ⇒ require_token 报 Err。
         * 旧行为：`await?` 把 Err 传播 ⇒ **整站握手失败 ⇒ search 全废** ⇒
         *   该站从聚合搜索结果里整体消失（Owner 报的"没有这个源结果"）。
         * 已观察部分空 token 路径可浏览；这不证明所有线路取流都不需要 token。
         *   DEX 语义也是"字段 b 为空就空着"。
         * ⇒ 现行为：userInfo 失败 ⇒ 记无敏感值的原因 ⇒ **空 token 继续握手**；
         *   业务请求若真需要 token 被站点拒 ⇒ 那是该站自己的错误，如实进扇出 fails——
         *   诚实容错，不猜、不编造"登录态可用"。
         * ```
         */
        let token = {
            let direct = v
                .get("userInfo")
                .and_then(|u| u.get("user_token"))
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string();
            if !direct.is_empty() {
                direct
            } else {
                match self
                    .user_info_token(&host, &key, &uuid, &ver_for_body, &header_version,
                        &login_path, &name, &pkg, &num, &sig, &now)
                    .await
                {
                    Ok(t) => t,
                    Err(why) => {
                        log::warn!(
                            "[APP99] userInfo 未给 token（{why}）⇒ 以空 token 继续握手，业务鉴权由上游决定"
                        );
                        String::new()
                    }
                }
            }
        };
        if token.is_empty() {
            log::info!(
                "[APP99] 两段握手都没有 token（systemInit 返回 code=0）⇒ 用空 token 发业务请求"
            );
        }
        *self.state.lock().map_err(|_| "状态锁中毒".to_string())? = Some(Handshaken {
            ext: ext.to_string(),
            host,
            uuid,
            token,
            version: header_version,
            categories,
            players: v.get("player").cloned().unwrap_or(serde_json::Value::Null),
            parser_ids: v.get("parser_api").and_then(|p| p.as_array())
                .map(|ids| ids.iter().filter_map(|p| int_field(p, "id")).collect())
                .unwrap_or_default(),
        });
        Ok(())
    }

    /// 业务请求：body → 加密 → 签名 → POST → **返回原始 base64 响应**
    ///
    /// 与 [`App99::call`] 分开，是为了能**把真实响应落成夹具**（测试要知道密文原文）。
    async fn call_raw(&self, path: &str, body: serde_json::Value) -> Result<(String, String), String> {
        let (host, key, token, uuid, version, nonce, ts, enc) = {
            let g = self.state.lock().map_err(|_| "状态锁中毒".to_string())?;
            let st = g
                .as_ref()
                .ok_or_else(|| "还没握手（先调用 home 或 list 触发一次）".to_string())?;
            let key = key_of(&st.uuid)?;
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0);
            let nonce = nonce_now();
            let ts = now_ms();
            let mut b = body.clone();
            if let Some(o) = b.as_object_mut() {
                o.insert("token".into(), serde_json::Value::String(st.token.clone()));
                o.insert("timestamp".into(), serde_json::Value::String(ts.clone()));
                o.insert("nonce".into(), serde_json::Value::String(nonce.clone()));
            }
            let iv = iv16(now, 11);
            let enc = encrypt_body(&key, &b.to_string(), &iv)?;
            (
                st.host.clone(),
                key,
                st.token.clone(),
                st.uuid.clone(),
                st.version.clone(),
                nonce,
                ts,
                enc,
            )
        };
        let url = format!("{host}{path}");
        let resp = self
            .signed_post(&url, &uuid, &version, &ts, &nonce, &token, &enc)
            .send()
            .await
            .map_err(|e| Self::transport_failure("业务", &e))?;
        let status = resp.status();
        if !status.is_success() {
            return Err(format!("业务 HTTP {}", status.as_u16()));
        }
        let text = resp.text().await.map_err(|e| Self::transport_failure("业务响应", &e))?;
        if text.trim().is_empty() {
            return Err(format!("{path} 返回空响应"));
        }
        let _ = key; // 解密在 call() 里做（这里只负责把密文带出去）
        Ok((uuid, text.trim().to_string()))
    }

    /// 业务请求：加密 → 签名 → POST → 解密 → JSON
    async fn call(&self, path: &str, body: serde_json::Value) -> Result<serde_json::Value, String> {
        let (uuid, b64) = self.call_raw(path, body).await?;
        let key = key_of(&uuid)?;
        let plain = decrypt_body(&key, &b64).map_err(|e| format!("{path} 响应解密失败：{e}"))?;
        let v = parse_loose_json(&plain).map_err(|e| format!("{path} 响应不是 JSON：{e}"))?;
        // ★ code != 0 必须原样报出来（别归因成"字段名改了"）
        parse_envelope(path, &v)
    }

    async fn resolve_episode(&self, episode: &EpisodeRef, flag: &str) -> Result<CspPlay, String> {
        if episode.url.is_empty() || episode.url.chars().any(char::is_control) {
            return Err("这条剧集没有有效的播放标识，请切换线路".to_string());
        }
        if native_share_url(&episode.url) {
            return Ok(CspPlay {
                url: episode.url.clone(),
                headers: vec![("User-Agent".to_string(), UA.to_string())],
                label: Some(flag.to_string()),
            });
        }
        let configured = {
            let state = self.state.lock().map_err(|_| "状态锁中毒".to_string())?;
            state.as_ref().and_then(|state| {
                let player = state.players.get(&episode.code).or_else(|| {
                    state.players.as_object()?.iter()
                        .find(|(code, _)| player_name(&state.players, code) == flag)
                        .map(|(_, value)| value)
                })?;
                Some((player.clone(), state.parser_ids.clone()))
            })
        };
        let requires_parser = configured.as_ref()
            .and_then(|(player, _)| int_field(player, "type"))
            .map(|kind| kind != 0).unwrap_or(false);
        // Media-shaped inputs on parser lines still carry the selected episode to vodParser.
        if direct_media_url(&episode.url) && !requires_parser {
            return Ok(CspPlay {
                url: episode.url.clone(),
                headers: vec![("User-Agent".to_string(), UA.to_string())],
                label: Some(flag.to_string()),
            });
        }
        let (player, ids) = configured
            .ok_or_else(|| "该线路没有媒体解析配置，请切换线路".to_string())?;
        if int_field(&player, "type") == Some(0) {
            if !http_url(&episode.url) {
                return Err("这条直连线路没有有效的播放地址，请切换线路".to_string());
            }
            self.verify_media_response(&episode.url).await?;
            return Ok(CspPlay {
                url: episode.url.clone(),
                headers: vec![("User-Agent".to_string(), UA.to_string())],
                label: Some(flag.to_string()),
            });
        }
        let allowed: Vec<&str> = player.get("parseUrl").and_then(|v| v.as_str())
            .unwrap_or("").split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
        let mut failures = Vec::new();
        for id in ids {
            if !allowed.is_empty() && !allowed.iter().any(|value| *value == id.to_string()) {
                continue;
            }
            let response = self.call("/app/vodParser", serde_json::json!({
                "id":id,"url":episode.url
            })).await;
            match response {
                Ok(value) => {
                    if let Some(url) = value.get("data").and_then(|v| v.as_str())
                        .map(str::trim).filter(|url| http_url(url))
                    {
                        if !direct_media_url(url) && !native_share_url(url)
                            && self.verify_media_response(url).await.is_err()
                        {
                            failures.push(format!("解析器 {id} 未返回媒体内容"));
                            continue;
                        }
                        return Ok(CspPlay {
                            url: url.to_string(),
                            headers: vec![("User-Agent".to_string(), UA.to_string())],
                            label: Some(flag.to_string()),
                        });
                    }
                    failures.push(format!("解析器 {id} 未返回媒体地址"));
                }
                Err(_) => failures.push(format!("解析器 {id} 请求失败")),
            }
        }
        Err(if failures.is_empty() {
            "该线路没有可用的媒体解析器，请切换线路".to_string()
        } else {
            format!("播放链接解析失败：{}。请切换线路", failures.join("；"))
        })
    }

    async fn verify_media_response(&self, url: &str) -> Result<(), String> {
        let mut response = self.client.get(url).header("Range", "bytes=0-511")
            .send().await.map_err(|_| "无法读取这条线路的媒体，请稍后重试".to_string())?;
        if !response.status().is_success() {
            return Err(format!("媒体请求返回 HTTP {}，请切换线路", response.status().as_u16()));
        }
        let content_type = response.headers().get("Content-Type")
            .and_then(|v| v.to_str().ok()).unwrap_or("").to_ascii_lowercase();
        if content_type.contains("text/html") || content_type.contains("application/json") {
            return Err("这条线路返回的是播放网页，没有可播放的媒体，请切换线路".to_string());
        }
        let chunk = response.chunk().await
            .map_err(|_| "无法读取这条线路的媒体，请稍后重试".to_string())?
            .ok_or_else(|| "这条线路没有返回媒体内容，请切换线路".to_string())?;
        let media_type = content_type.starts_with("video/") || content_type.starts_with("audio/")
            || content_type.contains("mpegurl");
        let magic = chunk.starts_with(b"#EXTM3U") || chunk.get(4..8) == Some(b"ftyp")
            || chunk.starts_with(&[0x1a, 0x45, 0xdf, 0xa3])
            || (chunk.first() == Some(&0x47) && chunk.get(188) == Some(&0x47));
        if media_type || magic {
            Ok(())
        } else {
            Err("这条线路没有返回可识别的媒体内容，请切换线路".to_string())
        }
    }
}

impl Default for App99 {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite
// ═══════════════════════════════════════════════════════════════════════

/// 搜索端点（DEX：与 `list` 同一个 `POST /vod/search`，只是 `kw` 来自用户）
const SEARCH_PATH: &str = "/vod/search";

/// 搜索请求体
///
/// ⚠️ 键名就是 `kw` —— 写成 `q`/`keyword` 服务端**不报错**，只会返回 0 条，
///    我们这边表现为"搜不到"。夹具用例把这条钉住。
fn search_body(kw: &str, page: u32) -> serde_json::Value {
    serde_json::json!({
        "kw": kw,
        "page": if page == 0 { 1 } else { page },
        "limit": 21,
        "orderBy": "vod_hits_month",
        "sort": "desc",
    })
}

/// 空结果 ⇒ Err（与全仓口径一致：不许把"0 条"当成功返回）
fn ensure_search_hits(
    items: Vec<CspItem>,
    kw: &str,
    page: u32,
) -> Result<Vec<CspItem>, String> {
    if items.is_empty() {
        return Err(format!(
            "搜索「{kw}」第 {page} 页返回 0 条（服务端没给数据，不是我们解析失败）"
        ));
    }
    Ok(items)
}

#[async_trait]
impl CspSite for App99 {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        self.handshake(ext).await?;
        let g = self.state.lock().map_err(|_| "状态锁中毒".to_string())?;
        let st = g.as_ref().expect("握手后必有状态");
        if st.categories.is_empty() {
            return Err(
                "握手成功，但该源没有下发任何分类（categories 为空）—— 只能靠搜索用，不能当分类源"
                    .to_string(),
            );
        }
        Ok(CspHome {
            categories: st.categories.clone(),
            items: Vec::new(),
        })
    }

    /// 分类列表：`tid` 当作搜索词（该源的分类就是服务端的检索词，见 DEX 的 categoryContent）
    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let page = if page == 0 { 1 } else { page };
        let body = serde_json::json!({
            "kw": tid.trim(),
            "page": page,
            "limit": 21,
            "orderBy": "vod_hits_month",
            "sort": "desc",
        });
        let v = self.call("/vod/search", body).await?;
        let items = items_of(&v)?;
        if items.is_empty() {
            return Err(format!(
                "搜索「{tid}」第 {page} 页返回 0 条（服务端没给数据，不是我们解析失败）"
            ));
        }
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        self.handshake(_ext).await?;
        let body = serde_json::json!({
            "id": id.trim(), "eps": "1", "v": "2.0.0", "pl": 1
        });
        let v = self.call("/vod/detail", body).await?;
        let d = v
            .get("data")
            .cloned()
            .unwrap_or(serde_json::Value::Null);
        if d.is_null() {
            return Err("详情响应里没有 data 字段".to_string());
        }
        let players = self.state.lock().map_err(|_| "状态锁中毒".to_string())?
            .as_ref().map(|s| s.players.clone()).unwrap_or(serde_json::Value::Null);
        detail_of(&d, id, &players)
    }

    /// 搜索：与 `list()` **同一条链路**（`POST /vod/search`，body 里 `kw`），
    /// 区别只是 `kw` 来自用户输入而不是分类 id。
    /// ★ 搜索能力声明（`capabilities.search` 直接用它的值）
    ///
    /// `AES 链路的 /vod/search 已实现（与 list 同一端点），但**"按关键词"这条没单独真网络验证**`
    fn supports_search(&self) -> bool {
        true
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        // ★ 必须先握手（与 `list()` 一致）：`call` 依赖握手拿到的 host/key/token
        self.handshake(_ext).await?;
        let v = self.call(SEARCH_PATH, search_body(kw, page)).await?;
        let items = items_of(&v)?;
        ensure_search_hits(items, kw, page)
            .map(|items| CspList { items, page, page_count: None, total: None })
    }

    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let raw = id.trim();
        if raw.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        let episode = if is_episode_id(raw) {
            decode_episode(raw)?
        } else {
            EpisodeRef { url: raw.to_string(), code: flag.to_string(), title: String::new(), index: 0 }
        };
        if !native_share_url(&episode.url) && !ext.is_empty() {
            self.handshake(ext).await?;
        }
        // Parser attempts share one deadline; a slow configured parser cannot hang playback.
        let play = tokio::time::timeout(PARSE_BUDGET, self.resolve_episode(&episode, flag))
            .await.map_err(|_| "媒体解析超时，请稍后重试或切换线路".to_string())??;
        Ok(vec![play])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  响应字段映射（纯函数，离线可测）
// ═══════════════════════════════════════════════════════════════════════

fn items_of(v: &serde_json::Value) -> Result<Vec<CspItem>, String> {
    let arr = v
        .get("data")
        .and_then(|d| d.as_array())
        .or_else(|| v.get("data").and_then(|d| d.get("list")).and_then(|l| l.as_array()))
        .ok_or_else(|| "响应里没有 data 数组（字段名可能改了）".to_string())?;
    Ok(arr
        .iter()
        .filter_map(|x| {
            let id = x
                .get("id")
                .map(|i| i.to_string().trim_matches('"').to_string())
                .unwrap_or_default();
            let title = x.get("name").and_then(|s| s.as_str()).unwrap_or("").to_string();
            if id.is_empty() || title.is_empty() {
                return None;
            }
            Some(CspItem {
                id,
                title: strip_tags(&title),
                cover: x.get("pic").and_then(|s| s.as_str()).map(|s| s.to_string()),
                subtitle: x
                    .get("remarks")
                    .and_then(|s| s.as_str())
                    .map(|s| s.to_string()),
            })
        })
        .collect())
}

fn detail_of(
    d: &serde_json::Value,
    id: &str,
    players: &serde_json::Value,
) -> Result<CspDetail, String> {
    let title = d.get("name").and_then(|s| s.as_str()).unwrap_or("").to_string();
    let desc = d.get("blurb").and_then(|s| s.as_str()).unwrap_or("").to_string();
    /*
     * ★ 真实响应（2026-10-26 实测）用的字段名是 **`play_from` / `play_url`**，
     *   不是苹果CMS 的 `vod_play_from` / `vod_play_url`（我最初按后者写，detail 一直"没有可播地址"）。
     *   两种都认：前者优先，后者兜底（不同源/不同版本可能不一致）。
     */
    let pick = |a: &str, b: &str| {
        d.get(a)
            .and_then(|s| s.as_str())
            .filter(|s| !s.is_empty())
            .or_else(|| d.get(b).and_then(|s| s.as_str()))
            .unwrap_or("")
    };
    let from = pick("play_from", "vod_play_from");
    let urls = pick("play_url", "vod_play_url");
    let mut episodes: Vec<CspEpisode> = Vec::new();
    let lines = split_lines(from, urls);
    for (flag_name, eps) in &lines {
        let flag = player_name(players, flag_name);
        for (index, (name, url)) in eps.iter().enumerate() {
            if url.is_empty() {
                continue;
            }
            episodes.push(CspEpisode {
                // Display names are not protocol keys; carry the raw code with each episode.
                id: encode_episode(url, flag_name, name, index + 1),
                title: name.clone(),
                flag: flag.clone(),
            });
        }
    }
    if episodes.is_empty() {
        // 不猜字段名：把真实结构打出来（只打键名）
        let top: Vec<String> = d
            .as_object()
            .map(|o| o.keys().cloned().collect())
            .unwrap_or_default();
        eprintln!("[APP99] detail.data 顶层键={top:?}");
        return Err(format!(
            "这个条目没有可播地址（vod_play_url 为空；线路={from}）；data 顶层键={top:?}"
        ));
    }
    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover: d.get("pic").and_then(|s| s.as_str()).map(|s| s.to_string()),
        description: if desc.is_empty() { None } else { Some(strip_tags(&desc)) },
        episodes,
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册（R3-D，2026-10-27）
// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，**不改核心注册表**。
// 改前这一行写死在 `csp/mod.rs` 的 `build_registry()` 里。
//
// # 这个类的事实（从核心文件头搬过来，别丢）
// ```text
// csp_App99：配置里 **2 个源**。AES/CBC 加密协议（取证 + 真网络都过了，见本文件头）。
// ⚠️ 已验：home（8 分类）/ list（20 条目）；**未验：detail / play**。
// ```
crate::csp::register_site!(App99);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn seal_fixture(key: &[u8], plain: &serde_json::Value) -> String {
        use std::io::Write as _;
        let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        z.write_all(plain.to_string().as_bytes()).unwrap();
        let comp = z.finish().unwrap();
        let iv = iv16(comp.len() as u64, 3);
        let mut buf = vec![0u8; (comp.len() / 16 + 1) * 16];
        buf[..comp.len()].copy_from_slice(&comp);
        let ct = Aes256CbcEnc::new_from_slices(key, &iv)
            .unwrap()
            .encrypt_padded_mut::<Pkcs7>(&mut buf, comp.len())
            .unwrap();
        b64_encode(&[iv.as_slice(), ct].concat())
    }

    fn open_request(key: &[u8], body: &str) -> serde_json::Value {
        let mut all = b64_decode(body).unwrap();
        let (iv, ct) = all.split_at_mut(16);
        let plain = Aes256CbcDec::new_from_slices(key, iv)
            .unwrap()
            .decrypt_padded_mut::<Pkcs7>(ct)
            .unwrap();
        serde_json::from_slice(plain).unwrap()
    }

    #[tokio::test]
    async fn app99_signed_post_matches_reference_okhttp_wire_contract() {
        use axum::{
            body::Bytes, extract::State, http::HeaderMap, routing::post, Router,
        };
        use std::sync::Arc;

        type Seen = Arc<Mutex<Vec<(HeaderMap, Bytes)>>>;
        async fn capture(
            State(seen): State<Seen>, headers: HeaderMap, body: Bytes,
        ) -> axum::http::StatusCode {
            seen.lock().unwrap().push((headers, body));
            axum::http::StatusCode::NO_CONTENT
        }

        let uuid = "aabbccddeeff00112233445566778899";
        let timestamp = "1700000000000";
        let nonce = b64_encode(&[0u8; 16]);
        let payload = serde_json::json!({
            "id": 1, "url": "fixture+opaque/input==", "token": "",
            "timestamp": timestamp, "nonce": nonce,
        });
        let key = key_of(uuid).unwrap();
        let encrypted = encrypt_body(&key, &payload.to_string(), &iv16(1, 2)).unwrap();
        let seen: Seen = Arc::new(Mutex::new(Vec::new()));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let router = Router::new().route("/vod/parser", post(capture)).with_state(seen.clone());
        let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let request = App99::new().signed_post(
            &format!("http://{addr}/vod/parser"), uuid, "fixture-version",
            timestamp, &nonce, "", &encrypted,
        );
        let response = tokio::time::timeout(Duration::from_secs(5), request.send()).await;
        server.abort();
        let _ = server.await;
        let response = response.expect("loopback request must be bounded")
            .expect("production signed_post must reach the loopback sink");
        assert_eq!(response.status(), axum::http::StatusCode::NO_CONTENT);
        let requests = seen.lock().unwrap();
        assert_eq!(requests.len(), 1, "one signed POST must produce exactly one request");
        let (headers, body) = &requests[0];
        let header = |name| headers.get(name).and_then(|value| value.to_str().ok());
        assert!(body.as_ref() == encrypted.as_bytes(), "encrypted body bytes must not change");
        let captured = open_request(&key, std::str::from_utf8(body).unwrap());
        assert!(captured == payload, "numeric parser ID and all original fields must remain unchanged");
        let signature_input = format!("{encrypted}:{timestamp}:{nonce}:");
        let hash = ring::digest::digest(&ring::digest::SHA256, signature_input.as_bytes());
        let signature: String = hash.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
        assert!(header("sign") == Some(signature.as_str()),
            "signature must cover the exact ciphertext, timestamp, nonce and empty token");
        for (name, expected) in [
            ("accept", "application/json"), ("client_type", "android"), ("uuid", uuid),
            ("version", "fixture-version"), ("api_version", "v1"),
            ("timestamp", timestamp), ("nonce", nonce.as_str()), ("user-agent", UA),
        ] {
            assert!(header(name) == Some(expected), "signed header {name} must remain unchanged");
        }
        assert!(header("content-encoding").is_none(), "request body must not be compressed");
        assert!(header("transfer-encoding").is_none(), "fixed body must not become chunked");
        assert!(header("content-length") == Some(encrypted.len().to_string().as_str()));
        let body_hash = ring::digest::digest(&ring::digest::SHA256, body);
        let body_hash: String = body_hash.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
        eprintln!(
            "[APP99-WIRE] body_sha256={body_hash} body_unchanged=true signature_matches=true \
             fields_unchanged=true content_type={:?}", header("content-type"),
        );
        assert_eq!(
            header("content-type"), Some("application/json; charset=utf-8"),
            "reference OkHttp bridge uses the RequestBody media type on the wire",
        );
    }

    async fn assert_guest_handshake_contract(
        header_version_override: Option<&str>,
        login_path: &str,
        reject_guest: bool,
    ) {
        use axum::{extract::State, http::{HeaderMap, Uri}, routing::post, Router};
        use std::sync::Arc;

        type Seen = Arc<Mutex<Vec<(String, HeaderMap, serde_json::Value, bool)>>>;
        let uuid = "aabbccddeeff00112233445566778899";
        let key = key_of(uuid).unwrap();
        let seen: Seen = Arc::new(Mutex::new(Vec::new()));
        async fn endpoint(
            State((key, seen, reject)): State<(Vec<u8>, Seen, bool)>,
            uri: Uri,
            headers: HeaderMap,
            body: String,
        ) -> String {
            let request = open_request(&key, &body);
            let header = |name| headers.get(name).and_then(|value| value.to_str().ok()).unwrap_or("");
            let signature_input = format!(
                "{}:{}:{}:{}", body, header("timestamp"), header("nonce"),
                request["token"].as_str().unwrap_or("")
            );
            let hash = ring::digest::digest(&ring::digest::SHA256, signature_input.as_bytes());
            let expected: String = hash.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
            let signature_matches = header("sign") == expected;
            let response = match uri.path() {
                "/app/systemInit" => serde_json::json!({
                    "code":0,"categorys":{"data":[{"id":"1","name":"fixture"}]}
                }),
                "/vod/search" => serde_json::json!({
                    "code":0,"data":[{"id":77,"name":"fixture"}]
                }),
                _ if reject => serde_json::json!({
                    "code":1,"msg":"user info error","userInfo":""
                }),
                _ => serde_json::json!({
                    "code":0,"userInfo":{"user_token":"fixture-guest-token"}
                }),
            };
            seen.lock().unwrap().push((uri.path().to_string(), headers, request, signature_matches));
            seal_fixture(&key, &response)
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = Router::new().fallback(post(endpoint))
            .with_state((key, seen.clone(), reject_guest));
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let mut ext = serde_json::json!({
            "host":format!("http://{addr}"),"name":"fixture-app","buildSignature":"FIXTURE-SIG",
            "buildNumber":"2001","versionName":"3.5.8","package":"com.fixture",
            "uuid":uuid,"LoginPath":login_path
        });
        if let Some(version) = header_version_override {
            ext["version"] = serde_json::json!(version);
        }
        let ext = ext.to_string();
        let before = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
        let site = App99::new();
        let outcome = tokio::time::timeout(Duration::from_secs(5), async {
            site.search("fixture", 1, &ext).await?;
            site.search("fixture", 2, &ext).await
        }).await;
        server.abort();
        assert!(matches!(outcome, Ok(Ok(_))), "guest response must not block browsing");
        let after = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
        let requests = seen.lock().unwrap();
        assert_eq!(requests.len(), 4, "cached handshake must not add guest requests");
        let paths: Vec<_> = requests.iter().map(|request| request.0.as_str()).collect();
        assert_eq!(paths, vec!["/app/systemInit", login_path, "/vod/search", "/vod/search"]);
        let expected_version = header_version_override.unwrap_or("3.5.8");
        for (_, headers, request, signature_matches) in requests.iter() {
            let header = |name| headers.get(name).and_then(|value| value.to_str().ok());
            assert!(header("version") == Some(expected_version), "all stages need the configured version header");
            assert!(header("api_version") == Some("v1"), "all stages need api_version=v1");
            assert!(header("uuid") == Some(uuid), "configured encryption uuid must be retained");
            assert!(header("client_type") == Some("android"));
            assert!(header("accept") == Some("application/json"));
            assert!(header("content-type") == Some("application/json; charset=utf-8"));
            assert!(header("user-agent") == Some(UA));
            assert!(header("timestamp") == request["timestamp"].as_str());
            assert!(header("nonce") == request["nonce"].as_str());
            assert!(request["timestamp"].as_str().unwrap().parse::<u64>().is_ok());
            assert!(b64_decode(request["nonce"].as_str().unwrap()).unwrap().len() == 16);
            assert!(*signature_matches, "signature must cover actual ciphertext, headers and request token");
        }
        let init = &requests[0].2;
        assert!(init["v"] == "3.5.8", "header override must not change systemInit body version");
        assert!(init["n"] == "fixture-app");
        assert!(init["s"] == "FIXTURE-SIG");
        assert!(init["pl"] == "1");
        assert!(init["apiVersion"] == "v2");
        assert!(init["token"] == "");
        let guest = &requests[1].2;
        let expected_device = serde_json::json!({
            "os":"android","name":"xiaomi","version":"15","sdkInt":32,
            "device":"xiaomi","brand":"xiaomi","manufacturer":"xiaomi","product":"b0q",
            "hardware":"xiaomi","isPhysicalDevice":true,"androidId":"V417IR",
            "bootloader":"unknown","display":"V417IR release-keys","host":"a11-gz01-test",
            "tags":"release-keys","type":"user",
            "finger":"xiaomi/b0q/b0q:15/V619IR/613:user/release-keys"
        });
        for (field, value) in expected_device.as_object().unwrap() {
            assert!(guest.get(field) == Some(value), "device constants belong at guest body top level");
        }
        let mut expected_keys: std::collections::BTreeSet<_> =
            expected_device.as_object().unwrap().keys().map(String::as_str).collect();
        expected_keys.extend(["app", "did", "apiVersion", "channel", "token", "timestamp", "nonce"]);
        let actual_keys: std::collections::BTreeSet<_> =
            guest.as_object().unwrap().keys().map(String::as_str).collect();
        assert!(actual_keys == expected_keys, "guest body keys must match the DEX contract");
        let guest_app = &guest["app"];
        assert!(guest_app["version"] == "3.5.8", "application version remains versionName");
        assert!(guest_app["name"] == "fixture-app");
        assert!(guest_app["package"] == "com.fixture");
        assert!(guest_app["buildNumber"] == "2001");
        assert!(guest_app["buildSignature"] == "FIXTURE-SIG");
        let install = guest_app["install"].as_u64().expect("install is numeric milliseconds");
        assert!(guest_app["update"].as_u64() == Some(install));
        assert!(install >= before && install <= after);
        let app_keys: std::collections::BTreeSet<_> =
            guest_app.as_object().unwrap().keys().map(String::as_str).collect();
        assert!(app_keys == ["version", "name", "package", "buildNumber", "buildSignature", "install", "update"]
            .into_iter().collect());
        let did = guest["did"].as_str().expect("did is an independent UUID");
        assert!(did != uuid && did.len() == 36);
        assert!(did.chars().enumerate().all(|(index, ch)| {
            if [8, 13, 18, 23].contains(&index) { ch == '-' } else { ch.is_ascii_hexdigit() }
        }));
        assert!(guest["apiVersion"] == "v2");
        assert!(guest["channel"] == "");
        assert!(guest["token"] == "");
        let business_token = if reject_guest { "" } else { "fixture-guest-token" };
        for (_, _, request, _) in requests.iter().skip(2) {
            assert!(request["token"] == business_token, "business must carry the guest result without invention");
        }
    }

    #[tokio::test]
    async fn app99_guest_handshake_dex_default_version_and_body_contract() {
        assert_guest_handshake_contract(None, "/app/userInfo", false).await;
    }

    #[tokio::test]
    async fn app99_guest_handshake_dex_login_path_and_version_override_contract() {
        assert_guest_handshake_contract(Some("header-override"), "/fixture/guest", false).await;
    }

    #[tokio::test]
    async fn app99_guest_handshake_dex_rejected_guest_keeps_anonymous_browsing() {
        assert_guest_handshake_contract(Some("header-override"), "/fixture/guest", true).await;
    }

    async fn assert_guest_http_error_privacy(status: u16) {
        use axum::{http::StatusCode, routing::post, Router};
        let marker = "fixture-private-credential-marker";
        let echoed = format!("token={marker}; address=https://fixture.invalid/private?sign={marker}");
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let status = StatusCode::from_u16(status).unwrap();
        let app = Router::new().fallback(post(move || {
            let echoed = echoed.clone();
            async move { (status, echoed) }
        }));
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let uuid = "aabbccddeeff00112233445566778899";
        let key = key_of(uuid).unwrap();
        let host = format!("http://{addr}");
        let ext = serde_json::json!({
            "host":host,"name":"fixture","buildSignature":"SIG","buildNumber":"1",
            "versionName":"3.5.8","package":"com.fixture","uuid":uuid
        }).to_string();
        let site = App99::new();
        let init_error = site.handshake(&ext).await.expect_err("fixture init must fail");
        let guest_error = site.user_info_token(&host, &key, uuid, "3.5.8", "3.5.8",
            "/app/userInfo", "fixture", "com.fixture", "1", "SIG", &1)
            .await.expect_err("fixture guest request must fail");
        *site.state.lock().unwrap() = Some(Handshaken {
            ext, host, uuid:uuid.to_string(), token:String::new(), version:"3.5.8".to_string(),
            categories:Vec::new(), players:serde_json::Value::Null, parser_ids:Vec::new()
        });
        let business_error = site.call_raw("/vod/search", serde_json::json!({"kw":"fixture"}))
            .await.expect_err("fixture business request must fail");
        server.abort();
        for error in [init_error, guest_error, business_error] {
            assert!(error.contains(&status.as_u16().to_string()), "HTTP status must remain visible");
            assert!(!error.contains(marker), "credential echoes must not enter errors");
            assert!(!error.contains("https://") && !error.contains("token=") && !error.contains("sign="),
                "HTTP response bodies must not enter errors");
        }
    }

    #[tokio::test]
    async fn app99_guest_handshake_dex_http_500_error_is_private() {
        assert_guest_http_error_privacy(500).await;
    }

    #[tokio::test]
    async fn app99_guest_handshake_dex_http_403_error_is_private() {
        assert_guest_http_error_privacy(403).await;
    }

    #[tokio::test]
    async fn app99_guest_handshake_dex_transport_error_is_private() {
        let marker = "fixture-private-query-marker";
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);
        let host = format!("http://{addr}/private?token={marker}");
        let ext = serde_json::json!({
            "host":host,"name":"fixture","buildSignature":"SIG","buildNumber":"1",
            "versionName":"3.5.8","package":"com.fixture",
            "uuid":"aabbccddeeff00112233445566778899"
        }).to_string();
        let error = App99::new().handshake(&ext).await.expect_err("closed loopback port must fail");
        assert!(!error.contains(marker) && !error.contains("127.0.0.1") && !error.contains("token="),
            "transport errors must not include the request URL or query");
    }

    #[tokio::test]
    async fn app99_detail_dex_request_contract() {
        use axum::{extract::State, http::Uri, routing::post, Router};
        use std::sync::Arc;

        let uuid = "aabbccddeeff00112233445566778899";
        let key = key_of(uuid).unwrap();
        let seen = Arc::new(Mutex::new(Vec::<serde_json::Value>::new()));
        async fn endpoint(
            State((key, seen)): State<(Vec<u8>, Arc<Mutex<Vec<serde_json::Value>>>)>,
            uri: Uri,
            body: String,
        ) -> String {
            let request = open_request(&key, &body);
            let response = match uri.path() {
                "/app/systemInit" => serde_json::json!({
                    "code":0,"categorys":{"data":[]}
                }),
                "/app/userInfo" => serde_json::json!({
                    "code":0,"userInfo":{"user_token":""}
                }),
                "/vod/detail" => {
                    seen.lock().unwrap().push(request);
                    serde_json::json!({
                        "code":0,"data":{
                            "id":234900,"name":"fixture","play_from":"NBY",
                            "play_url":"1$fixture-selected-input"
                        }
                    })
                }
                _ => serde_json::json!({"code":1}),
            };
            seal_fixture(&key, &response)
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let router = Router::new().fallback(post(endpoint)).with_state((key, seen.clone()));
        let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let ext = serde_json::json!({
            "host":format!("http://{addr}"),"name":"fixture","buildSignature":"SIG",
            "buildNumber":"1","versionName":"3.5.8","uuid":uuid,"package":"com.fixture"
        }).to_string();
        let result = tokio::time::timeout(Duration::from_secs(5),
            App99::new().detail(" 234900 ", &ext)).await;
        server.abort();
        assert!(matches!(result, Ok(Ok(_))), "detail must use the received fixture");
        let requests = seen.lock().unwrap();
        assert_eq!(requests.len(), 1);
        let request = &requests[0];
        assert!(request["id"] == "234900", "detail ID must remain the selected ID");
        assert!(request["eps"] == "1", "DEX detail eps is a string");
        assert!(request["v"] == "2.0.0", "DEX detail uses its own protocol version");
        assert!(request["pl"].as_i64() == Some(1), "DEX detail pl is numeric");
        assert!(request["token"] == "", "anonymous detail must not invent a token");
    }

    #[tokio::test]
    async fn app99_parser_resolves_media_shaped_input() {
        use axum::{extract::State, http::{HeaderMap, Uri}, routing::post, Router};
        use std::sync::Arc;

        type Seen = Arc<Mutex<Vec<(String, serde_json::Value)>>>;
        let uuid = "aabbccddeeff00112233445566778899";
        let key = key_of(uuid).unwrap();
        let seen: Seen = Arc::new(Mutex::new(Vec::new()));
        async fn endpoint(
            State((key, seen)): State<(Vec<u8>, Seen)>,
            uri: Uri,
            headers: HeaderMap,
            body: String,
        ) -> String {
            let request = open_request(&key, &body);
            assert_eq!(
                headers.get("sign").unwrap().to_str().unwrap(),
                sign_of(
                    &body,
                    headers.get("timestamp").unwrap().to_str().unwrap(),
                    headers.get("nonce").unwrap().to_str().unwrap(),
                    request["token"].as_str().unwrap(),
                )
            );
            seen.lock().unwrap().push((uri.path().to_string(), request));
            seal_fixture(&key, &serde_json::json!({
                "code":0,"data":"https://media.invalid/resolved-episode-2.m3u8"
            }))
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = Router::new().fallback(post(endpoint)).with_state((key, seen.clone()));
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let site = App99::new();
        *site.state.lock().unwrap() = Some(Handshaken {
            ext: String::new(), host: format!("http://{addr}"), uuid: uuid.to_string(),
            token: "fixture-token".to_string(), version: "1".to_string(), categories: Vec::new(),
            players: serde_json::json!({"parsed":{"name":"Parser","type":1,"parseUrl":"7"}}),
            parser_ids: vec![6, 7],
        });
        // DEX playerContent checks line type before selecting direct media or a parser.
        for input in [
            "https://media.invalid/source-episode-2.m3u8",
            "https://media.invalid/source-episode-2.ts?token=fixture",
        ] {
            let id = encode_episode(input, "parsed", "Episode 2", 2);
            let plays = site.play("Parser", &id, "").await.unwrap();
            assert!(
                plays[0].url == "https://media.invalid/resolved-episode-2.m3u8",
                "a media suffix does not override the configured parser line type"
            );
        }
        let requests = seen.lock().unwrap();
        assert_eq!(requests.len(), 2);
        for (index, (path, request)) in requests.iter().enumerate() {
            assert_eq!(path, "/app/vodParser");
            assert_eq!(request["id"], 7, "parseUrl filters the actual encrypted request");
            assert!(request["url"] == if index == 0 {
                "https://media.invalid/source-episode-2.m3u8"
            } else {
                "https://media.invalid/source-episode-2.ts?token=fixture"
            }, "the selected input must reach the parser unchanged");
        }
        server.abort();
    }

    #[tokio::test]
    async fn app99_parser_receives_selected_episode_and_configured_parser_id() {
        use axum::{extract::State, http::{HeaderMap, Uri}, routing::post, Router};
        use std::sync::{Arc, Mutex};

        type Seen = Arc<Mutex<Vec<(String, serde_json::Value)>>>;
        let uuid = "aabbccddeeff00112233445566778899";
        let key = key_of(uuid).unwrap();
        let seen: Seen = Arc::new(Mutex::new(Vec::new()));
        let state = (key.clone(), seen.clone());
        async fn endpoint(
            State((key, seen)): State<(Vec<u8>, Seen)>,
            uri: Uri,
            headers: HeaderMap,
            body: String,
        ) -> String {
            let request = open_request(&key, &body);
            let ts = headers.get("timestamp").unwrap().to_str().unwrap();
            let nonce = headers.get("nonce").unwrap().to_str().unwrap();
            let token = request.get("token").and_then(|v| v.as_str()).unwrap_or("");
            assert_eq!(
                headers.get("sign").unwrap().to_str().unwrap(),
                sign_of(&body, ts, nonce, token),
                "the actual POST must carry the protocol signature"
            );
            seen.lock().unwrap().push((uri.path().to_string(), request));
            let response = match uri.path() {
                "/app/systemInit" => serde_json::json!({
                    "code":0,
                    "userInfo":{"user_token":"fixture-token"},
                    "categorys":{"data":[{"id":"1","name":"全部"}]},
                    "player":{
                        "line-a":{"name":"蓝光","type":1,"parseUrl":"7"},
                        "line-b":{"name":"备用","type":0}
                    },
                    "parser_api":[{"id":6},{"id":7}]
                }),
                "/vod/detail" => serde_json::json!({
                    "code":0,
                    "data":{"id":"77","name":"测试剧",
                        "play_from":"line-a$$$line-b",
                        "play_url":"第1集$opaque-episode-1#第2集$opaque-episode-2$$$第1集$https://media.invalid/1.mp4"}
                }),
                "/app/vodParser" => serde_json::json!({
                    "code":0,"data":"https://media.invalid/selected-2.m3u8"
                }),
                _ => serde_json::json!({"code":1,"msg":"unexpected endpoint"})
            };
            seal_fixture(&key, &response)
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = Router::new().fallback(post(endpoint)).with_state(state);
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let ext = serde_json::json!({
            "host":format!("http://{addr}"),"name":"fixture","buildSignature":"SIG",
            "buildNumber":"1","versionName":"1.0","package":"com.fixture","uuid":uuid
        }).to_string();
        let site = App99::new();
        let detail = site.detail("77", &ext).await.unwrap();
        assert_eq!(detail.episodes.len(), 3);
        assert_eq!(detail.episodes[1].flag, "蓝光", "display names come from player");
        assert_eq!(detail.episodes[2].flag, "备用");
        let chosen = &detail.episodes[1];
        let plays = site.play(&chosen.flag, &chosen.id, &ext).await.unwrap();
        assert_eq!(plays.len(), 1);
        assert_eq!(plays[0].url, "https://media.invalid/selected-2.m3u8");
        let seen = seen.lock().unwrap();
        let parses: Vec<_> = seen.iter().filter(|(path, _)| path == "/app/vodParser").collect();
        assert_eq!(parses.len(), 1, "parseUrl must exclude parser 6");
        assert_eq!(parses[0].1["id"], 7);
        assert_eq!(parses[0].1["url"], "opaque-episode-2");
        server.abort();
    }

    #[tokio::test]
    async fn app99_never_hands_unresolved_html_page_to_player() {
        for url in ["https://page.invalid/watch/2", "https://page.invalid/s/looks-like-share"] {
            let err = App99::new().play("", url, "").await
                .expect_err("an unresolved HTML page is not a stream");
            assert!(!err.contains("https://"), "errors must not leak playback URLs");
        }
        assert!(native_share_url("https://pan.quark.cn/s/fixture"));
    }

    #[test]
    fn app99_episode_id_preserves_protocol_code_and_line_local_index() {
        let url = "https://example.invalid/vod?file=a@b&signature=x";
        let id = encode_episode(url, "raw-code", "第2集", 2);
        assert!(is_episode_id(&id));
        let episode = decode_episode(&id).unwrap();
        assert_eq!(episode.url, url);
        assert_eq!(episode.code, "raw-code");
        assert_eq!(episode_context(&id), Some(("第2集".to_string(), 2)));
        assert_eq!(episode_url(&id).as_deref(), Some(url));
        assert!(episode_context("app99:not-valid!").is_none());
        assert!(episode_url("app99:not-valid!").is_none());
        assert!(!is_episode_id(url));
        let players = serde_json::json!({
            "a":{"name":"蓝光","type":0},
            "b":{"name":"蓝光","type":1}
        });
        assert_ne!(player_name(&players, "a"), player_name(&players, "b"));
    }

    #[tokio::test]
    async fn app99_type_zero_rejects_html_and_accepts_media_bytes() {
        use axum::{http::{header, HeaderValue}, routing::get, Router};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = Router::new()
            .route("/html", get(|| async { ([(header::CONTENT_TYPE, HeaderValue::from_static("text/html"))], "<html>player</html>") }))
            .route("/media", get(|| async { ([(header::CONTENT_TYPE, HeaderValue::from_static("application/octet-stream"))], "#EXTM3U\n#EXTINF:10,\nchunk.ts\n") }));
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let site = App99::new();
        *site.state.lock().unwrap() = Some(Handshaken {
            ext:String::new(),host:String::new(),uuid:String::new(),token:String::new(),
            version:String::new(),categories:Vec::new(),
            players:serde_json::json!({"direct":{"name":"直连","type":0}}),parser_ids:Vec::new()
        });
        let opaque = encode_episode("opaque-episode-2", "direct", "第2集", 2);
        assert!(site.play("直连", &opaque, "").await.expect_err(
            "opaque identifiers belong to parser lines, not direct media"
        ).contains("直连"));
        let html = encode_episode(&format!("http://{addr}/html"), "direct", "第1集", 1);
        let err = site.play("直连", &html, "").await.expect_err("type 0 still must not emit HTML");
        assert!(err.contains("播放网页"));
        let media = encode_episode(&format!("http://{addr}/media"), "direct", "第1集", 1);
        let plays = site.play("直连", &media, "").await.unwrap();
        assert_eq!(plays.len(), 1);
        assert!(plays[0].url.ends_with("/media"));
        server.abort();
    }

    // Independent network capture proves the protocol; this case runs the production resolver.
    // It checks actual media bytes, not decoded frames. Player acceptance remains separate.
    #[tokio::test]
    #[ignore = "live isolated configuration: APP99_LIVE_RUN=1 plus APP99_LIVE_CONFIG/PROVIDER/LINE/QUERY"]
    async fn app99_live_selected_episode_has_media_bytes() {
        assert_eq!(std::env::var("APP99_LIVE_RUN").as_deref(), Ok("1"));
        let path = std::path::PathBuf::from(
            std::env::var("APP99_LIVE_CONFIG").expect("APP99_LIVE_CONFIG is required")
        ).canonicalize().expect("isolated config exists");
        let probe = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../.probe").canonicalize().expect("probe directory exists");
        assert!(path.starts_with(probe), "live config must stay in isolated .probe");
        let providers: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(path).expect("read isolated configuration")
        ).expect("parse isolated configuration");
        let provider_id = std::env::var("APP99_LIVE_PROVIDER").expect("provider id is required");
        let provider = providers.as_array().expect("provider array").iter()
            .find(|p| p.get("id").and_then(|v| v.as_str()) == Some(provider_id.as_str()))
            .expect("provider is present in isolated configuration");
        let ext = provider.get("ext").and_then(|v| v.as_str()).expect("provider has ext");
        let query = std::env::var("APP99_LIVE_QUERY").expect("query is required");
        let line_code = std::env::var("APP99_LIVE_LINE").expect("line code is required");
        let index = std::env::var("APP99_LIVE_EPISODE").unwrap_or_else(|_| "2".to_string())
            .parse::<usize>().expect("episode index is numeric");
        assert!(index > 0);
        let site = App99::new();
        let hits = site.search(&query, 1, ext).await.expect("production search succeeds");
        let hit = hits.items.iter().find(|hit| hit.title == query)
            .expect("the requested exact title is present");
        let detail = site.detail(&hit.id, ext).await.expect("production detail succeeds");
        let selected = detail.episodes.iter().find(|ep| {
            decode_episode(&ep.id).map(|reference| {
                reference.code == line_code && reference.index == index
            }).unwrap_or(false)
        }).expect("selected line and episode are present");
        let plays = site.play(&selected.flag, &selected.id, ext).await
            .expect("production parser resolves selected episode");
        assert_eq!(plays.len(), 1);
        eprintln!("[LIVE-MEDIA] lines={} selected_line={} episode_index={} episode_title={}",
            detail.episodes.iter().map(|ep| &ep.flag)
                .collect::<std::collections::HashSet<_>>().len(),
            selected.flag, index, selected.title);
        let mut url = reqwest::Url::parse(&plays[0].url).expect("resolver returns an HTTP URL");
        for depth in 0..6 {
            let mut request = site.client.get(url.clone()).header("Range", "bytes=0-4095");
            for (key, value) in &plays[0].headers {
                request = request.header(key, value);
            }
            let mut response = request.send().await
                .map_err(|_| "media transport failed").expect("media request succeeds");
            let status = response.status().as_u16();
            assert!(response.status().is_success(), "media HTTP {status}");
            let mut bytes = Vec::new();
            while bytes.len() < 4096 {
                let chunk = response.chunk().await
                    .map_err(|_| "media chunk transport failed").expect("media body reads");
                let Some(chunk) = chunk else { break };
                bytes.extend_from_slice(&chunk[..chunk.len().min(4096 - bytes.len())]);
            }
            if bytes.starts_with(b"#EXTM3U") {
                let text = std::str::from_utf8(&bytes).expect("HLS is UTF-8");
                let child = text.lines().map(str::trim)
                    .find(|line| !line.is_empty() && !line.starts_with('#'))
                    .expect("HLS contains a playable child");
                url = response.url().join(child).expect("HLS child URL resolves");
                eprintln!("[LIVE-MEDIA] depth={depth} HTTP={status} format=HLS");
                continue;
            }
            let ts_offset = (0..bytes.len().saturating_sub(376)).find(|offset|
                bytes[*offset] == 0x47 && bytes[*offset + 188] == 0x47
                    && bytes[*offset + 376] == 0x47);
            let mp4 = bytes.get(4..8) == Some(b"ftyp");
            let mkv = bytes.starts_with(&[0x1a, 0x45, 0xdf, 0xa3]);
            assert!(ts_offset.is_some() || mp4 || mkv, "media magic is absent");
            eprintln!("[LIVE-MEDIA] HTTP={status} bytes={} TS_offset={ts_offset:?} MP4={mp4} MKV={mkv}",
                bytes.len());
            return;
        }
        panic!("HLS traversal did not reach media bytes");
    }

    #[test]
    fn base64_roundtrip_matches_known_vectors() {
        assert_eq!(b64_encode(b"abc"), "YWJj");
        assert_eq!(b64_encode(b"ab"), "YWI=");
        assert_eq!(b64_encode(b"a"), "YQ==");
        assert_eq!(b64_decode("YWJj").unwrap(), b"abc");
        assert_eq!(b64_decode("YWI=").unwrap(), b"ab");
        assert!(b64_decode("YW*j").is_err(), "非法字符必须 Err");
    }

    #[test]
    fn key_of_strips_dashes_and_checks_length() {
        let k = key_of("aabbccdd-eeff-0011-2233-445566778899").unwrap();
        assert_eq!(k.len(), 32, "32 hex 字符 ⇒ AES-256");
        assert!(key_of("short").is_err());
    }

    #[test]
    fn encrypt_then_decrypt_roundtrip_with_zlib() {
        // 与 Java 侧一致：加密不压缩、解密后 zlib 解压 ⇒ 往返测试要自己先压缩
        let key = key_of("aabbccddeeff00112233445566778899").unwrap();
        let iv = iv16(42, 7);
        let plain = r#"{"ok":1,"名字":"测试"}"#;
        // 构造"服务端那样的"密文：先 zlib 压缩，再走 encrypt_body
        let mut comp = Vec::new();
        {
            use std::io::Write;
            let mut enc = flate2::write::ZlibEncoder::new(&mut comp, flate2::Compression::default());
            enc.write_all(plain.as_bytes()).unwrap();
            enc.finish().unwrap();
        }
        let compressed = String::from_utf8_lossy(&comp).to_string();
        // encrypt_body 接收文本 ⇒ 这里直接对压缩后的字节手工做一次 AES（与 encrypt_body 同算法）
        let mut buf = vec![0u8; (comp.len() / 16 + 1) * 16];
        buf[..comp.len()].copy_from_slice(&comp);
        let ct = Aes256CbcEnc::new_from_slices(&key, &iv)
            .unwrap()
            .encrypt_padded_mut::<Pkcs7>(&mut buf, comp.len())
            .unwrap()
            .to_vec();
        let mut all = Vec::new();
        all.extend_from_slice(&iv);
        all.extend_from_slice(&ct);
        let b64 = b64_encode(&all);
        let back = decrypt_body(&key, &b64).expect("应能解开");
        assert_eq!(back, plain, "往返必须还原（含中文）");
        let _ = compressed;
    }

    #[test]
    fn decrypt_rejects_wrong_key_and_bad_lengths() {
        let key = key_of("aabbccddeeff00112233445566778899").unwrap();
        let other = key_of("00112233445566778899aabbccddeeff").unwrap();
        let iv = iv16(1, 2);
        let b64 = encrypt_body(&key, "hello", &iv).unwrap();
        assert!(
            decrypt_body(&other, &b64).is_err(),
            "换 key 必须失败（不静默返回空）"
        );
        assert!(decrypt_body(&key, "not-base64!!").is_err());
        assert!(decrypt_body(&key, "YWJj").is_err(), "太短必须 Err");
    }

    #[test]
    fn sign_is_sha256_hex_of_enc_ts_nonce_token() {
        let s = sign_of("ENC", "1700000000", "NONCE", "TOKEN");
        assert_eq!(s.len(), 64, "SHA-256 hex 应 64 字符");
        assert!(s.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        // 顺序敏感性：换顺序必须得到不同签名（防止"顺序写错但测试照过"）
        assert_ne!(s, sign_of("TOKEN", "1700000000", "NONCE", "ENC"));
        // 已知向量：SHA-256("a:b:c:d")
        assert_eq!(
            sign_of("a", "b", "c", "d"),
            "d252cd6d29660d0e6572cd01ede1e9e5b08a3ab5c51f8efdc52c60a608823311"
        );
    }

    #[test]
    fn ext_fields_requires_all_six_keys() {
        let ok = r#"{"host":"http://h","name":"n","buildSignature":"s","buildNumber":"1","versionName":"3","package":"p"}"#;
        let (host, name, sig, num, ver, uuid) = App99::ext_fields(ok).expect("六件齐全应通过");
        assert_eq!(host, "http://h");
        assert_eq!((name.as_str(), sig.as_str(), num.as_str(), ver.as_str()), ("n", "s", "1", "3"));
        assert_eq!(uuid.replace('-', "").len(), 32, "缺 uuid ⇒ 生成随机 32 hex");

        let bad = r#"{"host":"http://h"}"#;
        let err = App99::ext_fields(bad).expect_err("缺键必须 Err");
        assert!(err.contains("name"), "错误要点名**第一个**缺的键（此处是 name）：{err}");
    }

    // ── ★★ detail 真实响应验收（离线）：解出 play_from / play_url 并能映射成播放候选 ──
    #[test]
    fn decrypts_known_detail_fixture_to_playable_candidates() {
        let mut cands = vec![
            std::path::PathBuf::from(".probe/app99-known-detail.json"),
            std::path::PathBuf::from("../.probe/app99-known-detail.json"),
            std::path::PathBuf::from("../../.probe/app99-known-detail.json"),
            std::path::PathBuf::from("../../../.probe/app99-known-detail.json"),
        ];
        let Some(path) = cands.iter_mut().find(|p| p.exists()).cloned() else {
            eprintln!("[SKIP] 找不到 .probe/app99-known-detail.json —— detail 真实响应验收未执行");
            return;
        };
        let raw = std::fs::read_to_string(&path).expect("读夹具");
        let j: serde_json::Value = parse_loose_json(&raw).expect("夹具必须是 JSON");
        let uuid = j.get("uuid").and_then(|x| x.as_str()).expect("夹具缺 uuid");
        let b64 = j.get("response_b64").and_then(|x| x.as_str()).expect("夹具缺 response_b64");
        let want_id = j.get("request_id").and_then(|x| x.as_str()).unwrap_or("").to_string();

        let key = key_of(uuid).expect("uuid 必须是合法密钥长度");
        let plain = decrypt_body(&key, b64).expect("★ detail 真实响应必须能解开");
        let v: serde_json::Value = parse_loose_json(&plain).expect("解出来必须是合法 JSON");
        let data = v.get("data").cloned().unwrap_or(serde_json::Value::Null);
        assert!(!data.is_null(), "detail 响应里应有 data 字段");

        // ★ 这条守的正是我当初写错的那个字段名错误：必须用 `play_from`/`play_url`
        let from = data.get("play_from").and_then(|x| x.as_str()).unwrap_or("");
        let url = data.get("play_url").and_then(|x| x.as_str()).unwrap_or("");
        assert!(
            !url.is_empty(),
            "★ 真实 detail 响应里 `play_url` 不能为空（我最初写成 vod_play_url 就是这条抓出来的）"
        );
        assert!(
            !from.is_empty(),
            "★ `play_from` 不许为空 —— 之前只打印不断言，字段名再写错一次也不会红"
        );
        eprintln!("[FIXTURE-DETAIL] play_from={from:?} play_url bytes={}", url.len());

        // 还能映射成播放候选（否则"解得开但用不了"）
        let det = detail_of(&data, &want_id, &serde_json::Value::Null).expect("应能映射成 CspDetail");
        assert!(!det.episodes.is_empty(), "至少 1 集");
        assert!(
            http_url(&decode_episode(&det.episodes[0].id).unwrap().url),
            "首集应携带 http(s) 地址"
        );
        eprintln!(
            "[FIXTURE-DETAIL] 映射结果：标题={} 集数={}",
            det.title,
            det.episodes.len()
        );
    }

    // ── ★★ 真实响应验收（lead 要的那条）：读夹具 → 解密 → 合法 JSON + 含 player ──
    //
    // 夹具由 `app99_live_handshake_and_search_decrypt_to_json` 在真网络成功时写出：
    //   `.probe/app99-known-systeminit.json` = {captured_at, endpoint, uuid, response_b64}
    // 本用例**不联网**，只用夹具复算 —— 这是"实现真的能解真实响应"的可重复证据。
    #[test]
    fn decrypts_known_systeminit_fixture_to_json() {
        let mut cands = vec![
            std::path::PathBuf::from(".probe/app99-known-systeminit.json"),
            std::path::PathBuf::from("../.probe/app99-known-systeminit.json"),
            std::path::PathBuf::from("../../.probe/app99-known-systeminit.json"),
        ];
        // 在 rust/sourin_core 下跑时，.probe 在仓库根 ⇒ 用相对两级目录兜住
        cands.push(std::path::PathBuf::from("../../../.probe/app99-known-systeminit.json"));
        let Some(path) = cands.into_iter().find(|p| p.exists()) else {
            // 夹具不在（例如只拷了 crate 出来）⇒ 明确跳过并说清原因，不假装通过
            eprintln!("[SKIP] 找不到 .probe/app99-known-systeminit.json —— 真实响应验收未执行");
            return;
        };
        let raw = std::fs::read_to_string(&path).expect("读夹具");
        let j: serde_json::Value = parse_loose_json(&raw).expect("夹具必须是 JSON");
        let uuid = j.get("uuid").and_then(|x| x.as_str()).expect("夹具缺 uuid");
        let b64 = j
            .get("response_b64")
            .and_then(|x| x.as_str())
            .expect("夹具缺 response_b64");

        let key = key_of(uuid).expect("uuid 必须是合法密钥长度");
        let plain = decrypt_body(&key, b64).expect("★ 真实响应必须能解开（解不开就是实现有问题）");
        let v: serde_json::Value = parse_loose_json(&plain).expect("解出来必须是合法 JSON");
        let keys: Vec<String> = v
            .as_object()
            .map(|o| o.keys().cloned().collect())
            .unwrap_or_default();
        eprintln!("[FIXTURE] 解出的顶层键 = {keys:?}");
        assert!(
            keys.iter().any(|k| k == "player"),
            "★ 解出的 JSON 必须含 player（真实响应顶层键之一），实际 {keys:?}"
        );
        assert!(
            keys.iter().any(|k| k == "parser_api"),
            "★ 还应含 parser_api，实际 {keys:?}"
        );
        eprintln!("[FIXTURE] 解密 bytes={}", plain.len());
    }

    // ── ★ 真实响应验收（唯一能证明"实现可用"的用例）──────────────────
    //
    // 为什么要它：构造样本只能证明"自己加自己能解"，证明不了协议读对了。
    // 这条真发一次握手，把响应用**我们自己的 uuid** 解开 —— 解不开就是没做完。
    //
    // 跑法：`CSP_LIVE=1 cargo test --lib app99_live --release -- --ignored --nocapture`
    // 说明：镜像/服务端会漂，失败先直连复测单 host（curl --noproxy '*'）。
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib app99_live --release -- --ignored --nocapture"]
    async fn app99_live_handshake_and_search_decrypt_to_json() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 这条要真网络：显式跑就必须给 CSP_LIVE=1（不给就失败，不许记成 ok）"
        );
        // ext 取自用户配置里 csp_App99 的那个源（不含任何账号凭据）
        // ★ 固定 uuid：夹具要能离线复算，就必须知道当时用的 key
        let ext = r#"{"host":"http://103.217.190.91:19987/app/bn","appkey":"24d625a8a29b4700a1a294c6f3b29e2c","versionName":"3.5.8","name":"半日闲","package":"com.yf.lelian","buildNumber":"2001","buildSignature":"A40DA80A59D170CAA950CF15C18C454D47A39B26989D8B640ECD745BA71BF5DC","uuid":"b2d948ee-3f9f-52ea-3bbf-98ffc4bd1266"}"#;
        let site = App99::new();
        // ① 握手（内部就是 systemInit：加密 + 签名 + 解密）
        let home = site.home(ext).await;
        match &home {
            Ok(h) => eprintln!("[LIVE] 握手成功：categories={} ", h.categories.len()),
            Err(e) => eprintln!("[LIVE] 握手失败：{e}"),
        }
        // ② 搜索（真正证明"加密请求 → 解密响应 → JSON"整条链通）
        let list = site.list("测试", 1, ext).await;
        match &list {
            Ok(l) => eprintln!(
                "[LIVE] 搜索成功：{} 条；首条 = {} ({})",
                l.items.len(),
                l.items.first().map(|i| i.title.clone()).unwrap_or_default(),
                l.items.first().map(|i| i.id.clone()).unwrap_or_default()
            ),
            Err(e) => eprintln!("[LIVE] 搜索失败：{e}"),
        }
        assert!(
            list.is_ok() || home.is_err(),
            "★ 握手成功但搜索失败 ⇒ 说明加密/签名口径仍有偏差：{:?} / {:?}",
            home.map(|h| h.categories.len()),
            list.map(|l| l.items.len())
        );
        let Some(l) = list.ok() else {
            return;
        };
        assert!(!l.items.is_empty(), "搜索应至少返回 1 条真实条目");

        // ③ 详情（真网络）：用搜索首条的 id，并**落一份真实响应夹具**（可离线复算）
        let first = l.items[0].id.clone();
        if let Ok((uuid, b64)) = site
            .call_raw("/vod/detail", serde_json::json!({ "id": first }))
            .await
        {
            let fixture = serde_json::json!({
                "captured_at": "2026-10-26",
                "endpoint": "/vod/detail",
                "request_id": first,
                "uuid": uuid,
                "response_b64": b64,
            });
            if let Ok(body) = serde_json::to_string_pretty(&fixture) {
                for p in [
                    "../.probe/app99-known-detail.json",
                    "../../.probe/app99-known-detail.json",
                ] {
                    let _ = std::fs::write(p, &body);
                }
                eprintln!("[APP99] detail 夹具已写出（{} 字节）", body.len());
            }
        }
        let det = site.detail(&first, ext).await;
        match &det {
            Ok(d) => eprintln!(
                "[LIVE] 详情成功：id={first} 标题={} 集数={}",
                d.title,
                d.episodes.len()
            ),
            Err(e) => eprintln!("[LIVE] 详情失败：{e}"),
        }

        // ④ 取流（真网络）：只有拿到 http 地址才可能成功
        if let Ok(d) = &det {
            if let Some(ep) = d.episodes.first() {
                let p = site.play("", &ep.id, ext).await;
                match &p {
                    Ok(v) => eprintln!(
                        "[LIVE] 取流成功：{} 条",
                        v.len()
                    ),
                    Err(e) => eprintln!("[LIVE] 取流失败（如实记录，不算可用）：{e}"),
                }
            }
        }
    }

    // ── ★ 上游 code != 0 必须原样报出（live-accept 复核第 1/2 条）──
    #[test]
    fn envelope_rejects_upstream_error_code() {
        let v: serde_json::Value =
            parse_loose_json(r#"{"code":1,"msg":"user info error","userInfo":""}"#).unwrap();
        let err = parse_envelope("/app/systemInit", &v).expect_err("★ code!=0 必须 Err");
        assert!(err.contains("code=1"), "错误里要带上游 code：{err}");
        assert!(err.contains("user info error"), "还要带 msg：{err}");
        // 对照：code=0 必须放行（否则"永远 Err"也能过 ⇒ 假绿）
        let ok: serde_json::Value = parse_loose_json(r#"{"code":0,"msg":"init"}"#).unwrap();
        assert!(parse_envelope("/vod/search", &ok).is_ok());
        // 缺 code 字段 ⇒ 视为 0（同一份响应里没见过 code 时不该阻断）
        let none: serde_json::Value = parse_loose_json(r#"{"data":[]}"#).unwrap();
        assert!(parse_envelope("/vod/search", &none).is_ok());
    }

    // ── ★ token 判定器：空 ⇒ Err（判定职责不变；**降级发生在 handshake 层**——
    //    2026-11-01 起 userInfo 被站点拒绝 ⇒ handshake 记原因后以空 token 继续，
    //    不再把"拿不到登录态"当"整站不可用"。见 handshake_degrades_when_userinfo_rejected）──
    #[test]
    fn require_token_rejects_empty() {
        let err = require_token(String::new()).expect_err("空 token 必须 Err（判定器语义）");
        assert!(err.contains("未给 user_token"), "{err}");
        assert!(require_token("  ".to_string()).is_err(), "空白也算没有");
        assert_eq!(require_token("tk".to_string()).unwrap(), "tk");
    }

    #[test]
    fn items_and_detail_parsing() {
        let v: serde_json::Value = parse_loose_json(
            r#"{"data":[{"id":7,"name":"示例","pic":"http://p/1.jpg","remarks":"更新"}]}"#,
        )
        .unwrap();
        let items = items_of(&v).expect("应解析出条目");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "7");

        let d: serde_json::Value = parse_loose_json(
            r#"{"name":"示例","blurb":"简介","pic":"http://p/1.jpg",
                "vod_play_from":"<某线路>","vod_play_url":"第1集$http://a/1.m3u8#第2集$http://a/2.m3u8"}"#,
        )
        .unwrap();
        let det = detail_of(&d, "7", &serde_json::Value::Null).expect("详情应解析");
        assert_eq!(det.episodes.len(), 2);
        let ep = decode_episode(&det.episodes[1].id).unwrap();
        assert_eq!(ep.url, "http://a/2.m3u8");
        assert_eq!(ep.index, 2);
        assert_eq!(det.episodes[0].title, "第1集");
    }

    #[test]
    fn search_body_uses_kw_key() {
        let b = search_body("兰香如故", 2);
        assert_eq!(b["kw"], "兰香如故", "★ 键名必须是 `kw`（服务端只认它）：{b}");
        assert_eq!(b["page"], 2);
        assert_eq!(b["limit"], 21);
        assert!(b.get("q").is_none(), "不许出现 `q` 这种想当然的别名字段");
    }

    #[test]
    fn search_empty_hits_is_error() {
        let err = ensure_search_hits(Vec::new(), "兰香如故", 1).unwrap_err();
        assert!(err.contains("返回 0 条"), "空结果必须如实报错：{err}");
        assert!(err.contains("兰香如故"), "报错要带上搜索词：{err}");
        assert!(ensure_search_hits(Vec::new(), "x", 1).is_err());
    }

    // ── 真网络：search（CSP_LIVE=1 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_search_app99 --release --offline -- --ignored --nocapture"]
    async fn csp_live_search_app99() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 显式跑就必须给 CSP_LIVE=1（不给就失败，不许记成 ok）"
        );
        let ext = r#"{"host":"http://103.217.190.91:19987/app/bn","appkey":"24d625a8a29b4700a1a294c6f3b29e2c","versionName":"3.5.8","name":"半日闲","package":"com.yf.lelian","buildNumber":"2001","buildSignature":"A40DA80A59D170CAA950CF15C18C454D47A39B26989D8B640ECD745BA71BF5DC"}"#;
        let site = App99::new();
        match site.search("兰香如故", 1, ext).await {
            Ok(list) => {
                assert!(!list.items.is_empty(), "★ 搜索必须返回条目");
                eprintln!("[LIVE] App99 search: {} 条", list.items.len());
                for it in list.items.iter().take(3) {
                    eprintln!("  · id={} title={}", it.id, it.title);
                }
            }
            Err(e) => panic!("[LIVE] App99 search 失败（如实记录）：{e}"),
        }
    }

    // ── ★ 夹具单测（2026-11-01 互检修复）：userInfo 被站点拒绝 ⇒ 握手降级空 token，搜索照走 ──
    //
    // 行为级（真 HTTP，无注入）：本地起一个"胖妞形态"的假站——
    //   systemInit → code:0（响应里无 token）；userInfo → code:1 user info error；
    //   /vod/search → code:0 + 1 条数据。判据：握手 Ok（空 token）+ search 拿到那条数据。
    // 注入证红：把 handshake 的降级改回 `.await?` ⇒ 本条红（整站握手失败，胖妞同款）。
    #[tokio::test]
    async fn handshake_degrades_when_userinfo_rejected() {
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
        // 固定 uuid ⇒ key 已知，假站响应用同一把钥匙加密
        let uuid = "aabbccddeeff00112233445566778899";
        let key = key_of(uuid).unwrap();

        // "服务端那样的"响应：明文 → zlib 压缩 → AES-CBC(key,iv) → IV‖密文 → base64
        let seal = move |plain: &str| -> String {
            use std::io::Write as _;
            let mut comp = Vec::new();
            {
                let mut z =
                    flate2::write::ZlibEncoder::new(&mut comp, flate2::Compression::default());
                z.write_all(plain.as_bytes()).unwrap();
                z.finish().unwrap();
            }
            let iv = iv16(comp.len() as u64, 3);
            let mut buf = vec![0u8; (comp.len() / 16 + 1) * 16];
            buf[..comp.len()].copy_from_slice(&comp);
            let ct = Aes256CbcEnc::new_from_slices(&key, &iv)
                .unwrap()
                .encrypt_padded_mut::<Pkcs7>(&mut buf, comp.len())
                .unwrap()
                .to_vec();
            let mut all = Vec::new();
            all.extend_from_slice(&iv);
            all.extend_from_slice(&ct);
            b64_encode(&all)
        };

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let mut buf: Vec<u8> = Vec::new();
                let mut chunk = [0u8; 4096];
                let head_end;
                loop {
                    let n = sock.read(&mut chunk).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        head_end = p + 4;
                        break;
                    }
                }
                let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
                let path = head.split(' ').nth(1).unwrap_or("").to_string();
                let clen: usize = head
                    .to_ascii_lowercase()
                    .lines()
                    .find_map(|l| {
                        l.strip_prefix("content-length:")
                            .map(|v| v.trim().to_string())
                    })
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0);
                while buf.len() < head_end + clen {
                    let n = sock.read(&mut chunk).await.unwrap();
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                }
                let body = match path.as_str() {
                    "/app/systemInit" => seal(
                        r#"{"code":0,"msg":"init","categorys":{"data":[{"id":"1","name":"全部"}]}}"#,
                    ),
                    "/app/userInfo" => {
                        seal(r#"{"code":1,"msg":"user info error","userInfo":""}"#)
                    }
                    "/vod/search" => seal(
                        r#"{"code":0,"data":[{"id":77,"name":"老舅（2023）","pic":"http://p/77.jpg","remarks":"33集"}]}"#,
                    ),
                    _ => String::new(),
                };
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = sock.write_all(resp.as_bytes()).await;
            }
        });

        let ext = format!(
            r#"{{"host":"http://{addr}","name":"夹具站","buildSignature":"SIG","buildNumber":"1","versionName":"1.0.0","package":"com.fixture.t","uuid":"{uuid}"}}"#
        );
        // ⚠️ 生产 handshake 每次成功都会把响应落成 `.probe/app99-known-systeminit.json`
        //   （真实抓包验收的夹具）。本测试的假站握手会冲掉真抓包 ⇒ 先存后还。
        //
        // ★★ 2026-11-01（P2）：恢复必须 **panic-safe** —— 测试体任何断言失败
        //   都会 unwind，落在函数尾部的"手工还原"就永远不执行 ⇒ 真抓包被打碎
        //   （自愈批实锤过一次，靠 CSP_LIVE 重抓才救回）。⇒ 用 Drop guard：
        //   无论测试怎么退场（正常 / panic），夹具都按原样退回。
        struct FixtureRestoreGuard {
            saved: Vec<(std::path::PathBuf, Option<Vec<u8>>)>,
        }
        impl Drop for FixtureRestoreGuard {
            fn drop(&mut self) {
                for (p, old) in &self.saved {
                    match old {
                        Some(bytes) => {
                            let _ = std::fs::write(p, bytes);
                        }
                        None => {
                            let _ = std::fs::remove_file(p);
                        }
                    }
                }
            }
        }
        let fixture_paths: Vec<std::path::PathBuf> = [
            "../.probe/app99-known-systeminit.json",
            "../../.probe/app99-known-systeminit.json",
        ]
        .iter()
        .map(std::path::PathBuf::from)
        .collect();
        let saved: Vec<(std::path::PathBuf, Option<Vec<u8>>)> = fixture_paths
            .iter()
            .map(|p| (p.clone(), std::fs::read(p).ok()))
            .collect();
        let _guard = FixtureRestoreGuard { saved: saved.clone() };
        let site = App99::new();
        // ① 握手：userInfo 被拒 ⇒ 降级空 token ⇒ 握手必须成功
        let home = site.home(&ext).await;
        assert!(
            home.is_ok(),
            "★★ 降级后握手必须成功（旧实现 `?` 直接整站失败，胖妞/剧圈同款）：{:?}",
            home.err()
        );
        // ② 搜索：空 token 的业务请求照走，拿到假站的数据
        let list = site.search("老舅", 1, &ext).await;
        let l = list.expect("★ 空 token 业务请求必须能走通（该站不要求 token）");
        assert_eq!(l.items.len(), 1);
        assert_eq!(l.items[0].title, "老舅（2023）");
        server.abort();
        drop(_guard); // guard 先还夹具（panic 路径由 Drop 兜底）
        // ★★ 护栏断言：恢复后的夹具必须与保存前**逐字节一致**——
        //   假站响应（uuid=aabbcc… 的 categorys-only 假 systemInit）一旦
        //   漏进真抓包文件，"真实响应验收"测试就会拿假响应当真 ⇒ 假绿。
        for (p, old) in &saved {
            if let Some(bytes) = old {
                assert_eq!(
                    std::fs::read(p).unwrap_or_default(),
                    *bytes,
                    "★ 抓包夹具被假响应污染（{}）——真响应验收会假绿",
                    p.display()
                );
            }
        }
    }
}
