use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::response::IntoResponse;
use std::collections::BTreeMap;

fn form_fields(hit: &Request, start: u64, end: u64) -> BTreeMap<String, String> {
    assert_eq!(hit.method, axum::http::Method::POST);
    assert_eq!(hit.headers["user-agent"], APP_UA);
    assert_eq!(hit.headers["referer"], "http://apprj-fixture.invalid/");
    assert_eq!(hit.headers["content-type"], "application/x-www-form-urlencoded");
    assert_eq!(hit.uri.host(), Some("apprj-fixture.invalid"));
    let raw = std::str::from_utf8(&hit.body).unwrap();
    // URL query parsing decodes the same percent escapes and '+' spaces as
    // the form media type, without adding a dependency just for this fixture.
    let parsed = reqwest::Url::parse(&format!("http://form.invalid/?{raw}")).unwrap();
    let mut form: BTreeMap<String, String> = parsed.query_pairs().into_owned().collect();
    assert_eq!(form.len(), raw.split('&').count(), "no duplicate form keys");
    let timestamp = form.remove("timestamp").unwrap();
    let seconds: u64 = timestamp.parse().unwrap();
    assert!((start..=end).contains(&seconds), "timestamp must remain seconds");
    assert_eq!(form.remove("sign").unwrap(), sign_of(&timestamp));
    form
}

#[tokio::test]
async fn app_rj_keeps_signed_post_forms_across_proxy_changes_and_failure() {
    let make = |label: &'static str| move |_| axum::Json(serde_json::json!({
        "code":1,"data":{"list":[{"vod_id":123,"vod_name":label}]}
    })).into_response();
    let first = serve(make("first")).await;
    let second = serve(make("second")).await;
    let store = std::sync::Arc::new(crate::proxy::ProxyStore::new());
    let site = AppRJ::new();
    site.set_http_context(store.clone(), "apprj-fixture");
    let ext = r#"{"url":"http://apprj-fixture.invalid/"}"#;
    let start = ts_secs();
    custom(&store, &first.url);
    assert_eq!(site.list(" 2 ", 3, ext).await.unwrap().items[0].title, "first");
    custom(&store, &second.url);
    assert_eq!(site.search("测试 + & =", 4, ext).await.unwrap().items[0].title, "second");
    assert_eq!(site.home(ext).await.unwrap().items[0].title, "second");
    let end = ts_secs();
    {
        let hits = first.hits.lock().unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].uri.path(), P_TYPE_SEARCH);
        assert_eq!(form_fields(&hits[0], start, end), BTreeMap::from([
            ("type_id".into(), "2".into()), ("page".into(), "3".into()),
            ("limit".into(), "12".into()), ("area".into(), String::new()),
            ("lang".into(), String::new()), ("class".into(), String::new()),
            ("year".into(), String::new()), ("extend".into(), String::new()),
        ]));
    }
    {
        let hits = second.hits.lock().unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].uri.path(), P_SEARCH);
        assert_eq!(form_fields(&hits[0], start, end), BTreeMap::from([
            ("keyword".into(), "测试 + & =".into()), ("page".into(), "4".into()),
        ]));
        assert_eq!(hits[1].uri.path(), P_TOP_TYPE);
        assert!(form_fields(&hits[1], start, end).is_empty());
    }

    let direct = serve(make("direct")).await;
    let rejected = serve(|_| axum::http::StatusCode::BAD_GATEWAY.into_response()).await;
    custom(&store, &rejected.url);
    assert!(site.list("1", 1, &direct.url).await.unwrap_err().contains("502"));
    let home = site.home(&direct.url).await.unwrap();
    assert_eq!(home.categories.len(), 5);
    assert!(home.items.is_empty());
    assert!(direct.hits.lock().unwrap().is_empty());
    assert_eq!(rejected.hits.lock().unwrap().len(), 2, "HTTP failures must not retry or fall back");
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(site.list("1", 1, &direct.url).await.unwrap().items[0].title, "direct");
    assert_eq!(direct.hits.lock().unwrap().len(), 1);
}
