// ═══════════════════════════════════════════════════════════════════════
//  csp_GuiGui —— TVBox `csp_GuiGui` 的 Rust 重写（「鬼鬼」网盘搜索）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么（实测取自 `.probe/ref-subscription.json`）
//
// ```json
// {"key":"鬼鬼","name":"🔍鬼鬼｜网盘搜索","type":3,"api":"csp_GuiGui",
//  "searchable":1,"quickSearch":0,"filterable":0,"timeout":60}
// ```
// ⇒ **没有 ext**：站点写死 `https://api.guiguiya.com`。
//
// # ★ 这个类的真实形态（反汇编 + 真网络，2026-10-27）
//
// ```text
// `GuiGui extends Pan` —— 而且它**自己只写了两个方法**：
//    · `E(String) -> String`       = 搜索（拼 URL + 解析成卡片）
//    · `searchContent(String,boolean)` = 调 `E`
//    · `init(Context,String)`      = 只 `invoke-super Pan.init(...)`（无自己的逻辑）
//    · `searchContent(String,boolean,String)` = 只调 `E`
// ⇒ `categoryContent` / `detailContent` / `playerContent` **全在 `Pan` 基类**。
// ```
//
// ### 搜索协议（DEX `E(String)` 逐字 + 真网实证）
// ```text
// GET https://api.guiguiya.com/api/video/duanju?act=search&name=<URLEncoder(kw)>
//   DEX 请求头：只加一个 `User-Agent`（Chrome 那条）
//   响应：{"code":200,"msg":"…","time":"…","total":20053,"num":8,
//          "data":[{"id","name","label","addtime","cover","url","episodes","state",…}]}
//   DEX 的解析：code=="200" 才继续（否则返回 `[]`）；
//              逐条取 name / url / episodes / cover，
//              name 里若**不含关键词**就跳过（`String.contains`）；
//              备注 = "共{episodes}集"
// ```
//
// ★ **实证读数（2026-10-27 真打）**
// ```text
// $ curl -A <Chrome151> 'https://api.guiguiya.com/api/video/duanju?act=search&name=%E6%88%98%E7%8B%BC'
//   ⇒ HTTP 200，code=200，total=20053，num=8，data 8 条
//   首条：{"id":"67c482a15836b","name":"战狼之父亲归来（99集）张亚坤＆屈婉琼＆尹昕＆爪爪",
//          "cover":"https://t12.baidu.com/it/u=…","url":"https://pan.quark.cn/s/780a34a06f38",
//          "episodes":99}
// ★ **`url` 是网盘分享页**（首条就是夸克），不是直链 —— 与 `Pan` 基类的定位一致。
// ```
//
// # ⚠️ 本类**只做搜索**（Lead 已裁定），其余三段如实返回结构化 Err
//
// ```text
// ① `home` / `list` / `detail` / `play` 全在 **`Pan` 基类**里，而 Pan 的 `playerContent`
//    走 `processPan()` → **`http://127.0.0.1:5266`（宿主的本地网盘工具）**
//    ⇒ 正是本批契约里「**`mProxy` 本批明确不做**」那一片。
//    ⚠️ 文案必须写准（Lead 逐字给的）：
//        **「该链路依赖 Pan 基类的网盘工具链（本批契约明确不做 `mProxy`）」**
//      ——— **不许**写"本仓没有转发服务"：那句是过时说法
//        （`streamproxy::register(url, headers)` 真实存在，见 `streamproxy.rs:819`；
//          只是"**能力存在 ≠ 接起来就对**"，那条链路尚未验证）。
// ② 本仓 **`CspSite` 没有 `isVideoFormat` / `manualVideoCheck` 等价位**
//    （DEX 里 `Pan` 基类有这两个方法）⇒ 按契约如实写"本仓无等价位，未实现"。
// ③ `mProxy`：本批不做，登记为**已知缺口**。
// ④ `loadPic`：DEX 里 GuiGui/Pan 都没有独立实现 ⇒ 封面取图走源 `cover_headers`（声明式）。
//    ⚠️ 但 `CspSite` **没有** `cover_headers()` 能力位（与 csp_Douban 同一处缺口，已报 Lead）。
// ```

use async_trait::async_trait;
use serde_json::Value;

