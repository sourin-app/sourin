// ═══════════════════════════════════════════════════════════════════════
//  csp_YunDuo —— 「🦊布布丨蓝光秒播」（多多影视，Vue SPA + `/api.php/web/*`）
// ═══════════════════════════════════════════════════════════════════════
//
// # 配置里覆盖什么
//
// ```text
// 订阅（8815.kstore.vip/tvbox/wmz）100 站里：
//   csp_YunDuo  🦊布布丨蓝光秒播
//   ext = {"host":"https://323433ssdfd.top",
//          "finger":"WF-2c064bc5b3400788f31b848849bc3a60f835423ba2dfe69d7ea93974c216e4f2",
//          "aid":"com.web.player",
//          "sk":"WEB-50a8e9c84a1dc05669a692ded99a2dac46527229e607a7be15db88dbc59059d1",
//          "client":"8f3d2a1c7b6e5d4c9a0b1f2e3d4c5b6a",
//          "sign":"ddtvf65f3a83d6d9ad6f"}
// ```
//
// # ★★ 探明方式（**读静态 JS 文本**，不是执行 JS —— 这条值得记）
//
// ```text
// 第一次探测：`/index/home`、`/filter/vod`、`/api/zzz` 等**任意路径**都返回
//   同一个 1629 字节的 index.html ⇒ 判定它是 **SPA 兜底路由**。
// ⇒ 我没有停在"SPA ⇒ 拿不到 API"，而是**读 index.html**：
//     它引 `/assets/index-CyTZheoy.js`（66 KB，Vite 构建的 Vue bundle）
//   ⇒ **下载那份 JS 当文本读**（不需要 JS 引擎！）：
//     · 端点表：`/api.php/web/{index/home, filter/vod, vod/get_detail,
//                search/index, ranking/list, feature, decode/url, …}`
//     · 请求头**全是常量**：
//         `X-Client: 8f3d2a1c7b6e5d4c9a0b1f2e3d4c5b6a`  ← 就是 ext.client
//         `web-sign: ddtvf65f3a83d6d9ad6f`              ← 就是 ext.sign
//       （且只在 URL 含 `api.php` 时才加 `web-sign`）
// ⇒ **ext 里给的 client/sign 就是直接用的头值，不需要"算"签名**。
// ★ 教训：**"SPA 拿不到接口"不是结论** —— 前端 bundle 里写着接口表与头常量，
//   而读文本**不需要 JS 引擎**。（把这条记下来，同类 SPA 站点都能这么拆。）
// ```
//
// # ★★ 2026-10-27 真网络实测：四段通，第五段（取流）卡在站点自身的解码器
//
// ```text
// ✅ home    GET /api.php/web/index/home → 200 真数据
//             data.categories 4 个：电影(1) 剧集(2) 动漫(3) 综艺(4)，各带 videos[]
//             + data.recommend[] / data.hotSearch[] / data.siteConfig.domain
// ✅ list    GET /api.php/web/filter/vod?type_name=&page=1 → 200，**24 条/页**
//             ★ 参数是 **type_name**（分类**名**），不是 type_id：
//               `type_name=电影` → 24 条；`type_name=1` → **0 条**（名字不匹配）
//               空 type_name → 24 条（= 全部）
//             响应自带 `total` / `page` / `limit` / `pageCount` ⇒ 真分页（如实透出）
// ✅ detail  GET /api.php/web/vod/get_detail?vod_id=363 → 200，171 KB
//             ★ **响应自带 `vod_play_from` + `vod_play_url`**（含剧集与多线路）
//               from = "PAN1$$$zijianm3u8$$$CO4K$$$NBY$$$qsvip$$$BBA"
//               url  = "第1集$PAN1-pBTFch38…"（`名$值`、`#` 分集、`$$$` 分线）
//               参数名是 **vod_id**（`id=` → `code:400 参数错误`）
// ✅ search  GET /api.php/web/search/index?wd=仙逆 → 200，**15 条真命中**
//             ★ 参数名是 **wd**（`name=`/`keywords=` → `400 搜索关键词不能为空`）
//             另有 `/internal/search_aggregate`（要 vod_id 或 name，聚合多站）
// ⛔ play    `vod_play_url` 的值是**不透明密文**（形如 `PAN1-pBTFch38YURjS_CJvf_…`），
//             必须过 `/api.php/web/decode/url` —— 见下"未实现"
// ```
//
// # ⛔ 未实现：`play` —— 卡在站点**自身的** wasm 解码器（如实登记 + 穷举留档）
//
// ```text
// 【原版怎么解】读 bundle 得到的调用链：
//     `await Ct()`                     ← 初始化 wasm（`/assets/web_app_wasm_bg-Bxwbrgev.wasm`）
//     `xt(e, t)`                       ← **wasm 编码**成 protobuf 请求体
//     `dt($.decodeUrlPb, r)`           ← POST /api.php/web/decode/url（`application/x-protobuf`）
//     `kt(n)`                          ← 解 protobuf 回应
//
// 【我做到哪一步（全部真网络实测）】
//   ① 手工拼 protobuf（**纯 Python/Rust 可以拼**，不需要 wasm）打这个端点，
//      把它的**错误 protobuf** 解出来当"服务端在告诉我缺什么"：
//        空 body            → field2="缺少url参数"
//        field1=<blob>      → field2="缺少vodFrom参数"
//        field1 + field2    → field1=varint 401、field2="签名验证失败: 缺少必要参数"
//      ⇒ **字段号是 f1=url、f2=vodFrom**（我用 1..6 逐字段试出来的，不是猜的）
//   ② 卡在最后一关：**第二个签名**。
//      · 站点对每个请求只加一个常量头 `web-sign: ddtvf65f3a83d6d9ad6f`
//      · 加了它仍报 `401 签名验证失败: 缺少必要参数`
//      · 我试过把各种签名放**请求头**（X-Sign / sign / web-sign2 / x-sign /
//        X-Nonce / X-Time / x-request-id）—— 错误**一字不变**
//      · 试过把签名放**请求体** f3..f6（sha256/md5/ext.sign/空）—— 错误**一字不变**
//      ⇒ 结论：这一步的签名由 **wasm 模块内部**产生（bundle 只有它的胶水层，
//        算法在 `web_app_wasm_bg.wasm` 里）。**本仓不嵌 wasm 运行时**
//        （与"不嵌 JVM / 不嵌 JS 引擎"同一口径）。
//   ③ 另试过一条**跨类线索**（打掉一个可能的侥幸）：
//      YunDuo 的线路名 `CO4K/NBY/qsvip` 与 **Gulu DEX 常量里**的解析服务**同名**，
//      于是我拿 Gulu 里那批供应商 api（`co4k.1ljx.com/api/?key=…&url=` 等）去解这些值。
//      ⇒ 供应商**全部活着**（各自回了自己的业务错误，不是 404），
//        但都说"url 不正确/Invalid ID" ⇒ **YunDuo 的值不是那些 api 认的编码**。
//        ⇒ 这条线索**被排除**（不是"能绕过 wasm"，如实记）。
//
// 【所以 play 的能力边界】
//     detail 能列出**全部线路与剧集**（真数据），
//     但点进去取流会得到**点名真因**的错误（缺站点自身 wasm 签名的能力位），
//     **绝不伪造地址**、也**不假装"这条线路没源"**。
// ```
//
// # 已知缺口（按 Lead 裁定的契约边界登记）
// ```text
// · mProxy   —— 本批不做（本批无 mProxy 等价位）
// · loadPic  —— 本仓不补 trait；封面头见 COVER_HEADERS（实测该 CDN 直连可取）
// · 上游 `?v=` 参数 —— DEX `b()` 里有 `v=1`，本实现照带（实测不被校验，但按 DEX 保真）
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use crate::csp::shared::{pick_arr, pick_id_str, pick_str, split_lines};

