// ═══════════════════════════════════════════════════════════════════════
//  csp_AppLY —— TVBox `csp_AppLY` 的 Rust 重写（「戏曲多多」梨园戏曲）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么（实测取自 `.probe/ref-subscription.json`）
//
// ```json
// {"key":"戏曲多多","name":"🎭梨园戏曲｜听戏","type":3,"api":"csp_AppLY",
//  "style":{"type":"rect","ratio":1.0009}}
// ```
// ⇒ **没有 ext**：站点是**写死**的 `https://fly.daoran.tv`（DEX 里 4 个端点的
//    const-string 全是这个 host，没有一处从 ext 读）。
//
// # ★ 协议（反汇编复原 + 真网络端到端实证，2026-10-27）
//
// 四段都是 **POST JSON**，`Content-Type: application/json;charset=utf-8`，
// 且必须带一个**固定头** `md5: SkvyrWqK9QHTdCT12Rhxunjx+WwMTe9y4KwgeASFDhbYabRSPskR0Q==`
// （DEX `AppLY.a(String url, Map)` 里与 Content-Type/UA 一起放进 header map）。
//
// ```text
// home   POST /API_ROP/page/setinf/get   {"leastNum":"0","memberId":"","project":"lyhxcx","userId":"yszyz"}
// list   POST /API_ROP/search/album/list {"cur":"<page>","item":"o5","pageSize":"20","sect":[...]}
// detail POST /API_ROP/album/res/list    {"albumCode":"<id>","cur":"1","project":"lyhxcx",
//                                         "pageSize":"2147483647","selectFlag":"0","userId":"yszyz"}
// play   POST /API_ROP/play/get/playurl  {"item":"y9","nodeCode":"001000","project":"lyhxcx",
//                                         "px":"2","resCode":"<集 code>",
//                                         "userId":"92315ec6e58a45ba7f47fd143b3d7956"}
// 封面前缀 https://ottphoto.daoran.tv/HD/ + <img>
// ```
//
// ★ **实证读数（2026-10-27 真打上游，逐段）**：
// ```text
// home   ⇒ 200 {"code":10000000,"text":"成功","sects":[{"code":"zaobang","name":"枣梆"},
//                {"code":"yuju","name":"豫剧"}, …]}                        ← 真分类
// list   cur=1 project=lyhxcx sect=[]   ⇒ 200 {"pb":{"totalCount":7315,"totalPage":366,
//                "curPageSize":20,"dataList":[{"code":"16omNSZdMV937489",
//                "name":"京剧《哪吒闹海》","img":"OPERATE/PAGE_IMAGE/…"}]}}  ← 真条目
// detail albumCode=16omNSZdMV937489     ⇒ 200 {"album":{…},"pb":{"dataList":[
//                {"code":"11040070003544","name":"京剧《哪吒闹海》","artistName":"魏娟",
//                 "allTime":4254,"clicks":167048}]}}                       ← 真剧集
// play   resCode=11040070003544         ⇒ 200 {"playres":{"playurl":
//                "http://flytx.daoran.tv/sv/…/….m3u8?auth_key=…&sign=…"}}  ← **真 m3u8 直链**
// ⚠️ 缺 md5 头 ⇒ 200 但 {"code":10000008,"text":"请求被拒绝，非法头信息",...}
//    ⇒ **判据：那个头是必需的**（不是"有它更好"）。
// ⚠️ list 的 `sect` 若为 `""`（非数组）⇒ Spring 直接 **HTTP 400 Bad Request**
//    ⇒ 这类"参数形状错就 400"的形态要求我们**形状严格按 DEX 造**（见下面 sect_of）。
// ```
//
// # ⚠️ 搜索：本类**把搜索整体委托给宿主基类**（如实报，不假装）
// ```text
// DEX：`AppLY.searchContent(String,boolean)` 的**唯一一条指令**是
//      `invoke-super com.github.catvod.crawler.Spider.searchContent(String,Z)`。
// 而这块 dex 里 `com.github.catvod.crawler.Spider` 是**空壳基类**：
//      r3_dexdump 读出 `methods=0`（class_data_off=0，无任何方法体）
//      ⇒ 基类实现**来自宿主 APK**，本 jar 里看不到 ⇒ **协议不可知**。
// ⇒ 处置：`supports_search() = false`，`search()` 返回**手写的** Err（点名原因）。
//    不写 `Ok(空列表)` 冒充支持。配置里该源也确实没有 `searchable`。
// ```
//
// # ⚠️ 已知缺口（Lead 已裁定本批不做，如实登记）
// ```text
// ① `mProxy`：AppLY 的 DEX 方法表里**没有** mProxy（本批"mProxy 不做"对该类零影响）。
// ② `loadPic`：也没有。封面取图只需 UA ⇒ 走源 `cover_headers`（声明式）。
// ③ `initApi`：没有（`AppLY.init` 只 `invoke-super`，一行）。
// ④ `isVideoFormat` / `manualVideoCheck`：**DEX 里没有这两个方法** ⇒ 该类不存在这两个位。
// ```

