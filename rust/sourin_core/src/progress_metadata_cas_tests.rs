//! Real DB CAS regressions. Tests-first RED used the previous save command;
//! only the call boundary changed after RED, retaining persisted assertions.
use super::*;
use crate::{proxy::ProxyStore, registry::Registry, remote::RemoteHub, store::Db, streamproxy::StreamProxy};
use std::sync::{Arc, RwLock, atomic::{AtomicBool, AtomicI64}};

fn state() -> AppState {
    let proxy = Arc::new(ProxyStore::new());
    AppState {
        registry: Arc::new(Registry::new()), db:Arc::new(Db::in_memory().unwrap()), proxy:proxy.clone(),
        sync:tokio::sync::RwLock::new(None), device_id:"metadata-fixture".into(),
        data_dir:std::path::PathBuf::from("unused-metadata-fixture"), third_party:RwLock::new(Vec::new()),
        remote:Arc::new(RemoteHub::new()), stream_proxy:Arc::new(StreamProxy::with_proxy_store(proxy)),
        cover_repair:tokio::sync::Mutex::new(Default::default()),
        providers_updated_at:AtomicI64::new(0), auto_loop_started:AtomicBool::new(false),
        js_mutation_epoch: std::sync::atomic::AtomicU64::new(0),
        js_reload_sequence: std::sync::atomic::AtomicU64::new(0),
    }
}

fn row(id: &str, episode: Option<&str>, updated_at: i64) -> Progress {
    Progress { key:"caller-key-is-not-authority".into(), provider:"metadata-fixture".into(), native_id:id.into(),
        title:"   ".into(), cover:Some("https://images.invalid/old.jpg".into()),
        episode_id:episode.map(str::to_owned), episode_title:Some("Episode title".into()),
        position:50, duration:100, finished:false, updated_at }
}

fn read(state: &AppState, expected: &Progress) -> Option<Progress> {
    state.db.get_progress_exact(&crate::store::progress_key(
        &expected.provider, &expected.native_id, expected.episode_id.as_deref())).unwrap()
}

fn patch(state: &AppState, snapshot: &Progress, title: &str, cover: Option<&str>) {
    let request = serde_json::json!({"args":{"provider":snapshot.provider,"id":snapshot.native_id,
        "episode_id":snapshot.episode_id,"expected_title":snapshot.title,"expected_cover":snapshot.cover,
        "title":title,"cover":cover}});
    let args = crate::args::Args::new(&request, "patch_progress_metadata");
    let patch = ProgressMetadataPatch::from_args(&args).unwrap();
    patch_progress_metadata(state, &patch).unwrap();
}

fn playback_fields(value: &Progress) -> serde_json::Value {
    serde_json::json!({"provider":value.provider,"id":value.native_id,"episode":value.episode_id,
        "episodeTitle":value.episode_title,"position":value.position,"duration":value.duration,
        "finished":value.finished,"updatedAt":value.updated_at})
}

#[test]
fn progress_metadata_cas_late_title_preserves_repaired_cover_and_newer_playback() {
    let state = state();
    let snapshot = row("target", Some("episode-1"), 100);
    state.db.upsert_progress(&snapshot).unwrap();
    let mut current = snapshot.clone();
    current.position = 98; current.duration = 101; current.finished = true; current.updated_at = 200;
    state.db.upsert_progress(&current).unwrap();
    state.db.repair_library_cover(&snapshot.provider, &snapshot.native_id,
        &[snapshot.cover.clone()], "https://images.invalid/repaired.jpg").unwrap();
    let before = read(&state, &snapshot).unwrap();
    patch(&state, &snapshot, "Resolved title", Some("https://images.invalid/stale-detail.jpg"));
    let after = read(&state, &snapshot).unwrap();
    assert_eq!(after.cover, before.cover, "late title metadata must not undo a committed cover repair");
    assert_eq!(playback_fields(&after), playback_fields(&before), "metadata must not replay stale progress or refresh ordering");
    assert_eq!(after.title, "Resolved title");
    assert!(state.db.list_history(20).unwrap().is_empty(), "metadata must not create viewing history");
}

#[test]
fn progress_metadata_cas_keeps_current_title_but_can_update_unchanged_cover() {
    let state = state();
    let snapshot = row("target", Some("episode-1"), 100);
    state.db.upsert_progress(&snapshot).unwrap();
    let mut current = snapshot.clone(); current.title = "Newer canonical title".into();
    current.updated_at = 200; state.db.upsert_progress(&current).unwrap();
    patch(&state, &snapshot, "Stale resolved title", Some("https://images.invalid/new.jpg"));
    let after = read(&state, &snapshot).unwrap();
    assert_eq!(after.title, current.title, "each metadata field needs its own current-value comparison");
    assert_eq!(after.cover.as_deref(), Some("https://images.invalid/new.jpg"));
    assert_eq!(playback_fields(&after), playback_fields(&current));
}

