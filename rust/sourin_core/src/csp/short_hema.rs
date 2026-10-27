// ═══════════════════════════════════════════════════════════════════════
//  csp_ShortHema —— 河马短剧（**本批不注册**：设备/会话门禁挡住，真网取不到数据）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅（`.probe/ref-subscription.json` 逐字）：
//   {"type":3, "api":"csp_ShortHema", "key":"河马短剧", "name":"🦛河马丨短剧爽看", "ext": null}
// ⇒ ext 为 null ⇒ host 只能写死。
// ```
//
// # ★ 为什么**没有** `register_site!`（三条判据缺第 ③ 条）
//
// ```text
// ① 订阅里这 1 站                                  ✅ 成立
// ② 有可用 host                                    ✅ 成立（DEX 逐字 https://freevideo.zqqds.cn）
// ③ 真网**真的取到数据**                            ❌ **不成立**
//    —— 端点活着（POST 200 + 结构化信封，GET 直接 405），
//       但服务端对"我们伪造的设备/会话体"回 `code=1 参数非法`，
//       解不出任何一条内容（详细读数见下"真网读数"）。
// ⇒ 按纪律：做实现、**不注册**，并且**不许**把这条写成"站点挂了"
//   （它是"被设备门禁挡住"，不是死站 —— 见 note `upstream-dead-is-a-strong-claim`）。
// ```
//
// # 协议取证（`.probe/csp26-downloads/lmw_classes.dex` 直读，**未起 jadx**）
//
// 常量：`.probe/csp24-dex-ShortHema.txt`（101 条）。**这个类自己一条 URL 都没有** ——
// 它的 base 长在共享层 `merge.J.b.b1()` 里，必须反汇编那个类才能拿到。这是本类最费时的点：
//
// ```text
// merge.J.b.b1(String path, JSONObject biz, boolean retry) 的逐条事实
//   · base      : 'https://freevideo.zqqds.cn'.concat(path)        ← 常量在 b1 里
//   · method    : POST（GET 实测 405 Method Not Allowed，见读数）
//   · 加密      : merge.g.a3 —— **AES/CBC/PKCS5Padding**
//                  key = "dzkjgfyxgshylgzm"（16 B）   ← a3.<clinit> 逐字
//                  iv  = "apiupdownedcrypt"（16 B）   ← 同上
//   · 头（5 项）
//       User-Agent     : okhttp/4.10.0
//       Content-Type   : application/json; charset=utf-8
//       alg            : HG45LKBS
//       datas          : base64(AES(biz 的紧凑 JSON))   ← **业务参数走 header**
//       x-request-id   : UUID（每次一个）
//   · body      : base64(AES(设备/会话 JSON))  —— 由 merge.J.b.l() 生成，见下
//   · 信封      : 有 code 且 code!=0 且同时有 data/datas ⇒ 重试一次后抛 Exception
//                否则把 data（或 datas）当 base64 **AES 解密**成 JSON
// 设备体（merge.J.b.l() 逐字字段）
//   version=3.6.0 pname=com.dz.hmjc channelCode=HMJC1000001 nchid=HMJC1000004
//   utdidTmp='A'+yyyyMMddHHmmss+'TVBX' utdid=7d2e96f3ed64e228ef1b337de386cdce
//   token='' os=android osv=30 brand=Redmi model=M2012K10C manu=Xiaomi
//   userId='' launch=shortcut mchid='' session1/2=UUID startScene='' recSwitch=true
//   installTime=millis p=36
// 业务路径（5 条，全部同 base）
//   /free-video-portal/portal/1125  home + list（{recSwitch,pageFlag,theaterSubscriptSwitch[,channelGroupId,channelId]}）
//   /free-video-portal/portal/1131  detail（{bookId,needNextChapter,isNeedAlias,bookAlias,resolutionRate:"1080P"}）
//   /free-video-portal/portal/1139  play（{bookId,chapterId,…} → data.chapterInfo.content）
//   /free-video-portal/portal/1803  search（{keyword,page,size,hotWordType} → data.searchVos[]）
// 取流（DEX playerContent）
//   content 里是 `aliplayer(appv=2.7.1&av=7.1.0&…dm=<机型>)` 这种**解析器入口**，
//   配一个专用 User-Agent；本实现只做"从 content 里挑出 http(s) 地址"，挑不到就如实 Err。
// ```
//
// # 真网读数（2026-10-27 实测，直连；原始行见 `.probe/csp-short-live.log`）
//
// ```text
// POST /free-video-portal/portal/1125
//      headers{alg:HG45LKBS, datas:base64(AES({recSwitch,pageFlag,theaterSubscriptSwitch})), x-request-id}
//      → 200 · 66 B · {"timestamp":1793116874758,"code":1,"msg":"参数非法","mode":1}
//      ★ 这个信封说明**端点活着**（不是 404/502），只是不认我们这份参数/身份。
// GET  同路径 → **405** {"status":405,"error":"Method Not Allowed","path":"/free-video-portal/portal/1125"}
//      ⇒ 方法确实是 POST（"我打错方法"会被这条否掉，不是站点死）。
// body 换成**明文 JSON**（不是 AES 密文）→ 200 · {"code":100,"msg":"服务器内部错误,请稍后重试"}
//      ⇒ 服务端确实**在解 AES**（明文进去解不开 ⇒ 500 语义）；而密文进去解开了 ⇒ 才轮到"参数非法"。
//      ⇒ 结论：加密/路径/方法/alg/datas 都对上了，缺的是**设备/会话身份**（token='' 是伪造的）。
// ```
//
// ★ 我**没有**做假通：没有把"200"写成"可用"，也没有把上面这些写成"站点挂了"。
//   缺的那一环（真设备 token）也无法靠逆向补齐 —— 它要一次真登录。
//
// # 契约边界（本仓纪律）
// ```text
// · 空结果 ⇒ Err，文案写明"可能模板改版/风控壳页"；不写 Ok(vec![])。
// · `.timeout()` 之后、`.build()` 之前必须 `.no_proxy()`（全仓判据会扫）。
// · 不新增依赖：AES 用仓里已有的 `aes`/`cbc`（`Cargo.toml` 零 diff），base64 用 shared。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use cbc::{Decryptor, Encryptor};

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use crate::csp::shared::{b64_decode, b64_encode, pick_arr, pick_id_str, pick_str};
use crate::tvbox::parse_loose_json;