/// ext 缺省时的兜底 host（订阅里 ext 有给，这里是保险）
const DEFAULT_HOST: &str = "https://323433ssdfd.top";

/// ★ `X-Client` 与 `web-sign` 是**常量头**（bundle 里逐字读出来的；与 ext 给的相同）
const CLIENT_FALLBACK: &str = "8f3d2a1c7b6e5d4c9a0b1f2e3d4c5b6a";
const WEB_SIGN_FALLBACK: &str = "ddtvf65f3a83d6d9ad6f";

const UA: &str = "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 封面请求头（声明式）—— 实测 `vcover-vt-pic.puui.qpic.cn` / `cos.hxx2023.cc` 直连可取
pub const COVER_HEADERS: &[(&str, &str)] = &[];

const TIMEOUT: Duration = Duration::from_secs(20);

/// 重试次数：★ 实测该站 TLS 有**间歇性握手超时**（同一 URL 重试即 200）
const RETRIES: usize = 3;

pub struct YunDuo {
    client: reqwest::Client,
}

/// ext 里的几个值（全是**可选**：缺了用 bundle 里的常量兜底）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtCfg {
    pub host: String,
    pub client: String,
    pub web_sign: String,
}

impl YunDuo {
    pub const CLASS: &'static str = "YunDuo";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build yun_duo http client");
        Self { client }
    }

    /// 从 ext 抽 host / client / sign
    ///
    /// ```text
    /// ext = {"host":"https://…","client":"…","sign":"…", …}
    /// ⇒ host 必用 ext 的；client/sign 缺了用 bundle 里的常量（实测两者相同）
    /// ```
    pub fn cfg_of(ext: &str) -> ExtCfg {
        let j = crate::tvbox::parse_loose_json(ext).ok();
        let get = |k: &str| -> Option<String> {
            j.as_ref()
                .and_then(|v| v.get(k))
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        };
        let mut host = get("host").unwrap_or_default();
        if host.is_empty() {
            host = DEFAULT_HOST.to_string();
        }
        ExtCfg {
            host: host.trim_end_matches('/').to_string(),
            client: get("client").unwrap_or_else(|| CLIENT_FALLBACK.to_string()),
            // ⚠️ ext 里的键叫 `sign`，而**请求头**叫 `web-sign`（bundle 里就是这么写的）
            web_sign: get("sign").unwrap_or_else(|| WEB_SIGN_FALLBACK.to_string()),
        }
    }

    /// 带 `X-Client` + `web-sign` 的 GET（JSON 回参）
    async fn get_json(&self, cfg: &ExtCfg, path: &str) -> Result<Value, String> {
        let url = format!("{}{}", cfg.host, path);
        let mut last = String::new();
        for attempt in 1..=RETRIES {
            let sent = self
                .client
                .get(&url)
                .header(reqwest::header::ACCEPT, "application/json")
                .header("X-Client", &cfg.client)
                // ★ 只在 URL 含 api.php 时才加（照 bundle 的拦截器逻辑）
                .header("web-sign", &cfg.web_sign)
                .header(reqwest::header::REFERER, format!("{}/", cfg.host))
                .send()
                .await;
            match sent {
                Ok(resp) => {
                    let status = resp.status();
                    let text = resp
                        .text()
                        .await
                        .map_err(|e| format!("读取 {path} 失败：{e}"))?;
                    if !status.is_success() {
                        return Err(format!("{path} 返回 HTTP {status}：{}", head(&text)));
                    }
                    let v: Value = crate::tvbox::parse_loose_json(&text)
                        .map_err(|e| format!("{path} 不是 JSON：{e}（前 120 字：{}）", head(&text)))?;
                    // ★ 上游业务码：`code` 200 = 成功（注意**不是** 0，与 AppYQK/Hxq 不同）
                    match v.get("code").and_then(|c| c.as_i64()) {
                        Some(200) => return Ok(v),
                        Some(code) => {
                            return Err(format!(
                                "{path} 上游 code={code}：{}",
                                v.get("msg").and_then(|m| m.as_str()).unwrap_or("（无 msg）")
                            ))
                        }
                        None => return Err(format!("{path} 响应没有 code 字段（形状变了）")),
                    }
                }
                Err(e) => {
                    last = format!("请求 {path} 失败（第 {attempt}/{RETRIES} 次）：{e}");
                    if attempt < RETRIES {
                        tokio::time::sleep(Duration::from_millis(500 * attempt as u64)).await;
                    }
                }
            }
        }
        Err(last)
    }

    /// `vod` 形态的一条 → [`CspItem`]（列表/首页/搜索**共用**，避免三份映射漂移）
    ///
    /// 实测字段：`vod_id`（**数字**）/ `vod_name` / `vod_pic` / `vod_remarks`
    fn item_of(v: &Value) -> Option<CspItem> {
        let id = pick_id_str(v, &["vod_id"])?;
        let title = pick_str(v, &["vod_name"]).unwrap_or("").trim().to_string();
        if title.is_empty() {
            return None;
        }
        Some(CspItem {
            id,
            title,
            cover: pick_str(v, &["vod_pic"]).map(|s| s.to_string()),
            subtitle: pick_str(v, &["vod_remarks"])
                .filter(|s| !s.trim().is_empty())
                .map(|s| s.to_string()),
        })
    }

    fn items_from(arr: &[Value]) -> Vec<CspItem> {
        arr.iter().filter_map(Self::item_of).collect()
    }

    /// 把 detail 的 `vod_play_from` + `vod_play_url` 摊成剧集（**复用 `shared::split_lines`**）
    ///
    /// ```text
    /// from = "PAN1$$$zijianm3u8$$$CO4K$$$NBY$$$qsvip$$$BBA"
    /// url  = "第1集$PAN1-pBTF… #第2集$… $$$ 第1集$zijian_… $$$ …"
    /// ⇒ 每个 (线路, 集) 一条 CspEpisode，flag = 线路名
    ///    id 编码成 `线路名|集名|该集的值`（play 需要 line + 值）
    /// ```
    fn episodes_of(d: &Value) -> Vec<CspEpisode> {
        let from = pick_str(d, &["vod_play_from"]).unwrap_or("");
        let url = pick_str(d, &["vod_play_url"]).unwrap_or("");
        let mut out: Vec<CspEpisode> = Vec::new();
        for (line, eps) in split_lines(from, url) {
            for (ep_name, val) in eps {
                if val.trim().is_empty() {
                    continue;
                }
                out.push(CspEpisode {
                    // ★ 编码三个值：play 要 line（vodFrom）+ 值（url）
                    id: format!("{line}|{ep_name}|{val}"),
                    title: ep_name,
                    flag: line.clone(),
                });
            }
        }
        out
    }
}

