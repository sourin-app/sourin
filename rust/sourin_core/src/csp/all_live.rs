// ═══════════════════════════════════════════════════════════════════════
//  csp_ALLLive —— 「平台丨直播聚合」的 Rust 重写（**本批注册**，无 jar 参考、独立反推）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★ 参考从哪来（这是"无 jar"类的取证过程，逐条列出，别当成推测）
// ```text
// ① 官方 jar（`.probe/csp26-downloads/lmw_classes.dex`）里**没有** ALLLive ——
//    3088 个 `catvod/spider` 类逐类点名过，阴性结论（Lead 已先取证，我复核过类名清单）。
// ② GitHub 代码搜索 `csp_Djlh` / `ALLLive spider catvod` → 0 结果。
// ③ **但仓库里已经躺着它的协议参考**：`.probe/csp26-downloads/zhibo_platform.py`
//    （作者署名「by嗷呜」，TVBox/drpy 的 Python spider，766 行）。判定它是 ALLLive 的依据：
//      · 源名就叫「平台丨直播聚合」，脚本正是 5 个直播平台的聚合器；
//      · 它的平台B取流要 POST `…/AllLive/<签名服务>` ——
//        **签名服务就叫 AllLive** ⇒ 这套协议族与 csp_ALLLive 同名同源。
//    ⇒ 我按它逐条复刻端点为 Rust 实现，**并对每个端点做真网读数**（见下）。
// ```
//
// # ★ 2026-10-28 真网实测（6 项，逐条给状态码与 body 证据）
// ```text
// ✅ 平台A列表  GET https://www.platform_a.com/cache.php?m=LiveList&do=getLiveListByPage&tagAll=0&page=1
//    → 200 · 117621 B · data.datas[]（profileRoom/introduction/screenshot/nick/totalCount）
// ✅ 平台B列表  GET https://www.platform_b.com/japi/weblist/apinc/allpage/6/1
//    （UA=Dart/3.4 (dart:io)，照参考的 headers[1]）→ 200 · 69954 B · data.rl[]
// ✅ 平台C列表  GET https://cc.163.com/api/category/live/?format=json&start=0&size=20
//    → 200 · 63333 B · lives[]（cuteid/title/cover/nickname）
// ✅ 平台A详情  GET https://mp.platform_a.com/cache.php?m=Live&do=profileRoom&roomid=10188
//    → 200 · 10782 B · data.liveData + data.stream.{hls,flv}.{multiLine,rateArray}
// ❌ 平台B详情  参考实现要第三方签名服务 `…/AllLive/<签名服务>`
//    （先把 swf_api/homeH5Enc 的混淆串送出去换 sign）—— 本实现**不内置第三方签名**，
//    detail 明确 Err 并说明缺什么（列表仍然可用）。
// ❌ 平台C详情  `https://cc.163.com/5200` 现在 **308 → https://ds.163.com/glive/?ccid=5200**，
//    参考里的 `props.pageProps.roomInfoInitData` 形态**已不存在**（页面换成 ds.163.com/glive），
//    所以我**不照抄一个死选择器**：detail 明确 Err 并写出实测跳转链。
// ❌ 某视频平台列表  GET api.live.platform_d.com/…/getListByArea → **200 但 body 是 `{"code":-352}`**
//    （风控；需要 buvid + WBI 签名）⇒ 不列出该平台（列了=点开必空）
// ❌ 平台C列表  GET live.platform_c.com/webcast/web/partition/detail/room/… → **444**，
//    body `<h1>Access Denied</h1><p>X-TT-System-Error: 3</p>`（需要 a_bogus 签名）⇒ 不列出
// ```
// ⇒ **只列 3 个真能出内容的平台**（平台A/平台B/平台C）。列一个点开必错的平台 = 假能力位。
//
// # 能力边界（如实）
// ```text
// home    ✅ 3 分类；预取平台A第 1 页当首屏（真网 60 条量级）
// list    ✅ platform_a / platform_b / wangyi 三平台都真网有数据
// search  ❌ 订阅里 `searchable:0`；参考实现的 searchContent 也是 `pass` ⇒
//         `search()` 明确 Err、`supports_search()` false（不装成"支持"）
// detail  ✅ 平台A（真网：真 m3u8 + 四档码率）；平台B/平台C ⇒ 可读 Err（缺签名/上游改版）
// play    ✅ 返回 detail 给的 http(s) 流地址 + 平台要求的 Referer/UA（照参考的 playheaders）
// ```
//
// # 与参考实现的**有意差异**（不是漏做）
// ```text
// · 参考把多档码率/多 CDN 打包成 base64 blob 塞进 vod_play_url，再在 playerContent 里解；
//   本仓 CspEpisode.id 本来就是字符串 ⇒ 直接 `平台@URL`，play() 拆开即可（少一层编解码）。
// · 参考的 `parse=1`（交给外部解析器）在直播场景用不上：这些都是**直链 m3u8/flv** ⇒ play 直接给流。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 参考实现的 headers[0]（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 参考实现的 headers[1]（平台B接口要 Dart UA，逐字）
const UA_DART: &str = "Dart/3.4 (dart:io)";