type Aes128CbcEnc = Encryptor<aes::Aes128>;
type Aes128CbcDec = Decryptor<aes::Aes128>;

/// base（**不在本类的常量里**，在共享层 `merge.J.b.b1` 里逐字）
pub const BASE: &str = "https://freevideo.zqqds.cn";

/// AES key / iv（`merge.g.a3.<clinit>` 逐字）
pub const KEY: &[u8; 16] = b"dzkjgfyxgshylgzm";
pub const IV: &[u8; 16] = b"apiupdownedcrypt";

/// 头里的算法标记（`J.b.b1` 逐字）
pub const ALG: &str = "HG45LKBS";
/// UA 是 **okhttp**，不是浏览器（照抄；浏览器 UA 会少一层"这是 App"的暗示）
const UA: &str = "okhttp/4.10.0";

pub const API_HOME: &str = "/free-video-portal/portal/1125";
pub const API_DETAIL: &str = "/free-video-portal/portal/1131";
pub const API_PLAY: &str = "/free-video-portal/portal/1139";
pub const API_SEARCH: &str = "/free-video-portal/portal/1803";

/// 线路名（DEX `detailContent` 里写死的 `河马`）
pub const FLAG: &str = "河马";

/// DEX 设备体里的常量（逐字；`token` 是**空串** —— 这正是被挡的原因，如实保留）
const UTDID: &str = "7d2e96f3ed64e228ef1b337de386cdce";
const PNAME: &str = "com.dz.hmjc";
const VERSION: &str = "3.6.0";
const CHANNEL_CODE: &str = "HMJC1000001";
const NCHID: &str = "HMJC1000004";

const TIMEOUT: Duration = Duration::from_secs(20);

pub struct ShortHema {
    client: reqwest::Client,
    seq: std::sync::atomic::AtomicU64,
}

impl ShortHema {
    pub const CLASS: &'static str = "ShortHema";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // ★ 不读系统代理：装了代理时会把"站点可用"测成"全宕"（全仓判据会扫这一行）。
            .no_proxy()
            .build()
            .expect("build short_hema http client");
        Self {
            client,
            seq: std::sync::atomic::AtomicU64::new(0),
        }
    }

    fn uuid_like(&self) -> String {
        // 不引 uuid crate：用时间 + 自增序号凑一个 RFC4122 形状（服务端只要求"每次不同"）
        let n = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
            ^ (self.seq.fetch_add(1, std::sync::atomic::Ordering::Relaxed) as u128);
        let hex = format!("{n:032x}");
        format!(
            "{}-{}-{}-{}-{}",
            &hex[0..8],
            &hex[8..12],
            &hex[12..16],
            &hex[16..20],
            &hex[20..32]
        )
    }

    /// 一次业务请求（DEX `J.b.b1`）：头 5 项 + 体=设备体
    async fn request(&self, path: &str, biz: &Value) -> Result<Value, String> {
        let url = format!("{BASE}{path}");
        let datas = encode_payload(biz)?;
        let body = encode_payload(&device_json(&self.uuid_like(), &self.uuid_like(), now_millis()))?;
        let resp = self
            .client
            .post(&url)
            .header(reqwest::header::USER_AGENT, UA)
            .header(reqwest::header::CONTENT_TYPE, "application/json; charset=utf-8")
            .header("alg", ALG)
            .header("datas", datas)
            .header("x-request-id", self.uuid_like())
            .body(body)
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）：{}", head(&text)));
        }
        let v = parse_loose_json(&text)
            .map_err(|e| format!("{url} 不是 JSON：{e}（前 160 字：{}）", head(&text)))?;
        decode_envelope(&v, path)
    }
}