impl Default for YunDuo {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

/// 从剧集 id（`线路|集名|值`）拆出 `(线路, 值)` —— **抽成纯函数以便门禁驱动**
///
/// # 为什么用 `|` 而不用别的分隔符
/// ```text
/// 值本身是 base64url 字符集（`A-Za-z0-9_-`）+ 可能含 `%`（实测 CO4K 那条带 `%2F`）
/// ⇒ **不含 `|`** ⇒ 用 `|` 分隔**不会歧义**。
/// ★ 集名里可能含中文/`$`（实测"普通话版"、"20261022上"）⇒ 用 `splitn(3)` 取前两段、
///   剩下整段都是值（不能用 `split('|')` —— 那只在多段时才安全）。
/// ```
pub fn parse_ep_id(id: &str) -> Option<(String, String)> {
    let mut it = id.splitn(3, '|');
    let line = it.next()?.trim().to_string();
    let _name = it.next()?.trim().to_string();
    let val = it.next()?.trim().to_string();
    if line.is_empty() || val.is_empty() {
        return None;
    }
    Some((line, val))
}

#[async_trait]
impl CspSite for YunDuo {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：`/api.php/web/index/home` → `data.categories[]`
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let cfg = Self::cfg_of(ext);
        let v = self.get_json(&cfg, "/api.php/web/index/home").await?;
        let d = v
            .get("data")
            .ok_or_else(|| "首页响应没有 data（形状变了）".to_string())?;

