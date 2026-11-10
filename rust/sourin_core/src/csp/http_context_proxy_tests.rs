use super::*;
use super::test_support::{custom, serve};
use axum::response::IntoResponse;
use std::time::Duration;

#[tokio::test]
async fn context_keeps_instances_isolated_and_rebuilds_only_on_policy_change_without_fallback() {
    let first = serve(|_| "first".into_response()).await;
    let second = serve(|_| "second".into_response()).await;
    let origin = serve(|_| "direct".into_response()).await;
    let first_store = Arc::new(ProxyStore::new());
    let second_store = Arc::new(ProxyStore::new());
    custom(&first_store, &first.url);
    custom(&second_store, &second.url);
    let builds = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let built = builds.clone();
    let one = CspHttpContext::new(move || {
        built.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        reqwest::Client::builder().user_agent("Csp fixture UA").timeout(Duration::from_secs(1))
    });
    let two = CspHttpContext::new(reqwest::Client::builder);
    one.set_proxy(first_store.clone(), "same-id");
    two.set_proxy(second_store.clone(), "same-id");
    for _ in 0..2 {
        assert_eq!(one.client().unwrap().get("http://context.invalid/item").send().await.unwrap().text().await.unwrap(), "first");
    }
    assert_eq!(builds.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(two.client().unwrap().get("http://context.invalid/item").send().await.unwrap().text().await.unwrap(), "second");
    assert!(first.hits.lock().unwrap().iter().all(|r| r.headers["user-agent"] == "Csp fixture UA"));
    custom(&first_store, &second.url);
    assert_eq!(one.client().unwrap().get("http://context.invalid/item").send().await.unwrap().text().await.unwrap(), "second");
    assert_eq!(builds.load(std::sync::atomic::Ordering::SeqCst), 2);
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    custom(&first_store, &unavailable);
    assert!(one.client().unwrap().get(&origin.url).send().await.is_err());
    assert!(origin.hits.lock().unwrap().is_empty());
    first_store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(one.client().unwrap().get(&origin.url).send().await.unwrap().text().await.unwrap(), "direct");
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    assert_eq!(two.client().unwrap().get("http://context.invalid/item").send().await.unwrap().text().await.unwrap(), "second");
}

#[tokio::test]
async fn context_preserves_builder_timeout_redirects_and_rejects_builder_errors() {
    let redirect = serve(|_| (axum::http::StatusCode::FOUND, [("location", "http://redirect.invalid/next")]).into_response()).await;
    let store = Arc::new(ProxyStore::new());
    custom(&store, &redirect.url);
    let context = CspHttpContext::new(|| reqwest::Client::builder().redirect(reqwest::redirect::Policy::none()));
    context.set_proxy(store.clone(), "redirect");
    assert_eq!(context.client().unwrap().get("http://redirect.invalid/start").send().await.unwrap().status(), 302);
    assert_eq!(redirect.hits.lock().unwrap().len(), 1);
    let invalid = CspHttpContext::new(|| reqwest::Client::builder().user_agent("bad\nheader"));
    invalid.set_proxy(store.clone(), "invalid-builder");
    assert!(invalid.client().is_err());
    assert_eq!(redirect.hits.lock().unwrap().len(), 1);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    custom(&store, &format!("http://{}", listener.local_addr().unwrap()));
    let slow = CspHttpContext::new(|| reqwest::Client::builder().timeout(Duration::from_millis(60)));
    slow.set_proxy(store, "short-timeout");
    let started = std::time::Instant::now();
    let error = tokio::time::timeout(Duration::from_secs(1), slow.client().unwrap().get("http://slow.invalid/item").send()).await.unwrap().unwrap_err();
    assert!(error.is_timeout());
    assert!(started.elapsed() < Duration::from_secs(1));
}


#[tokio::test]
async fn context_clear_releases_cached_route() {
    let proxy = serve(|_| "proxy".into_response()).await;
    let origin = serve(|_| "origin".into_response()).await;
    let store = Arc::new(ProxyStore::new());
    // A fresh synthetic key never overlaps an application credential entry.
    let provider = format!("proxy-clear-fixture-{}-{}", std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos());
    store.set(&provider, crate::proxy::ProxyConfig {
        mode: crate::proxy::ProxyMode::Custom,
        url: Some(proxy.url.clone()), ..Default::default()
    }).unwrap();
    let context = CspHttpContext::new(|| reqwest::Client::builder().timeout(Duration::from_secs(1)));
    context.set_proxy(store.clone(), &provider);
    assert_eq!(context.client().unwrap().get(&origin.url).send().await.unwrap().text().await.unwrap(), "proxy");
    assert!(origin.hits.lock().unwrap().is_empty());
    store.clear(&provider).unwrap();
    assert_eq!(context.client().unwrap().get(&origin.url).send().await.unwrap().text().await.unwrap(), "origin");
    assert_eq!(proxy.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
}
