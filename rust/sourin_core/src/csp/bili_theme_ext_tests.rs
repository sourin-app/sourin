//! Public object-ext directory contracts, exercised through real loopback HTTP.
//! The resource shape comes from the retained local reference, not a captured
//! response from the seven requested plain-URL ext resources. No account mode.
use super::*;
use crate::csp::bili::Bili;
use crate::csp::http_context::test_support::{custom, serve, Fixture, Request};
use crate::csp::CspSite;
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use md5::{Digest, Md5};
use serde_json::json;
use std::{collections::BTreeMap, time::{SystemTime, UNIX_EPOCH}};

const THEME_ID: &str = "fixture-opera + 合集";
const THEME_NAME: &str = "Fixture Opera";
const LEGACY_IDS: [&str; 16] = [
    "1", "3", "4", "5", "11", "13", "23", "36", "119", "129", "155", "160",
    "181", "188", "202", "211",
];

#[derive(Clone, Copy)]
enum DirectoryResponse {
    Valid,
    MalformedJson,
    InvalidCategory,
    Forbidden,
}

fn resource_response(kind: DirectoryResponse) -> axum::response::Response {
    match kind {
        DirectoryResponse::Valid => axum::Json(json!({
            "class": [
                {"type_id": THEME_ID, "type_name": THEME_NAME},
                {"type_id": "4", "type_name": "Numeric keyword theme"}
            ],
            "filters": {}
        })).into_response(),
        DirectoryResponse::MalformedJson => "<html>not a directory</html>".into_response(),
        DirectoryResponse::InvalidCategory => axum::Json(json!({
            "class": [{"type_id": THEME_ID}], "filters": {}
        })).into_response(),
        DirectoryResponse::Forbidden => (StatusCode::FORBIDDEN, "directory denied").into_response(),
    }
}

fn api_response(request: &Request) -> axum::response::Response {
    let body = match request.uri.path() {
        "/x/web-interface/ranking/v2" => json!({"code":0,"data":{"list":[
            {"bvid":"BVgeneral","title":"General ranking"}
        ]}}),
        "/x/web-interface/newlist" => json!({"code":0,"data":{
            "archives":[{"bvid":"BVnumeric","title":"Numeric region"}],
            "page":{"count":41,"size":20}
        }}),
        "/x/web-interface/nav" => json!({"code":-101,"data":{"wbi_img":{
            "img_url":"https://image.invalid/7cd084941338484aae1ad9425b84077c.png",
            "sub_url":"https://image.invalid/4932caff0ff746eab6f01bf08b70ac45.png"
        }}}),
        "/x/web-interface/wbi/search/type" => json!({"code":0,"data":{
            "result":[{"bvid":"BVtheme","title":"Themed result"}],
            "numResults":41,"numPages":3
        }}),
        _ => panic!("unexpected loopback API path"),
    };
    axum::Json(body).into_response()
}

struct ThemeFixture {
    origin: Fixture,
    proxy: Fixture,
    store: Arc<crate::proxy::ProxyStore>,
    ext: String,
}

impl ThemeFixture {
    async fn new(kind: DirectoryResponse) -> Self {
        let origin = serve(|_| panic!("configured proxy must not fall back to origin")).await;
        let proxy = serve(move |request| {
            if request.uri.path() == "/theme.json" {
                resource_response(kind)
            } else {
                api_response(&request)
            }
        }).await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &proxy.url);
        let ext = json!({"json":format!("{}/theme.json", origin.url)}).to_string();
        Self { origin, proxy, store, ext }
    }

    fn site(&self) -> Bili {
        let site = Bili::with_base(&self.origin.url);
        site.set_http_context(self.store.clone(), "bili-theme-fixture");
        site
    }

    fn restored_provider(&self, ext: &str) -> CspProvider {
        // Model the existing persisted category array at the real constructor
        // boundary. Replace only the API base so every request stays loopback;
        // the production engine, ext, provider identity and classes stay real.
        let saved_classes = json!(LEGACY_IDS.iter().map(|id| {
            json!({"id":id,"name":format!("Legacy general {id}")})
        }).collect::<Vec<_>>());
        let classes = serde_json::from_value::<Vec<TvboxCategoryEntry>>(saved_classes).unwrap();
        let mut provider = CspProvider::new(
            "bili-theme-restored", "Restored directory", "csp_Bili", ext,
            classes, true, true,
        ).unwrap();
        provider.site = Arc::new(Bili::with_base(&self.origin.url));
        provider.with_proxy(self.store.clone())
    }

    fn assert_public_proxy_only(&self) {
        assert!(self.origin.hits.lock().unwrap().is_empty(), "no direct origin request");
        for hit in self.proxy.hits.lock().unwrap().iter() {
            assert_eq!(hit.method, Method::GET);
            assert_eq!(hit.uri.scheme_str(), Some("http"), "actual request must traverse the loopback proxy");
            assert!(hit.headers.get("cookie").is_none(), "no account cookie");
            assert!(hit.headers.get("authorization").is_none(), "no authorization header");
        }
    }

    fn assert_directory_only(&self) {
        self.assert_public_proxy_only();
        let hits = self.proxy.hits.lock().unwrap();
        assert_eq!(hits.len(), 1, "one declared resource read, without general-catalog fallback");
        assert_eq!(hits[0].uri.path(), "/theme.json");
    }
}