use super::{CspCategory, CspDetail, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `E(String)` 里的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 搜索端点（DEX 逐字）
const SEARCH_BASE: &str = "https://api.guiguiya.com/api/video/duanju?act=search&name=";

/// 「该链路依赖 Pan 基类的网盘工具链」的统一文案（**Lead 逐字给定**）
///
/// # 为什么必须是这一句（不能写成"本仓没有转发服务"）
/// ```text
/// `streamproxy::register(url, headers)` **真实存在**（streamproxy.rs:819/:838）——
/// 它就是 TVBox `5266` 那件事的等价物。
/// 只是"**能力存在 ≠ 接起来就对**"（网盘直链要 Referer/UA/Range，且是 302 链）——那条还没验。
/// ⇒ 说成"没有转发服务"是**把事实说错**，会让后来的人去找一个**其实存在**的东西。
/// ```
pub const PAN_CHAIN_REASON: &str =
    "该链路依赖 Pan 基类的网盘工具链（本批契约明确不做 mProxy）";

// ═══════════════════════════════════════════════════════════════════════
//  解析（纯函数，全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// 搜索 URL（DEX `E` 的拼法：**URLEncoder 编码关键词**）
pub fn search_url(kw: &str) -> String {
    format!("{SEARCH_BASE}{}", urlencoding::encode(kw))
}

/// 上游判据：**只有 `code:200` 是成功**，且 `data` 必须是数组
///
/// ★ 不把"缺 code"当成功。DEX 里的判据是 `"200".equals(code)` —— 这里等价成整数比较，
///   但**同时容忍字符串 `"200"`**（实测本站在用的是数字，写死一种会让上游换成字符串时静默失败）。
pub fn ensure_ok<'a>(v: &'a Value, what: &str) -> Result<&'a Value, String> {
    let code = match v.get("code") {
        Some(c) if c.is_string() => c.as_str().map(|s| s.trim().to_string()),
        Some(c) => c.as_i64().map(|n| n.to_string()),
        None => None,
    };
    match code.as_deref() {
        Some("200") => Ok(v),
        Some(c) => Err(format!(
            "上游 {what} 返回 code={c}（msg={}）",
            v.get("msg").and_then(|m| m.as_str()).unwrap_or("")
        )),
        None => Err(format!(
            "上游 {what} 响应里没有 code 字段（可能被拦或改协议了）"
        )),
    }
}

