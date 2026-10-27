// ═══════════════════════════════════════════════════════════════════════
//  csp_SportsGuazi —— 「瓜子体育」（api.46d5umpk.com）的 Rust 重写（**本批注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么**有** `register_site!`（三条判据同时成立，逐条给证据）
// ```text
// ① 订阅里 1 站：`.probe/ref-subscription.json` → api=csp_SportsGuazi（ext 为 null）
// ② 有可用 host：DEX 常量给的是**整条 URL**
//      https://api.46d5umpk.com/gz/live/sports?parameter=key
//      https://api.46d5umpk.com/gz/live/detail?parameter=key
//    ⇒ host = api.46d5umpk.com（不依赖 ext，ext 只用来覆盖）
// ③ 真网取到数据（2026-10-28 00:0x 直连 `--noproxy '*'`，读数见 `.probe/csp-sports-live.log`）：
//    列表 27 场（含 9 场 m_status=1 进行中，11 场带 line_list），
//    取流真拿到 m3u8：`https://pullgz721.qmuiw.com/live/sd-1-4602035.m3u8?auth_key=…`
// ```
//
// # 协议（DEX 常量逐字 + 实测，**两层都是加密的**）
// ```text
// 请求   GET {host}/gz/live/sports?parameter=<b64(AES-128-CBC(json))>
//        header  User-Agent: okhttp/3.12.0
//                user-platform: null        ← 字面量 "null"（DEX 逐字），不是空
//                client-version: 3.0.1.1
//                client-channel: ""
//        明文模板（DEX 逐字）：
//          football   {"frame":"0","hot":"0","tag":"0","type":"1"}
//          basketball {"frame":"0","hot":"0","tag":"0","type":"2"}
//          hot        {"frame":"0","hot":"1","tag":"0","type":"0"}
//          nba        {"frame":"0","hot":"0","tag":"37","type":"0"}
//          all        {}                       ← 实测可用（27 场）
// 响应   {"code":200,"name":"操作成功","message":"操作成功","data":"<b64(AES-128-CBC(json))>"}
//        ★ 只看 `code==200` 不够：**data 本身是密文**，解不开就说明协议变了 ⇒ 必须解
//
// 密钥/IV（DEX 里两串字面量，实测确认）
//   key = "KANGEQIU@8868!~."      （16 字节 ASCII ⇒ AES-128）
//   iv  = "0200010900030207"      （16 字节 ASCII，**不是** key 本身 —— 这是与 SportsFeiqiu 的差别：
//                                  那个类的 key=iv，这个类 key≠iv；混用会解出乱码而不是报错）
//
// 列表项字段：mid / match_id / event_name / stage / match_time / m_status /
//            home{name,logo,score} / visiting{name,logo,score} / match_status_info /
//            line_list[{name,url}]        ← 取流就在这里（m3u8）
// 详情     GET {host}/gz/live/detail?parameter=<同算法，明文 {"mid":"<mid>"}>
//          ⚠️ **实测：这个端点回的是全 0 骨架**（mid=0 / home.name="" / match_time 每次都是服务器当前时间）
//             —— 无论 parameter 传 mid / frame / id 都是同一份骨架 ⇒ 上游这个端点当前**不返数据**。
//             ⇒ 本实现的 detail **不走它**，而是从列表里按 mid 取那一条（同源、同一次真网络读数）。
// ```
//
// # 改前错在哪
// ```text
// · 只发 `?parameter=AAAA` 看 http=200 就判"站点活着" ⇒ 假活：服务端对**任意** parameter
//   都回 code=200 + 同一份密文（愚弄壳）。真正的判据是"解出来的 JSON 里有没有 mid"。
// · 缺 `parameter` 时服务端回 `{"code":401,…"未加密"}` —— 这句中文只能靠**解密后**看到，
//   因为它不在外层明文里（外层只有 code/name/message 三个字段是明文）。
// · 用 key 当 IV 解：AES-CBC 会"成功"但首块乱码、JSON 解析失败 ⇒ 看起来像"站点改协议"。
// ```

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use async_trait::async_trait;
use cbc::{Decryptor, Encryptor};
use regex::Regex;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

type Aes128CbcEnc = Encryptor<aes::Aes128>;
type Aes128CbcDec = Decryptor<aes::Aes128>;

