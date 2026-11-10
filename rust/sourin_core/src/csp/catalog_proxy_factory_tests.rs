use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use axum::{http::StatusCode, response::{IntoResponse, Response}};

fn catalog_response(request: &Request, label: &str) -> Response {
    assert_eq!(request.uri.scheme_str(), Some("http"), "the factory must use the proxy");
    let path = request.uri.path();
    let html = if path.starts_with("/wwys/") {
        format!(r#"<a href="/vod-type-id-1-pg-1.html">电影</a>
<ul><li><a href="/vod-detail-id-101.html" title="Wwys {label}"><img src="http://cover.invalid/1.jpg"><span class="sTit">Wwys {label}</span></a></li></ul>"#)
    } else if path.starts_with("/zhinan/") {
        format!(r#"<a href="/books/zuixin/">最新</a>
<article class="posts-item book-item"><a href="/book/102.html"><img data-src="http://cover.invalid/2.jpg"></a><h3><a href="/book/102.html">Zhinan {label}</a></h3></article>"#)
    } else if path.starts_with("/czsapp/") {
        format!(r#"<ul><li><a href="/voddetail/103.html"><img data-original="http://cover.invalid/3.jpg"><h4 class="dytit"><a>Czsapp {label}</a></h4></a></li></ul>"#)
    } else {
        return StatusCode::NOT_FOUND.into_response();
    };
    html.into_response()
}

async fn assert_catalogs(
    state: &crate::state::AppState,
    sources: &[(String, String, String)],
    label: &str,
) {
    for (class, category, id) in sources {
        let page = state.registry.get(id).unwrap().list(crate::provider::ListRequest {
            category_id: category.clone(), page: 1, ..Default::default()
        }).await.unwrap();
        let title = if class == "4KZhinan" { "Zhinan" } else { class.as_str() };
        assert_eq!(page.items.len(), 1, "{class} must parse the fixture item");
        assert_eq!(page.items[0].title, format!("{title} {label}"));
    }
}

#[tokio::test]
async fn catalog_proxy_import_runtime_hot_change_and_restore_use_engine_contexts() {
    // Even if injection regresses, every configured target stays on loopback.
    // The origin is reachable but must receive zero requests.
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let base = origin.url.clone();
    let subscription = serde_json::json!({"sites":[
        {"key":"catalog-wwys","name":"Wwys fixture","type":3,"api":"csp_Wwys","ext":format!("{base}/wwys")},
        {"key":"catalog-zhinan","name":"Zhinan fixture","type":3,"api":"csp_4KZhinan","ext":format!("{base}/zhinan")},
        {"key":"catalog-czsapp","name":"Czsapp fixture","type":3,"api":"csp_Czsapp","ext":format!("{base}/czsapp")}
    ]});
    let first = serve(move |request| {
        if request.uri.path() == "/subscription.json" {
            axum::Json(subscription.clone()).into_response()
        } else {
            catalog_response(&request, "first fixture")
        }
    }).await;
    let second = serve(|request| catalog_response(&request, "second fixture")).await;
    let dir = scratch("catalog-batch-factories");
    let state = crate::state::AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &first.url);
    let report = crate::tvbox::import_tvbox_config(
        &state, &format!("{base}/subscription.json"),
    ).await.unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let imported = report["imported"].as_array().unwrap();
    assert_eq!(imported.len(), 3);
    let mut sources = Vec::new();
    for (class, category) in [("Wwys", "1"), ("4KZhinan", "books:zuixin"), ("Czsapp", "1")] {
        let api = format!("csp_{class}");
        let row = imported.iter().find(|row| row["api"] == api).unwrap();
        if class == "Czsapp" {
            // Preserve its existing home limitation; proxy routing must not
            // turn an unknown page into a successful category probe.
            assert!(row["probeFailed"].as_str().unwrap().contains("无法判定形态"));
            assert_eq!(row["categories"], 0);
        } else {
            assert!(row["probeFailed"].is_null(), "{row}");
            assert_eq!(row["categories"], 1);
        }
        sources.push((class.to_string(), category.to_string(), row["id"].as_str().unwrap().to_string()));
    }
    assert_catalogs(&state, &sources, "first fixture").await;
    assert_eq!(first.hits.lock().unwrap().len(), 8, "config + four home requests + three lists");
    assert!(origin.hits.lock().unwrap().is_empty());

    custom(&state.proxy, &second.url);
    assert_catalogs(&state, &sources, "second fixture").await;
    assert_eq!(first.hits.lock().unwrap().len(), 8);
    assert_eq!(second.hits.lock().unwrap().len(), 3);
    drop(state);

    let restored = crate::state::AppState::bootstrap(dir.clone()).await.unwrap();
    assert_catalogs(&restored, &sources, "second fixture").await;
    assert_eq!(second.hits.lock().unwrap().len(), 6);
    assert!(origin.hits.lock().unwrap().is_empty(), "no factory request may escape the proxy");
    drop(restored);
    let _ = std::fs::remove_dir_all(dir);
}
