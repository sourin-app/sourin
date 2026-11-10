use super::*;
use crate::csp::{CspSite, http_context::test_support::{custom, serve, Request}};
use axum::response::IntoResponse;
use std::sync::{Arc, Mutex};

const PLAYBACK_ORIGIN: &str = "http://anonymous-playback-fixture.invalid";

#[test]
fn declared_media_query_policy_is_source_local_and_honors_explicit_disable() {
    let source = Hxq::new();
    let url = "https://voldn-ser01.51touxiang.com/m3u8/fixture.m3u8?pid=fixture&sign=issued%2f";
    for ext in ["", "{}", r#"{"use_proxy":true}"#, r#"{"use_proxy":1}"#] {
        assert!(source.hls_query_policy(url, ext).is_some());
    }
    for ext in [r#"{"use_proxy":false}"#, r#"{"use_proxy":0}"#, r#"{"use_proxy":"0"}"#,
        r#"{"use_proxy":"FALSE"}"#] {
        assert!(source.hls_query_policy(url, ext).is_none());
    }
    for url in ["https://media.invalid/m3u8/fixture.m3u8", "https://voldn-ser01.51touxiang.com/video/a.mp4",
        "http://voldn-ser01.51touxiang.com/m3u8/fixture.m3u8", "https://voldn-ser01.51touxiang.com:444/m3u8/a.m3u8"] {
        assert!(source.hls_query_policy(url, "").is_none());
    }
}

fn session() -> Session {
    Session { uid: "syntheticUser12345678".into(), said: "0123456789abcdef".into(),
        advertising: "fedcba9876543210".into(), installed: 1793062600000 }
}

fn encrypted_candidate(session: &Session, url: &str) -> Value {
    let key = md5(&format!("{}{ENVELOPE_SALT}", session.key()));
    let data = encrypt(&json!({"playUrl":url,"header":{"User-Agent":"FixtureMediaUA"}}).to_string(),
        &key.as_bytes()[..16], &key.as_bytes()[16..]).unwrap();
    json!({"rescode":0,"datas":[{"data":data}]})
}

#[test]
fn normalization_candidates_apply_reference_media_origin_and_keep_raw_query() {
    let session = session();
    let query = "sign=synthetic%2bkeep%2Fraw&repeated=one&repeated=two&empty=&plus=a+b";
    let input = format!("http://legacy.51touxiang.com/m3u8/fixture_media?{query}");
    let plays = session.candidates(&encrypted_candidate(&session, &input)).unwrap();
    assert_eq!(plays[0].url, format!("https://voldn-ser01.51touxiang.com/m3u8/fixture_media.m3u8?{query}"));
    assert_eq!(plays[0].headers, vec![("User-Agent".into(), "FixtureMediaUA".into())]);
}

#[test]
fn normalization_candidates_accept_reference_relative_and_bare_media_forms() {
    let session = session();
    for (input, expected) in [
        ("/m3u8/fixture_media?x=keep%2Braw", "https://voldn-ser01.51touxiang.com/m3u8/fixture_media.m3u8?x=keep%2Braw"),
        ("/video/fixture_media.mp4?x=keep+raw", "https://voldn-ser01.51touxiang.com/video/fixture_media.mp4?x=keep+raw"),
        ("fixture_media_1234567890", "https://voldn-ser01.51touxiang.com/m3u8/fixture_media_1234567890.m3u8"),
    ] {
        let plays = session.candidates(&encrypted_candidate(&session, input)).unwrap();
        assert_eq!(plays[0].url, expected);
    }
}

#[test]
fn normalization_candidates_leave_unrelated_hosts_and_nonmedia_paths_unchanged() {
    let session = session();
    for input in [
        "http://media.invalid/video/fixture.mp4?sign=synthetic%2braw",
        "https://media.invalid/m3u8/fixture_media.m3u8?x=a+b&x=c",
        "http://legacy.51touxiang.com/catalog/item?sign=synthetic%2braw",
    ] {
        let plays = session.candidates(&encrypted_candidate(&session, input)).unwrap();
        assert_eq!(plays[0].url, input, "reference normalization must not rewrite an unrelated/nonmedia route");
    }
    for input in ["file:///private/movie.mp4", "https://user:password@media.invalid/video/a.mp4", "/catalog/not-a-media-route"] {
        assert!(session.candidates(&encrypted_candidate(&session, input)).is_err());
    }
}

#[test]
fn query_and_envelope_match_independent_protocol_fixtures() {
    let session = session();
    let query = session.query("selected_pid", "selected_scid", 1794272200000, &"a".repeat(32));
    let parsed = reqwest::Url::parse(&format!("http://fixture.invalid/?{query}")).unwrap();
    let fields = parsed.query_pairs().collect::<std::collections::HashMap<_, _>>();
    assert_eq!(fields.get("pid").unwrap(), "selected_pid");
    assert_eq!(fields.get("scid").unwrap(), "selected_scid");
    assert_eq!(fields.get("sign").unwrap(), "7f5e7fef900ee72d6ead0acb8585f919");
    assert!(!fields.contains_key("udid"), "udid participates in signing, not the transmitted query");
    // Generated independently with Python cryptography from the documented DEX contract.
    let fixture = json!({"ts":1794272200000u64,"data":"2LGVw3fAQEBDRVWoYMs/pZD1rYvlmOtk7JetRY1sS6Sg27uG54qEHGzOv90zUwpeq6OjZXAQtMYERLbzX3XFuLUfp24ApnvHKShtciHfUmRSzKuwpdGA3ZnjL9YPk1ywZuv9Zb1wltxwDLGiRr1gZQ=="});
    let decrypted = session.envelope(fixture).unwrap();
    assert_eq!(decrypted["playItem"]["pid"], "selected_pid");
    assert_eq!(decrypted["playItem"]["sources"][0]["scid"], "selected_scid");
}

