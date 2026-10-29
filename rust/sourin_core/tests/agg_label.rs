//! task-2（Rust 半边）门禁：TvboxAggregate::resolve 给每条 StreamCandidate.label
//! 填「<子源显示名> · <线路名/分享页文件名>」
//!
//! ```text
//! · 判据核心是 tvbox_aggregate::compose_stream_label（纯函数）+ resolve 全链路
//!   （注册假子站 → 聚合 resolve → 断言 label 前缀是子站 manifest.name）。
//! · 注入证红方式：把 resolve 里套 compose_stream_label 的循环删掉 ⇒
//!   resolve_labels_prefix_child_name 必红（label 退回内层"原画"）。
//! ```
//!
//! 详见 .agents/notes/implemented/feature/2026-10-30-agg-stream-label-child-name.md

use std::sync::Arc;

use async_trait::async_trait;

use sourin_core::model::{
    MediaId, PlayRequest, ProviderManifest, StreamCandidate, StreamKind,
};
use sourin_core::provider::MediaProvider;
use sourin_core::registry::Registry;
use sourin_core::tvbox_aggregate::{
    compose_stream_label, derive_hidden, save, AggregateConfig, TvboxAggregate, AGGREGATE_ID,
};

/// 纯函数直测：三种形状都要产完整串
#[test]
fn compose_stream_label_shapes() {
    // 有内层 label ⇒ 「子源 · 线路」
    assert_eq!(
        compose_stream_label("天天影视", Some("分享页 · 老舅01.mp4")),
        "天天影视 · 分享页 · 老舅01.mp4"
    );
    assert_eq!(compose_stream_label("苹果CMS", Some("原画")), "苹果CMS · 原画");
    // 内层空 ⇒ 只给子源名
    assert_eq!(compose_stream_label("天天影视", Some("   ")), "天天影视");
    assert_eq!(compose_stream_label("天天影视", None), "天天影视");
    // 子源名空 ⇒ 退回内层，不产出「 · x」残缺串
    assert_eq!(compose_stream_label("", Some("原画")), "原画");
    assert_eq!(compose_stream_label("  ", None), "");
}

/// 纯函数直测：不许重复拼接（子源名已在前缀里时）
#[test]
fn compose_stream_label_no_double_prefix() {
    // 内层已带子源名 ⇒ 不再套一层
    assert_eq!(
        compose_stream_label("天天影视", Some("天天影视 · 原画")),
        "天天影视 · 原画"
    );
}

/// 假子站：manifest.name 是「子源显示名」，resolve 回带内层 label 的候选
struct LabelChild {
    manifest: ProviderManifest,
    labels: Vec<Option<String>>,
}

#[async_trait]
impl MediaProvider for LabelChild {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }
    async fn resolve(
        &self,
        _id: &MediaId,
        _req: &PlayRequest,
    ) -> Result<Vec<StreamCandidate>, sourin_core::model::ProviderError> {
        Ok(self
            .labels
            .iter()
            .map(|l| {
                let c = StreamCandidate::new("https://cdn.example/v.m3u8", StreamKind::Hls);
                match l {
                    Some(x) => c.with_label(x.clone()),
                    None => c,
                }
            })
            .collect())
    }
}

fn manifest(id: &str, name: &str) -> ProviderManifest {
    ProviderManifest {
        id: id.to_string(),
        name: name.to_string(),
        version: "1.0.0".to_string(),
        kind: "tvbox".to_string(),
        description: None,
        icon: None,
        id_prefixes: Vec::new(),
        capabilities: Default::default(),
        hidden: false,
        cover_headers: Vec::new(),
        config: Vec::new(),
        api_version: 1,
        theme_color: None,
        working: true,
        broken_reason: None,
        enabled: None,
    }
}

fn tmp_dir(tag: &str) -> std::path::PathBuf {
    let p = std::env::temp_dir().join(format!("agg_label_test_{tag}_{}", std::process::id()));
    let _ = std::fs::create_dir_all(&p);
    p
}

fn agg_with_child(tag: &str, child: Arc<dyn MediaProvider>) -> TvboxAggregate {
    let reg = Arc::new(Registry::new());
    reg.register(child);
    let dir = tmp_dir(tag);
    let mut cfg = AggregateConfig::default();
    cfg.enabled_site_ids = vec!["child1".to_string()];
    cfg.hidden_site_ids = derive_hidden(&cfg.enabled_site_ids);
    save(&dir, &cfg).expect("写聚合配置");
    TvboxAggregate::new(reg, dir)
}

#[tokio::test]
async fn resolve_labels_prefix_child_name() {
    let child = Arc::new(LabelChild {
        manifest: manifest("child1", "天天影视"),
        labels: vec![
            Some("分享页 · 老舅01.mp4".to_string()),
            Some("原画".to_string()),
            None,
            Some("   ".to_string()),
        ],
    }) as Arc<dyn MediaProvider>;
    let agg = agg_with_child("label", child);
    let cands = agg
        .resolve(
            &MediaId {
                provider: AGGREGATE_ID.to_string(),
                native: "child1::episode-1".to_string(),
            },
            &PlayRequest::default(),
        )
        .await
        .expect("resolve 必须成功");
    assert_eq!(cands.len(), 4);
    assert_eq!(
        cands[0].label.as_deref(),
        Some("天天影视 · 分享页 · 老舅01.mp4"),
        "内层 label 要拼在子源名后"
    );
    assert_eq!(cands[1].label.as_deref(), Some("天天影视 · 原画"));
    // 内层空 ⇒ 只给子源名（不许是空/None —— 否则换源列表里这条没名字）
    assert_eq!(cands[2].label.as_deref(), Some("天天影视"));
    assert_eq!(cands[3].label.as_deref(), Some("天天影视"));
}

#[tokio::test]
async fn resolve_labels_use_routed_child_not_hardcoded() {
    // 换个子站名 ⇒ label 前缀跟着变（证明取的是 route 到的 manifest.name）
    let child = Arc::new(LabelChild {
        manifest: manifest("child1", "子源乙"),
        labels: vec![Some("官方 HLS".to_string())],
    }) as Arc<dyn MediaProvider>;
    let agg = agg_with_child("label2", child);
    let cands = agg
        .resolve(
            &MediaId {
                provider: AGGREGATE_ID.to_string(),
                native: "child1::ep".to_string(),
            },
            &PlayRequest::default(),
        )
        .await
        .expect("resolve 必须成功");
    assert_eq!(cands[0].label.as_deref(), Some("子源乙 · 官方 HLS"));
}

#[tokio::test]
async fn resolve_passes_episode_id_through_unlabeled() {
    // 对照组：episode_id 透传不受 label 改造影响（前缀剥离是既有门禁的职责）
    let child = Arc::new(LabelChild {
        manifest: manifest("child1", "子源丙"),
        labels: vec![Some("原画".to_string())],
    }) as Arc<dyn MediaProvider>;
    let agg = agg_with_child("label3", child);
    let cands = agg
        .resolve(
            &MediaId {
                provider: AGGREGATE_ID.to_string(),
                native: "child1::https://pan.quark.cn/s/abc".to_string(),
            },
            &PlayRequest {
                episode_id: Some("child1::https://pan.quark.cn/s/abc".to_string()),
                ..Default::default()
            },
        )
        .await
        .expect("resolve 必须成功");
    assert_eq!(cands[0].label.as_deref(), Some("子源丙 · 原画"));
    assert_eq!(cands[0].url, "https://cdn.example/v.m3u8", "url 不被改写");
}