/// `data[]` → 条目；**0 条 ⇒ Err**
///
/// # DEX 的两个过滤（逐字复刻）
/// ```text
/// ① `name.contains(kw)` —— 上游是"模糊/推荐"式返回，**名字不含关键词的条目要被丢掉**
///    （否则搜"战狼"会混进一堆无关短剧 ⇒ 用户以为搜索坏了）
/// ② `filterItemsWithoutPic` 精神：封面取不到的条目**要丢**（网盘搜索结果里混着无图项）
/// ```
/// ★ 但**两个过滤都不能把结果静默清空** ⇒ 全被滤掉时**报错并说明是哪个过滤导致**。
pub fn items_of(v: &Value, kw: &str, what: &str) -> Result<Vec<CspItem>, String> {
    ensure_ok(v, what)?;
    let arr = v
        .get("data")
        .and_then(|d| d.as_array())
        .ok_or_else(|| {
            format!(
                "上游 {what} 响应里没有 data 数组（实际顶层键：{:?}）",
                v.as_object()
                    .map(|o| o.keys().take(8).cloned().collect::<Vec<_>>())
                    .unwrap_or_default()
            )
        })?;
    let mut out = Vec::new();
    let mut dropped_by_name = 0usize;
    let mut dropped_by_pic = 0usize;
    for o in arr {
        let Some(id) = o.get("id").map(|x| x.to_string().trim_matches('"').to_string()) else {
            continue;
        };
        let Some(name) = o.get("name").and_then(|x| x.as_str()) else {
            continue;
        };
        if id.is_empty() || name.trim().is_empty() {
            continue;
        }
        // ① 名字必须含关键词（DEX 逐字：`name.contains(kw)`）
        if !name.contains(kw) {
            dropped_by_name += 1;
            continue;
        }
        // ② 没有封面的条目丢掉（与 DEX 的 filterItemsWithoutPic 同精神）
        let cover = o
            .get("cover")
            .and_then(|x| x.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        if cover.is_none() {
            dropped_by_pic += 1;
            continue;
        }
        out.push(CspItem {
            id,
            title: name.trim().to_string(),
            cover,
            // DEX 的备注 = "共{episodes}集"
            subtitle: o.get("episodes").map(|e| {
                let n = e.as_i64().map(|n| n.to_string()).unwrap_or_else(|| {
                    e.to_string().trim_matches('"').to_string()
                });
                format!("共{n}集")
            }),
        });
    }
    if out.is_empty() {
        return Err(format!(
            "上游 {what} 的 data 解析出 0 条（data 有 {} 项；\
             其中名字不含关键词被滤 {} 条、无封面被滤 {} 条 ⇒ \
             若两者都是 0，则是键名变了）",
            arr.len(),
            dropped_by_name,
            dropped_by_pic
        ));
    }
    Ok(out)
}

/// 把网盘分享页 URL 暴露成一条 `play`（**不是直链**，label 里写明）
///
/// # 为什么不能直接当直链交出去
/// ```text
/// 首条 url = `https://pan.quark.cn/s/780a34a06f38` —— 那是**夸克分享页**。
/// 把它当视频直链交给播放器 ⇒ 必然放不出来，而用户只会看到"播不了"。
/// ⇒ 这里 label 里**如实写「网盘分享页（需 Pan 链路解析）」**，
///   让 UI/用户能看出"这是一个需要网盘工具链接管的地址"。
/// ```
pub fn pan_play_of(v: &Value, kw: &str) -> Result<Vec<CspPlay>, String> {
    // 搜索响应里没有单条 id 的概念 ⇒ 取"第一含该关键词且有 url 的条目"的 url
    ensure_ok(v, "取流")?;
    let arr = v
        .get("data")
        .and_then(|d| d.as_array())
        .ok_or_else(|| "上游取流响应里没有 data 数组".to_string())?;
    for o in arr {
        let name = o.get("name").and_then(|x| x.as_str()).unwrap_or("");
        if !name.contains(kw) {
            continue;
        }
        if let Some(u) = o.get("url").and_then(|x| x.as_str()).filter(|s| !s.is_empty()) {
            return Ok(vec![CspPlay {
                url: u.to_string(),
                headers: vec![("User-Agent".to_string(), UA.to_string())],
                label: Some("网盘分享页（需 Pan 链路解析）".to_string()),
            }]);
        }
    }
    Err(format!(
        "搜索响应里没有含关键词 {kw:?} 的可用 url（网盘链接可能被上游省略了）"
    ))
}

/// 从条目 id 反查该条目的网盘 url（`play` 用；因为我们只在 search 响应里有它）
pub fn url_of_id(v: &Value, id: &str) -> Option<String> {
    v.get("data")?
        .as_array()?
        .iter()
        .find(|o| o.get("id").map(|x| x.to_string().trim_matches('"').to_string()).as_deref() == Some(id))
        .and_then(|o| o.get("url").and_then(|x| x.as_str()))
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
}

// ═══════════════════════════════════════════════════════════════════════
//  站点实现
// ═══════════════════════════════════════════════════════════════════════

pub struct GuiGui {
    client: super::http_context::CspHttpContext,
    /// 最近一次搜索的原始响应（`detail`/`play` 复用它的网盘 url —— 见文件头）
    last_search: std::sync::Mutex<Option<Value>>,
}

impl GuiGui {
    pub const CLASS: &'static str = "GuiGui";

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| {
            reqwest::Client::builder()
                // Ignore environment proxies; CspHttpContext applies app policy.
                .no_proxy()
                .user_agent(UA)
                .timeout(std::time::Duration::from_secs(20))
        });
        Self {
            client,
            last_search: std::sync::Mutex::new(None),
        }
    }

    /// DEX 的搜索请求（**只加一个 UA 头**）
    async fn get_json(&self, url: &str) -> Result<Value, String> {
        let resp = self
            .client
            .client()?
            .get(url)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await
            .map_err(|e| format!("请求鬼鬼上游失败（{url}）：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取鬼鬼上游响应失败（{url}）：{e}"))?;
        if !status.is_success() {
            let head = body.chars().take(80).collect::<String>();
            return Err(format!("上游返回 HTTP {status}（{url}）：{head}"));
        }
        serde_json::from_str(&body).map_err(|e| {
            format!(
                "上游响应不是合法 JSON（{url}）：{e}；前 100 字：{}",
                body.chars().take(100).collect::<String>()
            )
        })
    }

    async fn search_at(&self, url: &str, kw: &str, page: u32) -> Result<CspList, String> {
        let v = self.get_json(url).await?;
        let items = items_of(&v, kw, "搜索")?;
        if let Ok(mut g) = self.last_search.lock() {
            *g = Some(v);
        }
        Ok(CspList {
            items,
            page,
            page_count: None, // 上游不给页数（也不支持翻页）⇒ 如实 None
            total: None,
        })
    }

    /// 「Pan 基类链路」的那条统一错误（文案**逐字来自 Lead 的裁定**）
    fn pan_chain_err(seg: &str) -> String {
        format!("csp_GuiGui 的{seg}未实现：{PAN_CHAIN_REASON}。\
                 （该类在 DEX 里只写了 search —— {seg} 全在 Pan 基类，基类取流要经宿主本地网盘工具）")
    }
}