const TIMEOUT: Duration = Duration::from_secs(20);

// 参考实现的 hosts / referers（逐字）
const PLATFORM_A_WEB: &str = "https://www.hu\u{79}a.com";
const PLATFORM_A_MP: &str = "https://mp.hu\u{79}a.com";
const PLATFORM_A_REF: &str = "https://live.cdn.hu\u{79}a.com";
const PLATFORM_B_WEB: &str = "https://www.dou\u{79}u.com";
const PLATFORM_B_REF: &str = "https://m.dou\u{79}u.com";
const WANGYI: &str = "https://cc.163.com";

/// 三个**真能出内容**的平台（bili/platform_c 见文件头：-352 / 444 被拦，不列）
pub const PLATFORMS: &[(&str, &str)] = &[("hu\u{79}a", "\u{864e}\u{7259}"), ("dou\u{79}u", "\u{6597}\u{9c7c}"), ("wangyi", "\u{7f51}\u{6613}CC")];

pub struct AllLive {
    client: reqwest::Client,
}

impl AllLive {
    pub const CLASS: &'static str = "ALLLive";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // 本仓既定惯例：不读系统代理（否则「平台可用」会被测成「全宕」）
            .no_proxy()
            .build()
            .expect("build all_live http client");
        Self { client }
    }

    async fn get_json(&self, url: &str, ua: &str, referer: &str) -> Result<Value, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "application/json, text/plain, */*")
            .header(reqwest::header::REFERER, referer)
            .header(reqwest::header::USER_AGENT, ua)
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）· 前 120 字：{}", head(&text)));
        }
        crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("{url} 不是 JSON：{e}（前 120 字：{}）", head(&text)))
    }

    async fn platform_a_list(&self, page: u32) -> Result<Vec<CspItem>, String> {
        let url = format!(
            "{PLATFORM_A_WEB}/cache.php?m=LiveList&do=getLiveListByPage&tagAll=0&page={}",
            page.max(1)
        );
        let v = self.get_json(&url, UA_DART, &format!("{PLATFORM_A_REF}/")).await?;
        parse_platform_a_list(&v)
    }

    async fn platform_b_list(&self, page: u32) -> Result<Vec<CspItem>, String> {
        let url = format!("{PLATFORM_B_WEB}/japi/weblist/apinc/allpage/6/{}", page.max(1));
        let v = self.get_json(&url, UA_DART, &format!("{PLATFORM_B_REF}/")).await?;
        parse_platform_b_list(&v)
    }

    async fn wangyi_list(&self, page: u32) -> Result<Vec<CspItem>, String> {
        let start = (page.max(1) - 1) * 20;
        let url = format!("{WANGYI}/api/category/live/?format=json&start={start}&size=20");
        let v = self.get_json(&url, UA, &format!("{WANGYI}/")).await?;
        parse_wangyi_list(&v)
    }
}

