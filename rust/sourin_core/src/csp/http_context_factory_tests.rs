use super::test_support::{custom, scratch, serve};
use crate::{model::PersistedProvider, provider::ListRequest, state::AppState};
use axum::response::IntoResponse;

#[tokio::test]
async fn selected_csp_startup_and_saved_restore_factories_route_through_the_global_proxy() {
    let proxy = serve(|_| axum::http::StatusCode::BAD_GATEWAY.into_response()).await;
    let dir = scratch("factories");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &proxy.url);
    let classes = [("Bili", "csp-bili"), ("Ikanbot", "csp-ikanbot"), ("Libvio", "csp-libvio")];
    for (_, id) in classes {
        let before = proxy.hits.lock().unwrap().len();
        let request = ListRequest { category_id:"1".into(), page:1, ..Default::default() };
        assert!(state.registry.get(id).unwrap().list(request).await.is_err());
        assert_eq!(proxy.hits.lock().unwrap().len(), before + 1, "startup factory failed to inject {id}");
    }
    let saved: Vec<_> = classes.iter().map(|(class, _)| PersistedProvider::Tvbox {
        id: format!("saved-{class}"), name: format!("Saved {class}"), api: format!("csp_{class}"),
        categories: Vec::new(), parsers: Vec::new(), ext: None,
    }).collect();
    crate::persist::save_persisted(&dir, &saved).unwrap();
    drop(state);
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    for (class, _) in classes {
        let before = proxy.hits.lock().unwrap().len();
        let request = ListRequest { category_id:"1".into(), page:1, ..Default::default() };
        assert!(state.registry.get(&format!("saved-{class}")).unwrap().list(request).await.is_err());
        assert_eq!(proxy.hits.lock().unwrap().len(), before + 1, "restore factory failed to inject {class}");
    }
    assert!(proxy.hits.lock().unwrap().iter().all(|r| r.method == axum::http::Method::CONNECT || r.uri.scheme_str() == Some("http")));
    drop(state);
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn douban_app_rj_yun_duo_import_probes_and_saved_runtime_receive_proxy_context() {
    let proxy = serve(|request| {
        if request.method == axum::http::Method::CONNECT {
            // Douban has a fixed HTTPS endpoint. Refusing its tunnel exercises
            // injection without reaching that endpoint or changing production URLs.
            return axum::http::StatusCode::BAD_GATEWAY.into_response();
        }
        match (request.uri.host(), request.uri.path()) {
            (Some("csp-batch.invalid"), "/subscription.json") => axum::Json(serde_json::json!({"sites":[
                {"key":"douban","name":"Douban fixture","type":3,"api":"csp_Douban"},
                {"key":"apprj","name":"AppRJ fixture","type":3,"api":"csp_AppRJ","ext":{"url":"http://apprj-batch.invalid"}},
                {"key":"yunduo","name":"YunDuo fixture","type":3,"api":"csp_YunDuo","ext":{"host":"http://yunduo-batch.invalid","client":"fixture-client","sign":"fixture-sign"}}
            ]})).into_response(),
            (Some("apprj-batch.invalid"), _) => axum::Json(serde_json::json!({
                "code":1,"data":{"list":[{"vod_id":1,"vod_name":"AppRJ fixture"}]}
            })).into_response(),
            (Some("yunduo-batch.invalid"), "/api.php/web/index/home") => axum::Json(serde_json::json!({
                "code":200,"data":{"categories":[{"type_id":1,"type_name":"电影"}]}
            })).into_response(),
            (Some("yunduo-batch.invalid"), _) => axum::Json(serde_json::json!({
                "code":200,"data":[{"vod_id":1,"vod_name":"YunDuo fixture"}]
            })).into_response(),
            _ => axum::http::StatusCode::BAD_GATEWAY.into_response(),
        }
    }).await;
    let dir = scratch("selected-batch");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &proxy.url);
    let report = crate::tvbox::import_tvbox_config(&state, "http://csp-batch.invalid/subscription.json").await.unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty());
    let mut sources = Vec::new();
    for (class, category) in [("Douban", "hot_gaia"), ("AppRJ", "1"), ("YunDuo", "电影")] {
        let api = format!("csp_{class}");
        let row = report["imported"].as_array().unwrap().iter().find(|row| row["api"] == api).unwrap();
        assert!(row["probeFailed"].is_null());
        assert!(row["categories"].as_u64().unwrap() > 0);
        sources.push((class, category, row["id"].as_str().unwrap().to_string()));
    }
    assert_eq!(proxy.hits.lock().unwrap().len(), 4, "config and all three home probes must use the proxy");
    for (class, category, id) in &sources {
        let request = ListRequest { category_id:(*category).into(), page:1, ..Default::default() };
        let result = state.registry.get(id).unwrap().list(request).await;
        if *class == "Douban" {
            assert!(result.is_err(), "the local proxy refuses Douban's fixed HTTPS endpoint");
        } else {
            assert_eq!(result.unwrap().items[0].title, format!("{class} fixture"));
        }
    }
    assert_eq!(proxy.hits.lock().unwrap().len(), 7);
    drop(state);
    let restored = AppState::bootstrap(dir.clone()).await.unwrap();
    for (class, category, id) in &sources {
        let request = ListRequest { category_id:(*category).into(), page:1, ..Default::default() };
        let result = restored.registry.get(id).unwrap().list(request).await;
        if *class == "Douban" { assert!(result.is_err()); }
        else { assert_eq!(result.unwrap().items[0].title, format!("{class} fixture")); }
    }
    assert_eq!(proxy.hits.lock().unwrap().len(), 10, "restoration retains policy for every migrated class");
    drop(restored);
    let _ = std::fs::remove_dir_all(dir);
}
