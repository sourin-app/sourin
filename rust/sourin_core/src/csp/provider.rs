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

use super::{route, CspSite};

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
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        api: &str,
        ext: &str,
        classes: Vec<TvboxCategoryEntry>,
    ) -> std::result::Result<Self, String> {
        let id = id.into();
        let name = name.into();
        if id.is_empty() {
            return Err("源 id 为空".to_string());
        }
        let site = route(api).ok_or_else(|| super::unimplemented_reason(api))?;
        let capabilities = crate::model::Capabilities {
            vod: true,
            // ★ search 声明为 false：上游搜索接口要 buvid/风控签名，
            //   本实现没做 —— 声明 true 就是假能力位（用户点了只会报错）。
            search: false,
            ..Default::default()
        };
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
        };
        Ok(Self {
            manifest,
            api: api.trim().to_string(),
            ext: ext.to_string(),
            site,
            classes,
        })
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
        Ok(Page {
            items: out
                .items
                .into_iter()
                .map(|i| to_item(&self.manifest.id, i))
                .collect(),
            page: out.page,
            page_count: out.page_count,
            total: out.total,
        })
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
        let err = CspProvider::new("id", "名", sample, "", Vec::new())
            .err()
            .expect("没实现的类不能建 Provider");
        // ★ 文案的唯一来源是 `unimplemented_reason`（App99 这种"有具体原因"的类
        //   文案会是"暂不可用：…"，硬编码"尚未实现"就会随升级假红）
        assert_eq!(err, crate::csp::unimplemented_reason(sample));
    }

    #[test]
    fn new_rejects_empty_id() {
        let err = CspProvider::new("", "名", "csp_Bili", "", Vec::new())
            .err()
            .expect("空 id 必须报错");
        assert_eq!(err, "源 id 为空");
    }

    #[test]
    fn new_keeps_api_and_declares_no_fake_search() {
        let p = CspProvider::new("lib-bili", "哔哩", "csp_Bili", "{\"n\":\"x\"}", Vec::new())
            .expect("csp_Bili 必须能建 Provider");
        assert_eq!(p.api(), "csp_Bili");
        assert_eq!(p.ext, "{\"n\":\"x\"}", "ext 必须原样透传");
        let m = p.manifest();
        assert_eq!(m.kind, "tvbox");
        assert!(m.capabilities.vod);
        assert!(
            !m.capabilities.search,
            "★ 搜索没实现就不许声明（否则界面出现一个点了必报错的搜索框）"
        );
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