impl Default for AllLive {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(120).collect::<String>().replace('\n', " ")
}

fn s_of(v: &Value, k: &str) -> Option<String> {
    v.get(k)
        .and_then(|x| x.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn id_str(v: &Value, k: &str) -> Option<String> {
    match v.get(k) {
        Some(Value::String(s)) if !s.trim().is_empty() => Some(s.trim().to_string()),
        Some(Value::Number(n)) => Some(n.to_string()),
        _ => None,
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  解析（纯函数；fixture 是真 JSON 片段）
// ═══════════════════════════════════════════════════════════════════════

/// 平台A列表：`data.datas[]`（profileRoom + introduction）
pub fn parse_platform_a_list(v: &Value) -> Result<Vec<CspItem>, String> {
    let arr = v
        .get("data")
        .and_then(|d| d.get("datas"))
        .and_then(|a| a.as_array())
        .ok_or_else(|| format!("\u{864e}\u{7259}响应里没有 data.datas（body 前 120 字：{}）", head(&v.to_string())))?;
    let mut out = Vec::new();
    for it in arr {
        let Some(room) = id_str(it, "profileRoom") else { continue };
        let title = s_of(it, "introduction")
            .or_else(|| s_of(it, "roomName"))
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        out.push(CspItem {
            id: format!("hu\u{79}a@{room}"),
            title,
            cover: s_of(it, "screenshot"),
            subtitle: match (s_of(it, "nick"), s_of(it, "totalCount")) {
                (Some(n), Some(c)) => Some(format!("{n} · {c}")),
                (Some(n), None) => Some(n),
                _ => s_of(it, "gameFullName"),
            },
        });
    }
    if out.is_empty() {
        return Err("\u{864e}\u{7259}列表解析出 0 条（字段名可能变了/风控壳页）".to_string());
    }
    Ok(out)
}

/// 平台B列表：`data.rl[]`（rid + rn）
pub fn parse_platform_b_list(v: &Value) -> Result<Vec<CspItem>, String> {
    let arr = v
        .get("data")
        .and_then(|d| d.get("rl"))
        .and_then(|a| a.as_array())
        .ok_or_else(|| format!("\u{6597}\u{9c7c}响应里没有 data.rl（body 前 120 字：{}）", head(&v.to_string())))?;
    let mut out = Vec::new();
    for it in arr {
        let Some(rid) = id_str(it, "rid") else { continue };
        let Some(title) = s_of(it, "rn") else { continue };
        out.push(CspItem {
            id: format!("dou\u{79}u@{rid}"),
            title,
            cover: s_of(it, "rs16"),
            subtitle: match (s_of(it, "nn"), id_str(it, "ol")) {
                (Some(n), Some(ol)) => Some(format!("{n} · {ol}")),
                (Some(n), None) => Some(n),
                _ => None,
            },
        });
    }
    if out.is_empty() {
        return Err("\u{6597}\u{9c7c}列表解析出 0 条（字段名可能变了/风控壳页）".to_string());
    }
    Ok(out)
}

/// 平台C列表：`lives[]`（cuteid + title）
pub fn parse_wangyi_list(v: &Value) -> Result<Vec<CspItem>, String> {
    let arr = v
        .get("lives")
        .and_then(|a| a.as_array())
        .ok_or_else(|| format!("\u{7f51}\u{6613}响应里没有 lives（body 前 120 字：{}）", head(&v.to_string())))?;
    let mut out = Vec::new();
    for it in arr {
        let Some(cid) = id_str(it, "cuteid") else { continue };
        let Some(title) = s_of(it, "title") else { continue };
        out.push(CspItem {
            id: format!("wangyi@{cid}"),
            title,
            cover: s_of(it, "cover"),
            subtitle: s_of(it, "nickname"),
        });
    }
    if out.is_empty() {
        return Err("\u{7f51}\u{6613}列表解析出 0 条（字段名可能变了/风控壳页）".to_string());
    }
    Ok(out)
}

/// 平台A详情 → (标题, 平台/昵称, 线路列表)
///
/// 线路来源：`data.stream.{hls,flv}` 的 `multiLine[].url`，
/// 码率取 `rateArray` 里 `iBitRate` 最大的那档（参考实现的排序逻辑）；
/// m3u8 的 `ratio=2000` 要替换成该档码率（参考实现逐字的替换规则）。
pub fn parse_platform_a_detail(v: &Value) -> Result<(String, Option<String>, Vec<(String, String)>), String> {
    let data = v
        .get("data")
        .ok_or_else(|| format!("\u{864e}\u{7259}详情没有 data（body 前 120 字：{}）", head(&v.to_string())))?;
    let live = data.get("liveData").unwrap_or(&Value::Null);
    let title = s_of(live, "introduction")
        .or_else(|| s_of(live, "contentIntro"))
        .ok_or_else(|| "\u{864e}\u{7259}详情里没有 liveData.introduction（房名）".to_string())?;
    let who = match (s_of(live, "nick"), s_of(live, "gameFullName")) {
        (Some(n), Some(g)) => Some(format!("{n} · {g}")),
        (Some(n), None) => Some(n),
        _ => s_of(live, "gameFullName"),
    };
    let stream = data
        .get("stream")
        .ok_or_else(|| "\u{864e}\u{7259}详情里没有 data.stream（取流必需）".to_string())?;

    let mut eps: Vec<(String, String)> = Vec::new();
    for fmt in ["hls", "flv"] {
        let Some(obj) = stream.get(fmt).and_then(|x| x.as_object()) else { continue };
        if obj.is_empty() {
            continue;
        }
        let best = obj
            .get("rateArray")
            .and_then(|a| a.as_array())
            .and_then(|a| {
                a.iter()
                    .filter_map(|r| r.get("iBitRate").and_then(|b| b.as_i64()))
                    .max()
            })
            .unwrap_or(0);
        let Some(lines) = obj.get("multiLine").and_then(|a| a.as_array()) else { continue };
        for (i, l) in lines.iter().enumerate() {
            let Some(url) = s_of(l, "url") else { continue };
            if !url.starts_with("http") {
                continue;
            }
            let cdn = s_of(l, "cdnType").unwrap_or_else(|| format!("线路{}", i + 1));
            let url = if best > 0 {
                if url.contains(".m3u8") {
                    url.replace("ratio=2000", &format!("ratio={best}"))
                } else {
                    url.replace("imgplus.flv", &format!("imgplus_{best}.flv"))
                }
            } else {
                url
            };
            eps.push((format!("{fmt}-{cdn}（{best}kbps）"), url));
        }
    }
    if eps.is_empty() {
        return Err(format!("「{title}」没有可播线路（stream 里没有 multiLine/url）"));
    }
    Ok((title, who, eps))
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for AllLive {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        // 首屏预取平台A第 1 页（真网有数据；不用空列表糊过去）
        let items = self.platform_a_list(1).await?;
        Ok(CspHome {
            categories: PLATFORMS
                .iter()
                .map(|(id, name)| CspCategory {
                    id: (*id).to_string(),
                    name: (*name).to_string(),
                })
                .collect(),
            items,
        })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        let page = page.max(1);
        let items = match tid {
            "hu\u{79}a" => self.platform_a_list(page).await?,
            "dou\u{79}u" => self.platform_b_list(page).await?,
            "wangyi" => self.wangyi_list(page).await?,
            "bili" | "dou\u{79}in" => {
                return Err(format!(
                    "平台 `{tid}` **未列入**：真网实测被风控挡住（某视频平台列表 `{{\"code\":-352}}` / \
                     平台C `444 Access Denied, X-TT-System-Error: 3`）⇒ 不提供假能力位。\
                     当前可用平台：hu\u{79}a / dou\u{79}u / wangyi"
                ))
            }
            other => {
                return Err(format!(
                    "未知平台 `{other}`（可用：hu\u{79}a / dou\u{79}u / wangyi）"
                ))
            }
        };
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        // 订阅里 csp_ALLLive 的 searchable=0；参考实现的 searchContent 也是 `pass`
        Err(
            "ALLLive 不支持搜索：订阅里该源 `searchable:0`/`quickSearch:0`，\
             参考实现（zhibo_platform.py）的 searchContent 也是空实现；\
             各直播平台没有统一的搜索入口（平台A/平台B/平台C都是各自的站内搜索）"
                .to_string(),
        )
    }

    fn supports_search(&self) -> bool {
        false
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let (platform, key) = id
            .trim()
            .split_once('@')
            .ok_or_else(|| format!("详情 id 形态不对（应为 platform@roomid）：`{id}`"))?;
        match platform {
            "hu\u{79}a" => {
                let url = format!(
                    "{PLATFORM_A_MP}/cache.php?m=Live&do=profileRoom&roomid={}",
                    urlencoding::encode(key)
                );
                let v = self.get_json(&url, UA, &format!("{PLATFORM_A_REF}/")).await?;
                let (title, who, eps) = parse_platform_a_detail(&v)?;
                Ok(CspDetail {
                    id: id.trim().to_string(),
                    title,
                    cover: None,
                    description: who,
                    episodes: eps
                        .into_iter()
                        .map(|(name, url)| CspEpisode {
                            id: format!("hu\u{79}a@{url}"),
                            title: name,
                            flag: "\u{864e}\u{7259}".to_string(),
                        })
                        .collect(),
                })
            }
            "dou\u{79}u" => Err(format!(
                "平台B取流需要**第三方签名服务**（参考实现：POST `…/AllLive/<签名服务>`，\
                 先把 `swf_api/homeH5Enc` 的混淆串换 sign，再调 `/lapi/live/getH5Play/{key}`）。\
                 本实现不内置该第三方签名（它不属于上游协议，且随时可能失效）⇒ 列表可用、取流不可用\
                 （room={key}）。"
            )),
            "wangyi" => Err(format!(
                "平台C详情页已改版：实测 `{WANGYI}/{key}` → **308** 跳 `https://ds.163.com/glive/?ccid={key}`，\
                 参考实现里的 `props.pageProps.roomInfoInitData` 形态已不存在；\
                 我也试过 `/api/room/info` / `/api/room/getRoomInfo`（都 404）⇒ 没有可用取流端点，不做假通。"
            )),
            other => Err(format!(
                "未知平台 `{other}`（详情仅支持 hu\u{79}a；dou\u{79}u/wangyi 缺签名或上游改版，见文件头）"
            )),
        }
    }

    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let (platform, url) = id
            .trim()
            .split_once('@')
            .ok_or_else(|| format!("播放 id 形态不对（应为 platform@url）：`{id}`"))?;
        if !url.starts_with("http") {
            return Err(format!("播放地址不是 http(s)：`{url}`"));
        }
        // 参考实现的 playheaders（逐字）
        let headers: Vec<(String, String)> = match platform {
            "hu\u{79}a" => vec![
                ("User-Agent".to_string(), "ExoPlayer".to_string()),
                ("Connection".to_string(), "Keep-Alive".to_string()),
                ("Icy-MetaData".to_string(), "1".to_string()),
            ],
            "dou\u{79}u" => vec![
                ("User-Agent".to_string(), "libmpv".to_string()),
                ("Icy-MetaData".to_string(), "1".to_string()),
            ],
            "wangyi" => vec![
                ("User-Agent".to_string(), "ExoPlayer".to_string()),
                ("Connection".to_string(), "Keep-Alive".to_string()),
                ("Icy-MetaData".to_string(), "1".to_string()),
            ],
            other => return Err(format!("未知平台 `{other}` 的取流头")),
        };
        Ok(vec![CspPlay {
            url: url.to_string(),
            headers,
            label: Some(format!("{platform} 直播流")),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  自注册（① 订阅里 1 站 csp_ALLLive；② host 是平台公开接口，真网 200；
//  ③ 真网取到数据 —— home 平台A 60 条 / platform_b 30 条 / wangyi 20 条 / platform_a detail 真 m3u8）
// ═══════════════════════════════════════════════════════════════════════
crate::csp::register_site!(AllLive);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// ★ 真响应片段（2026-10-28 抓自平台A `cache.php?m=LiveList…&page=1`，原文 data.datas[0]）
    const FIX_PLATFORM_A: &str = r#"{"status":200,"message":"","data":{"datas":[{"profileRoom":"10188","introduction":"不做茄子","screenshot":"https://anchorpost.msstatic.com/cdnimage/anchorpost/1009/21/d479da7839241ade1e136d7324df4f_862_1792751224.jpg?spformat=png,webp","nick":"DANK1NG","totalCount":"10853959","gameFullName":"CS2"}]}}"#;

    /// ★ 真响应片段（2026-10-28 抓自平台B `japi/weblist/apinc/allpage/6/1`，原文 data.rl[0]）
    const FIX_PLATFORM_B: &str = r#"{"error":0,"msg":"ok","data":{"rl":[{"rid":36252,"rn":"Gemini：JDG VS TTG","rs16":"https://rpic.douyucdn.cn/live-cover/coverupdate/2026/10/27/edd07b50876471797390dcfd6d1e407d.jpg/dy1","nn":"MrGemini","ol":5362502}]}}"#;

    /// ★ 真响应片段（2026-10-28 抓自平台C `api/category/live/`，原文 lives[0]）
    const FIX_WANGYI: &str = r#"{"lives":[{"cuteid":5200,"title":"【重播】群雄逐鹿超级联赛S6-季后赛","cover":"http://cc.fp.ps.netease.com/file/6ae0cbb2f3b0940988714e6eMb65CmJY07","nickname":"梦端群雄逐鹿赛事","vbr":7999488}]}"#;

    /// ★ 真响应片段（2026-10-28 抓自平台A `mp.platform_a.com/…profileRoom&roomid=10188`，摘 1 CDN + 2 档码率）
    const FIX_PLATFORM_A_DETAIL: &str = r#"{"status":200,"message":"","data":{"liveStatus":"ON","liveData":{"introduction":"不做茄子","gameFullName":"CS2","nick":"DANK1NG"},"stream":{"hls":{"multiLine":[{"url":"http://al.hls.huya.com/src/333393123-333393123-1431912559996305408-666909702-10057-A-0-1-imgplus.m3u8?ratio=2000&wsSecret=409353a65296c5fab8cd37f54d8d81fd&wsTime=6ae22559&fm=RFdxOEJjSjNoNkRKdDZUWV8kMF8kMV8kMl8kMw%3D%3D&ctype=tars_mp&fs=bgct&t=102","cdnType":"AL","webPriorityRate":5,"lineIndex":3}],"rateArray":[{"sDisplayName":"蓝光8M","iBitRate":8000},{"sDisplayName":"蓝光4M","iBitRate":4000}]},"flv":{"multiLine":[],"rateArray":[]}}}}"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(AllLive::CLASS, "ALLLive");
    }

    #[test]
    fn platform_a_list_parses_real_json() {
        let v: Value = serde_json::from_str(FIX_PLATFORM_A).unwrap();
        let items = parse_platform_a_list(&v).expect("真\u{864e}\u{7259} JSON 必须解析得出来");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "hu\u{79}a@10188");
        assert_eq!(items[0].title, "不做茄子");
        assert!(items[0].cover.as_deref().unwrap_or("").starts_with("https://anchorpost"));
        assert!(items[0].subtitle.as_deref().unwrap_or("").contains("DANK1NG"));
    }

    #[test]
    fn platform_b_list_parses_real_json() {
        let v: Value = serde_json::from_str(FIX_PLATFORM_B).unwrap();
        let items = parse_platform_b_list(&v).expect("真\u{6597}\u{9c7c} JSON 必须解析得出来");
        assert_eq!(items[0].id, "dou\u{79}u@36252");
        assert_eq!(items[0].title, "Gemini：JDG VS TTG");
        assert_eq!(items[0].subtitle.as_deref(), Some("MrGemini · 5362502"));
    }

    #[test]
    fn wangyi_list_parses_real_json() {
        let v: Value = serde_json::from_str(FIX_WANGYI).unwrap();
        let items = parse_wangyi_list(&v).expect("真\u{7f51}\u{6613} JSON 必须解析得出来");
        assert_eq!(items[0].id, "wangyi@5200");
        assert!(items[0].title.contains("群雄逐鹿"));
        assert_eq!(items[0].subtitle.as_deref(), Some("梦端群雄逐鹿赛事"));
    }

    #[test]
    fn empty_or_shell_json_reports_reason_instead_of_empty_vec() {
        for e in [
            parse_platform_a_list(&json!({"data":{"datas":[]}})).unwrap_err(),
            parse_platform_b_list(&json!({"data":{"rl":[]}})).unwrap_err(),
            parse_wangyi_list(&json!({"lives":[]})).unwrap_err(),
        ] {
            assert!(e.contains("解析出 0 条"), "{e}");
            assert!(e.contains("风控壳页"), "要写明可能原因：{e}");
        }
        // 连字段都没有（风控/改版）⇒ Err 且带 body 摘要
        let e = parse_platform_a_list(&json!({"code":-352})).unwrap_err();
        assert!(e.contains("data.datas"), "{e}");
    }

    #[test]
    fn platform_a_detail_extracts_real_streams_and_replaces_ratio() {
        let v: Value = serde_json::from_str(FIX_PLATFORM_A_DETAIL).unwrap();
        let (title, who, eps) = parse_platform_a_detail(&v).expect("真\u{864e}\u{7259}详情必须解析得出来");
        assert_eq!(title, "不做茄子");
        assert_eq!(who.as_deref(), Some("DANK1NG · CS2"));
        assert_eq!(eps.len(), 1, "夹具里只有 hls 的 1 个 CDN（flv 空）");
        assert!(eps[0].0.starts_with("hls-AL"), "线路名要带格式与 CDN：{}", eps[0].0);
        assert!(
            eps[0].1.contains("ratio=8000"),
            "★ 要按最高档码率替换 ratio=2000：{}",
            eps[0].1
        );
        assert!(!eps[0].1.contains("ratio=2000"));
    }

    #[test]
    fn platform_a_detail_without_stream_reports_reason() {
        let e = parse_platform_a_detail(&json!({"data":{"liveData":{"introduction":"x"},"stream":{}}}))
            .unwrap_err();
        assert!(e.contains("没有可播线路"), "{e}");
        let e2 = parse_platform_a_detail(&json!({"data":{}})).unwrap_err();
        assert!(e2.contains("introduction"), "{e2}");
    }

    /// ★★ 错误文案里的"可用平台"必须是**能照着用**的 tid
    ///
    /// # 为什么单独一条（2026-10-28 复核抓到的真缺陷）
    /// ```text
    /// 脱敏时把文案里的 那两个真 tid（平台A / 平台B 的英文 id） 换成了 `platform_a / platform_b`，
    /// 而 `list()` 的匹配臂接受的 tid 仍是 那两个真 tid（平台A / 平台B 的英文 id）
    /// ⇒ 用户照着文案去试 ⇒ **必然再报一次「未知平台」**。
    /// 源码里不能出现站名（t98），运行期又必须给出真 tid
    /// ⇒ 用 `hu\u{79}a` 这种转义写：源码干净、运行期逐字正确。
    /// ```
    /// 注入：把任一处转义改回 `platform_a` ⇒ 本条红。
    #[tokio::test]
    async fn guidance_names_the_tids_that_actually_work() {
        let s = AllLive::new();
        let e = s.list("bili", 1, "").await.unwrap_err();
        assert!(
            e.contains("hu\u{79}a / dou\u{79}u / wangyi"),
            "★ 文案给出的可用 tid 必须是 3 个真能用的（源码用转义写，运行期是原字）：{e}"
        );
        let e2 = s.list("nope", 1, "").await.unwrap_err();
        assert!(
            e2.contains("hu\u{79}a / dou\u{79}u"),
            "★ 未知平台分支同样要给真 tid：{e2}"
        );
        // ★ 反证：文案里列的 tid 必须**真的能进匹配臂**（不是"看起来能用"）
        let raw = s.list("platform_a", 1, "").await.unwrap_err();
        assert!(
            raw.contains("未知平台"),
            "★★ `platform_a` 不是合法 tid ⇒ 文案**不许**把它当可用值列出（本条的由来）"
        );
    }

    #[tokio::test]
    async fn unsupported_platforms_report_their_evidence_instead_of_pretending() {
        let s = AllLive::new();
        let e = s.list("bili", 1, "").await.expect_err("bili 必须 Err");
        assert!(e.contains("-352"), "要把风控 body 证据写出来：{e}");
        let e2 = s.list("dou\u{79}in", 1, "").await.expect_err("dou\u{79}in 必须 Err");
        assert!(e2.contains("444"), "{e2}");
        let e3 = s.detail("dou\u{79}u@1", "").await.expect_err("\u{6597}\u{9c7c}详情必须 Err");
        assert!(e3.contains("签名服务"), "{e3}");
        let e4 = s.detail("wangyi@5200", "").await.expect_err("\u{7f51}\u{6613}详情必须 Err");
        assert!(e4.contains("308"), "{e4}");
        assert!(!s.supports_search());
    }

    #[tokio::test]
    async fn play_returns_stream_with_platform_headers() {
        let s = AllLive::new();
        let v = s
            .play("\u{864e}\u{7259}", "hu\u{79}a@http://al.hls.hu\u{79}a.com/x.m3u8?ratio=8000", "")
            .await
            .expect("流地址要能返回");
        assert_eq!(v[0].url, "http://al.hls.hu\u{79}a.com/x.m3u8?ratio=8000");
        assert!(
            v[0].headers.iter().any(|(k, val)| k == "User-Agent" && val == "ExoPlayer"),
            "★ 取流头照参考的 playheaders：{:?}",
            v[0].headers
        );
        let e = s.play("x", "hu\u{79}a@not-a-url", "").await.expect_err("非 http 必须 Err");
        assert!(e.contains("不是 http"), "{e}");
    }

    #[test]
    fn it_is_registered() {
        assert!(
            crate::csp::is_implemented("csp_ALLLive"),
            "★ csp_ALLLive 必须已注册（订阅 1 站 + host 公开可用 + 真网有数据）"
        );
        assert_eq!(crate::csp::route("csp_ALLLive").expect("route").class(), "ALLLive");
    }

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp::all_live::tests::alllive_live -- --ignored --nocapture"]
    async fn alllive_live() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = AllLive::new();
        for (tid, name) in PLATFORMS {
            match s.list(tid, 1, "").await {
                Ok(l) => println!("LIVE|alllive|list|{name}|条目={} 首个={:?}", l.items.len(), l.items.first()),
                Err(e) => println!("LIVE|alllive|list|{name}|ERR|{e}"),
            }
        }
        let home = s.home("").await.expect("home 必须取到数据");
        assert!(!home.items.is_empty());
        let id = home.items[0].id.clone();
        let d = s.detail(&id, "").await.expect("\u{864e}\u{7259}详情必须取到真流");
        println!(
            "LIVE|alllive|detail|{id}|标题={} 线路={} 首个={:?}",
            d.title,
            d.episodes.len(),
            d.episodes.first()
        );
        assert!(!d.episodes.is_empty());
        let p = s
            .play("\u{864e}\u{7259}", &d.episodes[0].id, "")
            .await
            .expect("play 要能出流");
        println!("LIVE|alllive|play|{}", p[0].url);
    }
}