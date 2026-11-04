// ═══════════════════════════════════════════════════════════════════════
//  csp 源 → MediaProvider 的桥
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这一层
//
// [`crate::csp::CspSite`] 是「TVBox spider 四个方法」的最小映射，
// 而宿主只认 [`crate::provider::MediaProvider`]。
// 两者字段形状不同（TVBox 用 tid/pg，宿主用 ListRequest；TVBox 的
// playerContent 返回一条 id，宿主返回候选流列表），所以必须有桥。
//
// # 这一层**不加任何数据**
//
// ```text
// 名字  ← 配置里的 sites[].name（导入时给的，不由 csp 实现编）
// 分类  ← 导入时真探测的 home()（拿不到就如实报错，不填假分类）
// 条目  ← list()/detail() 的真返回值
// 地址  ← play() 的真 URL（拿不到就报错，不给空字符串）
// ```
//
// ★ 尤其：**绝不**在没有分类时补一个「全部」分类糊过去 ——
//   那样用户点进去只会看到一个空列表，却不知道是源没给分类。

use std::sync::Arc;

use async_trait::async_trait;

use crate::model::{
    Category, Episode, ErrorKind, MediaDetail, MediaId, MediaItem, MediaKind, Page, PlayRequest,
    PlaySource, ProviderError, ProviderManifest, Result, Section, SectionSource, StreamCandidate,
    StreamKind, TvboxCategoryEntry,
};
use crate::provider::{ListRequest, MediaProvider};

use super::{
    CspList,route, CspSite};

/// 首页最多给几个分类区块（与 `tvbox.rs` 的 HOME_SECTIONS 对齐）
const HOME_SECTIONS: usize = 8;

/// 一个 `csp_Xxx` 源
pub struct CspProvider {
    manifest: ProviderManifest,
    /// 配置里的原始 api（`csp_Bili`），原样保留 —— 落盘与订阅比对要用
    api: String,
    /// ext **原样透传**文本（见 [`CspSite`]）
    ext: String,
    site: Arc<dyn CspSite>,
    /// 导入时探测到的分类（可为空 ⇒ 运行期再问 home()）
    classes: Vec<TvboxCategoryEntry>,
}

impl CspProvider {
    /// 建一个 csp 源
    ///
    /// `api` 必须是注册表里有的类（否则 [`route`] 返回 None ⇒ 这里报错，
    /// 而不是建一个「什么都做不了」的 Provider）。
    /// # `from_import`：来源是"由 TVBox 配置导入"吗（**显式标记，与 id 命名无关**）
    ///
    /// 判据为什么必须是显式参数而不是 `id.starts_with("csp-")`：
    /// ```text
    /// 将来加"内置 csp 源"时，最自然的命名就是 `csp-bili`（本文件类名都叫 `csp_*`）——
    /// 用前缀判断会把**内置源静默藏起来**（用户永远看不到它）。
    /// 而且本仓已有 `builtin-bili` 反例，它恰好绕开了前缀，证明不了这个坑。
    /// ```
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        api: &str,
        ext: &str,
        classes: Vec<TvboxCategoryEntry>,
        from_import: bool,
        // `hidden`：是否**在源列表里隐藏**（只影响展示；搜索/收藏/进度不受影响）。
        // ★ 2026-10-28（Owner 图1）：内置 csp 源也要藏进聚合的**二级页** ——
        //   它们是"TVBox 的类"，不是"聚合的子站"，平铺在一级列表里会引起误会。
        //   与 `from_import` 分开传：来源（是否来自配置）与展示（藏不藏）是两件事。
        hidden: bool,
    ) -> std::result::Result<Self, String> {
        let id = id.into();
        let name = name.into();
        if id.is_empty() {
            return Err("源 id 为空".to_string());
        }
        let site = route(api).ok_or_else(|| super::unimplemented_reason(api))?;
        /*
         * ★ search 能力按 **这个类自己的声明** 判定，不再写死 false。
         *
         * 历史（别退回去）：
         * ```text
         * 早先写死 `search: false`，注释理由是"上游搜索接口要 buvid/风控签名，本实现没做"。
         * 那句话已经过期 —— Bili 的 WBI 搜索真网络搜到 20 条、PanWebShare 搜到 2 条。
         * 而写死 false 的后果是：`registry.rs:287` 的 `h.enabled && capabilities.search`
         * 把**所有** csp 源直接排除在搜索之外，连"试着搜一下"的机会都没有。
         * ```
         */
        let capabilities = crate::model::Capabilities {
            vod: true,
            search: site.supports_search(),
            ..Default::default()
        };
        /*
         * ★ 是否"由 TVBox 配置导入的子站"—— 决定 manifest.hidden，判据是**调用点传入的
         *   `from_import`**，与 id 怎么命名**无关**（上一版用 `id.starts_with("csp-")`，
         *   会把将来命名成 `csp-bili` 的内置源静默藏起来 —— 交叉复核指出的真缺口）。
         *
         * 为什么要藏：A′ 的口径是"导入的 TVBox 源不单独出现在源列表里，只经由
         * `tvbox_agg` 聚合入口使用"。appleCMS 子站已经这么做了（`tvbox.rs:1200 hidden: true`），
         * 而 csp 子站走本文件，之前写死 `hidden: false` ⇒ 16 个 csp 子站全在列表里可见。
         */
        let manifest = ProviderManifest {
            id,
            name,
            version: "1.0.0".to_string(),
            kind: "tvbox".to_string(),
            description: Some(format!(
                "由 TVBox 配置导入（{} 的 Rust 重写实现，不依赖 Java/DEX）：{}",
                site.class(),
                api.trim()
            )),
            icon: None,
            id_prefixes: Vec::new(),
            capabilities,
            cover_headers: Vec::new(),
            config: Vec::new(),
            api_version: 1,
            theme_color: None,
            working: true,
            broken_reason: None,
            enabled: None,
            /*
             * ★★★ 2026-10-28（Owner 图1：「Tvbox聚合源…应该属于第二个的二级页面，
             *   而不是直接平铺 这样子会引起误会」）
             * ```text
             * 改前：导入来的子站 hidden（对），内置 csp 源**可见**（错）——
             *   于是设置页出现"TVBox 聚合（47 个源）"这一组，把 47 个内置源**平铺**在
             *   聚合卡片旁边，看起来像"聚合的子站"，其实它们是独立源。
             * ⇒ 两类都藏进聚合的**二级页**（聚合卡片的 ⚙ / 组头的「配置」）：
             *   一级列表只剩聚合那一条，二级页里才有这 47 条（带勾选、可停用）。
             * ⚠️ `hidden` 只影响**列表展示**：搜索仍经聚合扇出到它们，收藏/进度不受影响。
             * ```
             */
            hidden,
        };
        Ok(Self {
            manifest,
            api: api.trim().to_string(),
            ext: ext.to_string(),
            site,
            classes,
        })
    }

    /// 测试专用：直接注入一个 site（用于断言"search 真的转发到 site"）
    #[cfg(test)]
    pub(crate) fn for_test(id: &str, site: Arc<dyn CspSite>, ext: &str) -> Self {
        let capabilities = crate::model::Capabilities {
            vod: true,
            search: site.supports_search(),
            ..Default::default()
        };
        Self {
            manifest: ProviderManifest {
                id: id.to_string(),
                name: id.to_string(),
                version: "0".into(),
                kind: "tvbox".into(),
                description: None,
                icon: None,
                id_prefixes: Vec::new(),
                capabilities,
                cover_headers: Vec::new(),
                config: Vec::new(),
                api_version: 1,
                theme_color: None,
                working: true,
                broken_reason: None,
                enabled: None,
                hidden: false,
            },
            api: "csp_Test".into(),
            ext: ext.to_string(),
            site,
            classes: Vec::new(),
        }
    }

    /// `CspList` → `Page<MediaItem>`（**list 与 search 共用**，避免两份映射漂移）
    fn page_of(&self, out: CspList) -> Page<MediaItem> {
        Page {
            items: out
                .items
                .into_iter()
                .map(|i| to_item(&self.manifest.id, i))
                .collect(),
            page: out.page,
            page_count: out.page_count,
            total: out.total,
        }
    }

    /// 配置里的原始 api（`csp_Xxx`）
    pub fn api(&self) -> &str {
        &self.api
    }

    /// 取分类：导入时探测过就用那份，没有就现问一次（真 HTTP）
    async fn categories_or_probe(&self) -> Result<Vec<TvboxCategoryEntry>> {
        if !self.classes.is_empty() {
            return Ok(self.classes.clone());
        }
        let home = self
            .site
            .home(&self.ext)
            .await
            .map_err(|e| classify_err(self.site.class(), e))?;
        Ok(home
            .categories
            .into_iter()
            .map(|c| TvboxCategoryEntry {
                id: c.id,
                name: c.name,
                pid: None,
            })
            .collect())
    }
}