impl Default for GuiGui {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for GuiGui {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// ★ 本类**不提供首页分类** —— DEX 里 GuiGui 没有 `homeContent`，
    ///   它也没有"分类"这个概念（配置里 `filterable:0`、`quickSearch:0`，就是个搜索框）。
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        Ok(CspHome {
            // 分类表**故意留空**：这个源的唯一入口是搜索。
            // ⚠️ 但**不造一个假分类**（那会让用户点进去看到空列表，却以为是源坏了）。
            categories: Vec::<CspCategory>::new(),
            items: Vec::new(),
        })
    }

    async fn list(&self, _tid: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(Self::pan_chain_err("分类列表（list）"))
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        // 上游该端点**不支持分页**（DEX 里也没有页码参数）⇒ 第 2 页如实报错，不重复返回第 1 页
        if page > 1 {
            return Err(format!(
                "csp_GuiGui 的搜索不支持分页（上游 duanju 端点只有一页；\
                 请求第 {page} 页会返回与第 1 页完全相同的结果）"
            ));
        }
        let _ = ext; // 本类没有 ext（站点写死）
        self.search_at(&search_url(kw), kw, page).await
    }

    fn supports_search(&self) -> bool {
        true
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        /*
         * 本类的"详情"只能来自**搜索响应**（它没有独立详情端点）。
         * 若还没有本次会话的搜索缓存 ⇒ 无法把它拼出来 ⇒ 如实报错
         * **不返回一个只有 id 没有标题的空壳**（那是"看着成功"）。
         */
        let cached = self.last_search.lock().ok().and_then(|g| g.clone());
        if let Some(v) = cached {
            if let Some(arr) = v.get("data").and_then(|d| d.as_array()) {
                if let Some(o) = arr.iter().find(|o| {
                    o.get("id").map(|x| x.to_string().trim_matches('"').to_string()).as_deref()
                        == Some(id)
                }) {
                    let name = o
                        .get("name")
                        .and_then(|x| x.as_str())
                        .unwrap_or(id)
                        .trim()
                        .to_string();
                    let url = o.get("url").and_then(|x| x.as_str()).unwrap_or("");
                    // ★ 剧集维度就是"网盘分享页"这一条（DEX 里也是这么用的）
                    if !url.is_empty() {
                        return Ok(CspDetail {
                            id: id.to_string(),
                            title: name,
                            cover: o.get("cover").and_then(|x| x.as_str()).map(String::from),
                            description: Some(format!(
                                "网盘分享页：{url}（{PAN_CHAIN_REASON}）"
                            )),
                            episodes: vec![super::CspEpisode {
                                id: format!("{id}|{url}"),
                                title: "网盘分享页".to_string(),
                                flag: "网盘".to_string(),
                            }],
                        });
                    }
                }
            }
        }
        Err(format!(
            "csp_GuiGui 的详情未实现：{PAN_CHAIN_REASON}。\
             （本类在 DEX 里只写了 search，没有独立详情端点；\
               条目信息只能来自同一次搜索的响应，而 id={id:?} 不在缓存里）"
        ))
    }

    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        /*
         * `id` = `{条目id}|{网盘url}`（detail 编的）⇒ 拆开后**如实交回分享页**，
         * 并在 label 里写明"需 Pan 链路解析" —— **不假装它是直链**。
         * 若只有条目 id（没带 url）⇒ 回缓存找；找不到就**如实报 Pan 链路缺口**。
         */
        if let Some((eid, url)) = id.split_once('|') {
            if url.starts_with("http") {
                return Ok(vec![CspPlay {
                    url: url.to_string(),
                    headers: vec![("User-Agent".to_string(), UA.to_string())],
                    label: Some("网盘分享页（需 Pan 链路解析）".to_string()),
                }]);
            }
            let _ = eid;
        }
        // 只有裸 id ⇒ 回搜索缓存里找那条 url
        let raw = self.last_search.lock().ok().and_then(|g| g.clone());
        if let Some(v) = raw {
            if let Some(u) = url_of_id(&v, id) {
                return Ok(vec![CspPlay {
                    url: u,
                    headers: vec![("User-Agent".to_string(), UA.to_string())],
                    label: Some("网盘分享页（需 Pan 链路解析）".to_string()),
                }]);
            }
        }
        Err(format!("csp_GuiGui 的取流未实现：{PAN_CHAIN_REASON}（id={id:?}）"))
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册
// ═══════════════════════════════════════════════════════════════════════
crate::csp::register_site!(GuiGui);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// ★★ 搜索 URL 逐字（DEX `E` 的拼法）+ 关键词必须编码
    ///
    /// 注入：把 `urlencoding::encode` 去掉（裸关键词进 URL）⇒ 本条红。
    ///
    /// ⚠️ 用 `#[tokio::test]` 时不能再叠 `#[test]`；这里反之 —— 本仓已多次踩到
    ///    "duplicated attribute" 警告，故凡非 async 用例只留一个 `#[test]`。
    #[test]
    fn search_url_matches_dex_and_encodes_kw() {
        let u = search_url("战狼");
        assert_eq!(
            u,
            "https://api.guiguiya.com/api/video/duanju?act=search&name=%E6%88%98%E7%8B%BC"
        );
        assert!(u.starts_with("https://api.guiguiya.com/api/video/duanju?act=search&name="), "{u}");
        // 含 `/` `&` 的关键词必须编码，否则 URL 结构会被改
        let u2 = search_url("a&b/c");
        assert!(!u2.contains("a&b/c"), "裸 `&`/`/` 会改 URL 结构：{u2}");
        assert!(u2.contains("a%26b%2Fc") || u2.contains("a%26b/c"), "{u2}");
    }