use async_trait::async_trait;
use serde_json::{json, Value};

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX 里 `AppLY.a(...)` 放进 header map 的那一条（逐字，含等号与两个 `=` 结尾）
const MD5_HEADER: &str =
    "SkvyrWqK9QHTdCT12Rhxunjx+WwMTe9y4KwgeASFDhbYabRSPskR0Q==";

/// DEX 里硬编码的 host（不来自 ext）
const HOST: &str = "https://fly.daoran.tv";

/// 封面前缀（DEX categoryContent/detailContent 都是这个）
const PIC_PREFIX: &str = "https://ottphoto.daoran.tv/HD/";

/// 固定参数（逐字来自 DEX 的 const-string）
const PROJECT: &str = "lyhxcx";
const USER_ID: &str = "yszyz";
/// play 段的 userId 与其余段**不同**（DEX 里就是这个值，别"统一"掉）
const PLAY_USER_ID: &str = "92315ec6e58a45ba7f47fd143b3d7956";

const P_HOME: &str = "/API_ROP/page/setinf/get";
const P_LIST: &str = "/API_ROP/search/album/list";
const P_DETAIL: &str = "/API_ROP/album/res/list";
const P_PLAY: &str = "/API_ROP/play/get/playurl";

// ═══════════════════════════════════════════════════════════════════════
//  纯函数（全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// `sect` 参数 —— ★ **形状敏感**（实测：给字符串 `""` ⇒ 上游 HTTP 400）
///
/// # 为什么不能"图省事写成字符串"
/// ```text
/// DEX 造的是 `ArrayList<String>`（`new ArrayList` + `add(tid)`），JSON 序列化成
/// `["<tid>"]`。若我们写 `"sect": ""`，Spring 反序列化失败 ⇒ **HTTP 400**，
/// 而错误页里没有 code 字段 ⇒ 从调用方看是"上游异常"，排查方向会被带偏。
/// ⇒ 空 tid 时**返回 JSON 空数组**（与 DEX 的 `sect=[]` 逐字一致）。
/// ```
pub fn sect_json(tid: &str) -> Value {
    if tid.trim().is_empty() {
        json!([])
    } else {
        json!([tid.trim()])
    }
}

/// 上游统一判据：**只有 `code:10000000` 是成功**（这是本站在用的成功码，不是 200）
///
/// ★ 不把"缺 code"当成功 —— 那会把一个错误 HTML 当 JSON 解析后静默成空。
///
/// ⚠️ 生命周期必须写 `'a`（同时借 `v` 与 `what`）：只写 `&Value` 会报
///    "missing lifetime specifier" —— 返回值借的是 `v`，而 `what` 只进错误串。
pub fn ensure_ok<'a>(v: &'a Value, what: &str) -> Result<&'a Value, String> {
    match v.get("code").and_then(|c| c.as_i64()) {
        Some(10000000) => Ok(v),
        Some(c) => Err(format!(
            "上游 {what} 返回 code={c}（text={}）",
            v.get("text").and_then(|t| t.as_str()).unwrap_or("")
        )),
        None => Err(format!(
            "上游 {what} 响应里没有 code 字段（可能被拦或改协议了）"
        )),
    }
}

