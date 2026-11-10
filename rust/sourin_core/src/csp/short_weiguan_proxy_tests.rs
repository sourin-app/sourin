use super::*;
#[path = "catalog_proxy_test_support.rs"]
mod catalog_proxy_test_support;
use catalog_proxy_test_support::FixtureSite;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::{provider::ListRequest, state::AppState};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{io::Write, sync::Arc, time::Duration};

#[derive(Clone, Copy)]
enum Entry { Home, List }

fn headers(r: &Request) {
    assert_eq!(r.headers["user-agent"], "okhttp/5.1.0");
    assert_eq!(r.headers["accept"], "application/json, text/plain, */*");
    assert!(!r.headers.contains_key("cookie")); assert!(!r.headers.contains_key("authorization"));
}

#[async_trait::async_trait]
impl FixtureSite for ShortWeiguan {
    async fn fetch(&self, url: &str) -> Result<String, String> { self.get(url).await }
    fn assert_headers(r: &Request) { headers(r); }
}

// The oracle uses the MD5 crate directly, without device_query/identity or the
// production md5_hex wrapper. Field order and constant values are explicit.
fn identity_query(q: &str) {
    use md5::{Digest, Md5};
    let pairs: Vec<_> = q.split('&').map(|part| part.split_once('=').unwrap()).collect();
    let names: Vec<_> = pairs.iter().map(|(key, _)| *key).collect();
    assert_eq!(names, ["version_code", "version_name", "device_name", "device_type", "is_first_day",
        "is_first_24h", "app_launch_way", "default_homepage", "device_owning_firm", "font_scale", "os_type", "clientInfo"]);
    for (index, value) in [(0,"1600"),(1,"1.6.0"),(3,"phone"),(4,"true"),(5,"true"),(6,"icon"),
        (7,"homepage_interaction"),(9,"default"),(10,"1")] { assert_eq!(pairs[index].1, value); }
    for index in [2, 8] {
        assert_eq!(pairs[index].1.len(), 16);
        assert!(pairs[index].1.bytes().all(|b| b.is_ascii_alphanumeric()));
    }
    assert_eq!(pairs[11].1, format!("{:x}", Md5::digest(pairs[2].1.as_bytes())));
}

fn request(r: &Request, entry: Entry) {
    headers(r); identity_query(r.uri.query().unwrap());
    if r.method == Method::GET {
        assert!(matches!(entry, Entry::Home)); assert_eq!(r.uri.path(), "/drama/home/shortVideoTags");
        assert!(r.body.is_empty()); assert!(!r.headers.contains_key("content-type"));
    } else {
        assert_eq!(r.method, Method::POST);
        assert!(matches!(r.uri.path(), "/drama/home/search" | "/landed"));
        assert_eq!(r.headers["content-type"], "application/json; charset=utf-8");
        let expected: &[u8] = match entry {
            Entry::Home => br#"{"audience":"","cateId":"","order":"","page":1,"pageSize":20,"searchWord":"","subject":""}"#,
            Entry::List => br#"{"audience":"","cateId":"7","order":"","page":1,"pageSize":20,"searchWord":"","subject":""}"#,
        };
        assert_eq!(r.body.as_ref(), expected);
    }
}

const TAGS: &str = r#"{"code":200,"tags":["fixture"]}"#;

fn payload(label: &str) -> String {
    serde_json::json!({"code":200,"data":[{"oneId":"71","title":label,"episodeCount":1}]}).to_string()
}

fn normal(r: Request, entry: Entry, label: &str) -> axum::response::Response {
    request(&r, entry);
    if r.method == Method::GET { TAGS.into_response() } else { payload(label).into_response() }
}

async fn fetch(site: &ShortWeiguan, base: &str, entry: Entry) -> Result<String, String> {
    tokio::time::timeout(Duration::from_secs(3), async {
        let items = match entry {
            Entry::Home => { let home = site.home(base).await?; assert_eq!(home.categories.len(), 1); home.items }
            Entry::List => { let page = site.list(" 7 ", 0, base).await?; assert_eq!(page.page, 1); page.items }
        };
        assert_eq!(items.len(), 1); Ok(items[0].title.clone())
    }).await.expect("loopback ShortWeiguan request exceeded fixture budget")
}

fn pair_queries(hits: &[Request], entry: Entry) {
    if let Entry::Home = entry {
        assert_eq!(hits[0].method, Method::GET); assert_eq!(hits[1].method, Method::POST);
        assert_eq!(hits[0].uri.query(), hits[1].uri.query(), "home tags and POST share one generated identity");
    }
}

