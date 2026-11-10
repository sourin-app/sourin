use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::{provider::ListRequest, state::AppState};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::sync::Arc;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

const FIXTURE_TOKEN: &str = "juying-loopback-token";

fn assert_headers(request: &Request, token: Option<&str>) {
    assert_eq!(request.method, Method::GET);
    assert!(request.body.is_empty());
    assert_eq!(request.headers["user-agent"], UA);
    assert_eq!(request.headers["accept"], "application/json");
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    assert_eq!(request.headers.get("x-app-user-token").map(|v| v.to_str().unwrap()), token);
    // reqwest applies its ordinary Referer rule after a redirect; the initial
    // request must retain Juying's fixed upstream Referer even with ext.host.
    if request.uri.path() != "/landed" {
        assert_eq!(request.headers["referer"].to_str().unwrap(), format!("{DEFAULT_HOST}/"));
    }
}

#[async_trait::async_trait]
impl contract::FixtureSite for Juying {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_json(url, Some(FIXTURE_TOKEN)).await.map(|value| value.to_string())
    }

    fn assert_headers(request: &Request) {
        assert_headers(request, Some(FIXTURE_TOKEN));
    }
}

#[tokio::test]
async fn catalog_proxy_juying_real_helper_preserves_policy_and_headers() {
    contract::exercise(Juying::new()).await;
}

fn list_body(label: &str) -> Value {
    serde_json::json!({"status":"success", "total_pages":3, "total_count":49,
        "results":[{"id":101,"title":format!("Juying {label}"),
            "cover":"http://cover.invalid/101.jpg", "release_year":2026, "resource_count":2}]})
}

async fn assert_list(state: &AppState, id: &str, label: &str) {
    let provider = state.registry.get(id).unwrap();
    let page = tokio::time::timeout(Duration::from_secs(3), provider.list(ListRequest {
        category_id: "movie|drama +|2026".into(), page: 2, ..Default::default()
    })).await.expect("loopback list exceeded its fixture budget").unwrap();
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].title, format!("Juying {label}"));
    assert_eq!(page.page, 2);
    assert_eq!(page.page_count, Some(3));
    assert_eq!(page.total, Some(49));
}

#[tokio::test]
async fn catalog_proxy_juying_import_runtime_hot_change_and_restore() {
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let base = origin.url.clone();
    let subscription = serde_json::json!({"sites":[{
        "key":"juying-local", "name":"Juying local fixture", "type":3,
        "api":"csp_Juying", "ext":{"host":format!("{base}/juying"),"token":FIXTURE_TOKEN}
    }]});
    let first = serve(move |request| {
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == "/subscription.json" {
            return axum::Json(subscription.clone()).into_response();
        }
        assert_headers(&request, Some(FIXTURE_TOKEN));
        assert_eq!(request.uri.path(), "/juying/api/app/movies/");
        assert!(matches!(request.uri.query(), Some("type=movie&page=1&page_size=24")
            | Some("type=movie&page=2&page_size=24&category=drama%20%2B&year=2026")));
        axum::Json(list_body("first proxy")).into_response()
    }).await;
    let second = serve(|request| {
        assert_headers(&request, Some(FIXTURE_TOKEN));
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.path(), "/juying/api/app/movies/");
        assert_eq!(request.uri.query(), Some("type=movie&page=2&page_size=24&category=drama%20%2B&year=2026"));
        axum::Json(list_body("second proxy")).into_response()
    }).await;
    let root = scratch("juying-proxy-factories");
    let dir = root.join("data");
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &first.url);
    let report = tokio::time::timeout(Duration::from_secs(5), crate::tvbox::import_tvbox_config(
        &state, &format!("{base}/subscription.json"),
    )).await.expect("loopback import exceeded its fixture budget").unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let imported = report["imported"].as_array().unwrap();
    assert_eq!(imported.len(), 1, "{report}");
    let row = &imported[0];
    assert_eq!(row["api"], "csp_Juying");
    assert_eq!(row["categories"], 5);
    assert!(row["probeFailed"].is_null(), "{row}");
    assert_eq!(row["persisted"], true);
    let id = row["id"].as_str().unwrap().to_string();
    assert_list(&state, &id, "first proxy").await;
    assert_eq!(first.hits.lock().unwrap().len(), 3, "config, home probe, runtime list");
    assert!(origin.hits.lock().unwrap().is_empty());

    custom(&state.proxy, &second.url);
    assert_list(&state, &id, "second proxy").await;
    assert_eq!(first.hits.lock().unwrap().len(), 3);
    assert_eq!(second.hits.lock().unwrap().len(), 1);
    drop(state);

    let restored = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_list(&restored, &id, "second proxy").await;
    assert_eq!(second.hits.lock().unwrap().len(), 2);
    assert!(origin.hits.lock().unwrap().is_empty(), "no factory may bypass its injected policy");
    drop(restored);
    let _ = std::fs::remove_dir_all(root);
}

#[tokio::test]
async fn catalog_proxy_juying_optional_token_and_resource_401_remain_explicit() {
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let proxy = serve(|request| {
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == "/probe" {
            assert_headers(&request, Some(FIXTURE_TOKEN));
            return axum::Json(serde_json::json!({"fixture":"token supplied"})).into_response();
        }
        assert_headers(&request, None);
        match request.uri.path() {
            "/api/app/movie/101/detail/" => axum::Json(serde_json::json!({
                "status":"success", "data":{"id":101,"title":"Juying anonymous metadata"}
            })).into_response(),
            "/api/app/movie/101/resources/" =>
                (StatusCode::UNAUTHORIZED, "fixture requires login").into_response(),
            "/invalid-json" => "fixture invalid JSON".into_response(),
            _ => StatusCode::NOT_FOUND.into_response(),
        }
    }).await;
    let site = Juying::new();
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    site.set_http_context(store, "juying-anonymous-fixture");
    let token_value = site.get_json(&format!("{}/probe", origin.url), Some(FIXTURE_TOKEN)).await.unwrap();
    assert_eq!(token_value["fixture"], "token supplied");
    let ext = serde_json::json!({"host":origin.url.clone()}).to_string();
    let detail = tokio::time::timeout(Duration::from_secs(3), site.detail("101", &ext))
        .await.expect("loopback detail exceeded its fixture budget").unwrap();
    assert_eq!(detail.title, "Juying anonymous metadata");
    assert_eq!(detail.episodes.len(), 1);
    assert_eq!(detail.episodes[0].id, format!("{NEED_LOGIN_PREFIX}101"));
    let error = site.play("", &detail.episodes[0].id, &ext).await.unwrap_err();
    assert!(error.contains("需要登录"), "{error}");
    let error = site.get_json(&format!("{}/invalid-json", origin.url), None).await.unwrap_err();
    assert!(error.contains("不是 JSON"), "{error}");
    assert!(error.contains("fixture invalid JSON"), "{error}");
    assert_eq!(proxy.hits.lock().unwrap().len(), 4);
    assert!(origin.hits.lock().unwrap().is_empty(), "neither auth nor parse failures may retry directly");
}