        let mut categories: Vec<CspCategory> = Vec::new();
        for c in pick_arr(d, &["categories"]).map(|a| a.as_slice()).unwrap_or(&[]) {
            let id = pick_id_str(c, &["type_id"]).unwrap_or_default();
            let name = pick_str(c, &["type_name"]).unwrap_or("").trim().to_string();
            if !id.is_empty() && !name.is_empty() {
                categories.push(CspCategory { id, name });
            }
        }
        if categories.is_empty() {
            return Err("首页没有 categories（上游结构可能变了）".to_string());
        }

        // 首屏：recommend[]（真数据；拿不到就空，不编）
        let items = pick_arr(d, &["recommend"])
            .map(|a| Self::items_from(a))
            .unwrap_or_default();

        Ok(CspHome { categories, items })
    }

    /// 分类列表：`/api.php/web/filter/vod?type_name=<分类名>&page=N`
    ///
    /// # ★★ 这个接口用**分类名**而不是 id（实测踩出来的）
    /// ```text
    /// 我第一版按其他类的习惯传 `type_id=1`，但更早的探测显示
    ///   `type_name=1`     → data:[]（0 条）      ← 名字不匹配
    ///   `type_name=电影`  → 24 条                ← 正确
    ///   `type_name=`      → 24 条（全部）
    /// ⇒ `type_name` 要的是**中文类名**。而 home 给的分类同时也是
    ///   `type_id`(1..4) + `type_name`(电影/剧集/动漫/综艺)。
    /// ⇒ 本实现：tid 里若是**纯数字**，先用 home 把它翻成名字（一次映射，缓存不必要）；
    ///   否则直接把 tid 当名字用。**这样两种 id 形态都能工作**，不猜。
    /// ```
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id/名 为空".to_string());
        }
        let cfg = Self::cfg_of(ext);
        let page = if page == 0 { 1 } else { page };

        // 纯数字 ⇒ 先翻成类名（home 的分类表是权威来源）
        let type_name = if tid.chars().all(|c| c.is_ascii_digit()) {
            let home = self.home(ext).await?;
            home.categories
                .iter()
                .find(|c| c.id == tid)
                .map(|c| c.name.clone())
                .ok_or_else(|| format!("分类 id={tid} 不在上游分类表里"))?
        } else {
            tid.to_string()
        };

        let path = format!(
            "/api.php/web/filter/vod?type_name={}&page={page}",
            urlencoding::encode(&type_name)
        );
        let v = self.get_json(&cfg, &path).await?;
        let items = pick_arr(&v, &["data"])
            .map(|a| Self::items_from(a))
            .unwrap_or_default();

        // ★ 上游**给** total/limit/pageCount ⇒ 如实透出（这是真分页）
        let total = v.get("total").and_then(|t| t.as_u64());
        let page_count = v
            .get("pageCount")
            .and_then(|p| p.as_u64())
            .map(|p| p as u32)
            // pageCount=0 而 total=0 ⇒ 这个分类没内容；如实报出来
            .filter(|p| *p > 0);

        if items.is_empty() {
            if page > 1 {
                return Ok(CspList {
                    items: Vec::new(),
                    page,
                    page_count: Some(page - 1),
                    total,
                });
            }
            return Err(format!(
                "分类「{type_name}」上游返回 0 条（total={total:?} pageCount={page_count:?}）"
            ));
        }
        Ok(CspList {
            items,
            page,
            page_count,
            total,
        })
    }

    /// 详情：`/api.php/web/vod/get_detail?vod_id=<数字>`
    ///
    /// ★ **响应自带剧集与多线路**（`vod_play_from` + `vod_play_url`）⇒ 不必再打别的端点。
    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let vid = id.trim();
        if vid.is_empty() {
            return Err("vod_id 为空".to_string());
        }
        let cfg = Self::cfg_of(ext);
        let v = self
            .get_json(&cfg, &format!("/api.php/web/vod/get_detail?vod_id={vid}"))
            .await?;
        // ⚠️ 实测 data 是**数组**（`data:[{…}]`），不是对象
        let d = pick_arr(&v, &["data"])
            .and_then(|a| a.first())
            .ok_or_else(|| format!("详情响应 data 不是非空数组（vod_id={vid}）"))?;

        let title = pick_str(d, &["vod_name"]).unwrap_or("").trim().to_string();
        if title.is_empty() {
            return Err(format!("详情响应 vod_name 为空（vod_id={vid}）"));
        }
        let episodes = Self::episodes_of(d);
        if episodes.is_empty() {
            return Err(format!(
                "「{title}」没有可播剧集（vod_play_url 为空 —— 上游对该条可能已下架）"
            ));
        }
        Ok(CspDetail {
            id: vid.to_string(),
            title,
            cover: pick_str(d, &["vod_pic"]).map(|s| s.to_string()),
            description: {
                // 实测 vod_content 是 **HTML**（`<p>…</p>`）⇒ 必须洗过
                let content = pick_str(d, &["vod_content"]).map(clean_html).unwrap_or_default();
                let area = pick_str(d, &["vod_area"]).unwrap_or("").trim();
                let year = pick_str(d, &["vod_year"]).unwrap_or("").trim();
                let actor = pick_str(d, &["vod_actor"]).unwrap_or("").trim();
                let mut parts: Vec<String> = Vec::new();
                if !content.is_empty() {
                    parts.push(content);
                }
                if !actor.is_empty() {
                    parts.push(format!("主演：{actor}"));
                }
                if !area.is_empty() || !year.is_empty() {
                    parts.push(format!("{area} {year}").trim().to_string());
                }
                if parts.is_empty() {
                    None
                } else {
                    Some(parts.join("\n"))
                }
            },
            episodes,
        })
    }

    /// 搜索：`/api.php/web/search/index?wd=<关键词>`
    ///
    /// # ★ 参数名是 `wd`（实测）
    /// ```text
    /// `wd=仙逆`        → 15 条真命中
    /// `name=`/`keywords=` → `code:400 搜索关键词不能为空`（参数名不对 ⇒ 服务端读不到）
    /// ```
    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let cfg = Self::cfg_of(ext);
        let page = if page == 0 { 1 } else { page };
        let path = format!(
            "/api.php/web/search/index?wd={}&page={page}",
            urlencoding::encode(kw)
        );
        let v = self.get_json(&cfg, &path).await?;
        let items = pick_arr(&v, &["data"])
            .map(|a| Self::items_from(a))
            .unwrap_or_default();
        // 搜索 0 条是**正常结果** ⇒ 空页，不 Err
        Ok(CspList {
            items,
            page,
            page_count: v.get("pageCount").and_then(|p| p.as_u64()).map(|p| p as u32),
            total: v.get("total").and_then(|t| t.as_u64()),
        })
    }

    fn supports_search(&self) -> bool {
        // ★ 已真网络验证：`?wd=仙逆` → 15 条真命中
        true
    }

    /// 取流：**未实现** —— 卡在站点自身的 **wasm 解码器**（见文件头"未实现"）
    ///
    /// # 为什么这里返回一个**说清原因**的 Err，而不是"尚未实现"
    /// ```text
    /// 我把 `/api.php/web/decode/url` 拆到了**最后一关**：
    ///   · 手工拼 protobuf **被服务端接受**（字段号 f1=url、f2=vodFrom 是试出来的）
    ///   · 服务端回应从"缺少url参数"→"缺少vodFrom参数"→
    ///     "401 签名验证失败: 缺少必要参数"（**逐关推进**，证明我在对的路上）
    ///   · 最后一关的签名由 wasm 模块产生（bundle 只有胶水层）⇒ 本仓不嵌 wasm 运行时
    /// ⇒ 真因是"缺 wasm 能力位"，不是"没动手"。按本仓口径点名真因。
    /// ```
    async fn play(&self, flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let (line, val) = parse_ep_id(id).ok_or_else(|| {
            format!("剧集 id 形态不对（应为 `线路|集名|值`）：{id}")
        })?;
        let _ = flag;
        Err(format!(
            "YunDuo 取流需要站点自身的 **wasm 解码器**（`/assets/web_app_wasm_bg-*.wasm`）——\
             本仓不嵌 wasm 运行时，所以不能解 线路={line} 的值（前 24 字：{}）。\
             已实测：`/api.php/web/decode/url` 手工拼 protobuf **被接受**\
             （字段 f1=url、f2=vodFrom），缺的是它的**第二道签名**（wasm 内计算）。\
             绝不伪造播放地址。",
            val.chars().take(24).collect::<String>()
        ))
    }
}