fn device(request: &Request) -> (String, Value) {
    assert_eq!(request.method, axum::http::Method::GET);
    assert_eq!(request.uri.scheme_str(), Some("http"));
    assert_eq!(request.uri.host(), Some("anonymous-playback-fixture.invalid"));
    assert_eq!(request.headers["user-agent"], DEVICE_UA);
    assert_eq!(request.headers.get_all("user-agent").iter().count(), 1,
        "the origin GET must carry exactly one device User-Agent");
    assert_eq!(request.headers["vc"], "a_8350");
    assert_eq!(request.headers["vn"], VERSION);
    assert_eq!(request.headers["ch"], "qq");
    assert_eq!(request.headers["app"], "hj");
    assert!(!request.headers.contains_key("auth-token"));
    assert!(!request.headers.contains_key("auth-uid"));
    assert!(!request.headers.contains_key("cookie"));
    let uid = decrypt(request.headers["uk"].to_str().unwrap(), b"f349wghhe784tqwh", b"d3w8hf94fidk38lk").unwrap();
    let key = md5(&uid);
    let signed = decrypt(request.headers["sign"].to_str().unwrap(), &key.as_bytes()[..16], &key.as_bytes()[16..]).unwrap();
    let object: Value = serde_json::from_str(&signed).unwrap();
    assert_eq!(object["uid"], uid);
    assert_eq!(object["ai"], request.headers["said"].to_str().unwrap());
    (uid, object)
}

#[tokio::test]
async fn anonymous_playback_preserves_pid_session_and_decrypts_actual_http_responses() {
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let observed = seen.clone();
    let fixture = serve(move |request| {
        let (uid, _) = device(&request);
        observed.lock().unwrap().push(uid.clone());
        match request.uri.path() {
            "/api/common/configs" => axum::Json(json!({"rescode":0})).into_response(),
            "/api/series2/episode/detail" => {
                let parsed = reqwest::Url::parse(&request.uri.to_string()).unwrap();
                let fields = parsed.query_pairs().collect::<std::collections::HashMap<_, _>>();
                assert_eq!(fields.get("pid").unwrap(), "selected_pid");
                let key = md5(&format!("{}{ENVELOPE_SALT}", md5(&format!("{uid}1794272200000"))));
                let data = encrypt(&json!({"playItem":{"pid":"selected_pid","permission":{"allowPlay":1},"sources":[{"scid":"selected_scid"}]}}).to_string(),
                    &key.as_bytes()[..16], &key.as_bytes()[16..]).unwrap();
                axum::Json(json!({"rescode":0,"ts":1794272200000u64,"data":data})).into_response()
            }
            "/api/series/rslvV4" => {
                let parsed = reqwest::Url::parse(&request.uri.to_string()).unwrap();
                let fields = parsed.query_pairs().collect::<std::collections::BTreeMap<_, _>>();
                assert_eq!(fields.get("pid").unwrap(), "selected_pid");
                assert_eq!(fields.get("scid").unwrap(), "selected_scid");
                assert!(!fields.contains_key("udid"));
                let key = md5(&format!("{}{ENVELOPE_SALT}", md5(&uid)));
                let data = encrypt(&json!({"playUrl":"https://media.invalid/selected.m3u8?sign=keep%2Bthis", "header":{"User-Agent":MEDIA_UA,"Referer":"https://catalog.invalid/"}}).to_string(),
                    &key.as_bytes()[..16], &key.as_bytes()[16..]).unwrap();
                axum::Json(json!({"rescode":0,"datas":[{"data":data}]})).into_response()
            }
            _ => panic!("unexpected request"),
        }
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &fixture.url);
    let site = Hxq::new();
    site.set_http_context(store, "anonymous-fixture");
    for _ in 0..2 {
        let plays = site.anonymous_play_at("selected_pid", PLAYBACK_ORIGIN).await.unwrap();
        assert_eq!(plays.len(), 1);
        assert_eq!(plays[0].url, "https://media.invalid/selected.m3u8?sign=keep%2Bthis");
        assert!(plays[0].headers.contains(&("User-Agent".into(), MEDIA_UA.into())));
        assert!(plays[0].headers.contains(&("Referer".into(), "https://catalog.invalid/".into())));
    }
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 6);
    assert!(seen.iter().all(|uid| uid == &seen[0]), "the anonymous identity must not rotate per play");
}

#[tokio::test]
async fn denied_or_mismatched_episode_does_not_resolve_or_reflect_private_data() {
    for (item, expected) in [
        (json!({"pid":"selected_pid","permission":{"allowPlay":0},"sources":[{"scid":"private"}]}), "播放权限"),
        (json!({"pid":"different_pid","permission":{"allowPlay":1},"sources":[{"scid":"private"}]}), "不一致"),
    ] {
        let fixture = serve(move |request| {
            device(&request);
            if request.uri.path() == "/api/common/configs" {
                return axum::Json(json!({"rescode":0})).into_response();
            }
            assert_eq!(request.uri.path(), "/api/series2/episode/detail");
            axum::Json(json!({"playItem":item})).into_response()
        }).await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &fixture.url);
        let site = Hxq::new();
        site.set_http_context(store, "denied-fixture");
        let error = site.anonymous_play_at("selected_pid", PLAYBACK_ORIGIN).await.unwrap_err();
        assert!(error.contains(expected), "must observe the actual permission/identity failure");
        assert!(!error.contains("private"));
        assert_eq!(fixture.hits.lock().unwrap().len(), 2);
    }
}