/// 首页分类：`sects[]` → `{code,name}`；**0 条 ⇒ Err**
pub fn cats_of(v: &Value) -> Result<Vec<CspCategory>, String> {
    ensure_ok(v, "首页")?;
    let arr = v
        .get("sects")
        .and_then(|s| s.as_array())
        .ok_or_else(|| "上游首页响应里没有 sects（键名可能变了）".to_string())?;
    let out: Vec<CspCategory> = arr
        .iter()
        .filter_map(|o| {
            let id = o.get("code").and_then(|c| c.as_str())?.to_string();
            let name = o.get("name").and_then(|c| c.as_str())?.to_string();
            if id.is_empty() || name.is_empty() {
                return None;
            }
            Some(CspCategory { id, name })
        })
        .collect();
    if out.is_empty() {
        return Err(format!(
            "上游首页 sects 解析出 0 个分类（sects 有 {} 项）",
            arr.len()
        ));
    }
    Ok(out)
}

/// 列表：`pb.dataList[]` → 条目；**0 条 ⇒ Err**
pub fn items_of(v: &Value, what: &str) -> Result<Vec<CspItem>, String> {
    ensure_ok(v, what)?;
    let pb = v
        .get("pb")
        .ok_or_else(|| format!("上游 {what} 响应里没有 pb（键名可能变了）"))?;
    let arr = pb
        .get("dataList")
        .and_then(|x| x.as_array())
        .ok_or_else(|| format!("上游 {what} 的 pb 里没有 dataList"))?;
    let out: Vec<CspItem> = arr
        .iter()
        .filter_map(|o| {
            let id = o.get("code").and_then(|c| c.as_str())?.to_string();
            let title = o.get("name").and_then(|c| c.as_str())?.to_string();
            if id.is_empty() || title.is_empty() {
                return None;
            }
            Some(CspItem {
                id,
                title,
                cover: pic_of(o.get("img").and_then(|x| x.as_str())),
                subtitle: o
                    .get("publishTime")
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.is_empty())
                    .map(String::from),
            })
        })
        .collect();
    if out.is_empty() {
        return Err(format!(
            "上游 {what} 的 pb.dataList 解析出 0 条（dataList 有 {} 项）",
            arr.len()
        ));
    }
    Ok(out)
}

/// 总页数（`pb.totalPage`）—— 只在确实是个正数时才给
pub fn page_count_of(v: &Value) -> Option<u32> {
    v.get("pb")
        .and_then(|p| p.get("totalPage"))
        .and_then(|x| x.as_i64())
        .filter(|n| *n > 0)
        .map(|n| n as u32)
}

/// 封面：相对路径要拼前缀；**已经是 http(s) 的原样返回**（DEX 也是这个判据：
/// `AppLY.categoryContent` 里对 img 直接拼前缀，而 detail 的 imgs 里有绝对地址）。
pub fn pic_of(img: Option<&str>) -> Option<String> {
    let s = img?.trim();
    if s.is_empty() {
        None
    } else if s.starts_with("http") {
        Some(s.to_string())
    } else {
        Some(format!("{PIC_PREFIX}{s}"))
    }
}