#[test]
fn progress_metadata_cas_does_not_resurrect_a_deleted_row() {
    let state = state();
    let snapshot = row("target", None, 100);
    state.db.upsert_progress(&snapshot).unwrap();
    state.db.clear_history().unwrap();
    assert!(read(&state, &snapshot).is_none());
    patch(&state, &snapshot, "Late detail", Some("https://images.invalid/new.jpg"));
    assert!(read(&state, &snapshot).is_none(), "late metadata must UPDATE existing rows only");
    assert!(state.db.list_history(20).unwrap().is_empty());
}

#[test]
fn progress_metadata_cas_preserves_continue_order_and_other_episode_rows() {
    let state = state();
    let first = row("target", Some("episode-1"), 100);
    let second = row("target", Some("episode-2"), 200);
    let other = row("other", None, 300);
    for value in [&first, &second, &other] { state.db.upsert_progress(value).unwrap(); }
    let before: Vec<_> = state.db.continue_watching(20).unwrap().iter().map(|p| p.key.clone()).collect();
    patch(&state, &first, "Title only", None);
    let after: Vec<_> = state.db.continue_watching(20).unwrap().iter().map(|p| p.key.clone()).collect();
    assert_eq!(after, before, "a metadata response must not reorder or replace the continuing episode");
    assert_eq!(playback_fields(&read(&state, &second).unwrap()), playback_fields(&second));
    assert_eq!(read(&state, &first).unwrap().cover, first.cover);
}

#[test]
fn progress_metadata_cas_success_retains_playback_fields_and_null_cover_semantics() {
    let state = state();
    let mut snapshot = row("target", None, 100); snapshot.cover = None;
    state.db.upsert_progress(&snapshot).unwrap();
    let before = read(&state, &snapshot).unwrap();
    patch(&state, &snapshot, "Resolved title", Some("https://images.invalid/new.jpg"));
    let after = read(&state, &snapshot).unwrap();
    assert_eq!(playback_fields(&after), playback_fields(&before), "successful metadata updates must not change updated_at");
    assert_eq!(after.title, "Resolved title");
    assert_eq!(after.cover.as_deref(), Some("https://images.invalid/new.jpg"));
    assert!(state.db.list_history(20).unwrap().is_empty());
}

#[test]
fn progress_metadata_cas_control_playback_save_still_writes_progress_and_history() {
    let state = state();
    let snapshot = row("target", None, 100);
    save_progress(&state, &snapshot.provider, &snapshot.native_id, "Playback title", snapshot.cover.clone(),
        None, snapshot.episode_title.clone(), 77, 100, Some(false)).unwrap();
    let saved = read(&state, &snapshot).unwrap();
    assert_eq!(saved.position, 77);
    assert_eq!(saved.title, "Playback title");
    assert!(saved.updated_at > snapshot.updated_at);
    assert_eq!(state.db.list_history(20).unwrap().len(), 1,
        "ordinary playback save retains its existing history behavior");
}

#[test]
fn progress_metadata_cas_control_existing_cover_repair_is_conditional_and_metadata_only() {
    let state = state();
    let snapshot = row("target", None, 100);
    state.db.upsert_progress(&snapshot).unwrap();
    assert_eq!(state.db.repair_library_cover(&snapshot.provider, &snapshot.native_id,
        &[snapshot.cover.clone()], "https://images.invalid/repaired.jpg").unwrap(), 1);
    assert_eq!(state.db.repair_library_cover(&snapshot.provider, &snapshot.native_id,
        &[snapshot.cover.clone()], "https://images.invalid/stale.jpg").unwrap(), 0);
    let saved = read(&state, &snapshot).unwrap();
    assert_eq!(saved.cover.as_deref(), Some("https://images.invalid/repaired.jpg"));
    assert_eq!(playback_fields(&saved), playback_fields(&snapshot));
    assert!(state.db.list_history(20).unwrap().is_empty());
}

#[test]
fn progress_metadata_cas_ignores_empty_candidates_and_nonempty_expected_titles() {
    let state = state();
    let mut snapshot = row("target", None, 100); snapshot.title = "Known title".into();
    state.db.upsert_progress(&snapshot).unwrap();
    patch(&state, &snapshot, "Different title", Some("  "));
    let after = read(&state, &snapshot).unwrap();
    assert_eq!(after.title, snapshot.title);
    assert_eq!(after.cover, snapshot.cover);
    assert_eq!(playback_fields(&after), playback_fields(&snapshot));
}