impl Default for ShortHema {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

fn now_millis() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数层（离线可测：AES / 信封 / 设备体 / 解析）
// ═══════════════════════════════════════════════════════════════════════

/// 紧凑 JSON → AES-CBC/PKCS5 → base64（DEX `a3.a(JSONObject)` 逐字）
///
/// ★ 服务端还顺手把 `", "` / `": "` 替换掉（DEX 里就是这么做的）；我们**先紧凑序列化**，
///   效果相同但少两次字符串替换（等价性由单测钉住：解回来必须与原对象相等）。
pub fn encode_payload(v: &Value) -> Result<String, String> {
    let plain = serde_json::to_string(v).map_err(|e| format!("序列化失败：{e}"))?;
    let pt = plain.as_bytes();
    let buf_len = (pt.len() / 16 + 1) * 16;
    let mut buf = vec![0u8; buf_len];
    buf[..pt.len()].copy_from_slice(pt);
    let ct = Aes128CbcEnc::new_from_slices(KEY, IV)
        .map_err(|e| format!("AES-128 初始化失败：{e}"))?
        .encrypt_padded_mut::<Pkcs7>(&mut buf, pt.len())
        .map_err(|e| format!("AES 加密失败：{e}"))?;
    Ok(b64_encode(ct).trim().to_string())
}

/// base64 → AES-CBC/PKCS5 解密 → JSON（DEX 解信封那一段）
pub fn decode_payload(b64: &str) -> Result<Value, String> {
    let raw = b64_decode(b64.trim())?;
    if raw.is_empty() || raw.len() % 16 != 0 {
        return Err(format!("密文长度不合法（{} 字节，必须是 16 的倍数）", raw.len()));
    }
    let mut buf = raw.clone();
    let pt = Aes128CbcDec::new_from_slices(KEY, IV)
        .map_err(|e| format!("AES-128 初始化失败：{e}"))?
        .decrypt_padded_mut::<Pkcs7>(&mut buf)
        .map_err(|_| "AES 解密失败（key/iv 不对，或响应不是给这次的）".to_string())?;
    let text = std::str::from_utf8(pt).map_err(|e| format!("明文不是 UTF-8：{e}"))?;
    parse_loose_json(text).map_err(|e| format!("明文不是 JSON：{e}（前 120 字：{}）", head(text)))
}

/// 信封：`code!=0 ⇒ Err`；`data`/`datas` 非空 ⇒ AES 解密；否则原样返回
///
/// # 与 DEX 的差别（刻意的）
/// DEX 只在"code!=0 **且** 同时有 data/datas"时才抛异常（并重试一次）；其余情况把响应
/// 原样返回给上层，上层随后解析不到字段 ⇒ **用户看到空列表**。
/// 本仓纪律：空 ⇒ 必须可读 Err。所以这里只要 `code!=0` 就 Err，并**带上 code/msg**。
pub fn decode_envelope(v: &Value, path: &str) -> Result<Value, String> {
    let code = v
        .get("code")
        .and_then(|c| match c {
            Value::Number(n) => Some(n.as_i64().unwrap_or(0)),
            Value::String(s) => s.trim().parse::<i64>().ok(),
            _ => None,
        })
        .unwrap_or(0);
    if code != 0 {
        let msg = v.get("msg").and_then(|m| m.as_str()).unwrap_or("");
        return Err(format!(
            "河马接口 {path} 业务码 code={code} msg={msg}（不是解析失败：端点活着，身份/参数没对上）"
        ));
    }
    let payload = v
        .get("data")
        .and_then(|d| d.as_str())
        .or_else(|| v.get("datas").and_then(|d| d.as_str()))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    match payload {
        Some(s) => decode_payload(&s),
        None => Ok(v.clone()),
    }
}

/// 设备/会话体（DEX `J.b.l()` 逐字字段；`token` 为空是**原样**，不是我们漏填）
pub fn device_json(session1: &str, session2: &str, millis: u128) -> Value {
    // DEX: 'A' + yyyyMMddHHmmss + 'TVBX'
    let utdid_tmp = format!("A{millis}TVBX");
    serde_json::json!({
        "version": VERSION,
        "pname": PNAME,
        "channelCode": CHANNEL_CODE,
        "utdidTmp": utdid_tmp,
        "token": "",
        "utdid": UTDID,
        "os": "android",
        "osv": 30,
        "brand": "Redmi",
        "model": "M2012K10C",
        "manu": "Xiaomi",
        "userId": "",
        "launch": "shortcut",
        "mchid": "",
        "nchid": NCHID,
        "session1": session1,
        "session2": session2,
        "startScene": "",
        "recSwitch": true,
        "installTime": millis,
        "p": 36,
    })
}

/// home/list 请求体（DEX `homeContent` / `categoryContent` 逐字字段）
pub fn list_body(group_id: i64, channel_id: i64) -> Value {
    serde_json::json!({
        "recSwitch": true,
        "pageFlag": "",
        "theaterSubscriptSwitch": true,
        "channelGroupId": group_id,
        "channelId": channel_id,
    })
}

/// detail 请求体（DEX `detailContent` 逐字字段）
pub fn detail_body(book_id: &str) -> Value {
    serde_json::json!({
        "bookId": book_id,
        "needNextChapter": 1,
        "isNeedAlias": "",
        "bookAlias": "",
        "resolutionRate": "1080P",
    })
}

/// search 请求体（DEX `searchContent` 逐字字段）
pub fn search_body(kw: &str, page: u32) -> Value {
    serde_json::json!({
        "keyword": kw.trim(),
        "page": page.max(1),
        "size": 20,
        "hotWordType": 1,
    })
}

/// `channelGroupData[]` + `channelData[]` → 扁平分类
///
/// # DEX 的两级结构怎么压平
/// ```text
/// 一级 channelGroupData[{channelGroupId, channelGroupName}]（名字是"全部"就显示"推荐"）
/// 二级 channelData[{channelId, channelName}]（挂在 `类型` 下，id 是 `groupId@channelId`）
/// 本仓 CspCategory 是扁平结构 ⇒ 先放一级（id=groupId），再放二级（id="groupId@channelId"）。
/// ```
pub fn categories_of(v: &Value) -> Vec<CspCategory> {
    let mut out: Vec<CspCategory> = Vec::new();
    let mut first_gid = String::new();
    for g in pick_arr(v, &["channelGroupData"]).map(|a| a.as_slice()).unwrap_or(&[]) {
        let gid = match g.get("channelGroupId") {
            Some(Value::Number(n)) => n.to_string(),
            Some(Value::String(s)) => s.trim().to_string(),
            _ => String::new(),
        };
        if gid.is_empty() {
            continue;
        }
        if first_gid.is_empty() {
            first_gid = gid.clone();
        }
        let raw = pick_str(g, &["channelGroupName"]).unwrap_or("").trim();
        let name = if raw == "全部" || raw.is_empty() {
            "推荐".to_string()
        } else {
            raw.to_string()
        };
        out.push(CspCategory { id: gid, name });
    }
    let gid_for_channels = if first_gid.is_empty() {
        "0".to_string()
    } else {
        first_gid
    };
    for c in pick_arr(v, &["channelData"]).map(|a| a.as_slice()).unwrap_or(&[]) {
        let cid = match c.get("channelId") {
            Some(Value::Number(n)) => n.to_string(),
            Some(Value::String(s)) => s.trim().to_string(),
            _ => String::new(),
        };
        let name = pick_str(c, &["channelName"]).unwrap_or("").trim().to_string();
        if cid.is_empty() || name.is_empty() {
            continue;
        }
        out.push(CspCategory {
            id: format!("{gid_for_channels}@{cid}"),
            name,
        });
    }
    out
}

/// 条目：`columnData[].videoData[]` **并上** `videoData[]`（DEX `c()` 的两处 addAll）
pub fn items_of(v: &Value) -> Vec<CspItem> {
    let mut out: Vec<CspItem> = Vec::new();
    let mut seen: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut push = |row: &Value, out: &mut Vec<CspItem>, seen: &mut std::collections::BTreeSet<String>| {
        if let Some(it) = item_of(row) {
            if seen.insert(it.id.clone()) {
                out.push(it);
            }
        }
    };
    for col in pick_arr(v, &["columnData"]).map(|a| a.as_slice()).unwrap_or(&[]) {
        for row in pick_arr(col, &["videoData"]).map(|a| a.as_slice()).unwrap_or(&[]) {
            push(row, &mut out, &mut seen);
        }
    }
    for row in pick_arr(v, &["videoData"]).map(|a| a.as_slice()).unwrap_or(&[]) {
        push(row, &mut out, &mut seen);
    }
    out
}

/// 一行 → CspItem（书 id + 书名是硬要求；副标题按 DEX 拼"更新到 N 集"/"评分"）
fn item_of(row: &Value) -> Option<CspItem> {
    let id = pick_id_str(row, &["bookId"])?;
    let title = pick_str(row, &["bookName"]).unwrap_or("").trim().to_string();
    if title.is_empty() {
        return None;
    }
    let mut sub: Vec<String> = Vec::new();
    if let Some(n) = pick_str(row, &["updateNum"]).map(|s| s.trim()).filter(|s| !s.is_empty()) {
        sub.push(format!("{n}集"));
    }
    if let Some(st) = pick_str(row, &["finishStatusCn"]).map(|s| s.trim()).filter(|s| !s.is_empty()) {
        sub.push(st.to_string());
    }
    if let Some(sc) = pick_str(row, &["videoStarsNum"]).map(|s| s.trim()).filter(|s| !s.is_empty()) {
        sub.push(format!("{sc}分"));
    }
    Some(CspItem {
        id,
        title,
        cover: pick_str(row, &["coverWap"])
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        subtitle: if sub.is_empty() { None } else { Some(sub.join(" · ")) },
    })
}

/// 详情：`videoInfo{bookName,coverWap,finishStatusCn,introduction,protagonist,chapterList[]}`
///
/// ★ 剧集 id 用 `bookId@chapterId`：DEX 的 `playerContent` 就是按 `'@'` 切的（见下）。
pub fn detail_of(v: &Value, id: &str) -> Result<CspDetail, String> {
    // 兼容两处位置：根上的 `videoInfo`，或 `data.videoInfo`
    let info = v
        .get("videoInfo")
        .filter(|x| x.is_object())
        .or_else(|| v.get("data").and_then(|d| d.get("videoInfo")));
    let info = match info {
        Some(i) => i,
        None => return Err(format!("详情没有 videoInfo（id={id}，可能改版/风控壳页）")),
    };
    let title = pick_str(info, &["bookName"]).unwrap_or("").trim().to_string();
    if title.is_empty() {
        return Err(format!("详情 bookName 为空（id={id}）"));
    }
    let mut desc_parts: Vec<String> = Vec::new();
    if let Some(p) = pick_str(info, &["protagonist"]).map(|s| s.trim()).filter(|s| !s.is_empty()) {
        desc_parts.push(format!("主演：{p}"));
    }
    if let Some(i) = pick_str(info, &["introduction"]).map(|s| s.trim()).filter(|s| !s.is_empty()) {
        desc_parts.push(i.to_string());
    }
    let mut episodes: Vec<CspEpisode> = Vec::new();
    for ch in pick_arr(info, &["chapterList"]).map(|a| a.as_slice()).unwrap_or(&[]) {
        let cid = pick_id_str(ch, &["chapterId"]).unwrap_or_default();
        if cid.is_empty() {
            continue;
        }
        let name = pick_str(ch, &["chapterName"]).unwrap_or("").trim().to_string();
        episodes.push(CspEpisode {
            id: format!("{id}@{cid}"),
            title: if name.is_empty() { format!("第{cid}集") } else { name },
            flag: FLAG.to_string(),
        });
    }
    if episodes.is_empty() {
        return Err(format!("「{title}」没有章节（chapterList 为空）"));
    }
    Ok(CspDetail {
        id: id.trim().to_string(),
        title,
        cover: pick_str(info, &["coverWap"])
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        description: if desc_parts.is_empty() { None } else { Some(desc_parts.join("\n")) },
        episodes,
    })
}

/// 从 `content` 里挑出可播地址（DEX 里是 `aliplayer(appv=…)` 解析器入口）
///
/// ★ 找不到 http 地址就**如实 Err**：把解析器入口当直链返回是假通。
pub fn pick_media_url(content: &str) -> Option<String> {
    let s = content.trim();
    if s.is_empty() {
        return None;
    }
    // ① 直接是地址
    if s.starts_with("http://") || s.starts_with("https://") {
        return Some(s.to_string());
    }
    // ② JSON 里带 url/mp4Url/playUrl
    if let Ok(j) = parse_loose_json(s) {
        for k in ["url", "mp4Url", "playUrl", "videoUrl"] {
            if let Some(u) = j.get(k).and_then(|x| x.as_str()) {
                if u.starts_with("http") {
                    return Some(u.to_string());
                }
            }
        }
    }
    // ③ 文本里第一个 http(s) 子串（`aliplayer(…url=https%3A%2F%2F…)` 这类）
    //
    // ★ 终止符里**必须有 `&`**：`aliplayer(appv=2.7.1&url=https://cdn/z.mp4&dm=x)` 用的是
    //   `&` 分隔的 k=v 串，不截断就会把 `&dm=x` 带进播放地址（→ 404）。
    //   带 `?a=1&b=2` 的真实地址走的是上面的 JSON 分支，不会被这条误伤。
    for sc in ["http://", "https://"] {
        if let Some(i) = s.find(sc) {
            let tail = &s[i..];
            let end = tail
                .find(|c: char| c == ')' || c == '"' || c == '\'' || c == '&' || c.is_whitespace())
                .unwrap_or(tail.len());
            let cand = &tail[..end];
            if cand.len() > sc.len() {
                return Some(cand.to_string());
            }
        }
    }
    None
}

// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for ShortHema {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let v = self.request(API_HOME, &list_body(0, 0)).await?;
        let categories = categories_of(&v);
        if categories.is_empty() {
            return Err(
                "河马首页没有 channelGroupData/channelData（可能模板改版/风控壳页）".to_string(),
            );
        }
        Ok(CspHome {
            categories,
            items: items_of(&v),
        })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let (gid, cid) = split_tid(tid)?;
        let _ = page; // DEX 的分页靠 `pageFlag`（字符串），第 1 页就是空串；这里如实只取第 1 页
        let v = self.request(API_HOME, &list_body(gid, cid)).await?;
        let items = items_of(&v);
        if items.is_empty() {
            return Err(format!(
                "分类 {tid} 没解析出条目（可能模板改版/风控壳页）"
            ));
        }
        Ok(CspList {
            items,
            page: 1,
            page_count: None,
            total: None,
        })
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let bid = id.trim();
        if bid.is_empty() {
            return Err("bookId 为空".to_string());
        }
        let v = self.request(API_DETAIL, &detail_body(bid)).await?;
        detail_of(&v, bid)
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let v = self.request(API_SEARCH, &search_body(kw, page)).await?;
        // DEX 读 `data.searchVos[]`，每项再取 `content`（内容是 JSON 字符串，里面有 bookId/bookName）
        let mut items: Vec<CspItem> = Vec::new();
        for row in pick_arr(&v, &["searchVos"]).map(|a| a.as_slice()).unwrap_or(&[]) {
            if let Some(it) = item_of(row) {
                items.push(it);
                continue;
            }
            // content 是字符串时再解一层（结构与上面一致）
            if let Some(inner) = pick_str(row, &["content"]) {
                if let Ok(j) = parse_loose_json(inner) {
                    if let Some(it) = item_of(&j) {
                        items.push(it);
                    }
                }
            }
        }
        if items.is_empty() {
            return Err(format!(
                "搜索「{kw}」没解析出条目（可能模板改版/风控壳页）"
            ));
        }
        Ok(CspList {
            items,
            page: page.max(1),
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        // ★ 未实测成功（被设备门禁挡住）⇒ 不声明 true。
        //   声明 true 会让 registry 把这个源拉进搜索，然后每次都 Err —— 那是假能力位。
        false
    }

    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let brief = id.trim();
        if brief.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        let (bid, cid) = brief
            .split_once('@')
            .ok_or_else(|| format!("播放 id 必须是 `bookId@chapterId`：{brief}"))?;
        if bid.is_empty() || cid.is_empty() {
            return Err(format!("播放 id 解析不出 bookId/chapterId：{brief}"));
        }
        let body = serde_json::json!({
            "bookId": bid,
            "chapterId": cid,
            "unClockType": "",
            "load": "",
            "tierPlaySource": "",
        });
        let v = self.request(API_PLAY, &body).await?;
        let content = v
            .get("chapterInfo")
            .and_then(|c| c.get("content"))
            .and_then(|c| c.as_str())
            .or_else(|| pick_str(&v, &["content"]))
            .unwrap_or("");
        match pick_media_url(content) {
            Some(url) => Ok(vec![CspPlay {
                url,
                headers: vec![("User-Agent".to_string(), UA.to_string())],
                label: Some(FLAG.to_string()),
            }]),
            None => Err(format!(
                "取流：chapterInfo.content 里没有可播地址（长度 {}；DEX 走的是 \
                 `aliplayer(appv=…)` 解析器，本仓没有该解析器；线路={FLAG}）",
                content.len()
            )),
        }
    }
}