/// 详情：`album` + `pb.dataList[]`（每项是一"集"，code 是取流要用的 resCode）
pub fn detail_of(v: &Value, id: &str) -> Result<CspDetail, String> {
    ensure_ok(v, "详情")?;
    let album = v
        .get("album")
        .ok_or_else(|| "上游详情响应里没有 album".to_string())?;
    let title = album
        .get("name")
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or(id)
        .to_string();
    let arr = v
        .get("pb")
        .and_then(|p| p.get("dataList"))
        .and_then(|x| x.as_array())
        .ok_or_else(|| "上游详情的 pb 里没有 dataList（剧集列表）".to_string())?;
    let mut eps: Vec<CspEpisode> = Vec::new();
    for (i, o) in arr.iter().enumerate() {
        let Some(code) = o.get("code").and_then(|c| c.as_str()).filter(|s| !s.is_empty()) else {
            continue;
        };
        let name = o
            .get("name")
            .and_then(|c| c.as_str())
            .filter(|s| !s.is_empty())
            .map(String::from)
            .unwrap_or_else(|| format!("第{}集", i + 1));
        eps.push(CspEpisode {
            id: code.to_string(),
            title: name,
            // 单线路源：DEX 里线路名就是 '在线播放'（detailContent 的 const-string）
            flag: "在线播放".to_string(),
        });
    }
    if eps.is_empty() {
        return Err(format!(
            "上游详情 {id} 的 pb.dataList 解析出 0 集（有 {} 项）",
            arr.len()
        ));
    }
    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover: pic_of(album.get("img").and_then(|x| x.as_str())),
        description: album
            .get("des")
            .or_else(|| album.get("description"))
            .and_then(|x| x.as_str())
            .filter(|s| !s.is_empty())
            .map(String::from),
        episodes: eps,
    })
}

/// 取流：`playres.playurl`；空 ⇒ Err
pub fn play_url_of(v: &Value) -> Result<String, String> {
    ensure_ok(v, "取流")?;
    v.get("playres")
        .and_then(|p| p.get("playurl"))
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .map(String::from)
        .ok_or_else(|| "上游取流响应里没有 playres.playurl（该集可能无源）".to_string())
}

// ═══════════════════════════════════════════════════════════════════════
//  站点实现
// ═══════════════════════════════════════════════════════════════════════

pub struct AppLY {
    client: super::http_context::CspHttpContext,
}

impl AppLY {
    pub const CLASS: &'static str = "AppLY";

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| {
            reqwest::Client::builder()
                // Ignore environment proxies; CspHttpContext applies app policy.
                .no_proxy()
                .timeout(std::time::Duration::from_secs(20))
        });
        Self { client }
    }

    /// DEX 的 `AppLY.a(url, map)`：POST JSON + 那三个固定头
    async fn post_json(&self, path: &str, body: &Value) -> Result<Value, String> {
        let url = format!("{HOST}{path}");
        self.post_json_url(&url, body).await
    }

    async fn post_json_url(&self, url: &str, body: &Value) -> Result<Value, String> {
        let resp = self
            .client
            .client()?
            .post(url)
            .header(reqwest::header::CONTENT_TYPE, "application/json;charset=utf-8")
            .header(reqwest::header::USER_AGENT, "okhttp/3.9.1")
            .header("md5", MD5_HEADER)
            .header(reqwest::header::ACCEPT, "*/*")
            .body(body.to_string())
            .send()
            .await
            .map_err(|e| format!("请求上游失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取上游响应失败（{url}）：{e}"))?;
        if !status.is_success() {
            /*
             * ★ 这里**不吞 HTTP 状态**：实测 list 的 sect 形状错时上游就是 400，
             *   而 400 的 body 是 Spring 默认错误 JSON（**没有 code 字段**）。
             *   带上状态码与 body 前 120 字，别让调用方看到"没有 code 字段"却猜不到 400。
             */
            let head = text.chars().take(120).collect::<String>();
            return Err(format!("上游返回 HTTP {status}（{url}）：{head}"));
        }
        serde_json::from_str(&text).map_err(|e| {
            format!(
                "上游响应不是合法 JSON（{url}）：{e}；前 120 字：{}",
                text.chars().take(120).collect::<String>()
            )
        })
    }
}

