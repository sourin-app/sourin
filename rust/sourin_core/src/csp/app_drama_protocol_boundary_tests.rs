//! Selected-episode protocol regression tests using independent fixture data.
use super::*;

#[tokio::test]
async fn omitted_flag_uses_the_exact_issued_line_for_site_and_provider_calls() {
    use crate::{
        model::{MediaId, PlayRequest},
        provider::MediaProvider,
    };
    let fixture = LocalFixture::new(ResponseMode::Normal).await;
    let site = Arc::new(fixture.site());
    let detail = site.detail("1001", &fixture.ext).await.unwrap();
    let selected = &detail.episodes[1];
    assert_eq!(
        site.play("", &selected.id, &fixture.ext).await.unwrap()[0]
            .label
            .as_deref(),
        Some(selected.flag.as_str())
    );
    assert!(site
        .play("Wrong line", &selected.id, &fixture.ext)
        .await
        .is_err());
    let provider =
        crate::csp::provider::CspProvider::for_test("v61-flag-fixture", site, &fixture.ext);
    let id = MediaId::new("v61-flag-fixture", "1001");
    let detail = provider.detail(&id).await.unwrap();
    let selected = &detail.episodes[1];
    let request = PlayRequest {
        episode_id: Some(selected.id.clone()),
        ..Default::default()
    };
    assert_eq!(
        provider.resolve(&id, &request).await.unwrap()[0].url,
        "https://media.invalid/selected-2.m3u8"
    );
    let bare = PlayRequest {
        episode_title: Some(selected.title.clone()),
        episode_order: Some(2),
        ..Default::default()
    };
    assert_eq!(
        provider.resolve(&id, &bare).await.unwrap()[0].url,
        "https://media.invalid/selected-2.m3u8"
    );
    fixture.assert_proxy_only();
}

#[tokio::test]
async fn an_oversized_detail_batch_is_rejected_before_mutating_any_issued_sibling() {
    let fixture = LocalFixture::new(ResponseMode::Normal).await;
    let site = fixture.site();
    let detail = site.detail("1001", &fixture.ext).await.unwrap();
    let session = {
        let mut state = site.session.lock().await;
        let current = state.current.as_mut().unwrap();
        current.expires = Instant::now() + Duration::from_secs(3600);
        current.clone()
    };
    let (count, bytes) = {
        let ledger = site.issued.lock().await;
        (ledger.entries.len(), ledger.bytes)
    };
    let recipes = (0..3000)
        .map(|index| EpisodeRecipe {
            version: 2,
            content: "1001".into(),
            index,
            flag: "Line".into(),
            source: "a".into(),
            value: "p".repeat(256),
            restricted: false,
            binding: format!("synthetic-batch-binding-{index}"),
        })
        .collect();
    assert!(site.remember_batch(&session, recipes).await.is_err());
    {
        let ledger = site.issued.lock().await;
        assert_eq!((ledger.entries.len(), ledger.bytes), (count, bytes));
        assert!(detail
            .episodes
            .iter()
            .all(|episode| ledger.entries.contains_key(&episode.id)));
    }
    let recipes = (0..2)
        .map(|index| EpisodeRecipe {
            version: 2,
            content: "1001".into(),
            index,
            flag: "Line".into(),
            source: "a".into(),
            value: "opaque".into(),
            restricted: false,
            binding: format!("synthetic-small-binding-{index}"),
        })
        .collect();
    let ids = site.remember_batch(&session, recipes).await.unwrap();
    assert_eq!(ids.len(), 2);
    assert!(ids
        .iter()
        .all(|id| site.issued.try_lock().unwrap().entries.contains_key(id)));
    fixture.assert_proxy_only();
}

#[test]
fn singular_cover_merge_keeps_scalar_last_wins_and_a_total_field_bound() {
    let mut encoded = Vec::new();
    wire::bytes(&mut encoded, 2, b"\x0a\x01a\x12\x01b");
    wire::bytes(&mut encoded, 2, b"\x0a\x01c");
    let parent = Message::parse(&encoded).unwrap();
    let merged = parent.merged_message(2).unwrap().unwrap();
    assert_eq!(merged.string(1).unwrap(), Some("c"));
    assert_eq!(merged.string(2).unwrap(), Some("b"));
    let mut bounded = Vec::new();
    wire::bytes(&mut bounded, 2, &b"\x0a\x00".repeat(8192));
    wire::bytes(&mut bounded, 2, &b"\x0a\x00".repeat(8193));
    assert!(Message::parse(&bounded).unwrap().merged_message(2).is_err());
}