/// 把 csp 实现给出的错误字符串映射成宿主错误类型
///
/// 判据写死在这里，是为了**同一个失败在 UI 上总是同一种提示**：
/// ```text
/// 上游给了 HTTP 状态 / 连不上   → Network（可以重试）
/// 上游 code != 0 / JSON 不对    → Parse（源站改版或需要登录）
/// 我们的实现没有这项能力        → Unsupported
/// ```
/// 网盘类名 → 盘种 code（与 `pan::PanKind::code()` 同一套词；`None` = 不是网盘类）
fn login_kind_of_class(class: &str) -> Option<&'static str> {
    match class {
        "Pan115" => Some("115"),
        "Pan123" => Some("123"),
        "PanAli" => Some("aliyun"),
        "PanTianyi" => Some("tianyi"),
        "PanXunlei" => Some("xunlei"),
        "PanGuangya" => Some("guangya"),
        "PanUC" => Some("uc"),
        "PanQuark" => Some("quark"),
        _ => None,
    }
}

/// 这条错误文案是不是"要登录"（而不是"站点坏了"）
///
/// # 为什么用文案判定而不是让每个类改返回值
/// ```text
/// csp 实现层的 trait 返回 `String`（不是结构化的），8 个网盘类各有一堆返回点。
/// 与其在那 8 个文件里逐处改（风险高、容易漏），不如在**唯一的分类点**判定：
/// 这些文案全是我们自己写的、且都带上游原话，标记表放在一处、有门禁守着。
/// ```
/// 判据：**只有网盘类才走这条判定**（`login_kind_of_class` 不为 None）；
/// 普通影视源出现同样的字眼不会变成"要登录"。
fn looks_like_login_required(msg: &str) -> bool {
    const MARKERS: &[&str] = &[
        "请重新登录",
        "未登录",
        "登录过期",
        "未授权",
        "InvalidSessionKey",
        "AccessTokenInvalid",
        "device_id is empty",
        "captcha_token",
        "无效token",
        "errno=99",
        "code=20101",
    ];
    MARKERS.iter().any(|m| msg.contains(m))
}