impl Default for AppLY {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for AppLY {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        // DEX 顺序：leastNum → memberId → project → userId（形状逐字照搬）
        let body = json!({
            "leastNum": "0",
            "memberId": "",
            "project": PROJECT,
            "userId": USER_ID,
        });
        let v = self.post_json(P_HOME, &body).await?;
        Ok(CspHome {
            categories: cats_of(&v)?,
            items: Vec::new(), // DEX 的 homeContent 只给分类，不预取条目
        })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        /*
         * `sect` 的**最终值**：优先用 ext 里 `q.sect`（Pan 基类同 csp_XBPQ 的 `q` 那套），
         * 没给就用本类的 tid。这与 Pan 基类读 `q.sect` 的行为同构，且**默认路径与
         * DEX 逐字一致**（tid 为空 ⇒ `sect: []`）。
         */
        let sect = sect_from_ext(ext).unwrap_or_else(|| tid.to_string());
        let body = json!({
            "cur": page.to_string(),
            "item": "o5",
            "pageSize": "20",
            "sect": sect_json(&sect),
        });
        let v = self.post_json(P_LIST, &body).await?;
        Ok(CspList {
            items: items_of(&v, "分类列表")?,
            page,
            page_count: page_count_of(&v),
            total: v
                .get("pb")
                .and_then(|p| p.get("totalCount"))
                .and_then(|x| x.as_u64()),
        })
    }

    /// ★ **本类不支持搜索** —— 见文件头「搜索」那段：DEX 把搜索整体 `invoke-super`
    ///   给宿主基类 `crawler.Spider`，而本 dex 里该基类**无方法体** ⇒ 协议不可知。
    ///   ⇒ 手写 Err 点名原因（不写 `Ok(空)` 冒充支持）。
    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("AppLY 不支持搜索（该类的 searchContent 整体委托给宿主基类 \
             crawler.Spider.searchContent，而本 dex 里基类无方法体 ⇒ 协议不可知）"
            .to_string())
    }

    fn supports_search(&self) -> bool {
        false
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let body = json!({
            "albumCode": id,
            "cur": "1",
            "project": PROJECT,
            "pageSize": "2147483647",
            "selectFlag": "0",
            "userId": USER_ID,
        });
        let v = self.post_json(P_DETAIL, &body).await?;
        detail_of(&v, id)
    }

    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        // `id` 就是剧集的 `code`（== resCode），见 detail_of 的注释
        let body = json!({
            "item": "y9",
            "nodeCode": "001000",
            "project": PROJECT,
            "px": "2",
            "resCode": id,
            "userId": PLAY_USER_ID,
        });
        let v = self.post_json(P_PLAY, &body).await?;
        let url = play_url_of(&v)?;
        Ok(vec![CspPlay {
            url,
            headers: vec![("User-Agent".to_string(), "okhttp/3.9.1".to_string())],
            label: Some("在线播放".to_string()),
        }])
    }
}