fn query_fields(hit: &Request) -> BTreeMap<String, String> {
    let url = reqwest::Url::parse(&hit.uri.to_string()).unwrap();
    url.query_pairs().into_owned().collect()
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

fn assert_keyword_request(hit: &Request, keyword: &str, page: u32, started: u64) {
    assert_eq!(hit.uri.path(), "/x/web-interface/wbi/search/type");
    let fields = query_fields(hit);
    assert_eq!(fields.get("keyword").map(String::as_str), Some(keyword));
    assert_eq!(fields.get("page"), Some(&page.to_string()));
    assert_eq!(fields.get("search_type").map(String::as_str), Some("video"));
    assert_eq!(fields.get("order").map(String::as_str), Some("totalrank"));
    assert_eq!(fields.get("duration").map(String::as_str), Some("0"));
    assert_eq!(fields.len(), 7, "only the declared search fields plus WBI timestamp/signature");
    let seconds = fields.get("wts").unwrap().parse::<u64>().unwrap();
    assert!((started..=now_secs()).contains(&seconds));
    let query = hit.uri.query().unwrap();
    let unsigned_pairs = query.split('&').filter(|pair| !pair.starts_with("w_rid=")).collect::<Vec<_>>();
    let mut sorted = unsigned_pairs.clone();
    sorted.sort_unstable();
    assert_eq!(unsigned_pairs, sorted, "actual query must have canonical key order");
    // Independent known image/mixin vector; never call the production signer.
    let expected = format!("{:x}", Md5::digest(format!(
        "{}ea1db124af3c7062474693fa704f4ff8", sorted.join("&")
    ).as_bytes()));
    assert_eq!(fields.get("w_rid"), Some(&expected));
}

#[tokio::test]
async fn bili_theme_ext_home_gets_declared_object_resource_and_exact_classes() {
    let fixture = ThemeFixture::new(DirectoryResponse::Valid).await;
    let home = fixture.site().home(&fixture.ext).await.unwrap();
    assert_eq!(home.categories.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), [THEME_ID, "4"]);
    assert_eq!(home.categories[0].name, THEME_NAME);
    assert!(home.items.is_empty(), "directory mode must not add unrelated global ranking items");
    fixture.assert_directory_only();
}

#[tokio::test]
async fn bili_theme_ext_text_category_uses_real_signed_keyword_defaults_and_page() {
    let fixture = ThemeFixture::new(DirectoryResponse::Valid).await;
    let started = now_secs();
    let page = fixture.site().list(THEME_ID, 2, &fixture.ext).await.unwrap();
    fixture.assert_public_proxy_only();
    let hits = fixture.proxy.hits.lock().unwrap();
    assert!(hits.iter().any(|h| h.uri.path() == "/theme.json"), "list must use the declared directory mode");
    assert!(!hits.iter().any(|h| h.uri.path().contains("newlist") || h.uri.path().contains("ranking")));
    let search = hits.iter().find(|h| h.uri.path() == "/x/web-interface/wbi/search/type")
        .expect("category must issue a real keyword request");
    assert!(hits.iter().any(|h| h.uri.path() == "/x/web-interface/nav"), "signature needs the real fixture nav response");
    assert_keyword_request(search, THEME_ID, 2, started);
    assert_eq!(page.items[0].id, "BVtheme");
    assert_eq!(page.page, 2);
    assert_eq!(page.page_count, Some(3));
    assert_eq!(page.total, Some(41));
}

