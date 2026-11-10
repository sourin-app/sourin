use super::*;
#[path = "app_drama_public_fixture.rs"]
mod app_drama_public_fixture;
use crate::csp::http_context::test_support::{custom, scratch, serve};
use crate::state::AppState;
use app_drama_public_fixture::{
    dispatch_headers, fixtures, respond, PublicFixture, ResponseMode, ZONE,
};
use axum::{http::StatusCode, response::IntoResponse};
use std::time::Duration;

async fn home(site: &AppDrama, ext: &str) -> CspHome {
    tokio::time::timeout(Duration::from_secs(5), site.home(ext))
        .await
        .expect("public loopback home exceeded fixture budget")
        .unwrap()
}

async fn home_error(site: &AppDrama, ext: &str) -> String {
    tokio::time::timeout(Duration::from_secs(5), site.home(ext))
        .await
        .expect("public loopback failure exceeded fixture budget")
        .unwrap_err()
}

fn catalog(home: &CspHome) {
    assert_eq!(home.categories.len(), 1);
    assert_eq!(home.categories[0].id, "cat-one");
    assert_eq!(home.categories[0].name, "Synthetic category");
}

fn available(state: &AppState, id: &str, ext: &str) {
    let provider = state.registry.get(id).unwrap();
    let manifest = provider.manifest();
    assert!(manifest.working && manifest.capabilities.vod && manifest.capabilities.search);
    assert_eq!(manifest.broken_reason, None);
    let saved = crate::persist::load_persisted(&state.data_dir);
    assert!(saved.iter().any(|row| matches!(row,
        crate::model::PersistedProvider::Tvbox { id:saved_id, ext:Some(saved_ext), categories, .. }
            if saved_id == id && saved_ext == ext && categories.len() == 1 && categories[0].id == "cat-one")));
}

