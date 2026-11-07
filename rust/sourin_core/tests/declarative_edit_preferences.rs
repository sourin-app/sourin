use sourin_core::{commands, commands_provider, commands_remote, state::AppState};
use std::sync::Arc;

async fn fixture() -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-declarative-edit-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = AppState::bootstrap(dir).await.unwrap();
    for id in ["edit-alpha", "edit-beta", "edit-gamma"] {
        import(&state, id, id).await;
    }
    state
}

async fn import(state: &AppState, id: &str, name: &str) {
    let json = serde_json::json!({
        "id": id,
        "name": name,
        "base": "https://source-fixture.invalid",
        "endpoints": {}
    });
    commands_remote::import_declarative_provider(state, &json.to_string())
        .await
        .unwrap();
}

#[tokio::test]
async fn declarative_edit_preserves_saved_order_before_any_order_read() {
    let state = fixture().await;
    let expected = ["edit-gamma", "edit-alpha", "edit-beta"];
    commands_provider::set_provider_order(
        &state,
        &expected.iter().map(|id| id.to_string()).collect::<Vec<_>>(),
    )
    .unwrap();
    let persisted_before = std::fs::read(state.data_dir.join("provider-order.json")).unwrap();

    import(&state, "edit-gamma", "Edited gamma").await;

    // Home reads list_providers directly. get_provider_order would repair the
    // registry as a side effect and hide the regression from this assertion.
    let providers = commands::list_providers(&state).unwrap();
    let actual = providers
        .iter()
        .filter(|p| p.id.starts_with("edit-"))
        .map(|p| p.id.as_str())
        .collect::<Vec<_>>();
    assert_eq!(actual, expected);
    assert_eq!(
        std::fs::read(state.data_dir.join("provider-order.json")).unwrap(),
        persisted_before
    );
    assert_eq!(
        providers
            .iter()
            .find(|p| p.id == "edit-gamma")
            .unwrap()
            .name,
        "Edited gamma"
    );
}

#[tokio::test]
async fn declarative_edit_preserves_disabled_runtime_handle() {
    let state = fixture().await;
    assert!(commands_provider::set_enabled_persisted(&state, "edit-gamma", false).unwrap());
    let persisted_before = std::fs::read(state.data_dir.join("disabled-providers.json")).unwrap();

    import(&state, "edit-gamma", "Edited gamma").await;

    assert!(!commands::get_provider_enabled(&state, "edit-gamma").unwrap());
    // The list endpoint reads the persisted flag; also inspect the registry
    // used by searches, which must not silently reactivate the edited source.
    assert!(!state
        .registry
        .enabled_manifests()
        .iter()
        .any(|p| p.id == "edit-gamma"));
    assert_eq!(
        std::fs::read(state.data_dir.join("disabled-providers.json")).unwrap(),
        persisted_before
    );
}