#[tokio::test]
async fn bili_theme_ext_numeric_category_is_still_a_keyword_in_declared_mode() {
    let fixture = ThemeFixture::new(DirectoryResponse::Valid).await;
    let started = now_secs();
    let page = fixture.site().list("4", 1, &fixture.ext).await.unwrap();
    fixture.assert_public_proxy_only();
    let hits = fixture.proxy.hits.lock().unwrap();
    assert!(!hits.iter().any(|h| h.uri.path().contains("newlist")), "mode belongs to the recipe, not category-id shape");
    let search = hits.iter().find(|h| h.uri.path() == "/x/web-interface/wbi/search/type")
        .expect("numeric theme id must remain a keyword");
    assert_keyword_request(search, "4", 1, started);
    assert_eq!(page.items[0].id, "BVtheme");
}

async fn assert_directory_rejected(kind: DirectoryResponse) {
    let fixture = ThemeFixture::new(kind).await;
    let result = fixture.site().home(&fixture.ext).await;
    assert!(result.is_err(), "invalid or denied declared directory must not become the general catalog");
    fixture.assert_directory_only();
}

#[tokio::test]
async fn bili_theme_ext_malformed_json_cannot_fall_back_to_general_ranking() {
    assert_directory_rejected(DirectoryResponse::MalformedJson).await;
}

#[tokio::test]
async fn bili_theme_ext_missing_category_name_cannot_fall_back_to_general_ranking() {
    assert_directory_rejected(DirectoryResponse::InvalidCategory).await;
}

#[tokio::test]
async fn bili_theme_ext_http_denial_cannot_fall_back_to_general_ranking() {
    let fixture = ThemeFixture::new(DirectoryResponse::Forbidden).await;
    let result = fixture.site().home(&fixture.ext).await;
    assert!(result.is_err(), "access rejection must remain a failure");
    assert!(result.err().unwrap().contains("403"), "retain actual access-denial status");
    fixture.assert_directory_only();
}

#[tokio::test]
async fn bili_theme_ext_restored_categories_replace_stale_persisted_general_classes() {
    let fixture = ThemeFixture::new(DirectoryResponse::Valid).await;
    let provider = fixture.restored_provider(&fixture.ext);
    let categories = provider.categories().await.unwrap();
    assert_eq!(categories.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), [THEME_ID, "4"]);
    fixture.assert_directory_only();
}

#[tokio::test]
async fn bili_theme_ext_restored_home_replaces_stale_persisted_general_sections() {
    let fixture = ThemeFixture::new(DirectoryResponse::Valid).await;
    let provider = fixture.restored_provider(&fixture.ext);
    let sections = provider.home().await.unwrap();
    assert_eq!(sections.iter().map(|s| s.title.as_str()).collect::<Vec<_>>(), [THEME_NAME, "Numeric keyword theme"]);
    fixture.assert_directory_only();
}

#[tokio::test]
async fn bili_theme_ext_restored_denial_cannot_hide_behind_persisted_general_classes() {
    let fixture = ThemeFixture::new(DirectoryResponse::Forbidden).await;
    let provider = fixture.restored_provider(&fixture.ext);
    assert!(provider.categories().await.is_err(), "stale general classes are not authority for an explicit theme");
    fixture.assert_directory_only();
}

#[tokio::test]
async fn bili_theme_ext_control_empty_ext_keeps_numeric_region_recipe() {
    let fixture = ThemeFixture::new(DirectoryResponse::Valid).await;
    let page = fixture.site().list("4", 2, "").await.unwrap();
    assert_eq!(page.items[0].id, "BVnumeric");
    assert_eq!(page.page_count, Some(3));
    fixture.assert_public_proxy_only();
    let hits = fixture.proxy.hits.lock().unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].uri.path(), "/x/web-interface/newlist");
    let fields = query_fields(&hits[0]);
    assert_eq!(fields.get("rid").map(String::as_str), Some("4"));
    assert_eq!(fields.get("pn").map(String::as_str), Some("2"));
}

#[tokio::test]
async fn bili_theme_ext_control_empty_ext_restores_persisted_classes_without_network() {
    let fixture = ThemeFixture::new(DirectoryResponse::Valid).await;
    let provider = fixture.restored_provider("");
    let categories = provider.categories().await.unwrap();
    assert_eq!(categories.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), LEGACY_IDS);
    assert!(fixture.proxy.hits.lock().unwrap().is_empty(), "ordinary persisted classes still avoid a source read");
    fixture.assert_public_proxy_only();
}