async fn exercise(entry: Entry) {
    let origin = serve(move |r| normal(r, entry, "origin")).await;
    let first = serve(move |r| { assert_eq!(r.uri.scheme_str(), Some("http")); normal(r, entry, "first") }).await;
    let redirect_base = origin.url.clone();
    let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    gzip.write_all(payload("second").as_bytes()).unwrap(); let compressed = gzip.finish().unwrap();
    let second = serve(move |r| {
        request(&r, entry); assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.method == Method::GET { return TAGS.into_response(); }
        if r.uri.path() != "/landed" {
            let redirect = format!("{redirect_base}/landed?{}", r.uri.query().unwrap());
            (StatusCode::TEMPORARY_REDIRECT, [("location", redirect),
                ("set-cookie", "fixture=must-not-persist; Path=/".into())]).into_response()
        } else { ([("content-encoding", "gzip")], compressed.clone()).into_response() }
    }).await;
    let site = ShortWeiguan::new(); assert_eq!(fetch(&site, &origin.url, entry).await.unwrap(), "origin");
    let initial_hits = origin.hits.lock().unwrap().clone(); pair_queries(&initial_hits, entry);
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &first.url);
    site.set_http_context(store.clone(), "weiguan-loopback"); assert_eq!(fetch(&site, &origin.url, entry).await.unwrap(), "first");
    custom(&store, &second.url); assert_eq!(fetch(&site, &origin.url, entry).await.unwrap(), "second");
    let first_hits = first.hits.lock().unwrap().clone(); let second_hits = second.hits.lock().unwrap().clone();
    let count = match entry { Entry::Home => 2, Entry::List => 1 };
    assert_eq!(first_hits.len(), count); assert_eq!(second_hits.len(), count + 1);
    pair_queries(&first_hits, entry); pair_queries(&second_hits, entry);
    assert_ne!(initial_hits[0].uri.query(), first_hits[0].uri.query(), "later business calls keep their own generated identity");
    assert_ne!(first_hits[0].uri.query(), second_hits[0].uri.query());
    assert_eq!(second_hits[count - 1].body, second_hits[count].body);
    assert_eq!(second_hits[count - 1].uri.query(), second_hits[count].uri.query());
    let encoding = initial_hits[0].headers["accept-encoding"].clone(); assert!(encoding.to_str().unwrap().contains("gzip"));
    for r in first_hits.iter().chain(second_hits.iter()) { assert_eq!(r.headers["accept-encoding"], encoding); }
    // The existing embedded POSTs parse the body without inspecting HTTP
    // status. A proxy migration must not quietly change that business rule.
    let status_only = serve(move |r| {
        request(&r, entry);
        if r.method == Method::GET { TAGS.into_response() }
        else { (StatusCode::BAD_GATEWAY, payload("status tolerated")).into_response() }
    }).await;
    custom(&store, &status_only.url); assert_eq!(fetch(&site, &origin.url, entry).await.unwrap(), "status tolerated");
    for (body, error_part) in [("fixture invalid JSON", "不是 JSON"),
        (r#"{"code":500,"msg":"fixture blocked","data":null}"#, "code=500")] {
        let failed = serve(move |r| {
            request(&r, entry);
            if r.method == Method::GET { TAGS.into_response() } else { (StatusCode::BAD_GATEWAY, body).into_response() }
        }).await;
        custom(&store, &failed.url); assert!(fetch(&site, &origin.url, entry).await.unwrap_err().contains(error_part));
        assert_eq!(failed.hits.lock().unwrap().len(), count);
    }
    if let Entry::Home = entry {
        // Change policy after the tags response, before the separately-built
        // home POST. That actual send must acquire the new policy too.
        let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let unavailable = format!("http://{}", unused.local_addr().unwrap()); drop(unused);
        let switching_store = store.clone();
        let switching = serve(move |r| {
            request(&r, Entry::Home); assert_eq!(r.method, Method::GET);
            custom(&switching_store, &unavailable); TAGS.into_response()
        }).await;
        custom(&store, &switching.url);
        assert!(fetch(&site, &origin.url, entry).await.is_err());
        assert_eq!(switching.hits.lock().unwrap().len(), 1, "home POST cannot retain the tags request's old client");
    }
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    custom(&store, &format!("http://{}", unused.local_addr().unwrap())); drop(unused);
    assert!(fetch(&site, &origin.url, entry).await.is_err());
    assert_eq!(origin.hits.lock().unwrap().len(), count, "errors cannot retry directly");
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(fetch(&site, &origin.url, entry).await.unwrap(), "origin");
    assert_eq!(origin.hits.lock().unwrap().len(), count * 2);
}