#[tokio::test]
async fn catalog_proxy_appdrama_public_home_retains_direct_live_policy_gzip_and_no_fallback() {
    let first = PublicFixture::new(ResponseMode::Normal).await;
    let second = PublicFixture::new(ResponseMode::Gzip).await;
    let site = AppDrama::new();
    assert!(site.supports_search() && site.needs_ext());
    // Unbound default construction is explicitly direct, independent of host
    // environment proxies; the full public protocol must work, not get_text.
    catalog(&home(&site, &first.ext).await);
    assert_eq!(first.origin.hits.lock().unwrap().len(), 3);
    assert!(first.proxy.hits.lock().unwrap().is_empty());
    site.set_http_context(first.store.clone(), "appdrama-policy-fixture");
    catalog(&home(&site, &first.ext).await);
    assert_eq!(first.proxy.hits.lock().unwrap().len(), 3);
    assert_eq!(first.origin.hits.lock().unwrap().len(), 3);
    custom(&first.store, &second.proxy.url);
    catalog(&home(&site, &first.ext).await);
    assert_eq!(
        second.proxy.hits.lock().unwrap().len(),
        3,
        "new proxy performs dispatch/zone/categories, including independent gzip envelopes"
    );
    assert_eq!(
        first.proxy.hits.lock().unwrap().len(),
        3,
        "same instance stops using the old proxy"
    );
    assert_eq!(
        first.origin.hits.lock().unwrap().len(),
        3,
        "policy change cannot fall back directly"
    );
    second.assert_proxy_only();
    let encoding = first.origin.hits.lock().unwrap()[0].headers["accept-encoding"].clone();
    assert!(encoding
        .to_str()
        .unwrap()
        .split(',')
        .any(|item| item.trim() == "gzip"));
    for fixture in [&first, &second] {
        for request in fixture.proxy.hits.lock().unwrap().iter() {
            assert_eq!(request.headers["accept-encoding"], encoding);
            assert!(!request.headers.contains_key("cookie"));
            assert!(!request.headers.contains_key("authorization"));
        }
    }
    let rejected = serve(|request| {
        dispatch_headers(&request);
        (StatusCode::BAD_GATEWAY, "synthetic rejected dispatch").into_response()
    })
    .await;
    custom(&first.store, &rejected.url);
    assert!(home_error(&site, &first.ext).await.contains("HTTP 502"));
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    assert_eq!(
        first.origin.hits.lock().unwrap().len(),
        3,
        "HTTP failure never retries directly"
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    custom(&first.store, &unavailable);
    let failure = home_error(&site, &first.ext).await;
    assert!(failure.starts_with("network:"), "{failure}");
    assert_eq!(
        first.origin.hits.lock().unwrap().len(),
        3,
        "transport failure never retries directly"
    );
    first
        .store
        .set(
            crate::proxy::GLOBAL_PROXY,
            crate::proxy::ProxyConfig::default(),
        )
        .unwrap();
    catalog(&home(&site, &first.ext).await);
    assert_eq!(
        first.origin.hits.lock().unwrap().len(),
        6,
        "explicit direct change takes effect on the same public site"
    );
    assert_eq!(first.proxy.hits.lock().unwrap().len(), 3);
    assert_eq!(second.proxy.hits.lock().unwrap().len(), 3);
    // Direct requests obey the same refusal, not only proxied ones.
    let sink = serve(|_| panic!("direct public home cannot follow a redirect")).await;
    let location = format!("{}/cross-authority", sink.url);
    let direct_redirect = serve(move |request| {
        dispatch_headers(&request);
        (StatusCode::FOUND, [("location", location.clone())]).into_response()
    })
    .await;
    let mut redirected: serde_json::Value = serde_json::from_str(&first.ext).unwrap();
    redirected["site"] = format!(
        "{}/dispatch?first=alpha%2Bbeta&second=two",
        direct_redirect.url
    )
    .into();
    let error = home_error(&AppDrama::new(), &redirected.to_string()).await;
    assert!(
        error.starts_with("unsupported:") && error.contains("重定向"),
        "{error}"
    );
    assert_eq!(direct_redirect.hits.lock().unwrap().len(), 1);
    assert!(sink.hits.lock().unwrap().is_empty());
}

#[tokio::test]
async fn catalog_proxy_appdrama_public_home_explicitly_rejects_all_3xx_without_cross_authority_requests(
) {
    // A different loopback authority is an observable, fully local sink. Even
    // a leaked signed header/body may never reach it, directly or via proxy.
    for stage in ["/dispatch", ZONE, "/api/v3/drama/getCategory"] {
        for status in [301u16, 302, 303, 304, 307, 308] {
            let fixture = PublicFixture::new(ResponseMode::Normal).await;
            let sink =
                serve(|_| panic!("AppDrama must not follow a redirect to another authority")).await;
            let location = format!("{}/cross-authority", sink.url);
            let origin = fixture.origin.url.clone();
            let parsed_origin = reqwest::Url::parse(&origin).unwrap();
            let expected_authority = format!(
                "{}:{}",
                parsed_origin.host_str().unwrap(),
                parsed_origin.port().unwrap()
            );
            let data = fixtures();
            let redirecting = serve(move |request| {
                assert_eq!(
                    request.uri.authority().unwrap().as_str(),
                    expected_authority
                );
                if request.uri.path() == stage {
                    if stage == "/dispatch" {
                        dispatch_headers(&request);
                    }
                    return (
                        StatusCode::from_u16(status).unwrap(),
                        [
                            ("location", location.clone()),
                            ("set-cookie", "synthetic=never-forward; Path=/".to_string()),
                        ],
                    )
                        .into_response();
                }
                respond(&request, &data, &origin, ResponseMode::Normal)
            })
            .await;
            custom(&fixture.store, &redirecting.url);
            let site = fixture.site();
            let error = home_error(&site, &fixture.ext).await;
            assert!(error.starts_with("unsupported:") && error.contains("重定向"),
                "every redirect/304 is an explicit refusal, not empty content: {status} {stage}: {error}");
            let expected = match stage {
                "/dispatch" => 1,
                ZONE => 2,
                _ => 3,
            };
            assert_eq!(
                redirecting.hits.lock().unwrap().len(),
                expected,
                "one bounded operation must stop at the first 3xx response"
            );
            assert!(sink.hits.lock().unwrap().is_empty());
            fixture.assert_proxy_only();
            assert!(fixture.proxy.hits.lock().unwrap().is_empty());
            assert!(!error.contains(&sink.url));
            assert!(!error.contains(&fixture.origin.url));
            assert!(!error.contains("publicParams"));
            // An explicit route change permits a fresh attempt, but the
            // redirect response's Set-Cookie must never create ambient state.
            custom(&fixture.store, &fixture.proxy.url);
            catalog(&home(&site, &fixture.ext).await);
            assert_eq!(fixture.proxy.hits.lock().unwrap().len(), 3);
            assert!(sink.hits.lock().unwrap().is_empty());
            fixture.assert_proxy_only();
        }
    }
}

#[tokio::test]
async fn catalog_proxy_appdrama_public_dispatch_restriction_and_invalid_json_stop_before_bootstrap()
{
    for disabled in [true, false] {
        let fixture = PublicFixture::new(ResponseMode::Normal).await;
        let domain = fixture.origin.url.clone();
        let rejecting = serve(move |request| {
            dispatch_headers(&request);
            if disabled {
                axum::Json(serde_json::json!({"domain":domain,"enabled":false})).into_response()
            } else {
                "synthetic invalid JSON".into_response()
            }
        })
        .await;
        custom(&fixture.store, &rejecting.url);
        let error = home_error(&fixture.site(), &fixture.ext).await;
        assert!(
            error.starts_with(if disabled { "unsupported:" } else { "parse:" }),
            "{error}"
        );
        assert_eq!(rejecting.hits.lock().unwrap().len(), 1);
        fixture.assert_proxy_only();
        assert!(fixture.proxy.hits.lock().unwrap().is_empty());
        assert!(!error.contains(&fixture.origin.url));
    }
}

#[tokio::test]
async fn catalog_proxy_appdrama_real_import_and_restoration_keep_available_registered_default_protocol(
) {
    let first = PublicFixture::new(ResponseMode::Normal).await;
    let second = PublicFixture::new(ResponseMode::Normal).await;
    let dir = scratch("appdrama-public-import-restore");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &first.proxy.url);
    let report = tokio::time::timeout(
        Duration::from_secs(5),
        crate::tvbox::import_tvbox_config(
            &state,
            &format!("{}/subscription.json", first.origin.url),
        ),
    )
    .await
    .expect("loopback AppDrama import exceeded budget")
    .unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let rows = report["imported"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "{report}");
    let row = &rows[0];
    assert_eq!(row["persisted"], true);
    assert_eq!(row["categories"], 1);
    assert!(
        row["probeFailed"].is_null(),
        "a real successful import cannot retain the old placeholder failure: {row}"
    );
    let id = row["id"].as_str().unwrap().to_string();
    available(&state, &id, &first.ext);
    assert_eq!(
        first.proxy.hits.lock().unwrap().len(),
        4,
        "subscription, dispatch, zone, categories"
    );
    let saved_bytes = std::fs::read(dir.join("third-party-providers.json")).unwrap();
    let saved_rows = crate::persist::load_persisted(&dir);
    let registered = state.registry.get(&id).unwrap();
    let page = registered.search("synthetic-query", 1).await.unwrap();
    assert_eq!(page.items[0].id.native, "1001");
    assert_eq!(
        first.proxy.hits.lock().unwrap().len(),
        7,
        "registered constructor owns its own explicit bootstrap and search"
    );
    custom(&state.proxy, &second.proxy.url);
    drop(registered);
    drop(state);
    let before = second.proxy.hits.lock().unwrap().len();
    let restored = AppState::bootstrap(dir.clone()).await.unwrap();
    available(&restored, &id, &first.ext);
    assert_eq!(
        second.proxy.hits.lock().unwrap().len(),
        before,
        "restore registers without a startup probe"
    );
    assert_eq!(
        std::fs::read(dir.join("third-party-providers.json")).unwrap(),
        saved_bytes
    );
    assert_eq!(crate::persist::load_persisted(&dir), saved_rows);
    assert!(crate::persist::load_restore_failures(&dir).is_empty());
    let provider = restored.registry.get(&id).unwrap();
    assert_eq!(
        provider.home().await.unwrap()[0].title,
        "Synthetic category"
    );
    assert_eq!(
        second.proxy.hits.lock().unwrap().len(),
        before,
        "saved categories preserve no-network home restoration"
    );
    let page = provider.search("synthetic-query", 1).await.unwrap();
    assert_eq!(page.items[0].id.native, "1001");
    assert_eq!(
        second.proxy.hits.lock().unwrap().len(),
        before + 3,
        "the restored public default provider reads the saved current global route"
    );
    assert_eq!(first.proxy.hits.lock().unwrap().len(), 7);
    first.assert_proxy_only();
    second.assert_proxy_only();
    drop(provider);
    drop(restored);
    let _ = std::fs::remove_dir_all(dir);
}