fn classify_err(class: &str, e: String) -> ProviderError {
    /*
     * ★★★ 2026-10-28（Owner：网盘要"提示登录 + 出二维码"，而不是空白）
     * ```text
     * csp 实现层的错误是 `String`（trait 决定），而宿主错误类型是有结构的
     * （`kind` + `needs_login`）。网盘族未登录时必须让 UI 能**认出**这是登录问题，
     * 否则用户只看到一句"取流失败"，点也没地方点。
     * ⇒ 约定一个前缀：`NEED_LOGIN:<盘种>|<人话>`。
     *   这里把它翻译成 `Unauthorized` + `login_kind`，并把 `NEED_LOGIN:...|` 剥掉，
     *   让消息本身仍是给用户看的原话。
     * ```
     * 约定只有这一个生产点（本函数），类那边只负责"打标记"。
     */
    if let Some(rest) = e.strip_prefix("NEED_LOGIN:") {
        let (kind, msg) = match rest.split_once('|') {
            Some((k, m)) => (k.to_string(), m.to_string()),
            None => ("unknown".to_string(), rest.to_string()),
        };
        let mut err = ProviderError::unauthorized(msg.chars().take(200).collect::<String>());
        err.login_kind = Some(kind);
        return err;
    }
    /*
     * ★ 2026-10-28：网盘类 + "要登录"的字眼 ⇒ Unauthorized + login_kind。
     *   UI 靠 `login_kind` 决定弹哪个盘的二维码（Owner：点登录要出二维码，不是空白）。
     */
    if let Some(kind) = login_kind_of_class(class) {
        if looks_like_login_required(&e) {
            let mut err = ProviderError::unauthorized(e.chars().take(200).collect::<String>());
            err.login_kind = Some(kind.to_string());
            return err;
        }
    }
    let head = e.chars().take(200).collect::<String>();
    if e.starts_with("HTTP ") || e.contains("请求 ") || e.contains("读取 ") {
        ProviderError::network(head)
    } else if e.contains("code=") || e.contains("不是 JSON") {
        ProviderError::parse(head)
    } else if e.contains("不支持") || e.contains("尚未实现") {
        ProviderError::new(ErrorKind::Unsupported, head)
    } else {
        ProviderError::new(ErrorKind::Other, head)
    }
}

/// 剧集 id 是否可**直接交给 site.play()**（无需再走一次 detail 二跳）
///
/// # 2026-10-30（23018 猎捕二轮·行号级诊断，lead 授权修复）
/// ```text
/// 原判据只认 `contains('|')`（bili 的 `bvid|cid` 形）。而 zhinan 这类源的剧集 id
/// 是**纯 URL**（`https://pan.quark.cn/s/xxx`，zhinan.rs:406-415）⇒ 被误判成
/// "只给了条目 id" ⇒ 拿 URL 再走一次 detail（resolve 的 detail 二跳）⇒
/// zhinan.rs:524 拼出 /book/https://pan.quark.cn/s/xxx.html ⇒ 实测 HTTP 404
/// ⇒ resolve 整体 Err，分享兜底（parse_share_page → resolve_share_play）根本
/// 到不了 —— 23018 猎捕二轮 4K网盘子站 9 条全灭、日志零痕迹的死点。
/// ⇒ 判据补：URL 形（http:// / https://）也是"可直接播"的 id 形态。
/// ```
/// # ★★ 2026-10-31（T4-C：hdmoli/libvio「夸克网盘 换分享 token 请求失败：builder error」）
/// ```text
/// 复合剧集 id（`{vid}\u{1}{分享页URL}`，HDMoli/Libvio 的 detail_of 产出形态）同样
/// 是"可直接交给 play()"的 id —— 它**已经**是剧集 id，再走 detail 二跳会把整个复合 id
/// 拼进 detail_url：hdmoli 路由宽松（污染 URL 实测返回 200 正常页）⇒ detail_of 用
/// 污染 id 再拼一层 `\u{1}` ⇒ 双重复合 ⇒ `split_ep_id` 按**第一个** `\u{1}` 切分后
/// URL 段内含 `\x01` ⇒ `parse_share_page` 在 `/` 截断 ⇒ share_id = `8efcd269e4b7\x01https:`
/// ⇒ `share_stoken` 把它拼进 Referer ⇒ http crate 的 HeaderValue 拒绝控制字符
/// （\x00-\x1F/\x7F）⇒ reqwest send 报 **Error::builder**（4kzhinan 纯 URL id 无二跳
/// ⇒ 同函数同 cookie 成功 —— 与 10-31 审计时间线完全吻合）。
/// 判据：`\u{1}` 之后的载荷能被 `parse_share_page` 认成夸克/UC 分享页 ⇒ 直通。
/// 只认分享页载荷 —— sao_huo/app_get 等其它复合 id 源的行为一字不动。
/// ```
/// 门禁：`tests/csp_episode_direct_play.rs` + 本文件 `mod tests`（注入删掉本分支 ⇒ 红）。
pub fn episode_id_is_direct_play(episode: &str) -> bool {
    episode.contains('|')
        || episode.starts_with("http://")
        || episode.starts_with("https://")
        || super::pan_episode_select::is_file_id(episode)
        || super::app99::is_episode_id(episode)
        || share_page_composite(episode)
}

/// 复合剧集 id 且 `\u{1}` 之后的载荷是夸克/UC 分享页（见 [`episode_id_is_direct_play`]）
fn share_page_composite(episode: &str) -> bool {
    match episode.split_once('\u{1}') {
        Some((_, tail)) => crate::csp::pan_share_play::parse_share_page(tail).is_some(),
        None => false,
    }
}

fn to_item(provider_id: &str, it: super::CspItem) -> MediaItem {
    MediaItem {
        id: MediaId::new(provider_id, it.id),
        title: it.title,
        cover: it.cover,
        subtitle: it.subtitle,
        badges: Vec::new(),
        kind: MediaKind::Movie,
        description: None,
    }
}

#[async_trait]
impl MediaProvider for CspProvider {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    async fn home(&self) -> Result<Vec<Section>> {
        let classes = self.categories_or_probe().await?;
        Ok(classes
            .iter()
            .take(HOME_SECTIONS)
            .map(|c| Section {
                id: format!("{}-{}", self.manifest.id, c.id),
                title: c.name.clone(),
                source: SectionSource::Category {
                    category_id: c.id.clone(),
                },
                items: Vec::new(),
            })
            .collect())
    }

