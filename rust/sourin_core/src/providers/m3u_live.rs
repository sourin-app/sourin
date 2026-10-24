//! m3u / txt 直播播放列表 Provider
//!
//! # 它解决什么
//!
//! TVBox 配置里的 `lives[]` 是一组 `{name, url}`，`url` 指向 `.m3u` / `.txt`
//! 播放列表。既有 `tvbox.rs` 只把这份清单回报给 UI **不导入**，因为没有解析器。
//! `src/m3u.rs` 补了解析器，本模块补**最后一跳**：把它变成一个真正能被
//! `registry.live_all()` 看见的 provider。
//!
//! # 为什么必须做成 provider，而不是直接塞频道列表
//!
//! 直播页面取数是 `get_live_channels → registry.live_all() → 每个 provider 的
//! live_channels()`。如果绕开 registry 直接塞数据，就需要改直播页的取数链路，
//! 而且"刷新""取流"都无处安放。
//! 做成 provider ⇒ 零改动接入现有直播页，且 `live_stream` 有地方实现。
//!
//! # 一个 provider 对一个播放列表 URL
//!
//! TVBox 的每个 `lives[i]` 就是一个独立列表（各自有名字），
//! 所以这里一个列表 = 一个 provider，manifest.id 由 URL 派生（稳定）。
//! 这样 UI 上能看到"列表 A / 列表 B"两个直播源，而不是混成一坨。

use std::sync::Mutex;

use crate::model::*;
use crate::provider::*;
use async_trait::async_trait;

/// 一个 m3u/txt 播放列表直播源
pub struct M3uLiveProvider {
    manifest: ProviderManifest,
    /// 播放列表地址
    url: String,
    /// 上次解析出来的频道（`live_stream` 按 id 反查 URL 用）
    ///
    /// 用 `Mutex<Vec<_>>` 而不是每次重拉：`live_stream` 是**高频**调用
    /// （每次切台），每次重拉整个列表会明显卡顿。
    /// 解析成功后填一次，`live_channels` 可以强制刷新。
    cache: Mutex<Vec<LiveChannel>>,
    /// 频道 id → 播放地址。与 `cache` 同步填充。
    urls: Mutex<std::collections::HashMap<String, String>>,
}

impl M3uLiveProvider {
    /// 由列表名与地址构造
    ///
    /// `id` 由 URL 派生 ⇒ 同一地址重复导入不会产生两个源（稳定）。
    pub fn new(name: &str, url: &str) -> Self {
        let id = format!("m3ulive-{}", crate::m3u::stable_key(url));
        Self {
            manifest: ProviderManifest {
                id,
                name: if name.trim().is_empty() {
                    "直播列表".to_string()
                } else {
                    name.trim().to_string()
                },
                version: "1".into(),
                kind: "m3u_live".into(),
                description: Some("m3u / txt 播放列表直播源".into()),
                icon: None,
                id_prefixes: vec![],
                capabilities: Capabilities {
                    live: true,
                    ..Default::default()
                },
                cover_headers: vec![],
                config: vec![],
                api_version: 1,
                theme_color: None,
                working: true,
                broken_reason: None,
                enabled: Some(true),
            },
            url: url.trim().to_string(),
            cache: Mutex::new(Vec::new()),
            urls: Mutex::new(std::collections::HashMap::new()),
        }
    }

    pub fn source_url(&self) -> &str {
        &self.url
    }

    /// 拉取并解析播放列表
    async fn load(&self) -> Result<Vec<LiveChannel>> {
        if self.url.is_empty() {
            return Err(ProviderError::unsupported("直播列表地址为空"));
        }
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(20))
            .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            .build()
            .map_err(|e| ProviderError::network(format!("创建 HTTP 客户端失败：{e}")))?;
        let resp = client
            .get(&self.url)
            .send()
            .await
            .map_err(|e| ProviderError::network(format!("拉取直播列表失败：{e}")))?;
        if !resp.status().is_success() {
            return Err(ProviderError::network(format!(
                "直播列表返回 HTTP {}",
                resp.status().as_u16()
            )));
        }
        let bytes = resp
            .bytes()
            .await
            .map_err(|e| ProviderError::network(format!("读取直播列表失败：{e}")))?;
        // 播放列表体量很小（几百 KB 顶天），超过 4 MiB 基本是拿错了地址
        const MAX: usize = 4 * 1024 * 1024;
        if bytes.len() > MAX {
            return Err(ProviderError::parse(format!(
                "直播列表体积异常（{} 字节，上限 {MAX}）",
                bytes.len()
            )));
        }
        let text = String::from_utf8_lossy(&bytes);
        let channels = crate::m3u::parse_playlist(&text, &self.manifest.id);
        // 填缓存（id → url 供 live_stream 反查）
        // ★ 重新解析一遍文本拿 url 映射：`parse_playlist` 只回 LiveChannel，
        //   而 LiveChannel 模型里**没有**存播放地址的字段（那是设计如此，
        //   频道列表不该把地址泄露到 UI 层）。所以这里单独建映射。
        let map = crate::m3u::parse_playlist_with_urls(&text, &self.manifest.id);
        let url_map: std::collections::HashMap<String, String> = map
            .into_iter()
            .map(|(ch, u)| (ch.id.clone(), u))
            .collect();
        if let Ok(mut g) = self.urls.lock() {
            *g = url_map;
        }
        if let Ok(mut g) = self.cache.lock() {
            *g = channels.clone();
        }
        Ok(channels)
    }
}