#[tokio::test]
async fn catalog_proxy_shortweiguan_home_get_and_post_share_identity_and_current_policy() { exercise(Entry::Home).await; }

#[tokio::test]
async fn catalog_proxy_shortweiguan_list_post_keeps_exact_body_and_status_semantics() { exercise(Entry::List).await; }

#[tokio::test]
async fn catalog_proxy_shortweiguan_get_and_public_detail_keep_headers_and_query() {
    catalog_proxy_test_support::exercise(ShortWeiguan::new()).await;
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let proxy = serve(|r| {
        headers(&r); assert_eq!(r.method, Method::GET); assert!(r.body.is_empty());
        assert_eq!(r.uri.scheme_str(), Some("http")); assert_eq!(r.uri.path(), "/drama/home/shortVideoDetail");
        let (identity, suffix) = r.uri.query().unwrap().split_once("&oneId=").unwrap(); identity_query(identity);
        assert_eq!(suffix, "71%20%2B%26%2F&page=1&pageSize=1000&userId=0&queryAll=true");
        r#"{"code":200,"title":"detail fixture","data":[{"playOrder":1,"videoClarityList":[{"name":"fixture","url":"http://127.0.0.1/fixture-media.mp4"}]}]}"#.into_response()
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &proxy.url);
    let site = ShortWeiguan::new(); site.set_http_context(store, "weiguan-detail");
    let detail = tokio::time::timeout(Duration::from_secs(3), site.detail(" 71 +&/ ", &origin.url)).await.unwrap().unwrap();
    assert_eq!(detail.title, "detail fixture"); assert_eq!(detail.episodes.len(), 1);
    assert_eq!(detail.episodes[0].id, "http://127.0.0.1/fixture-media.mp4");
    assert_eq!(proxy.hits.lock().unwrap().len(), 1); assert!(origin.hits.lock().unwrap().is_empty());
}

async fn runtime_list(state: &AppState, id: &str, label: &str) {
    let provider = state.registry.get(id).unwrap();
    let page = tokio::time::timeout(Duration::from_secs(3), provider.list(ListRequest {
        category_id:"7".into(), page:1, ..Default::default()
    })).await.expect("loopback ShortWeiguan factory list exceeded fixture budget").unwrap();
    assert_eq!(page.items.len(), 1); assert_eq!(page.items[0].title, label);
}

#[tokio::test]
async fn catalog_proxy_shortweiguan_import_home_runtime_hot_change_and_restore() {
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let subscription = serde_json::json!({"sites":[{"key":"weiguan-local","name":"Weiguan local",
        "type":3,"api":"csp_ShortWeiguan","ext":{"host":origin.url}}]});
    let first = serve(move |r| {
        assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.uri.path() == "/subscription.json" { return axum::Json(subscription.clone()).into_response(); }
        let is_home = r.method == Method::GET || r.body.as_ref() == br#"{"audience":"","cateId":"","order":"","page":1,"pageSize":20,"searchWord":"","subject":""}"#;
        normal(r, if is_home { Entry::Home } else { Entry::List }, "first")
    }).await;
    let second = serve(|r| { assert_eq!(r.uri.scheme_str(), Some("http")); normal(r, Entry::List, "second") }).await;
    let dir = scratch("weiguan-proxy-factories"); let state = AppState::bootstrap(dir.clone()).await.unwrap(); custom(&state.proxy, &first.url);
    let report = tokio::time::timeout(Duration::from_secs(5), crate::tvbox::import_tvbox_config(
        &state, &format!("{}/subscription.json", origin.url)
    )).await.expect("loopback ShortWeiguan import exceeded fixture budget").unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let rows = report["imported"].as_array().unwrap(); assert_eq!(rows.len(), 1, "{report}");
    let row = &rows[0]; assert_eq!(row["categories"], 1); assert_eq!(row["persisted"], true); assert!(row["probeFailed"].is_null(), "{row}");
    let id = row["id"].as_str().unwrap().to_string(); runtime_list(&state, &id, "first").await;
    let first_hits = first.hits.lock().unwrap().clone(); assert_eq!(first_hits.len(), 4);
    pair_queries(&first_hits[1..3], Entry::Home);
    custom(&state.proxy, &second.url); runtime_list(&state, &id, "second").await;
    drop(state); let restored = AppState::bootstrap(dir.clone()).await.unwrap(); runtime_list(&restored, &id, "second").await;
    assert_eq!(second.hits.lock().unwrap().len(), 2); assert!(origin.hits.lock().unwrap().is_empty());
    drop(restored); let _ = std::fs::remove_dir_all(dir);
}