    async fn categories(&self) -> Result<Vec<Category>> {
        Ok(self
            .categories_or_probe()
            .await?
            .into_iter()
            .map(|c| Category {
                id: c.id,
                name: c.name,
                children: Vec::new(),
            })
            .collect())
    }

    async fn list(&self, req: ListRequest) -> Result<Page<MediaItem>> {
        let page = if req.page == 0 { 1 } else { req.page };
        let out = self
            .site
            .list(&req.category_id, page, &self.ext)
            .await
            .map_err(|e| classify_err(self.site.class(), e))?;
        Ok(self.page_of(out))
    }

    /// ★ 搜索：**同一套映射**（`page_of`），同一套错误分类（`classify_err`）
    ///
    /// # 为什么这条曾经整条缺失（真事故）
    /// `CspProvider` 只覆写了 home/categories/list/detail/resolve，**没有 search**
    /// ⇒ 落到 `MediaProvider::search` 的默认实现 `Err(unsupported("该源不支持搜索"))`。
    /// 而各 site 类上的 `CspSite::search` 是另一层 —— 两层没接上，
    /// 所以 `tvbox_agg` 扇出去、16 个子站被调，全都返回"不支持搜索" ⇒ 聚合搜索恒空。
    async fn search(&self, keyword: &str, page: u32) -> Result<Page<MediaItem>> {
        if !self.site.supports_search() {
            return Err(ProviderError::unsupported(format!(
                "{} 不支持搜索（该类的能力声明是 false）",
                self.site.class()
            )));
        }
        let page = if page == 0 { 1 } else { page };
        let out = self
            .site
            .search(keyword, page, &self.ext)
            .await
            .map_err(|e| classify_err(self.site.class(), e))?;
        // 空结果与 list 同口径：返回**空页**（让 registry 记成"命中但 0 条"），
        // 不报错 —— 搜索没有结果是正常结果，不是故障。
        Ok(self.page_of(out))
    }

    async fn detail(&self, id: &MediaId) -> Result<MediaDetail> {
        let d = self
            .site
            .detail(&id.native, &self.ext)
            .await
            .map_err(|e| classify_err(self.site.class(), e))?;
        let d = super::pan_episode_select::expand_detail(d).await;
        let mut line_orders = std::collections::HashMap::<String, u32>::new();
        let episodes: Vec<Episode> = d
            .episodes
            .iter()
            .enumerate()
            .map(|(i, e)| {
                let order = line_orders.entry(e.flag.clone()).or_default();
                *order += 1;
                Episode {
                // ★ 剧集 id 就是 `bvid|cid`，resolve() 直接用它取流
                id: e.id.clone(),
                title: if e.title.is_empty() {
                    format!("第{}集", i + 1)
                } else {
                    e.title.clone()
                },
                order: *order,
                player_id: None,
                // ★ 线路名透出到 wire（多线路源靠它分组；单线路源是"默认"/play_from 名）
                flag: e.flag.clone(),
            }})
            .collect();
        Ok(MediaDetail {
            id: MediaId::new(&self.manifest.id, d.id),
            title: d.title,
            cover: d.cover,
            description: d.description,
            badges: Vec::new(),
            kind: MediaKind::Movie,
            meta: serde_json::Map::new(),
            sources: vec![PlaySource {
                code: "default".to_string(),
                title: self.manifest.name.clone(),
                count: episodes.len() as u32,
                nested: Vec::new(),
            }],
            episodes,
        })
    }

    async fn resolve(&self, id: &MediaId, req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
        let owner = super::pan_playback_guard::owner_from_payload(
            req.extra.as_ref().unwrap_or(&serde_json::Value::Null)
        ).and_then(super::pan_playback_guard::register)
            .map_err(|e| classify_err(self.site.class(), e))?;
        super::pan_playback_guard::with_scope(owner, async {
        let result = async {
        // ★ 与 tvbox.rs 的 appleCMS 分支同一条规矩（那边踩过「第二集播出第一集」）：
        //   剧集 id（这里形如 `bvid|cid`）优先于条目 id。
        let episode = match req.episode_id.as_deref() {
            Some(e) if !e.trim().is_empty() => e.trim().to_string(),
            _ => id.native.clone(),
        };
        let context = super::app99::episode_context(&episode);
        let mut spec = super::pan_episode_select::EpisodeSpec {
            title: req.episode_title.clone().or_else(|| context.as_ref().map(|c| c.0.clone())).unwrap_or_default(),
            order: req.episode_order.or_else(|| context.as_ref().map(|c| c.1)),
        };
        // 只给了条目 id（bvid）而没有 cid ⇒ 先取详情拿第一集，别猜一个 cid
        let episode = if episode_id_is_direct_play(&episode) {
            episode
        } else {
            let d = self
                .site
                .detail(&episode, &self.ext)
                .await
                .map_err(|e| classify_err(self.site.class(), e))?;
            super::pan_playback_guard::check_current()
                .map_err(|e| classify_err(self.site.class(), e))?;
            let d = super::pan_episode_select::expand_detail(d).await;
            let selected = d.episodes.first()
                .ok_or_else(|| ProviderError::new(ErrorKind::NotFound, "这个条目没有可播放的剧集"))?;
            if spec.title.is_empty() { spec.title = selected.title.clone(); }
            if spec.order.is_none() { spec.order = Some(1); }
            selected.id.clone()
        };
        super::pan_playback_guard::check_current()
            .map_err(|e| classify_err(self.site.class(), e))?;
        if super::pan_episode_select::is_file_id(&episode) {
            let play = super::pan_episode_select::resolve_file_id(&episode, &spec).await
                .map_err(|e| classify_err(self.site.class(), e))?;
            let mut candidate = StreamCandidate::new(play.url, StreamKind::Mp4).with_headers(play.headers);
            if let Some(label) = play.label { candidate = candidate.with_label(label); }
            return Ok(vec![candidate]);
        }
        // ★ 真 flag：来自 PlayRequest.flag（UI 选了哪条线路就传哪条），缺省空串
        let flag = req.flag.clone().unwrap_or_default();
        let plays = self
            .site
            .play(&flag, &episode, &self.ext)
            .await
            .map_err(|e| classify_err(self.site.class(), e))?;
        super::pan_playback_guard::check_current()
            .map_err(|e| classify_err(self.site.class(), e))?;
        if plays.is_empty() {
            return Err(ProviderError::new(
                ErrorKind::Other,
                "取流没有返回任何地址（上游没给 durl）",
            ));
        }
        // 分享页必须检查并选出具体文件，不能把页面或最大文件当作所选集。
        let mut out: Vec<StreamCandidate> = Vec::new();
        for p in plays {
            let ps = crate::pan::parse_share(&p.url);
            if ps.kind != crate::pan::PanKind::Unknown && !ps.share_id.is_empty() {
                let resolved = super::pan_episode_select::resolve_share(&p.url, None, &spec).await
                    .map_err(|e| classify_err(self.site.class(), e))?;
                let mut c = StreamCandidate::new(resolved.url, StreamKind::Mp4).with_headers(resolved.headers);
                if let Some(label) = resolved.label { c = c.with_label(label); }
                out.push(c);
                continue;
            }
            if ps.kind != crate::pan::PanKind::Unknown {
                let shell = reqwest::Url::parse(&p.url).ok().is_some_and(|url| {
                    matches!(url.path(), "/" | "/s" | "/s/" | "/pan") || url.path().starts_with("/share")
                });
                if shell {
                    return Err(ProviderError::new(ErrorKind::NotFound, "网盘分享地址缺少有效的分享标识，不能作为媒体播放"));
                }
            }
            let mut c = StreamCandidate::new(p.url, StreamKind::Mp4).with_headers(p.headers);
            if let Some(label) = p.label {
                c = c.with_label(label);
            }
            out.push(c);
        }
        Ok(out)
        }.await;
        super::pan_playback_guard::check_current()
            .map_err(|e| classify_err(self.site.class(), e))?;
        result
        }).await
    }
}

