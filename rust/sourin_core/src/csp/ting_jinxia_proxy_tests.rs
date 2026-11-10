use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::sync::Arc;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for TingJinxia {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_text(url).await
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
        assert!(!request.headers.contains_key("accept-language"));
        if request.uri.path() == "/probe" {
            assert_eq!(request.headers["referer"], PLAY_REFERER);
        }
    }
}

#[tokio::test]
async fn global_proxy_catalog_v3_ting_jinxia_preserves_catalog_get_contract() {
    contract::exercise(TingJinxia::new()).await;
}

fn episode_html(label: &str) -> String {
    format!(r#"<meta name="_b" content="book +&"><meta name="_p" content="0"><meta name="_cp" content="7"><meta name="_c" content="fixture-xt-{label}"><meta name="_f" content="m4a">"#)
}

fn assert_play_request(request: &Request, label: &str) {
    assert_eq!(request.headers["user-agent"], UA);
    assert!(!request.headers.contains_key("cookie"), "the original client has no cookie jar");
    assert!(!request.headers.contains_key("authorization"));
    assert!(!request.headers.contains_key("accept-language"));
    if request.method == Method::GET {
        assert_eq!(request.uri.path(), "/episode");
        assert_eq!(request.uri.query(), Some("first=alpha%2Bbeta&second=two"));
        assert!(request.body.is_empty());
        assert_eq!(request.headers["referer"], PLAY_REFERER);
        assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
    } else {
        assert_eq!(request.method, Method::POST);
        assert_eq!(request.uri.path(), "/");
        assert_eq!(request.uri.query(), Some("s=api-getneoplay"));
        assert_eq!(request.headers["xt"].to_str().unwrap(), format!("fixture-xt-{label}"));
        let referer = reqwest::Url::parse(request.headers["referer"].to_str().unwrap()).unwrap();
        assert_eq!(referer.path(), "/episode");
        assert_eq!(referer.query(), Some("first=alpha%2Bbeta&second=two"));
        assert_eq!(referer.host_str(), Some("127.0.0.1"));
        assert_eq!(request.headers["accept"], "application/json, text/javascript, */*; q=0.01");
        assert_eq!(request.headers["content-type"], "application/x-www-form-urlencoded; charset=UTF-8");
        assert_eq!(request.body.as_ref(), b"bookId=book+%2B%26&isPay=0&page=7");
    }
}

fn play_response(request: Request, label: &str) -> axum::response::Response {
    assert_play_request(&request, label);
    if request.method == Method::GET {
        ([("set-cookie", "fixture=must-not-persist; Path=/")], episode_html(label)).into_response()
    } else {
        axum::Json(serde_json::json!({"status":1,"ourl":format!("http://127.0.0.1/fixture-{label}.m4a"),"url":"http://127.0.0.1/ignored.m4a"})).into_response()
    }
}

async fn play_fixture(site: &TingJinxia, host: &str) -> Result<Vec<CspPlay>, String> {
    tokio::time::timeout(
        std::time::Duration::from_secs(3),
        site.play("fixture flag", "/episode?first=alpha%2Bbeta&second=two", host),
    ).await.expect("loopback play exceeded its fixture budget")
}

#[tokio::test]
async fn global_proxy_catalog_v3_ting_jinxia_routes_public_play_get_and_post() {
    let origin = serve(|request| play_response(request, "origin")).await;
    let first = serve(|request| play_response(request, "first")).await;
    let second = serve(|request| play_response(request, "second")).await;
    let site = TingJinxia::new();
    assert_eq!(play_fixture(&site, &origin.url).await.unwrap()[0].url, "http://127.0.0.1/fixture-origin.m4a");
    assert_eq!(origin.hits.lock().unwrap().len(), 2);
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "ting-jinxia-play-fixture");
    let first_play = play_fixture(&site, &origin.url).await.unwrap();
    assert_eq!(first_play[0].url, "http://127.0.0.1/fixture-first.m4a");
    assert_eq!(first_play[0].label.as_deref(), Some("fixture flag（m4a）"));
    assert_eq!(first_play[0].headers, vec![("Referer".to_string(), PLAY_REFERER.to_string()), ("User-Agent".to_string(), UA.to_string())]);
    assert_eq!(first.hits.lock().unwrap().len(), 2);
    assert_eq!(origin.hits.lock().unwrap().len(), 2);
    custom(&store, &second.url);
    assert_eq!(play_fixture(&site, &origin.url).await.unwrap()[0].url, "http://127.0.0.1/fixture-second.m4a");
    assert_eq!(second.hits.lock().unwrap().len(), 2);
    assert_eq!(first.hits.lock().unwrap().len(), 2);
    assert_eq!(origin.hits.lock().unwrap().len(), 2);

    let rejected = serve(|request| {
        assert_play_request(&request, "rejected");
        if request.method == Method::GET {
            episode_html("rejected").into_response()
        } else {
            (StatusCode::BAD_GATEWAY, "fixture rejection").into_response()
        }
    }).await;
    custom(&store, &rejected.url);
    let error = play_fixture(&site, &origin.url).await.unwrap_err();
    assert!(error.contains("取流 HTTP 502"), "{error}");
    assert!(error.contains("fixture rejection"), "{error}");
    assert_eq!(rejected.hits.lock().unwrap().len(), 2);
    assert_eq!(origin.hits.lock().unwrap().len(), 2);

    let invalid = serve(|request| {
        assert_play_request(&request, "invalid");
        if request.method == Method::GET {
            episode_html("invalid").into_response()
        } else {
            "fixture invalid JSON".into_response()
        }
    }).await;
    custom(&store, &invalid.url);
    let error = play_fixture(&site, &origin.url).await.unwrap_err();
    assert!(error.contains("api-getneoplay 不是 JSON"), "{error}");
    assert_eq!(invalid.hits.lock().unwrap().len(), 2);
    assert_eq!(origin.hits.lock().unwrap().len(), 2);

    // Change policy after the episode GET, so the independent POST must consult
    // the current context and fail without sending to the reachable origin.
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", unused.local_addr().unwrap());
    let switching_store = store.clone();
    let switching = serve(move |request| {
        assert_eq!(request.method, Method::GET);
        assert_play_request(&request, "switching");
        custom(&switching_store, &unavailable);
        episode_html("switching").into_response()
    }).await;
    drop(unused);
    custom(&store, &switching.url);
    let error = play_fixture(&site, &origin.url).await.unwrap_err();
    assert!(error.contains("取流请求失败"), "{error}");
    assert_eq!(switching.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 2);

    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(play_fixture(&site, &origin.url).await.unwrap()[0].url, "http://127.0.0.1/fixture-origin.m4a");
    assert_eq!(origin.hits.lock().unwrap().len(), 4);
}