/// 从 ext 读 `q.sect`（上层配置里偶尔出现，形态见 `csp_XBPQ` 的 `q`）
///
/// ⚠️ 刻意只认 http 里的裸键值，不做严格 JSON 解析：ext 可能是字符串也可能是对象，
///    本仓 `CspSite` 的契约是"原样文本"。取不到就 None（调用方用 tid 兜底）。
pub fn sect_from_ext(ext: &str) -> Option<String> {
    let t = ext.trim();
    if t.is_empty() {
        return None;
    }
    for seg in t.split(['&', '?', '{', '}', '"', ',']) {
        if let Some(rest) = seg.trim().strip_prefix("sect=") {
            let v = rest.trim();
            if !v.is_empty() && v != "[]" && !v.starts_with('%') {
                return Some(v.to_string());
            }
        }
    }
    None
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册
// ═══════════════════════════════════════════════════════════════════════
crate::csp::register_site!(AppLY);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    /// ★★ 成功码是 `10000000`（**不是** 200）—— 拿 200 判成功会全盘失灵
    ///
    /// 注入：把 `ensure_ok` 里的 `Some(10000000)` 改成 `Some(200)` ⇒ 本条立刻红。
    fn success_code_is_ten_million_not_two_hundred() {
        let ok: Value = serde_json::from_str(
            r#"{"code":10000000,"text":"成功","sects":[{"code":"zaobang","name":"枣梆"}]}"#,
        )
        .unwrap();
        ensure_ok(&ok, "首页").expect("★ 10000000 才是成功码");

        let http_ok: Value = serde_json::from_str(r#"{"code":200}"#).unwrap();
        assert!(ensure_ok(&http_ok, "首页").is_err(), "★ code:200 不是本站的成功码");

        // 实测的两条真实失败
        let bad_hdr: Value = serde_json::from_str(
            r#"{"streamNo":null,"code":10000008,"text":"请求被拒绝，非法头信息"}"#,
        )
        .unwrap();
        let e = ensure_ok(&bad_hdr, "首页").expect_err("★ 非法头必须 Err");
        assert!(e.contains("10000008"), "{e}");
        assert!(e.contains("非法头信息"), "要把上游 text 带出来：{e}");

        let unknown: Value =
            serde_json::from_str(r#"{"streamNo":"x","code":10000010,"text":"未知错误"}"#).unwrap();
        assert!(ensure_ok(&unknown, "详情").is_err(), "★ 10000010 也必须 Err");

        let no_code: Value = serde_json::from_str(r#"{"ok":true}"#).unwrap();
        let e2 = ensure_ok(&no_code, "首页").expect_err("★ 缺 code 必须 Err");
        assert!(e2.contains("没有 code"), "{e2}");
    }

    #[test]
    /// ★★ `sect` **必须是 JSON 数组**（实测：给字符串 ⇒ 上游 HTTP 400）
    ///
    /// 注入：把 `sect_json` 改成恒 `json!("")` ⇒ 本条红。
    fn sect_must_be_a_json_array() {
        assert_eq!(sect_json(""), json!([]), "★ 空 tid ⇒ 空数组（不是空串）");
        assert_eq!(sect_json("zaobang"), json!(["zaobang"]));
        assert_eq!(sect_json("  yuju  "), json!(["yuju"]), "要去空白");
        // 判据：它**不是**字符串
        assert!(!sect_json("zaobang").is_string(), "★ 不能是字符串（上游会 400）");
        assert!(sect_json("").is_array());
    }

    #[test]
    /// ★★ 反空真：分类/条目/剧集/取流 任一解析出 0 条 ⇒ **必须 Err**
    ///
    /// 注入：删掉任意一个 `is_empty()` 分支的 Err ⇒ 对应断言红。
    fn empty_parses_are_errors() {
        // 分类：sects 缺失 / 空 / 项缺字段
        let no_sects: Value = serde_json::from_str(r#"{"code":10000000}"#).unwrap();
        assert!(cats_of(&no_sects).is_err());
        let empty: Value = serde_json::from_str(r#"{"code":10000000,"sects":[]}"#).unwrap();
        let e = cats_of(&empty).expect_err("★ 0 分类必须 Err");
        assert!(e.contains("0 个分类"), "{e}");
        let junk: Value =
            serde_json::from_str(r#"{"code":10000000,"sects":[{"foo":1}]}"#).unwrap();
        assert!(cats_of(&junk).is_err(), "★ 取不出 code/name 也必须 Err");

        // 条目
        let no_pb: Value = serde_json::from_str(r#"{"code":10000000}"#).unwrap();
        let e2 = items_of(&no_pb, "分类列表").expect_err("★ 没有 pb 必须 Err");
        assert!(e2.contains("pb"), "{e2}");
        let empty_pb: Value =
            serde_json::from_str(r#"{"code":10000000,"pb":{"dataList":[]}}"#).unwrap();
        assert!(items_of(&empty_pb, "分类列表").is_err(), "★ 0 条必须 Err");

        // 剧集
        let no_ep: Value = serde_json::from_str(
            r#"{"code":10000000,"album":{"name":"x"},"pb":{"dataList":[]}}"#,
        )
        .unwrap();
        let e3 = detail_of(&no_ep, "1").expect_err("★ 0 集必须 Err");
        assert!(e3.contains("0 集"), "{e3}");

        // 取流
        let no_url: Value =
            serde_json::from_str(r#"{"code":10000000,"playres":{"playurl":""}}"#).unwrap();
        let e4 = play_url_of(&no_url).expect_err("★ 空 url 必须 Err");
        assert!(e4.contains("playurl"), "{e4}");
    }

    #[test]
    /// 真实形态解析（逐字段用实测读数构造，不是编的）
    fn parses_real_shapes() {
        // ① 首页（实测：sects[0] = zaobang/枣梆）
        let home: Value = serde_json::from_str(
            r#"{"streamNo":"00009xBMXDMtBf396245","code":10000000,"text":"成功",
                 "sects":[{"code":"zaobang","name":"枣梆"},{"code":"yuju","name":"豫剧"}]}"#,
        )
        .unwrap();
        let cats = cats_of(&home).unwrap();
        assert_eq!(cats.len(), 2);
        assert_eq!(cats[0].id, "zaobang");
        assert_eq!(cats[0].name, "枣梆");

        // ② 列表（实测：pb.totalCount=7315 / 首条 京剧《哪吒闹海》）
        let list: Value = serde_json::from_str(
            r#"{"code":10000000,"pb":{"totalPage":366,"totalCount":7315,"dataList":[
                 {"code":"16omNSZdMV937489","name":"京剧《哪吒闹海》",
                  "img":"OPERATE/PAGE_IMAGE/album/B/65433c77e4b0eabaeab32b5f.jpg"}]}}"#,
        )
        .unwrap();
        let items = items_of(&list, "分类列表").unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "16omNSZdMV937489");
        assert_eq!(items[0].title, "京剧《哪吒闹海》");
        assert_eq!(
            items[0].cover.as_deref(),
            Some("https://ottphoto.daoran.tv/HD/OPERATE/PAGE_IMAGE/album/B/65433c77e4b0eabaeab32b5f.jpg"),
            "★ 相对 img 要拼前缀"
        );
        assert_eq!(page_count_of(&list), Some(366), "★ 总页数取 pb.totalPage");

        // ③ 详情（实测：pb.dataList[0].code=11040070003544 / artistName=魏娟）
        let det: Value = serde_json::from_str(
            r#"{"code":10000000,"album":{"name":"京剧《哪吒闹海》","img":"x.jpg","des":"简介"},
                 "pb":{"dataList":[{"code":"11040070003544","name":"京剧《哪吒闹海》",
                                    "artistName":"魏娟","allTime":4254,"clicks":167048}]}}"#,
        )
        .unwrap();
        let d = detail_of(&det, "16omNSZdMV937489").unwrap();
        assert_eq!(d.title, "京剧《哪吒闹海》");
        assert_eq!(d.description.as_deref(), Some("简介"));
        assert_eq!(d.episodes.len(), 1);
        assert_eq!(d.episodes[0].id, "11040070003544", "★ 集 id 是 resCode（取流要用它）");
        assert_eq!(d.episodes[0].flag, "在线播放");

        // ④ 取流（实测：真 m3u8 + auth_key）
        let play: Value = serde_json::from_str(
            r#"{"code":10000000,"playres":{"fileCode":"11040070003544002",
                 "playurl":"http://flytx.daoran.tv/sv/1b8123eb/1b8123eb.m3u8?auth_key=1-2-3&sign=abc"}}"#,
        )
        .unwrap();
        let u = play_url_of(&play).unwrap();
        assert!(u.starts_with("http://flytx.daoran.tv/"), "{u}");
        assert!(u.contains("m3u8"), "{u}");
    }

    #[test]
    /// 封面：绝对地址原样、相对地址拼前缀、空 ⇒ None
    fn pic_prefixing() {
        assert_eq!(
            pic_of(Some("http://a/b.jpg")).as_deref(),
            Some("http://a/b.jpg"),
            "★ 绝对地址不许再拼前缀"
        );
        assert_eq!(
            pic_of(Some("rel/b.jpg")).as_deref(),
            Some("https://ottphoto.daoran.tv/HD/rel/b.jpg")
        );
        assert_eq!(pic_of(Some("")), None);
        assert_eq!(pic_of(None), None);
    }

    /// ★ 搜索**必须**如实报"不支持"，且 `supports_search()==false`
    ///
    /// 注入：把 `search` 改成返回 `Ok(CspList::default())` ⇒ 本条红（那是"占位返回空冒充成功"）。
    ///
    /// ⚠️ 这条用 `#[tokio::test]`（真正的 async fn），**不能**叠 `#[test]` ——
    ///    叠了会报 "async functions cannot be used for tests"，把整批门禁编译断掉。
    #[tokio::test]
    async fn search_is_honestly_unsupported() {
        let s = AppLY::new();
        assert!(!s.supports_search(), "★ 本类不支持搜索，能力位必须是 false");
        let e = s.search("京剧", 1, "").await.expect_err("★ 必须 Err，不许 Ok(空)");
        assert!(e.contains("不支持搜索"), "{e}");
        assert!(
            e.contains("宿主基类"),
            // ★ 用「」而不是 ASCII 引号：Rust 字符串里裸引号会直接变成语法错误
            "错误要点名真实原因（委托给宿主基类，不是「我们没写」）：{e}"
        );
    }

    #[test]
    /// 源码判据：`post_json` 必须真的带上那个 `md5` 头（缺了上游 `10000008`）
    ///
    /// ⚠️ 自证陷阱：本测试字面量里也有 `md5` ⇒ 单看 `contains("md5")` 删掉头也不会红。
    ///    ⇒ 按归一化后的出现次数判：调用点 1 次 + 断言字面量 1 次 = 2；删掉 ⇒ 1 ⇒ 红。
    fn md5_header_is_sent() {
        let src = include_str!("app_ly.rs");
        let flat: String = src.chars().filter(|c| !c.is_whitespace()).collect();
        let hits = flat.matches(r#".header("md5",MD5_HEADER)"#).count();
        assert!(
            hits >= 2,
            "★ post_json 必须带 md5 头（调用点不见了：hits={hits}）"
        );
    }

    #[test]
    /// ext 里的 `sect=` 能被取到（Pan 基类同构），取不到就 None
    fn sect_from_ext_reads_bare_key() {
        assert_eq!(sect_from_ext("").as_deref(), None);
        assert_eq!(sect_from_ext("sect=zaobang").as_deref(), Some("zaobang"));
        assert_eq!(
            sect_from_ext(r#"{"q":"a=1&sect=yuju&b=2"}"#).as_deref(),
            Some("yuju"),
            "要从字符串或对象文本里都抠得出来"
        );
        assert_eq!(sect_from_ext("sect=[]").as_deref(), None, "空数组视作没给");
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_app_ly -- --ignored --nocapture"]
    async fn csp_live_app_ly_four_segments() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = AppLY::new();
        let home = s.home("").await.expect("home 应成功");
        eprintln!(
            "[LIVE] home: 分类 {} 个，首分类={}",
            home.categories.len(),
            home.categories.first().map(|c| c.name.clone()).unwrap_or_default()
        );
        let l = s.list(&home.categories[0].id, 1, "").await.expect("list 应成功");
        eprintln!("[LIVE] list({}): {} 条 total={:?}", home.categories[0].name, l.items.len(), l.total);
        let d = s.detail(&l.items[0].id, "").await.expect("detail 应成功");
        eprintln!("[LIVE] detail: {} — {} 集", d.title, d.episodes.len());
        let p = s.play("在线播放", &d.episodes[0].id, "").await.expect("play 应成功");
        eprintln!("[LIVE] play: {}", p[0].url);
    }
}

#[cfg(test)]
#[path = "app_ly_proxy_tests.rs"]
mod proxy_tests;
