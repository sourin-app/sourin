use super::*;
use std::sync::Mutex;

struct LineSite {
    episodes: Vec<super::super::CspEpisode>,
    played: Mutex<Vec<(String, String)>>,
}
#[async_trait]
impl CspSite for LineSite {
    fn class(&self) -> &'static str {
        "LineFixture"
    }
    fn supports_search(&self) -> bool {
        false
    }
    async fn home(&self, _: &str) -> std::result::Result<super::super::CspHome, String> {
        Ok(Default::default())
    }
    async fn list(&self, _: &str, _: u32, _: &str) -> std::result::Result<CspList, String> {
        Ok(Default::default())
    }
    async fn search(&self, _: &str, _: u32, _: &str) -> std::result::Result<CspList, String> {
        Ok(Default::default())
    }
    async fn detail(
        &self,
        id: &str,
        _: &str,
    ) -> std::result::Result<super::super::CspDetail, String> {
        Ok(super::super::CspDetail {
            id: id.into(),
            title: "Lines".into(),
            episodes: self.episodes.clone(),
            ..Default::default()
        })
    }
    async fn play(
        &self,
        flag: &str,
        id: &str,
        _: &str,
    ) -> std::result::Result<Vec<super::super::CspPlay>, String> {
        self.played.lock().unwrap().push((flag.into(), id.into()));
        Ok(vec![super::super::CspPlay {
            url: "https://media.invalid/selected.mp4".into(),
            headers: vec![],
            label: Some(flag.into()),
        }])
    }
}
fn fixture(lines: &[&str]) -> (CspProvider, Arc<LineSite>, MediaId) {
    let site = Arc::new(LineSite {
        episodes: lines
            .iter()
            .enumerate()
            .map(|(i, line)| super::super::CspEpisode {
                id: format!("{line}|Episode {}|opaque-{i}", i % 2 + 1),
                title: format!("Episode {}", i % 2 + 1),
                flag: (*line).into(),
            })
            .collect(),
        played: Mutex::new(vec![]),
    });
    let provider = CspProvider::for_test("line-fixture", site.clone(), "");
    (provider, site, MediaId::new("line-fixture", "item"))
}

#[tokio::test]
async fn sources_preserve_flags_first_seen_order_and_actual_counts() {
    let (provider, site, id) = fixture(&["B", "A", "B", "A", ""]);
    let detail = provider.detail(&id).await.unwrap();
    assert_eq!(
        detail
            .sources
            .iter()
            .map(|s| (s.code.as_str(), s.count))
            .collect::<Vec<_>>(),
        [("B", 2), ("A", 2), ("default", 1)]
    );
    assert_eq!(detail.sources[0].title, "B");
    assert_eq!(detail.sources[1].title, "A");
    assert_eq!(
        detail
            .episodes
            .iter()
            .map(|e| e.id.as_str())
            .collect::<Vec<_>>(),
        site.episodes
            .iter()
            .map(|e| e.id.as_str())
            .collect::<Vec<_>>()
    );
    assert_eq!(
        detail.episodes.iter().map(|e| e.order).collect::<Vec<_>>(),
        [1, 1, 2, 2, 1]
    );
    assert!(provider.manifest().capabilities.multi_source);
    assert_eq!(provider.sources(&id).await.unwrap().len(), 3);
}

#[tokio::test]
async fn episodes_return_only_requested_line_and_reject_unknown_line() {
    let (provider, _, id) = fixture(&["A", "A", "B", "B"]);
    let episodes = provider.episodes(&id, "B").await.unwrap();
    assert_eq!(
        episodes.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(),
        ["B|Episode 1|opaque-2", "B|Episode 2|opaque-3"]
    );
    assert!(episodes.iter().all(|e| e.flag == "B"));
    assert_eq!(episodes.iter().map(|e| e.order).collect::<Vec<_>>(), [1, 2]);
    assert!(provider.episodes(&id, "missing").await.is_err());
    assert_eq!(
        provider.episodes(&id, "default").await.unwrap().len(),
        4,
        "legacy default session remains readable when no real default line exists"
    );
}

#[tokio::test]
async fn unflagged_default_group_does_not_include_other_lines() {
    let (provider, _, id) = fixture(&["A", "A", ""]);
    let default = provider.episodes(&id, "default").await.unwrap();
    assert_eq!(default.len(), 1);
    assert!(default[0].flag.is_empty());
    let (single, _, id) = fixture(&["", ""]);
    let sources = single.sources(&id).await.unwrap();
    assert_eq!(sources.len(), 1);
    assert_eq!(sources[0].code, "default");
    assert_eq!(sources[0].count, 2);
    assert_eq!(single.episodes(&id, "default").await.unwrap().len(), 2);
}