/// `"groupId@channelId"` → (i64, i64)；也接受纯数字（当成 channelId，group=0）
pub fn split_tid(tid: &str) -> Result<(i64, i64), String> {
    let t = tid.trim();
    if t.is_empty() {
        return Err("分类 id 为空".to_string());
    }
    match t.split_once('@') {
        Some((g, c)) => {
            let gid = g.trim().parse::<i64>().unwrap_or(0);
            let cid = c
                .trim()
                .parse::<i64>()
                .map_err(|_| format!("分类 id 里的 channelId 不是整数：{t:?}"))?;
            Ok((gid, cid))
        }
        None => {
            let cid = t
                .parse::<i64>()
                .map_err(|_| format!("分类 id 不是整数：{t:?}"))?;
            Ok((0, cid))
        }
    }
}

// ══ ⚠️ **没有 `register_site!`** ══
//
// 缺第 ③ 条（真网取不到数据：设备/会话门禁回 `code=1 参数非法`）。
// 等有真设备 token（或 Owner 明示"按站点协议独立反推"）再接注册那一行。

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── ① AES 往返：真站点就是用这把 key/iv（往返必须闭合，否则线上必错）──

    #[test]
    fn aes_roundtrip_matches_the_site() {
        let obj = json!({"recSwitch":true,"pageFlag":"","theaterSubscriptSwitch":true});
        let enc = encode_payload(&obj).expect("加密必须成功");
        // 长度是 16 的倍数（PKCS5），且 base64 解码后也是 16 的倍数
        let raw = b64_decode(&enc).unwrap();
        assert_eq!(raw.len() % 16, 0);
        let back = decode_payload(&enc).expect("解回来必须成功");
        assert_eq!(back, obj, "★ 往返必须闭合（key/iv/PKCS5 任一处错都会在这里红）");
    }

    /// 用**真站点密文形状**验证：把已知明文加密后必须能被服务端同样的 key 解回
    /// （这条把 key/iv **逐字**钉住 —— 改一个字节就红）
    #[test]
    fn key_and_iv_are_the_dex_literals() {
        assert_eq!(KEY, b"dzkjgfyxgshylgzm");
        assert_eq!(IV, b"apiupdownedcrypt");
        assert_eq!(ALG, "HG45LKBS");
        // 同一段明文 + 固定 IV ⇒ 密文确定（CBC 无随机 IV）
        let a = encode_payload(&json!({"a":1})).unwrap();
        let b = encode_payload(&json!({"a":1})).unwrap();
        assert_eq!(a, b);
    }

    // ── ② 真实响应片段：`code=1 参数非法`（2026-10-27 实测原文）──

    #[test]
    fn real_param_illegal_envelope_is_an_error_not_empty_ok() {
        let raw = r#"{"timestamp":1793116874758,"code":1,"msg":"参数非法","mode":1}"#;
        let v = parse_loose_json(raw).expect("真实响应必须是合法 JSON");
        let e = decode_envelope(&v, API_HOME).expect_err("★ 业务码 1 必须 Err（不许当空列表）");
        assert!(e.contains("code=1"), "{e}");
        assert!(e.contains("参数非法"), "{e}");
        assert!(e.contains("端点活着"), "要写清这是「端点活着但身份不对」：{e}");
    }

    /// 实测：body 换成明文 JSON 时服务端的回包（证明它在解 AES）
    #[test]
    fn real_internal_error_envelope_is_an_error() {
        let raw = r#"{"timestamp":1793116956554,"code":100,"msg":"服务器内部错误,请稍后重试","mode":1}"#;
        let v = parse_loose_json(raw).unwrap();
        let e = decode_envelope(&v, API_HOME).unwrap_err();
        assert!(e.contains("code=100"), "{e}");
    }

    /// 成功形态（**未实测**，按 DEX 的解密分支构造）：data 是 base64(AES(JSON))
    #[test]
    fn success_envelope_decrypts_data_string() {
        let inner = json!({"channelGroupData":[{"channelGroupId":1,"channelGroupName":"全部"}]});
        let enc = encode_payload(&inner).unwrap();
        let env = json!({"code":0,"data":enc});
        let got = decode_envelope(&env, API_HOME).expect("应解密成内层 JSON");
        assert_eq!(got, inner);
    }

    // ── ③ 解析：分类压平 / 条目 / 详情 / 取流挑地址 ──

    #[test]
    fn categories_flatten_groups_then_channels() {
        let v = json!({
            "channelGroupData":[{"channelGroupId":7,"channelGroupName":"全部"},
                                 {"channelGroupId":8,"channelGroupName":"都市"}],
            "channelData":[{"channelId":101,"channelName":"逆袭"},{"channelId":102,"channelName":"甜宠"}]
        });
        let cats = categories_of(&v);
        assert_eq!(cats.len(), 4, "2 组 + 2 频道");
        assert_eq!(cats[0].id, "7");
        assert_eq!(cats[0].name, "推荐", "「全部」按 DEX 改成「推荐」");
        assert_eq!(cats[1].name, "都市");
        assert_eq!(cats[2].id, "7@101");
        assert_eq!(cats[2].name, "逆袭");
    }

    #[test]
    fn items_merge_column_data_and_video_data_without_duplicates() {
        let v = json!({
            "columnData":[{"videoData":[
                {"bookId":"b1","bookName":"剧一","coverWap":"https://p/1.jpg","updateNum":"80","finishStatusCn":"完结","videoStarsNum":"9.1"}]}],
            "videoData":[
                {"bookId":"b1","bookName":"剧一（重复）"},
                {"bookId":"b2","bookName":"剧二"}]
        });
        let items = items_of(&v);
        assert_eq!(items.len(), 2, "b1 只留一条（去重）");
        assert_eq!(items[0].id, "b1");
        assert_eq!(items[0].subtitle.as_deref(), Some("80集 · 完结 · 9.1分"));
        assert_eq!(items[1].id, "b2");
        assert!(items[1].subtitle.is_none());
    }

    #[test]
    fn detail_builds_book_at_chapter_ids() {
        let v = json!({ "videoInfo": {
            "bookName":"剧一","coverWap":"https://p/1.jpg","finishStatusCn":"完结",
            "introduction":"简介","protagonist":"张三",
            "chapterList":[{"chapterName":"第1集","chapterId":"c1"},{"chapterId":"c2"}]
        }});
        let d = detail_of(&v, "b1").expect("真实结构必须能解析");
        assert_eq!(d.title, "剧一");
        assert_eq!(d.episodes.len(), 2);
        assert_eq!(d.episodes[0].id, "b1@c1", "★ 必须 bookId@chapterId（play 按 @ 切）");
        assert_eq!(d.episodes[1].title, "第c2集", "没有章节名就按 id 生成");
        assert!(d.description.as_deref().unwrap_or("").contains("主演：张三"));
    }

    #[test]
    fn detail_without_chapters_is_error() {
        let v = json!({"videoInfo":{"bookName":"空剧","chapterList":[]}});
        let e = detail_of(&v, "b1").unwrap_err();
        assert!(e.contains("chapterList"), "{e}");
        let e2 = detail_of(&json!({}), "b1").unwrap_err();
        assert!(e2.contains("videoInfo"), "{e2}");
    }

    #[test]
    fn media_url_picker_handles_the_three_shapes() {
        assert_eq!(
            pick_media_url("https://cdn/x.mp4").as_deref(),
            Some("https://cdn/x.mp4")
        );
        assert_eq!(
            pick_media_url(r#"{"url":"https://cdn/y.m3u8"}"#).as_deref(),
            Some("https://cdn/y.m3u8")
        );
        assert_eq!(
            pick_media_url("aliplayer(appv=2.7.1&url=https://cdn/z.mp4&dm=x)").as_deref(),
            Some("https://cdn/z.mp4")
        );
        // 纯解析器入口（没有地址）⇒ None（上层报 Err，不假通）
        assert_eq!(pick_media_url(r#"{"ad":1}"#), None);
        assert_eq!(pick_media_url(""), None);
    }

    #[test]
    fn split_tid_accepts_both_shapes() {
        assert_eq!(split_tid("7@101").unwrap(), (7, 101));
        assert_eq!(split_tid("101").unwrap(), (0, 101));
        assert!(split_tid("").is_err());
        assert!(split_tid("7@abc").is_err());
    }

    // ── ④ 设备体逐字（这是被门禁挡住的那一环，字段名不许漂）──

    #[test]
    fn device_body_keeps_the_dex_fields() {
        let j = device_json("s1", "s2", 1793116874758);
        for k in [
            "version", "pname", "channelCode", "utdidTmp", "token", "utdid", "os", "osv",
            "brand", "model", "manu", "userId", "launch", "mchid", "nchid", "session1",
            "session2", "startScene", "recSwitch", "installTime", "p",
        ] {
            assert!(j.get(k).is_some(), "设备体缺字段：{k}");
        }
        assert_eq!(j["token"], json!(""), "★ token 空是原样 —— 就是它被挡的原因");
        assert_eq!(j["utdid"], json!(UTDID));
        assert_eq!(j["utdidTmp"], json!("A1793116874758TVBX"));
    }

    // ── ⑤ **不注册**（本批第 ③ 条不成立）──

    #[test]
    fn must_not_register_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("short_hema.rs"));
        assert!(
            !flat.contains("register_site!(ShortHema)"),
            "★ 真网取不到数据 ⇒ 本批不注册"
        );
        assert!(
            !crate::csp::is_implemented("csp_ShortHema"),
            "★ 不许进注册表（问运行时，不读源码）"
        );
    }

    #[test]
    fn class_name_is_exact() {
        assert_eq!(ShortHema::CLASS, "ShortHema");
    }

    #[test]
    fn client_builder_turns_off_proxy() {
        let src = crate::csp::shared::impl_src_only(include_str!("short_hema.rs"));
        let t = src.find(".timeout(TIMEOUT)").expect("必须有 timeout");
        let n = src.find(".no_proxy()").expect("★ 必须有 .no_proxy()");
        let b = src.find(".build()").expect("必须有 build");
        assert!(t < n && n < b, "★ .no_proxy() 必须在 timeout 之后、build 之前");
    }

    #[tokio::test]
    async fn empty_inputs_are_rejected_before_network() {
        let s = ShortHema::new();
        assert!(s.detail("  ", "").await.is_err());
        assert!(s.search("  ", 1, "").await.is_err());
        assert!(s.play("", "", "").await.is_err());
        assert!(s.list("", 1, "").await.is_err());
        // 播放 id 形状不对 ⇒ Err（不猜）
        let e = s.play("河马", "只有bookId", "").await.unwrap_err();
        assert!(e.contains("bookId@chapterId"), "{e}");
    }

    #[test]
    fn search_is_declared_unsupported_because_never_verified() {
        let s = ShortHema::new();
        assert!(!s.supports_search(), "★ 未实测成功 ⇒ 不声明 true（假能力位）");
    }
}