#[test]
fn progress_metadata_cas_normalizes_current_cover_wrappers_without_writing_expired_tokens() {
    let state = state();
    let mut snapshot = row("target", None, 100);
    state.db.upsert_progress(&snapshot).unwrap();
    snapshot.cover = Some(state.stream_proxy.register_cover(snapshot.cover.as_ref().unwrap(), Vec::new()));
    let next = state.stream_proxy.register_cover("https://images.invalid/new.jpg", Vec::new());
    patch(&state, &snapshot, "Resolved title", Some(&next));
    let after = read(&state, &snapshot).unwrap();
    assert_eq!(after.cover.as_deref(), Some("https://images.invalid/new.jpg"));

    let mut missing = row("empty", None, 100); missing.cover = None;
    state.db.upsert_progress(&missing).unwrap();
    missing.cover = Some("http://127.0.0.1:1/s/expired-fixture".into());
    patch(&state, &missing, "Title allowed", Some("https://images.invalid/stale.jpg"));
    let after = read(&state, &missing).unwrap();
    assert_eq!(after.title, "Title allowed");
    assert_eq!(after.cover, None, "unresolved expected wrapper must not compare as an observed null cover");
}

#[test]
fn progress_metadata_cas_boundary_requires_explicit_snapshots_and_rejects_wrong_types() {
    let request = serde_json::json!({"args":{"provider":"metadata-fixture","id":"target",
        "episode_id":null,"expected_title":"   ","expected_cover":null,"title":"Title","cover":null}});
    for field in ["provider", "id", "episode_id", "expected_title", "expected_cover", "title", "cover"] {
        let mut missing = request.clone(); missing["args"].as_object_mut().unwrap().remove(field);
        assert!(ProgressMetadataPatch::from_args(&crate::args::Args::new(&missing, "patch_progress_metadata")).is_err(),
            "missing field {field} must not silently become a snapshot null");
        let mut invalid = request.clone(); invalid["args"][field] = serde_json::json!({"invalid":true});
        assert!(ProgressMetadataPatch::from_args(&crate::args::Args::new(&invalid, "patch_progress_metadata")).is_err());
    }
    let mut camel = request.clone();
    let values = camel["args"].as_object_mut().unwrap();
    for (snake, camel) in [("episode_id","episodeId"), ("expected_title","expectedTitle"), ("expected_cover","expectedCover")] {
        let value = values.remove(snake).unwrap(); values.insert(camel.into(), value);
    }
    let patch = ProgressMetadataPatch::from_args(&crate::args::Args::new(&camel, "patch_progress_metadata")).unwrap();
    assert_eq!(patch.expected_title, "   ");
    assert_eq!(patch.episode_id, None);
    assert_eq!(patch.expected_cover, None);
    let mut conflict = request.clone(); conflict["args"]["expectedCover"] = serde_json::json!("must-not-override-null");
    let patch = ProgressMetadataPatch::from_args(&crate::args::Args::new(&conflict, "patch_progress_metadata")).unwrap();
    assert_eq!(patch.expected_cover, None, "explicit canonical null snapshot takes precedence over aliases");
}

#[test]
fn progress_metadata_cas_boundary_does_not_accept_playback_fields_as_write_authority() {
    let state = state();
    let snapshot = row("target", None, 100); state.db.upsert_progress(&snapshot).unwrap();
    let before = read(&state, &snapshot).unwrap();
    let request = serde_json::json!({"args":{"provider":snapshot.provider,"id":snapshot.native_id,
        "episode_id":null,"expected_title":snapshot.title,"expected_cover":snapshot.cover,"title":"Title","cover":null,
        "key":"different:key", "position":99999,"duration":1,"finished":true,"episode_title":"changed","updated_at":999999}});
    let patch = ProgressMetadataPatch::from_args(&crate::args::Args::new(&request, "patch_progress_metadata")).unwrap();
    patch_progress_metadata(&state, &patch).unwrap();
    assert_eq!(playback_fields(&read(&state, &snapshot).unwrap()), playback_fields(&before));
    assert!(state.db.list_history(20).unwrap().is_empty());
}

#[test]
fn progress_metadata_cas_leaves_existing_history_record_unchanged() {
    let state = state();
    let snapshot = row("target", None, 100); state.db.upsert_progress(&snapshot).unwrap();
    state.db.add_history(&HistoryEntry { key:"metadata-fixture:target".into(), provider:snapshot.provider.clone(),
        native_id:snapshot.native_id.clone(), title:"History title".into(), cover:snapshot.cover.clone(),
        episode_title:Some("History episode".into()), position:7, duration:99, watched_at:150 }).unwrap();
    let before = serde_json::to_value(state.db.list_history(20).unwrap()).unwrap();
    patch(&state, &snapshot, "Resolved title", Some("https://images.invalid/new.jpg"));
    assert_eq!(serde_json::to_value(state.db.list_history(20).unwrap()).unwrap(), before,
        "metadata must neither append nor edit the separate history plane");
}
