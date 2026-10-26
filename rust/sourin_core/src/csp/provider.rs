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
            // 导入来的子站藏起来（经 tvbox_agg 聚合使用）；内置 csp 源仍可见
            hidden: from_import,
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
            .map_err(classify_err)?;
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
fn classify_err(e: String) -> ProviderError {
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
            .map_err(classify_err)?;
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
            .map_err(classify_err)?;
        // 空结果与 list 同口径：返回**空页**（让 registry 记成"命中但 0 条"），
        // 不报错 —— 搜索没有结果是正常结果，不是故障。
        Ok(self.page_of(out))
    }

    async fn detail(&self, id: &MediaId) -> Result<MediaDetail> {
        let d = self
            .site
            .detail(&id.native, &self.ext)
            .await
            .map_err(classify_err)?;
        let episodes: Vec<Episode> = d
            .episodes
            .iter()
            .enumerate()
            .map(|(i, e)| Episode {
                // ★ 剧集 id 就是 `bvid|cid`，resolve() 直接用它取流
                id: e.id.clone(),
                title: if e.title.is_empty() {
                    format!("第{}集", i + 1)
                } else {
                    e.title.clone()
                },
                order: (i + 1) as u32,
                player_id: None,
                // ★ 线路名透出到 wire（多线路源靠它分组；单线路源是"默认"/play_from 名）
                flag: e.flag.clone(),
            })
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
        // ★ 与 tvbox.rs 的 appleCMS 分支同一条规矩（那边踩过「第二集播出第一集」）：
        //   剧集 id（这里形如 `bvid|cid`）优先于条目 id。
        let episode = match req.episode_id.as_deref() {
            Some(e) if !e.trim().is_empty() => e.trim().to_string(),
            _ => id.native.clone(),
        };
        // 只给了条目 id（bvid）而没有 cid ⇒ 先取详情拿第一集，别猜一个 cid
        let episode = if episode.contains('|') {
            episode
        } else {
            let d = self
                .site
                .detail(&episode, &self.ext)
                .await
                .map_err(classify_err)?;
            d.episodes
                .first()
                .map(|e| e.id.clone())
                .ok_or_else(|| ProviderError::new(ErrorKind::NotFound, "这个条目没有可播放的剧集"))?
        };
        // ★ 真 flag：来自 PlayRequest.flag（UI 选了哪条线路就传哪条），缺省空串
        let flag = req.flag.clone().unwrap_or_default();
        let plays = self
            .site
            .play(&flag, &episode, &self.ext)
            .await
            .map_err(classify_err)?;
        if plays.is_empty() {
            return Err(ProviderError::new(
                ErrorKind::Other,
                "取流没有返回任何地址（上游没给 durl）",
            ));
        }
        Ok(plays
            .into_iter()
            .map(|p| {
                let mut c = StreamCandidate::new(p.url, StreamKind::Mp4)
                    .with_headers(p.headers);
                if let Some(label) = p.label {
                    c = c.with_label(label);
                }
                c
            })
            .collect())
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
mod tests {
    use super::*;

    #[test]
    fn new_rejects_unimplemented_class() {
        let sample = crate::csp::unimplemented_sample();
        let err = CspProvider::new("id", "名", sample, "", Vec::new(), false)
            .err()
            .expect("没实现的类不能建 Provider");
        // ★ 文案的唯一来源是 `unimplemented_reason`（App99 这种"有具体原因"的类
        //   文案会是"暂不可用：…"，硬编码"尚未实现"就会随升级假红）
        assert_eq!(err, crate::csp::unimplemented_reason(sample));
    }


    // ── A′：TVBox 导入的 csp 子站必须 hidden，内置 csp 源必须可见 ──────────
    #[test]
    fn tvbox_imported_csp_subsites_are_hidden() {
        // tvbox.rs 的 csp_id_base() 产出 `csp-<class>-<crc32>` 这种 id
        let p = CspProvider::new("csp-bili-1a2b3c4d", "哔哩", "csp_Bili", "", Vec::new(), true)
            .expect("csp_Bili 必须能建 Provider");
        assert!(
            p.manifest().hidden,
            "★ 由 TVBox 导入的 csp 子站必须 hidden（否则 A′ 里 16 个子站又全冒出来）"
        );
    }

    #[test]
    fn builtin_csp_provider_stays_visible() {
        // 非导入来源（将来内置源）用别的 id 形态 ⇒ 必须可见
        let p = CspProvider::new("builtin-bili", "内置哔哩", "csp_Bili", "", Vec::new(), false)
            .expect("合法");
        assert!(
            !p.manifest().hidden,
            "★ 内置 csp 源不能被误藏 —— 判据是「是否来自 TVBox 导入」，不是「是不是 csp」"
        );
    }


    // ── ★ 交叉复核那条真缺口：命名像 `csp-*` 但**不是导入**的源必须可见 ──────────
    #[test]
    fn builtin_provider_named_like_csp_stays_visible() {
        let p = CspProvider::new("csp-builtin-x", "内置（名字像导入）", "csp_Bili", "", Vec::new(), false)
            .expect("合法");
        assert!(
            !p.manifest().hidden,
            "★ 判据是显式来源标记 —— 名字叫 `csp-builtin-x` 也不能被藏（旧实现用前缀判断会在此红）"
        );
        // 对照：同一命名、来源是导入 ⇒ 必须藏（证明这条不是"永远可见"的假绿）
        let q = CspProvider::new("csp-builtin-x", "导入", "csp_Bili", "", Vec::new(), true)
            .expect("合法");
        assert!(q.manifest().hidden, "来源=导入 ⇒ 同一 id 也必须藏");
    }


    // ── ★ 搜索打通的三条门禁 ─────────────────────────────────────────────
    struct FakeSite {
        supports: bool,
        seen: std::sync::Mutex<Vec<(String, u32, String)>>,
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
        let err = CspProvider::new("", "名", "csp_Bili", "", Vec::new(), false)
            .err()
            .expect("空 id 必须报错");
        assert_eq!(err, "源 id 为空");
    }

    #[test]
    fn new_keeps_api_and_declares_no_fake_search() {
        let p = CspProvider::new("lib-bili", "哔哩", "csp_Bili", "{\"n\":\"x\"}", Vec::new(), false)
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
        assert_eq!(classify_err("请求 x 失败：timeout".into()).kind, ErrorKind::Network);
        assert_eq!(classify_err("HTTP 502（x）：bad".into()).kind, ErrorKind::Network);
        assert_eq!(
            classify_err("上游返回 code=-404 message=啥都木有".into()).kind,
            ErrorKind::Parse
        );
        assert_eq!(
            classify_err("csp_X 尚未实现".into()).kind,
            ErrorKind::Unsupported
        );
    }
}
