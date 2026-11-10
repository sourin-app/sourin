use super::*;
use crate::csp::http_context::test_support::{custom, serve, Fixture};
use crate::{model::MediaId, provider::MediaProvider};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{collections::BTreeMap, sync::Arc};

const ITEM: &str = "private-item-canary";
const PRIVATE_PATH: &str = "/private-endpoint-canary";
const PRIVATE_BODY: &str = "body-canary https://body.invalid/e?token=query-canary";

struct RejectedDetail {
    origin: Fixture,
    rejection: Fixture,
    site: Arc<AppRJ>,
    base: String,
    ext: String,
    started_at: u64,
}

impl RejectedDetail {
    async fn new(status: StatusCode) -> Self {
        let origin = serve(|_| panic!("HTTP rejection must not fall back to origin")).await;
        let rejection = serve(move |_| (status, PRIVATE_BODY).into_response()).await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &rejection.url);
        let site = Arc::new(AppRJ::new());
        site.set_http_context(store, "app-rj-error-fixture");
        let base = format!("{}{PRIVATE_PATH}", origin.url);
        let ext = serde_json::json!({"url": base}).to_string();
        Self { origin, rejection, site, base, ext, started_at: ts_secs() }
    }

    fn assert_one_signed_detail_request(&self) {
        assert!(self.origin.hits.lock().unwrap().is_empty(), "no origin fallback");
        let hits = self.rejection.hits.lock().unwrap();
        assert_eq!(hits.len(), 1, "one actual detail request, without retry");
        let hit = &hits[0];
        assert_eq!(hit.method, Method::POST);
        assert_eq!(hit.uri.path(), format!("{PRIVATE_PATH}{P_VOD_DETAILS}"));
        assert!(hit.uri.query().is_none());
        assert!(hit.headers["user-agent"] == APP_UA);
        assert!(hit.headers["referer"] == format!("{}/", self.base));
        assert_eq!(hit.headers["content-type"], "application/x-www-form-urlencoded");
        let raw = std::str::from_utf8(&hit.body).unwrap();
        let parsed = reqwest::Url::parse(&format!("http://form.invalid/?{raw}")).unwrap();
        let form: BTreeMap<String, String> = parsed.query_pairs().into_owned().collect();
        assert_eq!(raw.split('&').count(), 3, "detail identity plus signature fields");
        assert_eq!(form.len(), 3, "no duplicate or extra fields");
        assert!(form.get("vod_id").is_some_and(|value| value == ITEM));
        let timestamp = form.get("timestamp").expect("actual timestamp form field");
        let seconds = timestamp.parse::<u64>().unwrap();
        assert!((self.started_at..=ts_secs()).contains(&seconds));
        assert!(form.get("sign").is_some_and(|value| value == &sign_of(timestamp)));
    }
}

fn assert_private_details_are_absent(message: &str, fixture: &RejectedDetail) {
    // Never print the rejected message: the regression includes signing material.
    assert!(!message.contains(SIGN_KEY), "public error must omit source signing material");
    assert!(!message.contains(&fixture.base), "public error must omit the request address");
    assert!(!message.contains(PRIVATE_PATH), "public error must omit the configured endpoint");
    assert!(!message.contains(P_VOD_DETAILS), "public error must omit the API path");
    assert!(!message.contains(ITEM), "public error must omit request form values");
    let lower = message.to_ascii_lowercase();
    assert!(!lower.contains("http://") && !lower.contains("https://"), "public error must omit URLs");
    assert!(!lower.contains("body-canary"), "public error must omit response bodies");
    assert!(!lower.contains("query-canary") && !lower.contains("token="), "public error must omit query values");
    assert!(!lower.contains("405") && !lower.contains("sign error"), "502 must not include a historical signature failure");
    assert!(!lower.contains("md5") && !message.contains("签名"), "public error must omit signing recipes");
    assert!(!message.contains("实测") && !message.contains("端点存在") && !message.contains("路径变了"),
        "public error must not invent a diagnosis from historical debug notes");
}

fn assert_actionable_502(message: &str, fixture: &RejectedDetail) {
    assert!(message.contains("HTTP 502"), "public error must retain the actual HTTP status");
    assert_private_details_are_absent(message, fixture);
    assert!(["重试", "稍后再试", "切换", "换源"].iter().any(|action| message.contains(action)),
        "public error must provide a next action without guessing the cause");
}

#[tokio::test]
async fn app_rj_detail_http_502_is_actionable_and_omits_private_debug_text() {
    let fixture = RejectedDetail::new(StatusCode::BAD_GATEWAY).await;
    let error = fixture.site.detail(ITEM, &fixture.ext).await.expect_err("real HTTP 502 must reject detail");
    fixture.assert_one_signed_detail_request();
    assert_actionable_502(&error, &fixture);
}

#[tokio::test]
async fn app_rj_provider_detail_http_502_preserves_the_safe_public_message() {
    let fixture = RejectedDetail::new(StatusCode::BAD_GATEWAY).await;
    let provider = crate::csp::provider::CspProvider::for_test(
        "app-rj-error-fixture", fixture.site.clone(), &fixture.ext,
    );
    let error = provider.detail(&MediaId::new("app-rj-error-fixture", ITEM)).await
        .expect_err("the provider must preserve actual detail failure");
    fixture.assert_one_signed_detail_request();
    assert!(!error.needs_login && error.login_kind.is_none(), "502 must not request an account login");
    assert_actionable_502(&error.message, &fixture);
}

async fn assert_access_denial(status: StatusCode) {
    let fixture = RejectedDetail::new(status).await;
    let error = fixture.site.detail(ITEM, &fixture.ext).await.expect_err("access denial must reject detail");
    fixture.assert_one_signed_detail_request();
    assert!(error.contains(&format!("HTTP {}", status.as_u16())), "access denial must retain the actual status");
    assert!(!error.contains("HTTP 502"), "access denial must not become a gateway failure");
    assert!(!error.contains("重试") && !error.contains("稍后再试"), "access denial must not advise retrying the same denied request");
}

#[tokio::test]
async fn app_rj_detail_http_401_remains_access_denial_without_retry_or_fallback() {
    assert_access_denial(StatusCode::UNAUTHORIZED).await;
}

#[tokio::test]
async fn app_rj_detail_http_403_remains_access_denial_without_retry_or_fallback() {
    assert_access_denial(StatusCode::FORBIDDEN).await;
}