#[async_trait]
impl MediaProvider for M3uLiveProvider {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    /// 播放列表不提供点播
    async fn categories(&self) -> Result<Vec<Category>> {
        Ok(vec![])
    }

    async fn home(&self) -> Result<Vec<Section>> {
        Ok(vec![])
    }

    async fn list(&self, _req: ListRequest) -> Result<Page<MediaItem>> {
        Err(ProviderError::unsupported("直播列表源不支持点播分类"))
    }

    async fn detail(&self, _id: &MediaId) -> Result<MediaDetail> {
        Err(ProviderError::unsupported("直播列表源不支持点播详情"))
    }

    /// 必需方法（trait 无默认实现）：直播源没有点播可解析
    async fn resolve(&self, _id: &MediaId, _req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
        Err(ProviderError::unsupported("直播列表源不支持点播取流"))
    }

    // ── 直播 ───────────────────────────────────────────────

    async fn live_channels(&self) -> Result<Vec<LiveChannel>> {
        // 每次都重拉：直播列表会变（增删台），缓存只用于 live_stream 反查
        self.load().await
    }

    async fn live_stream(&self, channel_id: &str) -> Result<Vec<StreamCandidate>> {
        // 优先用缓存；缓存空说明还没拉过，先拉一次
        let cached = if let Ok(g) = self.urls.lock() {
            g.get(channel_id).cloned()
        } else {
            None
        };
        let url = match cached {
            Some(u) => u,
            None => {
                self.load().await?;
                let g = self
                    .urls
                    .lock()
                    .map_err(|_| ProviderError::parse("内部状态不可用"))?;
                g.get(channel_id)
                    .cloned()
                    .ok_or_else(|| ProviderError::new(ErrorKind::NotFound, "该频道不在播放列表里（列表可能已更新）"))?
            }
        };
        Ok(vec![StreamCandidate {
            url,
            kind: StreamKind::Hls,
            quality: None,
            label: None,
            headers: vec![],
            not_web_ready: false,
            drm_protected: false,
            audio_url: None,
            tags: None,
            needs_host_resolve: false,
            site_id: None,
            // 直播流是 HLS：不涉及 DRM、不需要 host 二级解析
            stream_flags: Default::default(),
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn id_is_derived_from_url_so_reimport_is_stable() {
        let a = M3uLiveProvider::new("列表A", "http://host/a.m3u");
        let b = M3uLiveProvider::new("列表B", "http://host/a.m3u");
        assert_eq!(
            a.manifest().id,
            b.manifest().id,
            "同一地址必须派生同一 id，否则重复导入会产生两个源"
        );
        let c = M3uLiveProvider::new("列表A", "http://host/b.m3u");
        assert_ne!(a.manifest().id, c.manifest().id, "不同地址 id 必须不同");
    }

    #[test]
    fn manifest_declares_live_capability_only() {
        let p = M3uLiveProvider::new("x", "http://host/a.m3u");
        let caps = &p.manifest().capabilities;
        assert!(caps.live, "直播列表必须声明 live 能力");
        assert!(!caps.vod, "不该声称支持点播");
    }

    #[test]
    fn empty_name_falls_back_but_is_not_blank() {
        let p = M3uLiveProvider::new("   ", "http://host/a.m3u");
        assert_eq!(p.manifest().name, "直播列表");
        assert!(!p.manifest().name.trim().is_empty());
    }

    #[tokio::test]
    async fn empty_url_fails_loudly() {
        let p = M3uLiveProvider::new("x", "");
        let e = p.live_channels().await.unwrap_err();
        assert!(
            e.message.contains("为空"),
            "空地址要明确报错，不能静默返回空列表：{:?}",
            e.message
        );
    }

    #[tokio::test]
    async fn vod_methods_are_unsupported_not_silent_empty() {
        let p = M3uLiveProvider::new("x", "http://host/a.m3u");
        assert!(p.categories().await.unwrap().is_empty(), "分类可以空");
        assert!(
            p.list(ListRequest::default()).await.is_err(),
            "点播列表必须明确报不支持，不能返回空页让 UI 显示'暂无内容'"
        );
    }
}