/// 洗掉 `vod_content` 里的 HTML（实测是 `<p>…</p>`）
///
/// 复用本仓既有 `strip_tags` / `decode_entities` ⇒ **不新增依赖**
pub fn clean_html(html: &str) -> String {
    let stripped = crate::tvbox::strip_tags(html);
    let decoded = crate::tvbox::decode_entities(&stripped);
    decoded
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_string()
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册（R3-D，2026-10-27）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类的事实（从文件头的长注释搬过来，别丢）
// ```text
// csp_YunDuo（🦊布布丨蓝光秒播 / 多多影视）：**四段真网络通**
//   home   /api.php/web/index/home → categories 4 个（电影/剧集/动漫/综艺）+ recommend
//   list   /api.php/web/filter/vod?type_name=电影&page=1 → 24 条/页，**上游给 total/pageCount**
//   detail /api.php/web/vod/get_detail?vod_id=363 → 171 KB，**自带 vod_play_from/url**（多线路）
//   search /api.php/web/search/index?wd=仙逆 → 15 条真命中
//   play   ⛔ 值是不透明密文，需站点自身 wasm 解码器 ⇒ 明确 Err（不伪造）
//
// ★★ 探明方式值得复用：它是 **Vue SPA**（任意路径都回同一 index.html），
//    但**下载它的 JS bundle 当文本读**就拿到了端点表 + 头常量
//    （`X-Client` / `web-sign` 都是常量，与 ext 给的相同）
//    ⇒ **"SPA 拿不到接口"不是结论；读 bundle 不需要 JS 引擎。**
// ```
crate::csp::register_site!(YunDuo);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn class_is_registered_under_exact_name() {
        assert_eq!(YunDuo::CLASS, "YunDuo");
        assert_eq!(YunDuo::new().class(), "YunDuo");
    }

    // ── ext 解析（对着"订阅里真的就是这么写的"） ────────────────────────
    #[test]
    fn cfg_reads_the_real_subscription_ext() {
        // ★ 订阅里 csp_YunDuo 的 ext **逐字**（我抄下来的）
        let ext = r#"{"host": "https://323433ssdfd.top", "finger": "WF-2c064bc5b3400788f31b848849bc3a60f835423ba2dfe69d7ea93974c216e4f2", "aid": "com.web.player", "sk": "WEB-50a8e9c84a1dc05669a692ded99a2dac46527229e607a7be15db88dbc59059d1", "client": "8f3d2a1c7b6e5d4c9a0b1f2e3d4c5b6a", "sign": "ddtvf65f3a83d6d9ad6f"}"#;
        let c = YunDuo::cfg_of(ext);
        assert_eq!(c.host, "https://323433ssdfd.top");
        assert_eq!(c.client, "8f3d2a1c7b6e5d4c9a0b1f2e3d4c5b6a");
        // ★ ext 的键是 `sign`，请求头名是 `web-sign` —— 映射别写错
        assert_eq!(c.web_sign, "ddtvf65f3a83d6d9ad6f");
    }

    #[test]
    fn cfg_falls_back_to_the_bundle_constants() {
        /*
         * ★ 兜底值必须**等于 bundle 里逐字读出来的常量**（不是编的）：
         *   bundle: `headers: { "X-Client": "8f3d2a1c…" }`、`Me = "ddtvf65f3a83d6d9ad6f"`
         * ⇒ 没了 ext 也能用（实测 ext=空的站点不会被这种缺失打死）。
         */
        let c = YunDuo::cfg_of("");
        assert_eq!(c.host, DEFAULT_HOST);
        assert_eq!(c.client, CLIENT_FALLBACK);
        assert_eq!(c.web_sign, WEB_SIGN_FALLBACK);
        assert_eq!(CLIENT_FALLBACK, "8f3d2a1c7b6e5d4c9a0b1f2e3d4c5b6a");
        assert_eq!(WEB_SIGN_FALLBACK, "ddtvf65f3a83d6d9ad6f");
        // host 末尾斜杠要去掉（否则拼出 `//api.php`）
        let c2 = YunDuo::cfg_of(r#"{"host":"https://a.example/"}"#);
        assert_eq!(c2.host, "https://a.example");
    }

    // ── ★ 剧集 id 编码/解码（play 要靠它拿 line + 值） ──────────────────
    #[test]
    fn parse_ep_id_roundtrips_the_wire_shape() {
        let (l, v) = parse_ep_id("PAN1|第1集|PAN1-pBTFch38YURjS_CJvf_mb4D").expect("应能解");
        assert_eq!(l, "PAN1");
        assert_eq!(v, "PAN1-pBTFch38YURjS_CJvf_mb4D");
        // ★ 集名可以含中文 / 空格（实测有"普通话版"、"20261022上"）
        let (l2, v2) = parse_ep_id("BBA|普通话版|jjkk-3036a0a6").unwrap();
        assert_eq!(l2, "BBA");
        assert_eq!(v2, "jjkk-3036a0a6");
        // 形态不对 ⇒ None（不许把垃圾当 id 发出去）
        assert!(parse_ep_id("PAN1|第1集").is_none(), "少一段 ⇒ None");
        assert!(parse_ep_id("|x|y").is_none(), "线路空 ⇒ None");
        assert!(parse_ep_id("PAN1|第1集|").is_none(), "值空 ⇒ None");
    }

    #[test]
    fn parse_ep_id_keeps_value_intact_when_it_contains_separators() {
        /*
         * ★ `splitn(3)` 而不是 `split('|')`：
         *   值里可能含 `%2F`（实测 CO4K 那条带 `%`）与 `_`、`-`；
         *   集名也可能含分隔符类字符。
         *   ⇒ 第 3 段之后**整段**都必须是值，不能被再切开。
         */
        let id = "CO4K|1|CO4K_QeoICcLE9vxDaJ1Pz%2FztJDE7-ljiFp9hUH";
        let (l, v) = parse_ep_id(id).unwrap();
        assert_eq!(l, "CO4K");
        assert_eq!(v, "CO4K_QeoICcLE9vxDaJ1Pz%2FztJDE7-ljiFp9hUH", "值必须完整");
        // 即使值里混进了 `|` 也要保住后面的部分（splitn 语义）
        let (_, v2) = parse_ep_id("A|B|C|D|E").unwrap();
        assert_eq!(v2, "C|D|E");
    }

    // ── 剧集摊平（对着真 from/url 形状） ────────────────────────────────
    #[test]
    fn episodes_of_flattens_real_multiline_shape() {
        // ★ 实测原样（截取）
        let d = json!({
            "vod_play_from": "PAN1$$$zijianm3u8$$$CO4K",
            "vod_play_url": "第1集$PAN1-aaa#第2集$PAN1-bbb$$$第1集$zijian_ccc$$$1$CO4K_ddd"
        });
        let eps = YunDuo::episodes_of(&d);
        assert_eq!(eps.len(), 4, "3 条线路共 4 集");
        assert_eq!(eps[0].flag, "PAN1");
        assert_eq!(eps[0].title, "第1集");
        // ★ id 是 `线路|集名|值`（play 要从这里拆）
        let (l, v) = parse_ep_id(&eps[0].id).expect("id 必须可解");
        assert_eq!(l, "PAN1");
        assert_eq!(v, "PAN1-aaa");
        assert_eq!(eps[2].flag, "zijianm3u8");
        assert_eq!(eps[3].flag, "CO4K");
        assert_eq!(eps[3].title, "1");
    }

    #[test]
    fn episodes_of_skips_empty_values_but_keeps_the_rest() {
        // 空值不许变成一条"能点但没地址"的剧集
        let d = json!({"vod_play_from": "A", "vod_play_url": "第1集$#第2集$real"});
        let eps = YunDuo::episodes_of(&d);
        assert_eq!(eps.len(), 1, "空值那条要跳过");
        assert_eq!(eps[0].title, "第2集");
        // 完全没有 play_url ⇒ 空（由 detail 负责报错）
        let none = json!({"vod_play_from": "", "vod_play_url": ""});
        assert!(YunDuo::episodes_of(&none).is_empty());
    }

    // ── 条目映射 ───────────────────────────────────────────────────────
    #[test]
    fn item_of_maps_real_fields() {
        // ★ 实测 /index/home recommend[0] 与 filter/vod 的字段
        let v = json!({"vod_id": 363, "vod_name": "仙逆",
                       "vod_pic": "https://vcover-vt-pic.puui.qpic.cn/x",
                       "vod_remarks": "更新至164集"});
        let it = YunDuo::item_of(&v).expect("应能映射");
        assert_eq!(it.id, "363", "★ 数字 vod_id 要转成字符串");
        assert_eq!(it.title, "仙逆");
        assert!(it.cover.unwrap().starts_with("https://vcover-vt-pic"));
        assert_eq!(it.subtitle.as_deref(), Some("更新至164集"));
        // 缺 id / 缺名 ⇒ 跳过
        assert!(YunDuo::item_of(&json!({"vod_name": "没 id"})).is_none());
        assert!(YunDuo::item_of(&json!({"vod_id": 1})).is_none());
        // 空 remarks ⇒ None（不是空串，别让 UI 显示空标签）
        assert_eq!(
            YunDuo::item_of(&json!({"vod_id": 1, "vod_name": "x", "vod_remarks": ""}))
                .unwrap()
                .subtitle,
            None
        );
    }

    // ── ★ intro 是 HTML（实测） ────────────────────────────────────────
    #[test]
    fn clean_html_strips_tags_and_entities() {
        let raw = "<p>改编自耳根同名小说《仙逆》，讲述了乡村平凡少年王林。</p>";
        let got = clean_html(raw);
        assert!(!got.contains('<'), "标签必须剥掉：{got}");
        assert!(got.contains("改编自耳根同名小说"), "{got}");
        assert!(got.starts_with('改'), "不该留前导空白：{got}");
    }

    // ── ★★ 结构判据：接口参数名（每个都是实测敲出来的） ──────────────────
    #[test]
    fn endpoints_and_param_names_match_the_live_verification() {
        /*
         * ★ 这几个参数名**都是实测敲出来的**（写错就是 400/0 条，症状隐蔽）：
         *   list   : `type_name`（**分类名**，不是 type_id）
         *   detail : `vod_id`
         *   search : `wd`（不是 name/keywords）
         * 判据用 `impl_src_only` 剥测试段（AppYQK 踩过自证陷阱）。
         */
        let flat = crate::csp::shared::impl_src_only(include_str!("yun_duo.rs"));
        assert!(flat.contains("/api.php/web/index/home"), "首页端点");
        assert!(
            flat.contains("/api.php/web/filter/vod?type_name="),
            "★ 列表必须用 `type_name`（传 type_id 会得 0 条）"
        );
        assert!(
            flat.contains("/api.php/web/vod/get_detail?vod_id="),
            "★ 详情必须用 `vod_id`（`id=` 会 400）"
        );
        assert!(
            flat.contains("/api.php/web/search/index?wd="),
            "★ 搜索必须用 `wd`（name/keywords 会报「关键词不能为空」）"
        );
        // 搜索关键词必须 URL 编码（中文实测要编码）
        assert!(flat.contains("urlencoding::encode(kw)"), "★ 搜索词要编码");
        // 业务码是 200（不是 0）
        assert!(
            flat.contains("Some(200)=>returnOk(v)"),
            "★ 这个站的成功码是 200（与 AppYQK/Hxq 的 0/result 不同）"
        );
    }

    #[test]
    fn list_translates_numeric_tid_to_the_category_name() {
        /*
         * ★ 这条钉住"两种 id 形态都能工作"：
         *   home 给的是 `type_id`(1..4)，而 filter 要 `type_name`(电影/剧集…)，
         *   ⇒ 纯数字的 tid 必须**先查 home 翻成名字**，不许直接当名字用
         *     （直接传 `type_name=1` 实测得 **0 条**，且不报错 ⇒ 静默空列表）。
         */
        let flat = crate::csp::shared::impl_src_only(include_str!("yun_duo.rs"));
        assert!(
            flat.contains("tid.chars().all(|c|c.is_ascii_digit())"),
            "★ 必须识别「纯数字 tid」这条路"
        );
        assert!(
            flat.contains("不在上游分类表里"),
            "★ 数字 tid 查不到时必须报错，不许静默当成类名"
        );
    }

    #[test]
    fn supports_search_true_matches_live() {
        assert!(YunDuo::new().supports_search(), "实测 ?wd=仙逆 命中 15 条");
    }

    #[tokio::test]
    async fn play_errs_naming_the_wasm_capability_gap() {
        let s = YunDuo::new();
        let e = s
            .play("PAN1", "PAN1|第1集|PAN1-pBTFch38YURjS_CJvf_mb4D", "")
            .await
            .expect_err("★ 缺 wasm 能力位 ⇒ 必须 Err，不许给假地址");
        // ★ 这三条是这个 Err 的价值：说清"卡在哪、我试到哪、不会伪造"
        assert!(e.contains("wasm"), "要点名缺的是 wasm 能力位：{e}");
        assert!(e.contains("decode/url"), "要点名端点：{e}");
        assert!(e.contains("绝不伪造"), "要表明不会给假地址：{e}");
        assert!(e.contains("PAN1"), "要带上线路便于定位：{e}");
        // 形态不对的 id 也要明确 Err（不是 panic）
        let e2 = s.play("", "坏id", "").await.expect_err("形态不对必须 Err");
        assert!(e2.contains("形态不对"), "{e2}");
    }

    #[test]
    fn retries_are_implemented_because_the_tls_really_flakes() {
        /*
         * ★ 实测：该站 TLS **间歇性握手超时**（同一 URL 重试即 200）。
         *   不加重试会把"网络抖动"误读成"接口挂了" ⇒ 必须带重试。
         *   （我的 Python 探测脚本也因此加了重试，否则一度误判 detail 不可用。）
         */
        let flat = crate::csp::shared::impl_src_only(include_str!("yun_duo.rs"));
        assert!(flat.contains("forattemptin1..=RETRIES"), "★ 必须有重试循环");
        assert!(flat.contains("tokio::time::sleep"), "★ 重试之间要退避");
        assert!(RETRIES >= 2, "至少重试一次：{RETRIES}");
    }

    // ── 真网络（显式开关 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_yun_duo --release -- --ignored --nocapture"]
    async fn csp_live_yun_duo_four_segments() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let ext = r#"{"host": "https://323433ssdfd.top", "client": "8f3d2a1c7b6e5d4c9a0b1f2e3d4c5b6a", "sign": "ddtvf65f3a83d6d9ad6f"}"#;
        let s = YunDuo::new();
        let home = s.home(ext).await.expect("home 应成功");
        eprintln!(
            "[LIVE] home: 分类 {} 个 {:?}，首屏 {} 条",
            home.categories.len(),
            home.categories.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
            home.items.len()
        );
        let list = s.list(&home.categories[0].id, 1, ext).await.expect("list 应成功");
        eprintln!("[LIVE] list({}): {} 条，首条={} total={:?} page_count={:?}",
            home.categories[0].name, list.items.len(),
            list.items.first().map(|i| i.title.clone()).unwrap_or_default(),
            list.total, list.page_count);
        let id = list.items[0].id.clone();
        let d = s.detail(&id, ext).await.expect("detail 应成功");
        let mut flags: Vec<String> = d.episodes.iter().map(|e| e.flag.clone()).collect();
        flags.dedup();
        eprintln!("[LIVE] detail({id}): 标题={} 集={} **线路={}** {:?}",
            d.title, d.episodes.len(), flags.len(),
            flags.iter().take(6).cloned().collect::<Vec<_>>());
        // ★ play 会明确 Err（缺 wasm）—— 这是预期
        let pe = s.play(&d.episodes[0].flag, &d.episodes[0].id, ext).await;
        eprintln!("[LIVE] play 实测: {}", match &pe {
            Ok(v) => format!("★ 意外成功（{} 条）—— 说明能绕过 wasm，需更新实现", v.len()),
            Err(e) => format!("如实 Err：{}", e.chars().take(80).collect::<String>()),
        });
        let se = s.search("仙逆", 1, ext).await.expect("search 应成功");
        eprintln!("[LIVE] search(仙逆): {} 条，首条={:?}", se.items.len(),
            se.items.first().map(|i| i.title.clone()));
    }
}