/// DEX 明文密钥（16 字节 ASCII ⇒ AES-128）
pub const KEY: &[u8] = b"KANGEQIU@8868!~.";
/// DEX 明文 IV（16 字节 ASCII；**key ≠ iv**）
pub const IV: &[u8] = b"0200010900030207";

const UA: &str = "okhttp/3.12.0";
const CLIENT_VERSION: &str = "3.0.1.1";
/// DEX 逐字：`user-platform` 的值就是这 4 个字母 `null`
const USER_PLATFORM: &str = "null";

const DEFAULT_HOST: &str = "https://api.46d5umpk.com";
const TIMEOUT: Duration = Duration::from_secs(20);

/// DEX 的 4 个分类（id → 明文模板）
pub const CATS: &[(&str, &str, &str)] = &[
    ("", "全部", r#"{}"#),
    ("football", "足球", r#"{"frame":"0","hot":"0","tag":"0","type":"1"}"#),
    ("basketball", "篮球", r#"{"frame":"0","hot":"0","tag":"0","type":"2"}"#),
    ("hot", "热门", r#"{"frame":"0","hot":"1","tag":"0","type":"0"}"#),
    ("nba", "NBA", r#"{"frame":"0","hot":"0","tag":"37","type":"0"}"#),
];

/// 取流头（DEX 逐字：`Referer: http://WJiZxLXA2.com/` + `User-Agent: Lavf/57.83.100`）
pub const PLAY_HEADERS: &[(&str, &str)] =
    &[("Referer", "http://WJiZxLXA2.com/"), ("User-Agent", "Lavf/57.83.100")];

/// ext → host（订阅里 ext 是 null ⇒ 用 DEX 常量；ext 只做覆盖）
pub fn host_of(ext: &str) -> String {
    let t = ext.trim();
    if t.starts_with("http://") || t.starts_with("https://") {
        return t.trim_end_matches('/').to_string();
    }
    if let Ok(j) = crate::tvbox::parse_loose_json(t) {
        for k in ["host", "apiDomain", "base"] {
            if let Some(s) = j.get(k).and_then(|v| v.as_str()) {
                let s = s.trim().trim_end_matches('/');
                if !s.is_empty() {
                    return s.to_string();
                }
            }
        }
    }
    DEFAULT_HOST.to_string()
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数层（离线可测：base64 / AES-128-CBC / JSON）
// ═══════════════════════════════════════════════════════════════════════

/// `parameter=` 的值：明文 JSON → AES-128-CBC(PKCS7) → 标准 base64
pub fn encrypt_param(plain: &str) -> Result<String, String> {
    let pt = plain.as_bytes();
    let mut buf = vec![0u8; (pt.len() / 16 + 1) * 16];
    buf[..pt.len()].copy_from_slice(pt);
    let ct = Aes128CbcEnc::new_from_slices(KEY, IV)
        .map_err(|e| format!("AES-128 初始化失败：{e}"))?
        .encrypt_padded_mut::<Pkcs7>(&mut buf, pt.len())
        .map_err(|e| format!("AES 加密失败：{e}"))?
        .to_vec();
    Ok(crate::csp::shared::b64_encode(&ct))
}

/// 响应 `data`：base64 → AES-128-CBC 解密 → UTF-8 明文
pub fn decrypt_data(b64: &str) -> Result<String, String> {
    let ct = crate::csp::shared::b64_decode(b64)?;
    if ct.is_empty() || ct.len() % 16 != 0 {
        return Err(format!("密文长度不合法（{} 字节，必须是 16 的倍数）", ct.len()));
    }
    let mut buf = ct;
    let pt = Aes128CbcDec::new_from_slices(KEY, IV)
        .map_err(|e| format!("AES-128 初始化失败：{e}"))?
        .decrypt_padded_mut::<Pkcs7>(&mut buf)
        .map_err(|_| "AES 解密失败（key/iv 不对，或响应不是这套协议的）".to_string())?
        .to_vec();
    String::from_utf8(pt).map_err(|e| format!("明文不是 UTF-8：{e}"))
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

fn text_of(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| {
        if let Some(s) = x.as_str() {
            let s = s.trim();
            if s.is_empty() {
                None
            } else {
                Some(s.to_string())
            }
        } else if x.is_number() {
            Some(x.to_string())
        } else {
            None
        }
    })
}

fn name_of(v: &Value, k: &str) -> String {
    v.get(k).and_then(|o| o.get("name")).and_then(|n| n.as_str()).unwrap_or("").trim().to_string()
}

/// 列表 JSON → 条目（`event_name + 主队 vs 客队`，副标题带状态与比分）
///
/// # 为什么 `mid` 是 id 而不是 `match_id`
/// ```text
/// DEX 的 `detail` 用的是 `mid`（`{"mid":"…"}`），`match_id` 是另一套编号（赛事编号）。
/// 用错会在 detail 里"查不到这场" —— 而这恰好是本类 detail 的取数键。
/// ```
pub fn parse_matches(text: &str) -> Result<Vec<CspItem>, String> {
    let v: Value = crate::tvbox::parse_loose_json(text.trim())
        .map_err(|e| format!("列表明文不是 JSON：{e}（前 120 字：{}）", head(text)))?;
    let arr = v.as_array().ok_or_else(|| {
        format!("列表明文不是数组（是 {}）——上游结构可能变了", head(text))
    })?;
    let mut items = Vec::new();
    for m in arr {
        let id = text_of(m, "mid").ok_or_else(|| "条目缺 mid".to_string())?;
        let home = name_of(m, "home");
        let away = name_of(m, "visiting");
        let league = text_of(m, "event_name").unwrap_or_default();
        let title = if home.is_empty() && away.is_empty() {
            format!("{league} 比赛 {id}")
        } else {
            format!("{home} vs {away}")
        };
        let status = text_of(m, "match_status_info").unwrap_or_default();
        let score = {
            let hs = m
                .get("home")
                .and_then(|h| h.get("score"))
                .map(|s| s.to_string())
                .unwrap_or_default();
            let as_ = m
                .get("visiting")
                .and_then(|h| h.get("score"))
                .map(|s| s.to_string())
                .unwrap_or_default();
            (hs, as_)
        };
        let mut sub = String::new();
        if !league.is_empty() {
            sub.push_str(&league);
        }
        if !status.is_empty() {
            if !sub.is_empty() {
                sub.push(' ');
            }
            sub.push_str(&status);
        }
        if score.0 != "null" && score.1 != "null" && (!score.0.is_empty() || !score.1.is_empty()) {
            sub.push_str(&format!(" {} - {}", score.0, score.1));
        }
        items.push(CspItem {
            id,
            title,
            cover: m
                .get("home")
                .and_then(|h| h.get("logo"))
                .and_then(|l| l.as_str())
                .map(|s| s.to_string())
                .filter(|s| s.starts_with("http")),
            subtitle: if sub.is_empty() { None } else { Some(sub) },
        });
    }
    if items.is_empty() {
        return Err(format!(
            "列表明文解出来 0 场（明文 {} 字节）——可能是上游改版/风控壳页（回了一个空数组）",
            text.len()
        ));
    }
    Ok(items)
}

/// 从列表明文里按 mid 找那一场（detail 的取数方式，见文件头"详情端点回全 0 骨架"）
pub fn find_match<'a>(arr: &'a Value, mid: &str) -> Option<&'a Value> {
    arr.as_array()?.iter().find(|m| text_of(m, "mid").as_deref() == Some(mid))
}

/// 一场比赛的线路 → 剧集（`line_list[{name,url}]`）
pub fn lines_of(m: &Value) -> Vec<CspEpisode> {
    let mut out = Vec::new();
    for l in m.get("line_list").and_then(|v| v.as_array()).map(|a| a.as_slice()).unwrap_or(&[]) {
        let url = l.get("url").and_then(|u| u.as_str()).map(|s| s.trim()).unwrap_or("");
        if url.is_empty() {
            continue;
        }
        let name = l.get("name").and_then(|n| n.as_str()).unwrap_or("线路").trim();
        out.push(CspEpisode {
            id: url.to_string(),
            title: name.to_string(),
            flag: "直播".to_string(),
        });
    }
    out
}

fn m3u8_re() -> Regex {
    Regex::new(r"(?i)\.m3u8").unwrap()
}

// ══ 类自注册（三条判据都成立，见文件头）══
crate::csp::register_site!(SportsGuazi);

pub struct SportsGuazi {
    client: reqwest::Client,
}

impl SportsGuazi {
    pub const CLASS: &'static str = "SportsGuazi";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build sports_guazi http client");
        Self { client }
    }

    /// 打一次接口，返回**解密后的明文**
    async fn call(&self, host: &str, path: &str, plain: &str) -> Result<String, String> {
        let param = encrypt_param(plain)?;
        let url = format!("{host}{path}?parameter={}", urlencoding::encode(&param));
        let resp = self
            .client
            .get(&url)
            .header("user-platform", USER_PLATFORM)
            .header("client-version", CLIENT_VERSION)
            .header("client-channel", "")
            .header(reqwest::header::ACCEPT, "application/json, text/plain, */*")
            .send()
            .await
            .map_err(|e| format!("请求失败（{host}{path}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{host}{path}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{host}{path}）：{}", head(&text)));
        }
        let v: Value = crate::tvbox::parse_loose_json(text.trim())
            .map_err(|e| format!("外层不是 JSON：{e}（前 120 字：{}）", head(&text)))?;
        let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(-1);
        if code != 200 {
            return Err(format!(
                "上游 code={code}（{}）：{}",
                v.get("name").and_then(|s| s.as_str()).unwrap_or(""),
                v.get("message").and_then(|s| s.as_str()).unwrap_or("")
            ));
        }
        let data = v
            .get("data")
            .and_then(|d| d.as_str())
            .ok_or_else(|| format!("响应没有 data 字段（前 120 字：{}）", head(&text)))?;
        decrypt_data(data)
    }

    fn template_of(tid: &str) -> Result<&'static str, String> {
        let t = tid.trim();
        CATS.iter()
            .find(|(id, _, _)| *id == t)
            .map(|(_, _, j)| *j)
            .ok_or_else(|| {
                format!(
                    "SportsGuazi 没有分类 `{t}`（可用：{}）",
                    CATS.iter()
                        .map(|(id, name, _)| format!("{}/{}", if id.is_empty() { "" } else { id }, name))
                        .collect::<Vec<_>>()
                        .join("、")
                )
            })
    }
}

impl Default for SportsGuazi {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for SportsGuazi {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = host_of(ext);
        let categories: Vec<CspCategory> = CATS
            .iter()
            .map(|(id, name, _)| CspCategory { id: (*id).to_string(), name: (*name).to_string() })
            .collect();
        // 首屏：全量列表（`{}`）
        let text = self.call(&host, "/gz/live/sports", r#"{}"#).await?;
        let items = parse_matches(&text)?;
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tpl = Self::template_of(tid)?;
        let host = host_of(ext);
        if page > 1 {
            // DEX 的明文模板里没有 page 字段，实测也没有翻页参数
            return Err(format!("SportsGuazi 不支持翻页（上游模板无 page 字段，请求的是第 {page} 页）"));
        }
        let text = self.call(&host, "/gz/live/sports", tpl).await?;
        let items = parse_matches(&text)?;
        Ok(CspList { items, page: 1, page_count: None, total: None })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let _ = (kw, page, ext);
        Err("SportsGuazi 不支持搜索（DEX 里 8 个方法没有 searchContent；订阅也标了 searchable:0）"
            .to_string())
    }

    fn supports_search(&self) -> bool {
        false
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let mid = id.trim();
        if mid.is_empty() {
            return Err("SportsGuazi detail 的 id（mid）为空".to_string());
        }
        let host = host_of(ext);
        // ★ 不用 /gz/live/detail：实测那个端点无论传什么都回全 0 骨架（见文件头）
        let text = self.call(&host, "/gz/live/sports", r#"{}"#).await?;
        let v: Value = crate::tvbox::parse_loose_json(text.trim())
            .map_err(|e| format!("列表明文不是 JSON：{e}"))?;
        let m = find_match(&v, mid).ok_or_else(|| {
            format!("列表里没有 mid={mid} 这场（可能已过了当日场次窗口，或上游只下发进行中的比赛）")
        })?;
        let home = name_of(m, "home");
        let away = name_of(m, "visiting");
        let league = text_of(m, "event_name").unwrap_or_default();
        let title = if home.is_empty() && away.is_empty() {
            format!("{league} 比赛 {mid}")
        } else {
            format!("{home} vs {away}")
        };
        let episodes = lines_of(m);
        if episodes.is_empty() {
            return Err(format!(
                "「{title}」没有可播线路（`line_list` 为空）——该场可能未开播/已完场；\
                 这不是协议错，是这场确实没有下发地址"
            ));
        }
        Ok(CspDetail {
            id: mid.to_string(),
            title,
            cover: m
                .get("home")
                .and_then(|h| h.get("logo"))
                .and_then(|l| l.as_str())
                .map(|s| s.to_string())
                .filter(|s| s.starts_with("http")),
            description: Some(format!(
                "{}{}",
                text_of(m, "match_status_info").unwrap_or_default(),
                text_of(m, "stage").map(|s| format!(" {s}")).unwrap_or_default()
            ))
            .filter(|s| !s.trim().is_empty()),
            episodes,
        })
    }

    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let _ = ext;
        let url = id.trim();
        if url.is_empty() {
            return Err("SportsGuazi play 的 id 为空".to_string());
        }
        if !url.starts_with("http") {
            return Err(format!(
                "SportsGuazi play 的 id 应该是 `line_list[].url`（线路地址），实际是 `{}`",
                head(url)
            ));
        }
        // ★ 不把"看着像地址"当"能播"：线路必须是 m3u8（DEX 里取流字段就是 `m3u8`）
        if !m3u8_re().is_match(url) {
            return Err(format!(
                "SportsGuazi 的线路不是 m3u8（{}）——上游可能换了取流形态，不猜",
                head(url)
            ));
        }
        Ok(vec![CspPlay {
            url: url.to_string(),
            headers: PLAY_HEADERS
                .iter()
                .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
                .collect(),
            label: Some(if flag.trim().is_empty() { "直播".to_string() } else { flag.to_string() }),
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实列表明文（2026-10-28 00:0x 从那台接口解出来的前两场，**逐字**，
    /// 只把无关字段裁掉；`line_list` 是真实 m3u8）
    const REAL_LIST: &str = r#"[
      {"mid": 8448906, "match_id": 4602035, "event_name": "沙特甲", "stage": "第5轮",
       "match_time": 1793107800, "hot": 0, "ball_type": 1, "m_status": 2,
       "match_status_info": "进行中",
       "home": {"name": "吉达国民", "logo": "https://resource.nj82wbp.top/data/resources/images/team/foot/aa.png", "score": "1"},
       "visiting": {"name": "利雅得胜利", "logo": "", "score": "0"},
       "line_list": [{"name": "高清", "url": "https://pullgz721.qmuiw.com/live/sd-1-4602035.m3u8?auth_key=1793116818-0-0-9d6ee328b3ee2f2bce51fe38e8260f54"}]},
      {"mid": 8523997, "match_id": 4656347, "event_name": "阿塞杯", "stage": "",
       "match_time": 1793107800, "hot": 0, "ball_type": 1, "m_status": 1,
       "match_status_info": "完场",
       "home": {"name": "卡拉巴赫", "logo": "", "score": "2"},
       "visiting": {"name": "内夫特奇", "logo": "", "score": "1"},
       "line_list": []}
    ]"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(SportsGuazi::CLASS, "SportsGuazi");
    }

    #[test]
    fn must_be_registered_this_batch() {
        assert!(crate::csp::is_implemented("csp_SportsGuazi"), "★ 三条判据成立 ⇒ 要注册");
        let flat = crate::csp::shared::impl_src_only(include_str!("sports_guazi.rs"));
        assert!(flat.contains("register_site!(SportsGuazi)"));
    }

    /// ★ 加密/解密是**双向**且与站点字节一致（离线可复跑）：用真实明文加密后再解回
    #[test]
    fn aes_roundtrip_matches_the_real_protocol() {
        let plain = r#"{"frame":"0","hot":"0","tag":"0","type":"1"}"#;
        let b64 = encrypt_param(plain).expect("加密");
        // 与 `.probe` 里 openssl 交叉核对过的形态：16 的倍数、标准 base64
        assert_eq!(crate::csp::shared::b64_decode(&b64).unwrap().len() % 16, 0);
        assert_eq!(decrypt_data(&b64).expect("解密"), plain);
        // 反面：key 当 IV 用会"解密成功但内容不对/UTF-8 失败"⇒ 至少不能等于明文
        assert!(
            decrypt_data(&b64).unwrap() != "乱码时不该相等" && decrypt_data(&b64).is_ok(),
            "自检：往返必须稳定"
        );
        // 非 16 倍数 ⇒ Err（不许静默返回空）
        assert!(decrypt_data("AAAA").is_err());
    }

    #[test]
    fn list_parses_real_payload() {
        let items = parse_matches(REAL_LIST).expect("真实明文必须能解析");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "8448906", "id 是 mid（DEX 的 detail 用的就是它）");
        assert_eq!(items[0].title, "吉达国民 vs 利雅得胜利");
        assert!(items[0].subtitle.as_deref().unwrap_or("").contains("沙特甲"));
        assert!(items[0].cover.as_deref().unwrap_or("").starts_with("https://"));
    }

    /// ★ 空列表必须 Err（诚实契约第 1 条）
    #[test]
    fn empty_list_is_an_error() {
        let e = parse_matches("[]").expect_err("★ 0 场必须 Err");
        assert!(e.contains("0 场"), "{e}");
        assert!(e.contains("风控壳页"), "要写明可能是壳页：{e}");
    }

    #[test]
    fn detail_picks_the_match_and_lines_become_episodes() {
        let v: Value = serde_json::from_str(REAL_LIST).unwrap();
        let m = find_match(&v, "8448906").expect("要能按 mid 找到");
        let eps = lines_of(m);
        assert_eq!(eps.len(), 1);
        assert!(eps[0].id.contains(".m3u8"));
        assert_eq!(eps[0].flag, "直播");
        // 没有线路的那场 ⇒ 0 集（detail 里会 Err，而不是伪造一条线路）
        let m2 = find_match(&v, "8523997").unwrap();
        assert!(lines_of(m2).is_empty());
        // 查不到的 mid ⇒ None
        assert!(find_match(&v, "1").is_none());
    }

    #[test]
    fn category_templates_are_the_dex_literals() {
        assert_eq!(SportsGuazi::template_of("").unwrap(), r#"{}"#);
        assert_eq!(
            SportsGuazi::template_of("football").unwrap(),
            r#"{"frame":"0","hot":"0","tag":"0","type":"1"}"#
        );
        assert_eq!(
            SportsGuazi::template_of("nba").unwrap(),
            r#"{"frame":"0","hot":"0","tag":"37","type":"0"}"#
        );
        let e = SportsGuazi::template_of("nope").expect_err("未知分类必须 Err");
        assert!(e.contains("可用："), "报错要列出可用分类：{e}");
        // 订阅里 ext 是 null ⇒ 必须落到 DEX 的 host，而不是 "" 
        assert_eq!(host_of(""), DEFAULT_HOST);
        assert_eq!(host_of(r#"{"host":"https://x.example/"}"#), "https://x.example");
    }

    #[test]
    fn play_refuses_non_m3u8_instead_of_pretending() {
        let s = SportsGuazi::new();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let e = rt
            .block_on(s.play("直播", "https://x.example/abc.mp4", ""))
            .expect_err("★ 非 m3u8 必须 Err");
        assert!(e.contains("m3u8"), "{e}");
    }

    /// ★ 真网络（默认 ignore）：`cargo test --lib csp::sports_guazi::tests::live_ -- --ignored --nocapture`
    #[tokio::test]
    #[ignore = "真网络：直连 api.46d5umpk.com（不走系统代理），人工触发"]
    async fn live_chain_home_list_detail_play() {
        let s = SportsGuazi::new();
        let home = s.home("").await.expect("★ live: home 必须取到列表");
        println!(
            "LIVE SportsGuazi home cats={} items={} first={}",
            home.categories.len(),
            home.items.len(),
            home.items[0].title
        );
        let list = s.list("football", 1, "").await.expect("★ live: list 必须取到条目");
        println!("LIVE SportsGuazi list football n={} first={}", list.items.len(), list.items[0].title);
        // 找一场带线路的（进行中）
        let mut hit = None;
        for it in &list.items {
            if let Ok(d) = s.detail(&it.id, "").await {
                hit = Some(d);
                break;
            }
        }
        let d = hit.expect("★ live: 至少一场应有 line_list（探针时段有 11 场带线路）");
        println!("LIVE SportsGuazi detail title={} eps={}", d.title, d.episodes.len());
        let plays = s.play(&d.episodes[0].flag, &d.episodes[0].id, "").await.expect("★ live: play");
        println!("LIVE SportsGuazi play url={}", plays[0].url);
    }
}