#[tokio::test]
async fn source_code_only_resolve_selects_second_line_and_second_episode() {
    let (provider, site, id) = fixture(&["A", "A", "B", "B"]);
    let req = PlayRequest {
        source_code: Some("B".into()),
        episode_title: Some("Episode 2".into()),
        episode_order: Some(2),
        ..Default::default()
    };
    let streams = provider.resolve(&id, &req).await.unwrap();
    assert_eq!(streams.len(), 1);
    assert_eq!(
        *site.played.lock().unwrap(),
        [("B".into(), "B|Episode 2|opaque-3".into())]
    );
}

#[tokio::test]
async fn conflicting_source_and_flag_fail_before_play() {
    let (provider, site, id) = fixture(&["A", "A", "B", "B"]);
    let req = PlayRequest {
        source_code: Some("B".into()),
        flag: Some("A".into()),
        episode_id: Some("A|Episode 1|opaque-0".into()),
        ..Default::default()
    };
    assert!(provider.resolve(&id, &req).await.is_err());
    assert!(site.played.lock().unwrap().is_empty());
}

#[tokio::test]
async fn legacy_default_source_keeps_explicit_selected_flag() {
    let (provider, site, id) = fixture(&["A", "A", "B", "B"]);
    let req = PlayRequest {
        source_code: Some("default".into()),
        flag: Some("B".into()),
        episode_id: Some("B|Episode 2|opaque-3".into()),
        ..Default::default()
    };
    assert_eq!(provider.resolve(&id, &req).await.unwrap().len(), 1);
    assert_eq!(
        *site.played.lock().unwrap(),
        [("B".into(), "B|Episode 2|opaque-3".into())]
    );
}

#[tokio::test]
async fn real_yunduo_manifest_advertises_line_selection() {
    let provider =
        CspProvider::new("fixture", "fixture", "csp_YunDuo", "", vec![], true, false).unwrap();
    assert!(provider.manifest().capabilities.multi_source);
}

#[tokio::test]
async fn default_source_only_selects_real_unflagged_group() {
    let (provider, site, id) = fixture(&["A", "A", ""]);
    let req = PlayRequest {
        source_code: Some("default".into()),
        episode_title: Some("Episode 1".into()),
        episode_order: Some(1),
        ..Default::default()
    };
    assert_eq!(provider.resolve(&id, &req).await.unwrap().len(), 1);
    assert_eq!(
        *site.played.lock().unwrap(),
        [("".into(), "|Episode 1|opaque-2".into())]
    );
}

#[tokio::test]
async fn unnamed_episode_titles_and_resolve_use_line_local_order() {
    let site = Arc::new(LineSite {
        episodes: ["A", "A", "B", "B"]
            .iter()
            .enumerate()
            .map(|(i, line)| super::super::CspEpisode {
                id: format!("{line}|unnamed|opaque-{i}"),
                title: String::new(),
                flag: (*line).into(),
            })
            .collect(),
        played: Mutex::new(vec![]),
    });
    let provider = CspProvider::for_test("line-fixture", site.clone(), "");
    let id = MediaId::new("line-fixture", "item");
    let detail = provider.detail(&id).await.unwrap();
    assert_eq!(
        detail
            .episodes
            .iter()
            .map(|e| e.title.as_str())
            .collect::<Vec<_>>(),
        ["第1集", "第2集", "第1集", "第2集"]
    );
    let req = PlayRequest {
        source_code: Some("B".into()),
        episode_title: Some("第2集".into()),
        episode_order: Some(2),
        ..Default::default()
    };
    assert_eq!(provider.resolve(&id, &req).await.unwrap().len(), 1);
    assert_eq!(
        *site.played.lock().unwrap(),
        [("B".into(), "B|unnamed|opaque-3".into())]
    );

    site.played.lock().unwrap().clear();
    let ambiguous = PlayRequest {
        episode_title: Some("第2集".into()),
        episode_order: Some(2),
        ..Default::default()
    };
    assert!(provider.resolve(&id, &ambiguous).await.is_err());
    assert!(
        site.played.lock().unwrap().is_empty(),
        "the same unnamed title on two lines cannot imply the first line"
    );
}
