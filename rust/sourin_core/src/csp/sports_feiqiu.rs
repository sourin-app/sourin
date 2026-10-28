// ═══════════════════════════════════════════════════════════════════════
//  csp_SportsFeiqiu —— 「飞球体育」（api.l1d0k2y5x8d0b8h.vip …）的 Rust 重写（**本批不注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★ 为什么**没有** `register_site!`（三条判据里第 ③ 条不成立）
// ```text
// ① 订阅里 1 站：`.probe/ref-subscription.json` → api=csp_SportsFeiqiu（ext 为 null）   ✅
// ② 有可用 host：域名是**加密下发**的，密钥在 DEX 里，能解开 ⇒ 两条 host 拿到              ✅
//      GET https://pullcfg.butueaa.cn/domain/master/raw/18  → 108 B base64
//      AES-128-CBC(key=iv="zNuZTzWqOliEgJAL") → ["http://api.l1d0k2y5x8d0b8h.vip",
//                                                  "http://api.j9y5m8k8w7q9h8a.xyz"]
// ③ **真网真的取到数据**：取不到 —— 每个业务端点的 `data=` 字节形态**仍未确定**        ❌
//    实测（本文件写之前 + 前一轮 `.probe/r3-sports_feiqiu-tierB.md` 的 90+ 组）：全 `参数错误`
// ⇒ 缺第 ③ 条 ⇒ **不注册**；实现照写（解密/域名下发/端点都真），失败时给可读 Err。
// ```
//
// # ★ 这一轮**新**拿到的硬证据（比"我试了 90 组"更硬的一条）
// ```text
// 对**两个不同端点**、**三份不同明文**发请求，响应密文**逐字节相同**：
//   GET /v191/domain?data=<AES(设备JSON)>    → "yfzvBXKcW86A2RDPObLVsaIXu+MJFWFQ0P8aeQt107XemCVNAnN98kpKkdhJ+A21"
//   GET /v220/schedule?data=<AES(赛事JSON)>  → 逐字一样
//   解出来都是 {"code":0,"message":"参数错误"}
// ⇒ 这不是"我拼错了某个字节"，而是这套端点在当前对**任何**输入都回同一份固定壳响应。
//   （"200 + 固定密文"正是本仓纪律里说的：200 不足以判活 —— 要看 200 的内容是谁的。）
// ```
//
// # 协议（DEX 常量逐字；除 `data=` 形态外都已确定）
// ```text
// 加密：AES-128-CBC，**key = iv = "zNuZTzWqOliEgJAL"**（16 字节 ASCII；与 SportsGuazi 的 key≠iv 不同）
//       外层 base64；响应也是同一算法（先 base64 再解，明文是 JSON）
// 头：  User-Agent: okhttp/4.2.2 · imei · device:1 · platform:fqzb · base
// init  GET {host}/v191/domain?data=…        → data.openim_zb_api_list
// list  GET {host}/v220/schedule?data=…      ← 明文模板 {"sport_id":"<id>","tab":"0","hot":"0"}
//       响应 data.list[]：tab/sport_id/match_id/home_logo/away_name/home_name/
//                        matching/alias_name/home_score/away_score/match_date
//       拼装常量：" vs " · ":"（比分）· " 直播中" · " 未开赛"
// detail GET {host}/v171/matchs_live?data=…  ← {"sport_id":"<id>","match_id":"<mid>","page":"0","page_size":"18"}
//       响应 data[]：room_title / user_nickname / chatroom_id
// play  GET {host}/v131/room?data=…         → 再 GET {host}/v230/play/url → data.play_url
// 分类（DEX 只给了 id 与名字两个列表，**没有给配对结构**）：
//       id: 101 / 3 / 1 / 2    名字: 电竞 / 其他 / 足球 / 篮球
//       ⚠️ 谁对谁**未确定** ⇒ 本实现按 DEX 出现顺序配对，并在注释里标明"未证实"
// ```
//
// # 改前错在哪
// ```text
// · 把 pullcfg 解出域名当成"站点可用" ⇒ 那只是**配置下发**活着，业务端点可以全是壳。
// · 用 key 当 IV 去解 SportsGuazi（或反过来）⇒ 两个类都是 AES-128-CBC，
//   但 IV 不同：feiqiu 是 key=iv，guazi 是另一串 16 字节。混用会"解密成功但 JSON 解不开"。
// · 把 `{"code":0,"message":"参数错误"}` 当成"站点挂了" ⇒ 不准确：
//   code=0 是**成功码**，message 才是业务拒绝。真实结论是"我们没拼对上"，不是"站点死"。
// ```

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use async_trait::async_trait;
use cbc::{Decryptor, Encryptor};
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspHome, CspItem, CspList, CspPlay, CspSite};