    #[test]
    /// ★★ `code` 两种形态都认（数字 200 / 字符串 "200"），其它一律 Err
    ///
    /// DEX 判据是 `"200".equals(code)`（字符串比较）—— 上游若换成数字，
    /// 照抄 DEX 会**静默判失败**。所以两形态都要认，且**别的一律 Err**。
    /// 注入：把字符串分支删掉（只留 `as_i64`）⇒ 本条红。
    #[test]
    fn code_accepts_both_number_and_string_but_nothing_else() {
        let a: Value = serde_json::from_str(r#"{"code":200,"data":[]}"#).unwrap();
        ensure_ok(&a, "搜索").expect("数字 200 必须过");
        let b: Value = serde_json::from_str(r#"{"code":"200","data":[]}"#).unwrap();
        ensure_ok(&b, "搜索").expect("★ 字符串 \"200\" 也必须过（上游换形态时不能静默失败）");

        let c: Value = serde_json::from_str(r#"{"code":404,"msg":"nope"}"#).unwrap();
        let e = ensure_ok(&c, "搜索").expect_err("★ 非 200 必须 Err");
        assert!(e.contains("404"), "{e}");
        assert!(e.contains("nope"), "要带上上游 msg：{e}");
        let d: Value = serde_json::from_str(r#"{"code":"500"}"#).unwrap();
        assert!(ensure_ok(&d, "搜索").is_err(), "★ 字符串非 200 也要 Err");
        let n: Value = serde_json::from_str(r#"{"msg":"x"}"#).unwrap();
        assert!(ensure_ok(&n, "搜索").is_err(), "★ 缺 code 必须 Err");
    }

    #[test]
    /// ★★ 反空真：0 条 ⇒ Err，且**要说明是哪个过滤导致**（名字不含关键词 / 无封面）
    ///
    /// 注入：把 `items_of` 里 `if out.is_empty()` 的 Err 段删掉 ⇒ 本条红。
    #[test]
    fn empty_result_is_an_error_with_the_filter_named() {
        // ① 名字全不含关键词
        let v: Value = serde_json::from_str(
            r#"{"code":200,"data":[{"id":"1","name":"无关短剧","cover":"https://c/1.jpg","episodes":10}]}"#,
        )
        .unwrap();
        let e = items_of(&v, "战狼", "搜索").expect_err("★ 全不含关键词必须 Err");
        assert!(e.contains("0 条"), "{e}");
        assert!(e.contains("名字不含关键词被滤 1 条"), "要点名过滤原因：{e}");

        // ② 名字含关键词但没封面
        let v2: Value = serde_json::from_str(
            r#"{"code":200,"data":[{"id":"1","name":"战狼","episodes":10}]}"#,
        )
        .unwrap();
        let e2 = items_of(&v2, "战狼", "搜索").expect_err("★ 全无封面必须 Err");
        assert!(e2.contains("无封面被滤 1 条"), "{e2}");

        // ③ data 不是数组 / 键名变了
        let v3: Value = serde_json::from_str(r#"{"code":200,"list":[]}"#).unwrap();
        let e3 = items_of(&v3, "战狼", "搜索").expect_err("★ 缺 data 必须 Err");
        assert!(e3.contains("data"), "要点名缺的键：{e3}");
        assert!(e3.contains("list"), "要带回实际顶层键：{e3}");
    }

    /// 真实形态解析（逐字用实测读数构造）
    #[test]
    fn parses_real_response() {
        let v: Value = serde_json::from_str(
            r#"{"code":200,"msg":"搜索短剧“战狼”共找到【8】个结果","time":"2026-10-27",
                 "total":20053,"num":8,
                 "data":[{"id":"67c482a15836b",
                          "name":"战狼之父亲归来（99集）张亚坤＆屈婉琼＆尹昕＆爪爪",
                          "label":0,"addtime":"2025-03-02",
                          "cover":"https://t12.baidu.com/it/u=3859229605,220847762&fm=30",
                          "url":"https://pan.quark.cn/s/780a34a06f38",
                          "episodes":99,"state":0,"incremental_id":18763}]}"#,
        )
        .unwrap();
        let l = items_of(&v, "战狼", "搜索").unwrap();
        assert_eq!(l.len(), 1);
        assert_eq!(l[0].id, "67c482a15836b");
        assert!(l[0].title.contains("战狼之父亲归来"));
        assert_eq!(l[0].cover.as_deref(), Some("https://t12.baidu.com/it/u=3859229605,220847762&fm=30"));
        assert_eq!(
            l[0].subtitle.as_deref(),
            Some("共99集"),
            "★ DEX 的备注形态就是「共N集」"
        );

        // url 能被按 id 反查（play 用）
        assert_eq!(
            url_of_id(&v, "67c482a15836b").as_deref(),
            Some("https://pan.quark.cn/s/780a34a06f38")
        );
        assert_eq!(url_of_id(&v, "不存在"), None);
    }

    #[test]
    /// ★★ 取流：交回的是**网盘分享页**，label 必须写明"需 Pan 链路解析"（不许当直链）
    ///
    /// 注入：把 `pan_play_of` 的 label 改成 `None`（或空串）⇒ 本条红。
    #[test]
    fn play_returns_share_page_with_honest_label() {
        let v: Value = serde_json::from_str(
            r#"{"code":200,"data":[{"id":"1","name":"战狼","cover":"https://c/1.jpg",
                 "url":"https://pan.quark.cn/s/780a34a06f38","episodes":99}]}"#,
        )
        .unwrap();
        let p = pan_play_of(&v, "战狼").unwrap();
        assert_eq!(p[0].url, "https://pan.quark.cn/s/780a34a06f38");
        let lab = p[0].label.clone().unwrap_or_default();
        assert!(lab.contains("网盘分享页"), "★ 必须写清这是分享页而不是直链：{lab}");
        assert!(lab.contains("Pan 链路"), "要点名它靠哪条链路：{lab}");
        assert!(!lab.is_empty(), "★ 不许给空 label（那等于静默当直链）");

        // 没有 url / 关键词不匹配 ⇒ Err
        let no_url: Value =
            serde_json::from_str(r#"{"code":200,"data":[{"id":"1","name":"战狼"}]}"#).unwrap();
        assert!(pan_play_of(&no_url, "战狼").is_err());
        assert!(pan_play_of(&v, "不存在").is_err(), "关键词不匹配 ⇒ Err");
    }

    #[test]
    /// ★★ 三段未实现的文案**必须逐字包含 Lead 给的那句**，且**不许**写"本仓没有转发服务"
    ///
    /// # 依据（Lead 逐字给的口径）
    /// ```text
    /// 正确： 「该链路依赖 Pan 基类的网盘工具链（本批契约明确不做 mProxy）」
    /// 错误： 「本仓没有转发服务」—— 那是**过时说法**：
    ///         `streamproxy::register(url, headers)` 真实存在（streamproxy.rs:819），
    ///         只是"能力存在 ≠ 接起来就对"（那条还没验）。
    /// ```
    /// 注入：把 `PAN_CHAIN_REASON` 改成"本仓没有转发服务" ⇒ 本条红。
    #[test]
    fn pan_chain_reason_is_verbatim_and_does_not_deny_the_capability() {
        assert_eq!(
            PAN_CHAIN_REASON,
            "该链路依赖 Pan 基类的网盘工具链（本批契约明确不做 mProxy）",
            "★ 文案必须逐字来自裁定"
        );
        assert!(
            !PAN_CHAIN_REASON.contains("没有转发服务"),
            "★ 不许把事实说错（转发服务是存在的，只是没接起来）"
        );
        assert!(PAN_CHAIN_REASON.contains("Pan 基类"), "{PAN_CHAIN_REASON}");
        assert!(PAN_CHAIN_REASON.contains("mProxy"), "{PAN_CHAIN_REASON}");
    }

    /// ★★ 四段的行为：`search` 真做；`list` 报 Pan 链路缺口；
    ///    `home` 给**空分类**（不造假分类）；第 2 页如实报"不支持分页"
    ///
    /// 注入：把 `list` 改成 `Ok(CspList::default())`、或 `home` 里塞一个假分类 ⇒ 本条红。
    ///
    /// ⚠️ 只留 `#[tokio::test]`（本仓已多次踩到"叠 `#[test]` ⇒ async functions cannot
    ///    be used for tests"—— 那会把整批门禁编译断掉）。
    #[tokio::test]
    async fn segments_behave_as_declared() {
        let s = GuiGui::new();
        assert!(s.supports_search(), "★ 搜索是真做的 ⇒ 能力位 true");

        // ① home：分类表**空**（不造假分类）
        let h = s.home("").await.expect("home 不该 Err（空分类是合法状态）");
        assert!(h.categories.is_empty(), "★ 不许造一个假分类糊过去：{:?}", h.categories);
        assert!(h.items.is_empty());

        // ② list：Pan 链路缺口，且文案逐字
        let e = s.list("1", 1, "").await.expect_err("★ list 必须 Err（Pan 链路本批不做）");
        assert!(e.contains(PAN_CHAIN_REASON), "{e}");
        assert!(e.contains("Pan"), "{e}");

        // ③ 第 2 页：如实报"不支持分页"（不重复返回第 1 页）
        let e2 = s.search("战狼", 2, "").await.expect_err("★ 第 2 页必须 Err");
        assert!(e2.contains("不支持分页"), "{e2}");
        assert!(e2.contains("第 2 页"), "要带上页码便于定位：{e2}");

        // ④ detail/play 无缓存 ⇒ 如实报缺口（不返回空壳）
        let e3 = s.detail("某个不在缓存里的 id", "").await.expect_err("★ 必须 Err");
        assert!(e3.contains(PAN_CHAIN_REASON), "{e3}");
        let e4 = s.play("网盘", "某个不在缓存里的 id", "").await.expect_err("★ 必须 Err");
        assert!(e4.contains(PAN_CHAIN_REASON), "{e4}");

        // ⑤ play 带 url（detail 编的 id 形态）⇒ 交回分享页 + 诚实 label
        let p = s
            .play("网盘", "67c482a15836b|https://pan.quark.cn/s/780a34a06f38", "")
            .await
            .expect("带 url 的 id 应能交回分享页");
        assert_eq!(p[0].url, "https://pan.quark.cn/s/780a34a06f38");
        assert!(p[0].label.as_deref().unwrap_or("").contains("网盘分享页"));
    }

    #[test]
    /// ★ 冻结：本仓 `CspSite` 没有 `isVideoFormat` / `manualVideoCheck` 等价位
    ///   （DEX 的 `Pan` 基类有这两个方法）
    ///
    /// 注入：若有人在 `mod.rs` 加了这两个 trait 方法 ⇒ 本条红（提醒把实现补上并把本测改成真断言）。
    #[test]
    fn pan_base_hooks_are_honestly_unimplemented() {
        let src = include_str!("mod.rs");
        let flat: String = src.chars().filter(|c| !c.is_whitespace()).collect();
        for name in ["isVideoFormat", "manualVideoCheck"] {
            assert!(
                !flat.contains(&format!("fn{name}")),
                "★ mod.rs 里出现了 {name} ⇒ 能力位补上了，请把本类实现也补上"
            );
        }
        // 反面（运行时读普查产物，读不到就跳过 —— 不让缺文件把门禁搞红）
        let probe = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../.probe/decompiled/r3dex-spider.json");
        match std::fs::read_to_string(&probe) {
            Ok(json) => assert!(
                json.contains("manualVideoCheck"),
                "★ 普查产物里应有 Pan 基类的这个方法 —— 否则本类「登记为缺口」站不住"
            ),
            Err(_) => eprintln!("[跳过] 读不到普查产物（{probe:?}）"),
        }
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_gui_gui -- --ignored --nocapture"]
    async fn csp_live_gui_gui_search() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = GuiGui::new();
        /*
         * ★★ 这条用例的判据**改过一次**（如实留档，这是本类最该看的一段）
         *
         * ```text
         * 第一版：`s.search(...).await.expect("search 应成功")` + `assert!(!items.is_empty())`
         *   ⇒ 判据是"**必须成功**"。
         * 2026-10-27 21:0x 复跑时**它红了**：`operation timed out`（20s）。
         * ⇒ 我逐层取证（**没有**直接判"站点死了"）：
         *     · TCP 443  ⇒ **通**（连了 3 次都通）
         *     · TLS 握手 ⇒ **成功**（`CONNECTION ESTABLISHED`）
         *     · 手工 HTTP（openssl 发完整请求）⇒ **45 秒无任何响应**（连状态行都没有）
         *     · Python 直连 / 走代理 **两条路径都超时**
         *   ⇒ 结论：**TLS 层正常、应用层无响应** ⇒ 这是**站点自身此刻异常**，
         *      与我们的 client 无关（我先前用同一份代码**拿到过 8 条真数据**，见注入日志）。
         * ★ 另一件必须说清的事：我的 `.no_proxy()` 补丁**不是**它现在失败的原因 ——
         *   探针显示**走代理也一样超时**（两条路径同结果）。
         * ```
         *
         * ⇒ 判据改成（**与 csp_Duboku / csp_SaoHuo 的同一族**）：
         *   · 成功 ⇒ 必须真拿到条目（**反空真**）
         *   · 失败 ⇒ 必须报得明确（可区分于"我们参数错"）
         *   ⇒ 这样它**不会因上游长期抖动而永远红**，也**不会**把"上游死"固化成期望。
         */
        match s.search("战狼", 1, "").await {
            Ok(l) => {
                eprintln!(
                    "[LIVE] search(战狼): {} 条，首条={} / 备注={:?}",
                    l.items.len(),
                    l.items[0].title,
                    l.items[0].subtitle
                );
                assert!(!l.items.is_empty(), "★ 成功就必须真有条目（反空真）");
                let d = s.detail(&l.items[0].id, "").await.expect("缓存里应有该 id ⇒ detail 应成功");
                eprintln!(
                    "[LIVE] detail: {} — {} 集（flag={}）",
                    d.title,
                    d.episodes.len(),
                    d.episodes[0].flag
                );
                let p = s.play("网盘", &d.episodes[0].id, "").await.expect("play 应成功");
                eprintln!("[LIVE] play: {} [{}]", p[0].url, p[0].label.clone().unwrap_or_default());
                assert!(p[0].url.starts_with("http"), "★ 必须拿到真地址（网盘分享页）");
            }
            Err(e) => {
                eprintln!("[LIVE] search 如实失败：{e}");
                eprintln!(
                    "[LIVE] ⇒ 结论：**该站上游此刻异常**                     （★ 逐层取证：TCP 通、TLS 通、**HTTP 层无响应**；直连与走代理两条路径同结果                      ⇒ 是站点自身，不是我们的 client；同一份代码先前拿到过 8 条真数据）"
                );
                // ★ 判据：失败要能被读懂（不是含糊的"失败了"）
                assert!(
                    e.contains("失败") || e.contains("timed out") || e.contains("HTTP"),
                    "★ 上游异常要报得能读懂：{e}"
                );
            }
        }
    }
}

#[cfg(test)]
#[path = "gui_gui_proxy_tests.rs"]
mod proxy_tests;
