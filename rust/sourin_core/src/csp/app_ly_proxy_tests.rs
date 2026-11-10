use super::{items_of, page_count_of, AppLY, CspSite, MD5_HEADER, P_LIST};
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::{provider::ListRequest, proxy::ProxyStore, state::AppState};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use serde_json::{json, Value};
use std::{io::Write, sync::Arc, time::Duration};

fn request_body() -> Value {
    json!({"cur":"2","item":"o5","pageSize":"20","sect":["枣梆"]})
}

fn response_body(label: &str) -> Value {
    json!({
        "code":10000000,
        "pb":{"totalPage":3,"totalCount":41,"dataList":[{
            "code":"fixture-album","name":label,"img":"fixture.jpg"
        }]}
    })
}

fn assert_post(request: &Request) {
    assert_eq!(request.method, Method::POST);
    assert_eq!(request.body.as_ref(), request_body().to_string().as_bytes());
    assert_eq!(request.headers["content-type"], "application/json;charset=utf-8");
    assert_eq!(request.headers["user-agent"], "okhttp/3.9.1");
    assert_eq!(request.headers["md5"], MD5_HEADER);
    assert_eq!(request.headers["accept"], "*/*");
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
}

async fn post(site: &AppLY, url: &str) -> Result<Value, String> {
    tokio::time::timeout(
        Duration::from_secs(3),
        site.post_json_url(url, &request_body()),
    )
    .await
    .expect("loopback POST exceeded its fixture budget")
}

/// Uses AppLY's production request helper with only loopback destinations. A
/// reachable origin detects proxy bypass and any silent direct retry on error.
#[tokio::test]
async fn app_ly_post_preserves_contract_across_proxy_changes_and_failures() {
    let origin = serve(|request| {
        assert_post(&request);
        axum::Json(response_body("origin")).into_response()
    }).await;
    let target = format!("{}{P_LIST}", origin.url);
    let site = AppLY::new();
    let direct = post(&site, &target).await.unwrap();
    assert_eq!(direct, response_body("origin"));
    assert_eq!(items_of(&direct, "分类列表").unwrap()[0].title, "origin");
    assert_eq!(page_count_of(&direct), Some(3));
    assert_eq!(origin.hits.lock().unwrap().len(), 1);

    let first = serve(|request| {
        assert_post(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.path(), P_LIST);
        axum::Json(response_body("first proxy")).into_response()
    }).await;
    let store = Arc::new(ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "apply-loopback-fixture");
    assert_eq!(post(&site, &target).await.unwrap(), response_body("first proxy"));
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1);

    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(response_body("second proxy gzip").to_string().as_bytes()).unwrap();
    let compressed = encoder.finish().unwrap();
    assert_eq!(&compressed[..3], &[0x1f, 0x8b, 0x08]);
    let redirect = format!("{}/redirected-list", origin.url);
    let second = serve(move |request| {
        assert_post(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == P_LIST {
            // 307 must preserve the POST body and the original redirect policy.
            (StatusCode::TEMPORARY_REDIRECT, [
                ("location", redirect.clone()),
                ("set-cookie", "fixture=must-not-persist; Path=/".to_string()),
            ]).into_response()
        } else {
            assert_eq!(request.uri.path(), "/redirected-list");
            ([
                ("content-type", "application/json;charset=utf-8"),
                ("content-encoding", "gzip"),
            ], compressed.clone()).into_response()
        }
    }).await;
    custom(&store, &second.url);
    let redirected = post(&site, &target).await.unwrap();
    assert_eq!(redirected, response_body("second proxy gzip"));
    assert_eq!(items_of(&redirected, "分类列表").unwrap()[0].title, "second proxy gzip");
    assert_eq!(second.hits.lock().unwrap().len(), 2);
    assert_eq!(first.hits.lock().unwrap().len(), 1, "same site must stop using the old proxy");
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "redirect must retain the proxy");

    let encoding = origin.hits.lock().unwrap()[0].headers["accept-encoding"].clone();
    assert!(encoding.to_str().unwrap().split(',').any(|part| part.trim() == "gzip"));
    for proxy in [&first, &second] {
        for request in proxy.hits.lock().unwrap().iter() {
            assert_eq!(request.headers["accept-encoding"], encoding);
        }
    }

    let rejected = serve(|request| {
        assert_post(&request);
        (StatusCode::BAD_GATEWAY, "fixture rejection").into_response()
    }).await;
    custom(&store, &rejected.url);
    let error = post(&site, &target).await.unwrap_err();
    assert!(error.contains("HTTP 502"), "{error}");
    assert!(error.contains("fixture rejection"), "{error}");
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "HTTP error cannot retry directly");

    let invalid = serve(|request| {
        assert_post(&request);
        "fixture is not JSON".into_response()
    }).await;
    custom(&store, &invalid.url);
    let error = post(&site, &target).await.unwrap_err();
    assert!(error.contains("上游响应不是合法 JSON"), "{error}");
    assert!(error.contains("fixture is not JSON"), "{error}");
    assert_eq!(invalid.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "parse error cannot retry directly");

    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    custom(&store, &unavailable);
    let error = post(&site, &target).await.unwrap_err();
    assert!(error.contains("请求上游失败"), "{error}");
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "transport error cannot retry directly");

    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(post(&site, &target).await.unwrap(), response_body("origin"));
    assert_eq!(origin.hits.lock().unwrap().len(), 2, "explicit direct policy takes effect");
}