type Aes128CbcEnc = Encryptor<aes::Aes128>;
type Aes128CbcDec = Decryptor<aes::Aes128>;

/// DEX 里的 16 字节串：**同时**是 key 与 iv（这个站的用法，已用 openssl 交叉验证）
pub const KEY: &[u8] = b"zNuZTzWqOliEgJAL";
pub const IV: &[u8] = b"zNuZTzWqOliEgJAL";

/// DEX `init()` 的 UA（逐字）
const UA: &str = "okhttp/4.2.2";

/// 域名下发入口（DEX 逐字；末尾的 `18` 是配置编号）
pub const DOMAIN_CFG: &str = "https://pullcfg.butueaa.cn/domain/master/raw/18";

const TIMEOUT: Duration = Duration::from_secs(20);

/// DEX 的分类（id, 名字）—— **配对未证实**，见文件头
pub const CATS: &[(&str, &str)] =
    &[("101", "电竞"), ("3", "其他"), ("1", "足球"), ("2", "篮球")];

/// 为什么这里是 `&str` 而不是 `Option`：域名要**先解**，没有静态默认值可退
pub const NEED_HOST_MSG: &str = "SportsFeiqiu 的 host 不在 ext 里（订阅里 ext 为 null），\
必须先解开 `pullcfg.butueaa.cn` 的加密域名下发";