/// 导入/更新时用的**真探测**：问一次 home()，把分类翻出来
///
/// # 为什么要真探测，而不是「先注册、用到再说」
/// ```text
/// ① 导入报告里的「分类数」必须是真数字（0 和「没探测」是两件事）
/// ② 一类都没取到 ⇒ 这个源当下就是不可用的，必须进 skipped 并说明原因，
///    而不是让用户点进去才发现是空的
/// ```
/// ★ 探测失败**不伪造分类**：原样把上游错误交给调用方。
pub async fn probe_categories(
    api: &str,
    ext: &str,
) -> std::result::Result<Vec<TvboxCategoryEntry>, String> {
    let site = route(api).ok_or_else(|| super::unimplemented_reason(api))?;
    let home = site.home(ext).await?;
    if home.categories.is_empty() {
        return Err("上游没有返回任何分类（home 为空）".to_string());
    }
    Ok(home
        .categories
        .into_iter()
        .map(|c| TvboxCategoryEntry {
            id: c.id,
            name: c.name,
            pid: None,
        })
        .collect())
}

#[cfg(test)]
#[path = "pan_host_dispatch_tests.rs"]
mod share_dispatch_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_rejects_unimplemented_class() {
        let sample = crate::csp::unimplemented_sample();
        let err = CspProvider::new("id", "名", sample, "", Vec::new(), false, false)
            .err()
            .expect("没实现的类不能建 Provider");
        // ★ 文案的唯一来源是 `unimplemented_reason`（App99 这种"有具体原因"的类
        //   文案会是"暂不可用：…"，硬编码"尚未实现"就会随升级假红）
        assert_eq!(err, crate::csp::unimplemented_reason(sample));
    }

    /// ★★★ T4-C 门禁（2026-10-31）：分享页复合剧集 id 必须直通 play（不再 detail 二跳）
    ///
    /// ```text
    /// 根因：复合 id 被旧判据当成"裸条目 id"⇒ detail 二跳 ⇒ hdmoli 宽松路由回 200
    /// ⇒ detail_of 用污染 id 再拼一层 `\u{1}` ⇒ split_ep_id 后 URL 段含 `\x01`
    /// ⇒ share_stoken 的 Referer 非法 ⇒ reqwest `Error::builder`（真机 C 类 ×6）。
    /// 注入证红：把 episode_id_is_direct_play 里的 `share_page_composite(episode)`
    ///   分支删掉 ⇒ 本条红。
    /// ```
    #[test]
    fn share_page_composite_episode_ids_are_direct_play() {
        // HDMoli / Libvio 的真实形态：`{详情id}\u{1}{分享页URL}`（真机审计 n=60/72）
        assert!(episode_id_is_direct_play(
            "2857\u{1}https://pan.quark.cn/s/8efcd269e4b7"
        ));
        assert!(episode_id_is_direct_play(
            "714891227\u{1}https://pan.quark.cn/s/3859962d7e13?pwd=ab12"
        ));
        // UC 同族同理
        assert!(episode_id_is_direct_play(
            "9\u{1}https://drive.uc.cn/s/ba2e2f0417114"
        ));
        // ★ 载荷不是分享页的复合 id 不受影响（sao_huo/app_get 等其它复合源照旧走二跳）
        assert!(!episode_id_is_direct_play("sao\u{1}flag\u{1}0"));
        assert!(!episode_id_is_direct_play("2857\u{1}https://cdn.example/x.m3u8"));
        // 既有判据不许回归（对照 tests/csp_episode_direct_play.rs）
        assert!(episode_id_is_direct_play("bvid|cid"));
        assert!(episode_id_is_direct_play("https://pan.quark.cn/s/abc"));
        assert!(!episode_id_is_direct_play("2857"));
    }


    // ── 可见性：由**显式参数**决定（不是 id 前缀，也不是"是不是 csp"）──────────
    #[test]
    fn tvbox_imported_csp_subsites_are_hidden() {
        // tvbox.rs 的 csp_id_base() 产出 `csp-<class>-<crc32>` 这种 id
        let p = CspProvider::new(
            "csp-bili-1a2b3c4d", "哔哩", "csp_Bili", "", Vec::new(),
            true,  // from_import
            true,  // hidden
        )
        .expect("csp_Bili 必须能建 Provider");
        assert!(
            p.manifest().hidden,
            "★ 由 TVBox 导入的 csp 子站必须 hidden（否则 A′ 里 16 个子站又全冒出来）"
        );
    }

    /*
     * ★★★ 2026-10-28 改判（Owner 图1 逐字）：
     * > Tvbox聚合源，是归属于 tvbox哪个源的…应该属于第二个的二级页面，
     * > 而不是直接平铺 这样子会引起误会
     *
     * 改前（A′ 2026-10-27）：内置 csp 源**必须可见** —— 那时确实需要让用户看见新源。
     * 改后：内置源与导入子站一样**藏进聚合二级页**，一级列表只剩聚合那一条。
     * ⇒ 判据跟着翻面，但保留"可见性由显式参数决定"这条更重要的不变量。
     */
    #[test]
    fn builtin_csp_provider_is_hidden_by_owner_decision() {
        let p = CspProvider::new(
            "csp-bili", "内置哔哩", "csp_Bili", "", Vec::new(),
            false, // from_import = false（它是内置源，不是导入的）
            true,  // hidden —— Owner 2026-10-28：藏进聚合二级页
        )
        .expect("合法");
        assert!(
            p.manifest().hidden,
            "★ 内置 csp 源现在也要 hidden（Owner：平铺在一级列表会引起误会）"
        );
        // 但**能力位**必须还在：hidden 只影响展示，不影响搜索/路由
        assert!(
            p.manifest().capabilities.vod,
            "★ hidden 不许把能力位也藏掉（否则聚合扇出/搜索会少它）"
        );
    }

    #[test]
    fn visibility_comes_from_the_parameter_not_the_id_prefix() {
        // 同一个"像 csp"的 id：传 visible 就可见
        let visible = CspProvider::new(
            "csp-builtin-x", "内置（名字像导入）", "csp_Bili", "", Vec::new(), false, false,
        )
        .expect("合法");
        assert!(
            !visible.manifest().hidden,
            "★ 判据是显式参数 —— 名字叫 `csp-builtin-x` 也不会被前缀判断藏掉"
        );
        // 同一个 id：传 hidden 就藏（证明这条不是"永远可见"的假绿）
        let hidden = CspProvider::new(
            "csp-builtin-x", "导入", "csp_Bili", "", Vec::new(), true, true,
        )
        .expect("合法");
        assert!(hidden.manifest().hidden, "显式 hidden=true ⇒ 必须藏");
    }


    // ── ★ 搜索打通的三条门禁 ─────────────────────────────────────────────
    struct FakeSite {
        supports: bool,
        seen: std::sync::Mutex<Vec<(String, u32, String)>>,
    }

    struct EpisodeFixtureSite {
        episodes: Vec<crate::csp::CspEpisode>,
        details: std::sync::atomic::AtomicUsize,
        plays: std::sync::atomic::AtomicUsize,
    }

    #[async_trait]
    impl CspSite for EpisodeFixtureSite {
        fn class(&self) -> &'static str { "EpisodeFixture" }
        fn supports_search(&self) -> bool { false }
        async fn home(&self, _: &str) -> std::result::Result<crate::csp::CspHome, String> { Ok(Default::default()) }
        async fn list(&self, _: &str, _: u32, _: &str) -> std::result::Result<CspList, String> { Ok(Default::default()) }
        async fn search(&self, _: &str, _: u32, _: &str) -> std::result::Result<CspList, String> { Err("夹具不支持搜索".into()) }
        async fn detail(&self, id: &str, _: &str) -> std::result::Result<crate::csp::CspDetail, String> {
            self.details.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(crate::csp::CspDetail { id:id.into(), title:"剧集".into(), episodes:self.episodes.clone(), ..Default::default() })
        }
        async fn play(&self, _: &str, _: &str, _: &str) -> std::result::Result<Vec<crate::csp::CspPlay>, String> {
            self.plays.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Err("分享文件不应调用源的播放页解析".into())
        }
    }

    fn episode_fixture(episodes: Vec<crate::csp::CspEpisode>) -> Arc<EpisodeFixtureSite> {
        Arc::new(EpisodeFixtureSite {
            episodes, details: std::sync::atomic::AtomicUsize::new(0),
            plays: std::sync::atomic::AtomicUsize::new(0),
        })
    }

    #[tokio::test]
    async fn episode_detail_keeps_selected_file_ids_and_counts_order_per_line() {
        let ids: Vec<String> = (1..=4).map(|n| super::super::pan_episode_select::encode_file_id(
            crate::pan::PanKind::Quark, "fixture", "", &format!("fid-{n}")
        )).collect();
        let site = episode_fixture(ids.iter().enumerate().map(|(i, id)| crate::csp::CspEpisode {
            id:id.clone(), title:format!("第{}集", i % 2 + 1), flag:if i < 2 { "A".into() } else { "B".into() },
        }).collect());
        let provider = CspProvider::for_test("episode-fixture", site, "");
        let detail = provider.detail(&MediaId::new("episode-fixture", "item")).await.unwrap();
        assert_eq!(detail.episodes.iter().map(|e| e.order).collect::<Vec<_>>(), [1, 2, 1, 2]);
        assert_eq!(detail.episodes.iter().map(|e| e.id.clone()).collect::<Vec<_>>(), ids);
    }

    #[tokio::test]
    async fn episode_file_ids_bypass_site_play_in_direct_and_detail_fallback_paths() {
        let site = episode_fixture(vec![crate::csp::CspEpisode {
            id:"panfile:invalid".into(), title:"第3集".into(), flag:"A".into(),
        }]);
        let provider = CspProvider::for_test("episode-fixture", site.clone(), "");
        let id = MediaId::new("episode-fixture", "item");
        let request = PlayRequest { episode_id:Some("panfile:invalid".into()), ..Default::default() };
        let err = provider.resolve(&id, &request).await.unwrap_err();
        assert!(!err.message.contains("没有可播放"), "具体文件不能再当条目id调用detail");
        assert_eq!(site.details.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert_eq!(site.plays.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert!(provider.resolve(&id, &PlayRequest::default()).await.is_err());
        assert_eq!(site.details.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert_eq!(site.plays.load(std::sync::atomic::Ordering::SeqCst), 0);
    }

    struct SlowPlaybackSite {
        entered: tokio::sync::Notify,
        release: tokio::sync::Notify,
        owners: std::sync::Mutex<Vec<Option<super::super::pan_playback_guard::PlaybackOwner>>>,
    }

    #[async_trait]
    impl CspSite for SlowPlaybackSite {
        fn class(&self) -> &'static str { "SlowPlaybackFixture" }
        fn supports_search(&self) -> bool { false }
        async fn home(&self, _: &str) -> std::result::Result<crate::csp::CspHome, String> { Ok(Default::default()) }
        async fn list(&self, _: &str, _: u32, _: &str) -> std::result::Result<CspList, String> { Ok(Default::default()) }
        async fn search(&self, _: &str, _: u32, _: &str) -> std::result::Result<CspList, String> { Err("不支持搜索".into()) }
        async fn detail(&self, _: &str, _: &str) -> std::result::Result<crate::csp::CspDetail, String> { Err("不应调用详情".into()) }
        async fn play(&self, _: &str, id: &str, _: &str) -> std::result::Result<Vec<crate::csp::CspPlay>, String> {
            self.owners.lock().unwrap().push(super::super::pan_playback_guard::current_owner());
            if id.contains("slow") {
                self.entered.notify_one();
                self.release.notified().await;
            }
            if id.contains("error") { return Err("上游迟到的错误".into()); }
            Ok(vec![crate::csp::CspPlay {
                url:"https://cdn.example/video.mp4".into(), headers:Vec::new(), label:None,
            }])
        }
    }

    #[tokio::test]
    async fn playback_provider_registers_before_parser_and_rejects_stale_success_and_error() {
        for (index, old_id) in ["slow-success", "slow-error"].into_iter().enumerate() {
            let site = Arc::new(SlowPlaybackSite {
                entered:tokio::sync::Notify::new(), release:tokio::sync::Notify::new(),
                owners:std::sync::Mutex::new(Vec::new()),
            });
            let provider = CspProvider::for_test("slow-fixture", site.clone(), "");
            let id = MediaId::new("slow-fixture", "item");
            let consumer = format!("provider-slow-parser-{index}");
            let request = |generation, episode: &str| PlayRequest {
                episode_id:Some(format!("https://cdn.example/{episode}")),
                extra:Some(serde_json::json!({"play_consumer":consumer,"play_generation":generation})),
                ..Default::default()
            };
            let old = request(1, old_id);
            let (old_result, ()) = tokio::join!(
                provider.resolve(&id, &old),
                async {
                    tokio::time::timeout(std::time::Duration::from_secs(2), site.entered.notified()).await.unwrap();
                    assert_eq!(provider.resolve(&id, &request(2, "new-success")).await.unwrap().len(), 1);
                    site.release.notify_one();
                }
            );
            assert!(old_result.unwrap_err().message.contains("已过期"), "迟到的成功及错误都不能覆盖新播放");
            let owners = site.owners.lock().unwrap();
            assert_eq!(owners.iter().map(|o| o.as_ref().unwrap().generation).collect::<Vec<_>>(), [1, 2],
                "真实源play future必须继承请求scope，不能在首await之后才登记");
        }
    }

    #[tokio::test]
    async fn playback_provider_rejects_incomplete_owner_before_source_call() {
        let site = Arc::new(SlowPlaybackSite {
            entered:tokio::sync::Notify::new(), release:tokio::sync::Notify::new(),
            owners:std::sync::Mutex::new(Vec::new()),
        });
        let provider = CspProvider::for_test("owner-fixture", site.clone(), "");
        let request = PlayRequest {
            episode_id:Some("https://cdn.example/ready".into()),
            extra:Some(serde_json::json!({"play_consumer":"partial-owner"})),
            ..Default::default()
        };
        assert!(provider.resolve(&MediaId::new("owner-fixture", "item"), &request).await.is_err());
        assert!(site.owners.lock().unwrap().is_empty());
    }

    #[async_trait]
    impl CspSite for FakeSite {
        fn class(&self) -> &'static str {
            "Fake"
        }
        fn supports_search(&self) -> bool {
            self.supports
        }
        async fn home(&self, _ext: &str) -> std::result::Result<crate::csp::CspHome, String> {
            Ok(Default::default())
        }
        async fn list(&self, _tid: &str, _p: u32, _ext: &str) -> std::result::Result<CspList, String> {
            Ok(CspList::default())
        }
        async fn search(&self, kw: &str, page: u32, ext: &str) -> std::result::Result<CspList, String> {
            self.seen
                .lock()
                .unwrap()
                .push((kw.to_string(), page, ext.to_string()));
            Ok(CspList {
                items: vec![crate::csp::CspItem {
                    id: "native-1".into(),
                    title: "命中".into(),
                    cover: None,
                    subtitle: None,
                }],
                page,
                page_count: None,
                total: None,
            })
        }
        async fn detail(&self, _id: &str, _ext: &str) -> std::result::Result<crate::csp::CspDetail, String> {
            Ok(Default::default())
        }
        async fn play(
            &self,
            _f: &str,
            _id: &str,
            _ext: &str,
        ) -> std::result::Result<Vec<crate::csp::CspPlay>, String> {
            Ok(Vec::new())
        }
    }

    #[tokio::test]
    async fn search_forwards_to_site_with_ext() {
        let site = Arc::new(FakeSite {
            supports: true,
            seen: std::sync::Mutex::new(Vec::new()),
        });
        let p = CspProvider::for_test("csp-fake-1", site.clone(), "{\"site\":[\"x\"]}");
        let page = p.search("兰香如故", 2).await.expect("应转发成功");
        assert_eq!(page.items.len(), 1, "映射必须复用 list 那一套");
        let idstr = format!("{:?}", page.items[0].id);
        assert!(idstr.contains("native-1"), "id 必须原样带上 native id：{idstr}");
        let seen = site.seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 1, "★ 必须真的调到 site.search 一次");
        assert_eq!(seen[0].0, "兰香如故");
        assert_eq!(seen[0].1, 2);
        assert_eq!(seen[0].2, "{\"site\":[\"x\"]}", "ext 必须原样透传");
    }

    #[tokio::test]
    async fn search_refuses_when_class_declares_false() {
        let site = Arc::new(FakeSite {
            supports: false,
            seen: std::sync::Mutex::new(Vec::new()),
        });
        let p = CspProvider::for_test("csp-fake-2", site.clone(), "");
        assert!(p.manifest().capabilities.search == false, "能力位必须跟着 supports_search");
        let err = p.search("x", 1).await.expect_err("声明 false 时不许搜");
        assert!(format!("{err}").contains("不支持搜索"), "{err}");
        assert!(site.seen.lock().unwrap().is_empty(), "不许偷偷发请求");
    }

    #[test]
    fn capability_search_follows_supports_search_per_class() {
        // ★ 直接对真实类断言（这几条就是"是否纳入聚合搜索"的判据）
        assert!(crate::csp::bili::Bili::new().supports_search(), "Bili 已真网络验证");
        assert!(crate::csp::pan_web_share::PanWebShare::new().supports_search(), "PanWebShare 已真网络验证");
        assert!(crate::csp::zhinan::Zhinan::new().supports_search(), "4KZhinan 已实现（未真网络验证，注释写明）");
        assert!(crate::csp::app99::App99::new().supports_search(), "App99 已实现（未单独真网络验证，注释写明）");
        assert!(!crate::csp::first_aid::FirstAid::new().supports_search(), "FirstAid 是占位 Err");
        assert!(!crate::csp::ikanbot::Ikanbot::new().supports_search(), "Ikanbot 搜索入口未确认");
    }

    #[test]
    fn new_rejects_empty_id() {
        let err = CspProvider::new("", "名", "csp_Bili", "", Vec::new(), false, false)
            .err()
            .expect("空 id 必须报错");
        assert_eq!(err, "源 id 为空");
    }

    #[test]
    fn new_keeps_api_and_declares_no_fake_search() {
        let p = CspProvider::new("lib-bili", "哔哩", "csp_Bili", "{\"n\":\"x\"}", Vec::new(), false, false)
            .expect("csp_Bili 必须能建 Provider");
        assert_eq!(p.api(), "csp_Bili");
        assert_eq!(p.ext, "{\"n\":\"x\"}", "ext 必须原样透传");
        let m = p.manifest();
        assert_eq!(m.kind, "tvbox");
        assert!(m.capabilities.vod);
        // ★ 这条原先是"搜索没实现就不许声明 search"。现在 search 已实现，
        //   口径改成：**能力位必须等于该类自己的 `supports_search()`**。
        assert_eq!(
            m.capabilities.search,
            p.site.supports_search(),
            "capabilities.search 必须与 supports_search() 一致（Bili 现在是 true）"
        );
        assert!(m.capabilities.search, "Bili 的搜索已真网络验证 ⇒ 必须声明 true");
        assert!(m.description.as_deref().unwrap_or("").contains("Rust 重写"));
    }

    #[test]
    fn classify_err_maps_network_and_upstream_codes() {
        assert_eq!(classify_err("Bili", "请求 x 失败：timeout".into()).kind, ErrorKind::Network);
        /* ★ 2026-10-28：网盘类 + "要登录"的字眼 ⇒ Unauthorized + login_kind
         *   （UI 靠 login_kind 决定弹哪个盘的二维码） */
        let e = classify_err("Pan115", "上游返回：请重新登录（errno=99）".into());
        assert_eq!(e.kind, ErrorKind::Unauthorized, "网盘类要认出这是登录问题");
        assert_eq!(e.login_kind.as_deref(), Some("115"), "且要说清是哪个盘");
        assert!(e.needs_login, "needs_login 必须跟着 Unauthorized");
        assert!(!e.message.contains("NEED_LOGIN"), "标记要从消息里剥掉（用户读不懂）");

        // 反空真：普通影视源出现同样的字眼**不许**变成"要登录"
        let e2 = classify_err("Bili", "请重新登录".into());
        assert_ne!(e2.kind, ErrorKind::Unauthorized, "非网盘类不许被误判成登录问题");
        assert!(e2.login_kind.is_none());


        assert_eq!(classify_err("Bili", "HTTP 502（x）：bad".into()).kind, ErrorKind::Network);
        assert_eq!(
            classify_err("Bili", "上游返回 code=-404 message=啥都木有".into()).kind,
            ErrorKind::Parse
        );
        assert_eq!(
            classify_err("Bili", "csp_X 尚未实现".into()).kind,
            ErrorKind::Unsupported
        );
    }
}