async fn rejected_list(state: &AppState, id: &str) {
    let request = ListRequest { category_id:"yuju".into(), page:1, ..Default::default() };
    let provider = state.registry.get(id).expect("AppLY provider must be registered");
    assert!(tokio::time::timeout(Duration::from_secs(3), provider.list(request))
        .await.expect("local CONNECT rejection exceeded its fixture budget").is_err());
}

fn assert_apply_connect(request: &Request) {
    assert_eq!(request.method, Method::CONNECT);
    assert_eq!(request.uri.authority().map(|a| a.as_str()), Some("fly.daoran.tv:443"));
    assert!(request.body.is_empty());
}

/// Positive factory-hook evidence only: the loopback proxy refuses the fixed
/// HTTPS endpoint before TLS. This does not verify upstream content or POST
/// bytes, and must not be used for a missing-hook mutation that could go public.
#[tokio::test]
async fn app_ly_startup_import_runtime_and_restore_receive_global_proxy_context() {
    let proxy = serve(|request| {
        if request.method == Method::CONNECT {
            assert_apply_connect(&request);
            return StatusCode::BAD_GATEWAY.into_response();
        }
        assert_eq!(request.method, Method::GET);
        assert_eq!(request.uri.host(), Some("apply-fixture.invalid"));
        assert_eq!(request.uri.path(), "/subscription.json");
        axum::Json(json!({"sites":[
            {"key":"apply-default","name":"AppLY default fixture","type":3,"api":"csp_AppLY"},
            {"key":"apply-sect","name":"AppLY sect fixture","type":3,"api":"csp_AppLY",
             "ext":{"q":"sect=yuju"}}
        ]})).into_response()
    }).await;
    let dir = scratch("apply-factories");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &proxy.url);
    rejected_list(&state, "csp-app-ly").await;
    assert_eq!(proxy.hits.lock().unwrap().len(), 1, "startup factory must inject AppLY policy");

    let report = tokio::time::timeout(Duration::from_secs(5), crate::tvbox::import_tvbox_config(
        &state, "http://apply-fixture.invalid/subscription.json",
    )).await.expect("loopback import exceeded its fixture budget").unwrap();
    let skipped = report["skipped"].as_array().unwrap();
    assert_eq!(skipped.len(), 1, "failed no-ext probe follows the existing import behavior: {report}");
    assert_eq!(skipped[0]["name"], "AppLY default fixture");
    assert_eq!(skipped[0]["stage"], "probe");
    let imported = report["imported"].as_array().unwrap();
    assert_eq!(imported.len(), 1, "ext-bearing AppLY remains available after probe failure: {report}");
    assert_eq!(imported[0]["name"], "AppLY sect fixture");
    assert_eq!(imported[0]["api"], "csp_AppLY");
    assert_eq!(imported[0]["persisted"], true);
    assert_eq!(imported[0]["categories"], 0);
    assert!(imported[0]["probeFailed"].is_string());
    let id = imported[0]["id"].as_str().unwrap().to_string();
    assert_eq!(proxy.hits.lock().unwrap().len(), 4, "config and both home probes must use the proxy");
    assert_eq!(proxy.hits.lock().unwrap().iter().filter(|r| r.method == Method::CONNECT).count(), 3);

    rejected_list(&state, &id).await;
    assert_eq!(proxy.hits.lock().unwrap().len(), 5, "imported runtime must retain policy");
    let switched = serve(|request| {
        assert_apply_connect(&request);
        StatusCode::BAD_GATEWAY.into_response()
    }).await;
    custom(&state.proxy, &switched.url);
    rejected_list(&state, &id).await;
    assert_eq!(switched.hits.lock().unwrap().len(), 1, "existing imported provider follows policy changes");
    assert_eq!(proxy.hits.lock().unwrap().len(), 5);
    drop(state);

    let restored = AppState::bootstrap(dir.clone()).await.unwrap();
    rejected_list(&restored, &id).await;
    assert_eq!(switched.hits.lock().unwrap().len(), 2, "saved factory must restore the latest policy");
    assert_eq!(proxy.hits.lock().unwrap().len(), 5);
    drop(restored);
    let _ = std::fs::remove_dir_all(dir);
}