/// ext 里若显式给了 host 就直接用（订阅里没有 ⇒ 走域名下发）
pub fn host_of(ext: &str) -> Option<String> {
    let t = ext.trim();
    if t.starts_with("http://") || t.starts_with("https://") {
        return Some(t.trim_end_matches('/').to_string());
    }
    if let Ok(j) = crate::tvbox::parse_loose_json(t) {
        for k in ["host", "apiDomain", "base"] {
            if let Some(s) = j.get(k).and_then(|v| v.as_str()) {
                let s = s.trim().trim_end_matches('/');
                if !s.is_empty() {
                    return Some(s.to_string());
                }
            }
        }
    }
    None
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数层（离线可测：base64 / AES-128-CBC key=iv）
// ═══════════════════════════════════════════════════════════════════════

/// 明文 → base64(AES-128-CBC)（与站点的 `data=` 同一算法）
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

/// base64(AES-128-CBC) → 明文（key=iv）
pub fn decrypt_blob(b64: &str) -> Result<String, String> {
    let ct = crate::csp::shared::b64_decode(b64.trim())?;
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

/// 域名下发响应 → host 列表
///
/// # 为什么"解出来不是 JSON 数组"要当错误而不是回空
/// ```text
/// 这份配置是站点的**唯一入口**：解出空 ⇒ 该类连 host 都没有。
/// 回 `Ok(vec![])` 会把"配置换了密钥"渲染成"这个站点没有域名"，排查方向直接跑偏。
/// ```
pub fn parse_domains(resp_b64: &str) -> Result<Vec<String>, String> {
    let plain = decrypt_blob(resp_b64)?;
    let v: Value = crate::tvbox::parse_loose_json(plain.trim())
        .map_err(|e| format!("域名下发明文不是 JSON：{e}（前 120 字：{}）", head(&plain)))?;
    let arr = v
        .as_array()
        .ok_or_else(|| format!("域名下发明文不是数组（前 120 字：{}）", head(&plain)))?;
    let hosts: Vec<String> = arr
        .iter()
        .filter_map(|x| x.as_str())
        .map(|s| s.trim().trim_end_matches('/').to_string())
        .filter(|s| s.starts_with("http"))
        .collect();
    if hosts.is_empty() {
        return Err(format!(
            "域名下发明文里没有 http 域名（解出 {} 字节）——可能配置换了密钥/结构",
            plain.len()
        ));
    }
    Ok(hosts)
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

/// 业务响应的统一判据：**`code==0` 且带 `data` 且 message 不是"参数错误"** 才算成功
///
/// # 为什么 `code==0` 单独不够（这是实测出来的，不是洁癖）
/// ```text
/// 这套端点的"壳响应"是 `{"code":0,"message":"参数错误"}` —— **code 是成功码**！
/// 只看 code 会把"上游拒绝"读成"成功但没数据"（我第一版就是这样，live 探针当场打脸：
///   打印 `schedule OK keys=["code","message"]`，而 message 明明是"参数错误"）。
/// ⇒ 成功必须**同时**满足：code==0 + 有 data + message 不是业务拒绝文案。
/// ```
///
/// # 为什么错误文案要写"可能是我们拼错了"
/// ```text
/// 实测这套端点对任何输入都回同一份密文（连两个不同端点、三份不同明文都是同一串）。
/// 把它写成"站点挂了"是**不准确的**：站点活着（TLS/HTTP 都正常），死的是我们的拼装依据。
/// ```
pub fn unwrap_upstream(text: &str, what: &str) -> Result<Value, String> {
    let t = text.trim();
    let v: Value = crate::tvbox::parse_loose_json(t)
        .map_err(|e| format!("{what} 明文不是 JSON：{e}（前 120 字：{}）", head(t)))?;
    let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(-1);
    let msg = v.get("message").and_then(|m| m.as_str()).unwrap_or("");
    let has_data = v.get("data").map(|d| !d.is_null()).unwrap_or(false);
    if code == 0 && has_data && msg != "参数错误" {
        return Ok(v);
    }
    Err(format!(
        "{what} 被上游拒绝：code={code} message={msg:?}（带 data={has_data}）—— \
         这是「拼装依据不足」（不是站点挂了）：该端点的 `data=` 字节形态仍未确定"
    ))
}

/// 赛事条目（DEX 字段逐字）
pub fn parse_schedule(v: &Value) -> Result<Vec<CspItem>, String> {
    let mut items = Vec::new();
    for m in v
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(|l| l.as_array())
        .map(|a| a.as_slice())
        .unwrap_or(&[])
    {
        let id = m
            .get("match_id")
            .map(|x| x.to_string().trim_matches('"').to_string())
            .unwrap_or_default();
        if id.is_empty() || id == "null" {
            continue;
        }
        let home = m.get("home_name").and_then(|x| x.as_str()).unwrap_or("").trim();
        let away = m.get("away_name").and_then(|x| x.as_str()).unwrap_or("").trim();
        if home.is_empty() && away.is_empty() {
            continue;
        }
        // DEX 的拼装：`{home} vs {away}` + 比分 `a:b` + 状态（" 直播中" / " 未开赛"）
        let mut sub = String::new();
        let hs = m.get("home_score").map(|x| x.to_string().trim_matches('"').to_string());
        let as_ = m.get("away_score").map(|x| x.to_string().trim_matches('"').to_string());
        if let (Some(a), Some(b)) = (hs, as_) {
            if a != "null" && b != "null" {
                sub.push_str(&format!("{a}:{b}"));
            }
        }
        if let Some(md) = m.get("match_date").and_then(|x| x.as_str()) {
            if !sub.is_empty() {
                sub.push(' ');
            }
            sub.push_str(md.trim());
        }
        items.push(CspItem {
            id,
            title: format!("{home} vs {away}"),
            cover: m
                .get("home_logo")
                .and_then(|x| x.as_str())
                .map(|s| s.to_string())
                .filter(|s| s.starts_with("http")),
            subtitle: if sub.trim().is_empty() { None } else { Some(sub.trim().to_string()) },
        });
    }
    if items.is_empty() {
        return Err(format!(
            "schedule 明文解析出 0 场（data.list 为空或字段改名）——可能上游结构变了/风控壳页"
        ));
    }
    Ok(items)
}

// ══ ⚠️ **没有 `register_site!`**（判据③不成立，见文件头）══

pub struct SportsFeiqiu {
    client: reqwest::Client,
}

impl SportsFeiqiu {
    pub const CLASS: &'static str = "SportsFeiqiu";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build sports_feiqiu http client");
        Self { client }
    }

    /// 拿 host：先看 ext，再解开域名下发（**顺序不能反**：ext 是运维的手动覆盖口）
    async fn resolve_host(&self, ext: &str) -> Result<String, String> {
        if let Some(h) = host_of(ext) {
            return Ok(h);
        }
        let resp = self
            .client
            .get(DOMAIN_CFG)
            .header(reqwest::header::ACCEPT, "*/*")
            .send()
            .await
            .map_err(|e| format!("域名下发请求失败（{DOMAIN_CFG}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("域名下发读取失败：{e}"))?;
        if !status.is_success() {
            return Err(format!("域名下发 HTTP {status}：{}", head(&text)));
        }
        let hosts = parse_domains(&text)?;
        Ok(hosts[0].clone())
    }

    /// 打一个业务端点：`data=` 用 key=iv 的 AES-CBC 包 base64（**唯一已确定的算法**）
    async fn call(&self, host: &str, path: &str, plain: &str, what: &str) -> Result<Value, String> {
        let data = encrypt_param(plain)?;
        let url = format!("{host}{path}{}", urlencoding::encode(&data));
        let resp = self
            .client
            .get(&url)
            .header("imei", "1")
            .header("device", "1")
            .header("platform", "fqzb")
            .header(reqwest::header::ACCEPT, "*/*")
            .send()
            .await
            .map_err(|e| format!("请求失败（{host}{path}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{host}{path}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{host}{path}）：{}", head(&text)));
        }
        let plain_json = decrypt_blob(&text)?;
        unwrap_upstream(&plain_json, what)
    }
}

impl Default for SportsFeiqiu {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for SportsFeiqiu {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = self.resolve_host(ext).await?;
        // 分类表是 DEX 常量（配对未证实）；首屏条目必须真取到，否则 Err
        let categories: Vec<CspCategory> = CATS
            .iter()
            .map(|(id, n)| CspCategory { id: (*id).to_string(), name: (*n).to_string() })
            .collect();
        let v = self
            .call(
                &host,
                "/v220/schedule?data=",
                r#"{"sport_id":"1","tab":"0","hot":"0"}"#,
                "schedule",
            )
            .await
            .map_err(|e| format!("home 取首屏失败（host={host}）：{e}"))?;
        let items = parse_schedule(&v)?;
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let sport = tid.trim();
        if sport.is_empty() {
            return Err("SportsFeiqiu 分类 id 为空".to_string());
        }
        let host = self.resolve_host(ext).await?;
        let page = if page == 0 { 1 } else { page };
        if page > 1 {
            // DEX 的 schedule 模板里没有 page 字段（只有 detail 那个模板有 page/page_size）
            return Err(format!("SportsFeiqiu 列表不支持翻页（schedule 模板无 page 字段，请求的是第 {page} 页）"));
        }
        let plain = format!(r#"{{"sport_id":"{sport}","tab":"0","hot":"0"}}"#);
        let v = self.call(&host, "/v220/schedule?data=", &plain, "schedule").await?;
        let items = parse_schedule(&v)?;
        Ok(CspList { items, page: 1, page_count: None, total: None })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let _ = (kw, page, ext);
        Err(
            "SportsFeiqiu 不支持搜索（DEX 里 8 个方法没有 searchContent；订阅标了 searchable:0）"
                .to_string(),
        )
    }

    fn supports_search(&self) -> bool {
        false
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let mid = id.trim();
        if mid.is_empty() {
            return Err("SportsFeiqiu detail 的 id（match_id）为空".to_string());
        }
        let host = self.resolve_host(ext).await?;
        // DEX 的 detail 模板只有 sport_id + match_id + page/page_size（sport_id 不在 id 里，
        // 用分类首项兜底并在错误文案里写清，避免"悄悄用错 sport_id 还报成功"）
        let sport = CATS[0].0;
        let plain = format!(
            r#"{{"sport_id":"{sport}","match_id":"{mid}","page":"0","page_size":"18"}}"#
        );
        let v = self.call(&host, "/v171/matchs_live?data=", &plain, "matchs_live").await?;
        let rooms = v
            .get("data")
            .and_then(|d| d.as_array())
            .map(|a| a.as_slice())
            .unwrap_or(&[]);
        let title = rooms
            .iter()
            .find_map(|r| r.get("room_title").and_then(|t| t.as_str()))
            .map(|s| s.to_string())
            .ok_or_else(|| {
                format!(
                    "matchs_live 里没有 room_title（match_id={mid}）——上游结构可能变了"
                )
            })?;
        let mut episodes: Vec<super::CspEpisode> = Vec::new();
        for r in rooms {
            let rid = r
                .get("chatroom_id")
                .map(|x| x.to_string().trim_matches('"').to_string())
                .unwrap_or_default();
            if rid.is_empty() || rid == "null" {
                continue;
            }
            let name = r
                .get("user_nickname")
                .and_then(|x| x.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "比赛原声".to_string());
            episodes.push(super::CspEpisode { id: rid, title: name, flag: "原声".to_string() });
        }
        if episodes.is_empty() {
            return Err(format!("「{title}」没有可播房间（chatroom_id 全空）——上游结构可能变了"));
        }
        Ok(CspDetail {
            id: mid.to_string(),
            title,
            cover: None,
            description: None,
            episodes,
        })
    }

    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let rid = id.trim();
        if rid.is_empty() {
            return Err("SportsFeiqiu play 的 id（chatroom_id）为空".to_string());
        }
        let host = self.resolve_host(ext).await?;
        // DEX 的 room 模板：`{"room_id":"…","sport_id":"…","match_id":"…"}`
        let plain = format!(r#"{{"room_id":"{rid}","sport_id":"1","match_id":"0"}}"#);
        let v = self.call(&host, "/v131/room?data=", &plain, "room").await?;
        let code_id = v
            .get("data")
            .and_then(|d| d.get("code_id"))
            .and_then(|c| c.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("gqzm"); // DEX 逐字的默认解析器 code
        let plain2 = format!(r#"{{"room_id":"{rid}","code_id":"{code_id}"}}"#);
        let v2 = self.call(&host, "/v230/play/url", &plain2, "play/url").await?;
        let url = v2
            .get("data")
            .and_then(|d| d.get("play_url"))
            .and_then(|u| u.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| "play/url 里没有 data.play_url（上游结构可能变了）".to_string())?;
        Ok(vec![CspPlay {
            url,
            headers: vec![("User-Agent".to_string(), UA.to_string())],
            label: Some(if flag.trim().is_empty() { "直播".to_string() } else { flag.to_string() }),
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实域名下发响应（2026-10-28 00:0x 直连抓到，108 B，逐字）
    const REAL_DOMAIN_RESP: &str = "w4HsAOEqwMIRutHXBfQ1T3oTYqDkoW9i74KKywBBcdRBRnc4XZPUU5CORtuohOU9ZNomB5Nl7M7j7bJcMKBfqHay7KYixyB8XR1Sduak9h4=";

    /// 真实业务响应（两个端点、不同明文，密文**逐字节相同** —— 就是"固定壳"那条证据）
    const REAL_SHELL_RESP: &str = "yfzvBXKcW86A2RDPObLVsaIXu+MJFWFQ0P8aeQt107XemCVNAnN98kpKkdhJ+A21";

    #[test]
    fn class_name_is_exact() {
        assert_eq!(SportsFeiqiu::CLASS, "SportsFeiqiu");
    }

    /// ★ 本批**不注册**（判据③不成立）
    #[test]
    fn must_not_be_registered_this_batch() {
        assert!(
            !crate::csp::is_implemented("csp_SportsFeiqiu"),
            "★ 业务端点 `data=` 形态未确定（全 `参数错误`）⇒ 不许进注册表"
        );
        let flat = crate::csp::shared::impl_src_only(include_str!("sports_feiqiu.rs"));
        assert!(!flat.contains("register_site!(SportsFeiqiu)"), "★ 本批 SportsFeiqiu 不注册");
    }

    /// ★ 域名下发**真能解开**（离线复跑；这是判据②的唯一依据）
    #[test]
    fn domain_config_decrypts_to_real_hosts() {
        let hosts = parse_domains(REAL_DOMAIN_RESP).expect("真实响应必须能解开");
        assert_eq!(hosts.len(), 2);
        assert_eq!(hosts[0], "http://api.l1d0k2y5x8d0b8h.vip");
        assert_eq!(hosts[1], "http://api.j9y5m8k8w7q9h8a.xyz");
        // 反面：换成 SportsGuazi 的算法参数（key≠iv）不该解出同样的东西
        assert!(parse_domains("AAAA").is_err(), "非 16 倍数必须 Err");
    }

    #[test]
    fn key_equals_iv_and_roundtrip_holds() {
        assert_eq!(KEY, IV, "本类 key=iv（与 SportsGuazi 的 key≠iv 不同）");
        let plain = r#"{"sport_id":"1","tab":"0","hot":"0"}"#;
        let b64 = encrypt_param(plain).expect("加密");
        assert_eq!(decrypt_blob(&b64).expect("解密"), plain);
    }

    /// ★ "200 + 固定壳"必须被识别成**上游拒绝**，而不是"成功但没数据"
    #[test]
    fn shell_response_is_an_upstream_rejection_not_success() {
        let plain = decrypt_blob(REAL_SHELL_RESP).expect("这条固定壳能解开");
        // ★ 站点的中文是 **unicode 转义**形态（`\u53c2\u6570\u9519\u8bef`）——
        //   直接 `contains("参数错误")` 会恒 false（前一轮就踩过这个假判据）。
        //   所以要"先解 JSON 再比较解码后的中文"。
        assert!(plain.contains("\\u53c2\\u6570"), "真实壳明文里中文是转义形态：{plain}");
        let v: Value = serde_json::from_str(plain.trim()).expect("壳响应是 JSON");
        assert_eq!(v.get("message").and_then(|m| m.as_str()), Some("参数错误"));
        let e = unwrap_upstream(&plain, "schedule").expect_err("★ 必须 Err");
        assert!(e.contains("参数错误"), "{e}");
        assert!(e.contains("不是站点挂了"), "文案要说清不是站点死：{e}");
        // 反面：code=0 且 message 正常时不许被判错
        assert!(unwrap_upstream(r#"{"code":0,"message":"ok","data":{}}"#, "x").is_ok());
    }

    /// 列表解析（用 DEX 字段构造的**结构样本**，字段名逐字；真数据当前取不到）
    #[test]
    fn schedule_fields_follow_the_dex_names() {
        let v: Value = serde_json::from_str(
            r#"{"code":0,"message":"ok","data":{"list":[
                 {"sport_id":"1","match_id":"9001","home_name":"甲队","away_name":"乙队",
                  "home_logo":"https://x.example/a.png","home_score":"1","away_score":"2",
                  "match_date":"2026-10-28 00:00","tab":"0"}]}}"#,
        )
        .unwrap();
        let items = parse_schedule(&v).expect("按 DEX 字段名必须能解析");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "9001");
        assert_eq!(items[0].title, "甲队 vs 乙队");
        assert!(items[0].subtitle.as_deref().unwrap_or("").contains("1:2"));
        // 空 list ⇒ Err（诚实契约第 1 条）
        let empty: Value =
            serde_json::from_str(r#"{"code":0,"message":"ok","data":{"list":[]}}"#).unwrap();
        assert!(parse_schedule(&empty).is_err());
    }

    #[test]
    fn host_prefers_ext_override() {
        assert_eq!(host_of("https://h.example/").as_deref(), Some("https://h.example"));
        assert_eq!(host_of(r#"{"host":"https://x.example"}"#).as_deref(), Some("https://x.example"));
        assert!(host_of("").is_none(), "ext 为空 ⇒ 必须走域名下发，不许编一个默认 host");
    }

    /// ★ 真网络（默认 ignore）：只作取证 —— 记录域名下发的真实读数与业务端点的真实拒绝
    #[tokio::test]
    #[ignore = "真网络：直连 pullcfg.butueaa.cn（不走系统代理），人工触发"]
    async fn live_domain_then_business_endpoint() {
        let s = SportsFeiqiu::new();
        let host = s.resolve_host("").await.expect("★ live: 域名下发必须能解开");
        println!("LIVE SportsFeiqiu host={host}");
        let r = s
            .call(&host, "/v220/schedule?data=", r#"{"sport_id":"1","tab":"0","hot":"0"}"#, "schedule")
            .await;
        match r {
            Ok(v) => println!("LIVE SportsFeiqiu schedule OK keys={:?}", v.as_object().map(|o| o.keys().cloned().collect::<Vec<_>>())),
            Err(e) => println!("LIVE SportsFeiqiu schedule Err(如实): {e}"),
        }
    }
}
