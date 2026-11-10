use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::model::{MediaId, MediaDetail};
use crate::provider::ListRequest;
use crate::state::AppState;
use axum::response::{IntoResponse, Response};
use serde_json::{json, Value};

fn video(fid: &str, name: &str) -> Value {
    json!({"fid":fid,"file_name":name,"size":1024,"dir":false,"file_type":1,
        "share_fid_token":"fixture-file-token"})
}

fn reply(request: Request, marker: &str, origin: &str, kind: PanKind, pan_share: bool, remote_library: bool) -> Response {
    let path = request.uri.path();
    let query: std::collections::HashMap<String,String> = reqwest::Url::parse(&format!("http://fixture.invalid{}", request.uri.path_and_query().unwrap())).unwrap().query_pairs().into_owned().collect();
    if path == "/subscription.json" {
        let ext = if remote_library { json!(format!("{origin}/library.json")) } else if pan_share {
            json!({"shares":{kind.code():["episodeFixture 分享夹具"]}})
        } else { json!({"site":[origin]}) };
        return axum::Json(json!({"sites":[{"key":"episode-proxy-fixture","name":"Episode fixture",
            "type":3,"api":if pan_share {"csp_PanShare"} else {"csp_PanWebShare"},"ext":ext}]})).into_response();
    }
    if path == "/library.json" {
        return axum::Json(json!({"shares":{kind.code():["episodeFixture 分享夹具"]}})).into_response();
    }
    if path.contains("/index.php/vod/show/") {
        return r#"<nav><a href="/index.php/vod/show/id/1.html">分类</a></nav><div class="module-item"><a href="/index.php/vod/detail/id/1234.html" title="片名"><img data-src="http://cover.invalid/a.jpg"></a></div>"#.into_response();
    }
    if path.contains("/index.php/vod/detail/") {
        let share = share_url(kind, "episodeFixture", "").unwrap();
        return format!(r#"<h1 class="video-info-header"><span class="page-title">片名</span></h1><div data-clipboard-text="{share}"></div>"#).into_response();
    }
    if path.contains("/page/") { return "fixture share page".into_response(); }
    if path.ends_with("/token") {
        return axum::Json(json!({"status":200,"code":0,"data":{"stoken":"fixture-stoken"}})).into_response();
    }
    if path.ends_with("/detail") {
        let folder = query.get("pdir_fid").map(String::as_str).unwrap_or("0");
        let page = query.get("_page").map(String::as_str).unwrap_or("1");
        let entries = if folder == "nested" {
            vec![video("selected-first", &format!("{marker} 第01集.mkv"))]
        } else if page == "2" {
            vec![video("selected-second", &format!("{marker} 第02集.mkv"))]
        } else {
            let mut entries: Vec<_> = (0..49).map(|i| json!({"fid":format!("txt-{i}"),
                "file_name":format!("readme-{i}.txt"),"size":1,"dir":false,"file_type":1})).collect();
            entries.push(json!({"fid":"nested","file_name":"剧集目录","dir":true,"file_type":0,"size":0}));
            entries
        };
        return axum::Json(json!({"status":200,"code":0,"data":{"list":entries}})).into_response();
    }
    panic!("unexpected fixture request: {} {}", request.method, request.uri);
}

fn check_detail(detail: &MediaDetail, marker: &str, kind: PanKind) {
    assert_eq!(detail.episodes.len(), 2, "all pages and nested folders must expand into videos");
    for (episode, fid, title) in [
        (&detail.episodes[0], "selected-first", format!("剧集目录/{marker} 第01集.mkv")),
        (&detail.episodes[1], "selected-second", format!("{marker} 第02集.mkv")),
    ] {
        let reference = decode_file_id(&episode.id).expect("real stable selected-file id");
        assert_eq!(reference.fid, fid);
        assert_eq!(reference.kind, kind.code());
        assert_eq!(reference.share_id, "episodeFixture");
        assert_eq!(episode.title, title);
    }
}

async fn imported_detail(kind: PanKind, pan_share: bool, remote_library: bool, switch_midway: bool) {
    let origin = serve(move |request| reply(request, "origin", "", kind, pan_share, remote_library)).await;
    let base = origin.url.clone();
    let second = serve(move |request| reply(request, "second", &base, kind, pan_share, remote_library)).await;
    let switch = std::sync::Arc::new(std::sync::Mutex::new(None::<std::sync::Arc<crate::proxy::ProxyStore>>));
    let changing = switch.clone();
    let next_proxy = second.url.clone();
    let base = origin.url.clone();
    let first = serve(move |request| {
        if request.uri.path().contains("/checker/") && request.uri.path().ends_with("/token") {
            if let Some(store) = changing.lock().unwrap().take() { custom(&store, &next_proxy); }
        }
        reply(request, "first", &base, kind, pan_share, remote_library)
    }).await;
    let mut endpoints = crate::pan_check::PanEndpoints::default();
    endpoints.quark_page = format!("{}/checker/quark/page", origin.url);
    endpoints.quark_token = format!("{}/checker/quark/token", origin.url);
    endpoints.quark_detail = format!("{}/checker/quark/detail", origin.url);
    endpoints.uc_page = format!("{}/checker/uc/page", origin.url);
    endpoints.uc_token = format!("{}/checker/uc/token", origin.url);
    endpoints.uc_detail = format!("{}/checker/uc/detail", origin.url);
    let checker = Box::leak(Box::new(PanChecker::with_endpoints(endpoints)));
    let _checker = crate::pan_check::override_global_checker_for_tests(checker);
    let _bases = crate::csp::pan_drive::debug_override_api_bases(vec![
        ("drive-pc.quark.cn".into(), origin.url.clone()), ("pc-api.uc.cn".into(), origin.url.clone())]);
    let dir = scratch("episode-proxy");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &first.url);
    let imported = crate::tvbox::import_tvbox_config(&state,"http://episode-fixture.invalid/subscription.json").await.unwrap();
    let row = &imported["imported"][0];
    assert!(row["probeFailed"].is_null(), "{imported}");
    let id = row["id"].as_str().unwrap().to_string();
    let provider = state.registry.get(&id).unwrap();
    let native = if pan_share {
        provider.list(ListRequest {category_id:kind.code().into(),page:1,..Default::default()})
            .await.unwrap().items[0].id.native.clone()
    } else { "1234".into() };
    let media = MediaId {provider:id.clone(),native};
    if switch_midway { *switch.lock().unwrap() = Some(state.proxy.clone()); }
    check_detail(&provider.detail(&media).await.unwrap(), "first", kind);
    if switch_midway {
        assert!(switch.lock().unwrap().is_none(), "policy switch must run inside the precheck");
        assert!(second.hits.lock().unwrap().is_empty(), "in-flight listing keeps original route");
    }
    let before = first.hits.lock().unwrap().len();
    custom(&state.proxy, &second.url);
    check_detail(&provider.detail(&media).await.unwrap(), "second", kind);
    assert_eq!(first.hits.lock().unwrap().len(), before);
    drop(provider);
    drop(state);
    let restored = AppState::bootstrap(dir.clone()).await.unwrap();
    check_detail(&restored.registry.get(&id).unwrap().detail(&media).await.unwrap(), "second", kind);
    assert!(origin.hits.lock().unwrap().is_empty(), "no direct precheck/listing requests");
    // Broken policy must not retry a reachable origin. PanShare reports the
    // failure; the catalog retains its original unresolved share candidate.
    let unavailable = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let dead_url = format!("http://{}", unavailable.local_addr().unwrap());
    drop(unavailable);
    custom(&restored.proxy, &dead_url);
    let result = restored.registry.get(&id).unwrap().detail(&media).await;
    assert!(result.is_err(), "broken catalog or internal share request must fail");
    assert!(origin.hits.lock().unwrap().is_empty(), "failed proxy must not be bypassed");
    for fixture in [&first, &second] {
        let hits = fixture.hits.lock().unwrap();
        assert!(hits.iter().any(|r| r.uri.path().contains("/checker/")));
        assert!(hits.iter().any(|r| r.uri.query().unwrap_or("").contains("_page=2")));
        assert!(hits.iter().any(|r| r.uri.query().unwrap_or("").contains("pdir_fid=nested")));
        assert!(hits.iter().all(|r| !r.uri.path().ends_with("/save") && !r.uri.path().ends_with("/delete")));
    }
}

#[tokio::test(flavor="current_thread")]
async fn imported_quark_catalog_detail_routes_all_pages_and_restore() { imported_detail(PanKind::Quark,false,false,false).await; }
#[tokio::test(flavor="current_thread")]
async fn imported_uc_catalog_detail_routes_all_pages_and_restore() { imported_detail(PanKind::Uc,false,false,false).await; }
#[tokio::test(flavor="current_thread")]
async fn imported_quark_share_detail_routes_internal_helpers() { imported_detail(PanKind::Quark,true,false,false).await; }
#[tokio::test(flavor="current_thread")]
async fn imported_uc_share_detail_routes_internal_helpers() { imported_detail(PanKind::Uc,true,false,false).await; }

#[tokio::test(flavor="current_thread")]
async fn imported_share_remote_library_keeps_global_policy() { imported_detail(PanKind::Quark,true,true,false).await; }
#[tokio::test(flavor="current_thread")]
async fn imported_quark_listing_keeps_one_revision_across_precheck_and_pages() { imported_detail(PanKind::Quark,true,false,true).await; }
#[tokio::test(flavor="current_thread")]
async fn imported_uc_listing_keeps_one_revision_across_precheck_and_pages() { imported_detail(PanKind::Uc,false,false,true).await; }


fn playback_reply(request: Request, marker: &str, video_fallback: bool) -> Response {
    let path = request.uri.path();
    let body: Value = serde_json::from_slice(&request.body).unwrap_or(Value::Null);
    let value = if path.contains("/page/") { return "fixture page".into_response(); }
    else if path.ends_with("/token") { json!({"status":200,"code":0,"data":{"stoken":"fixture-token"}}) }
    else if path.ends_with("/detail") { json!({"status":200,"code":0,"data":{"list":[
        video("selected-first", "第01集.mkv"), video("selected-second", "第02集.mkv")
    ]}}) }
    else if path.ends_with("/file/sort") { json!({"code":0,"data":{"list":[]}}) }
    else if path.ends_with("/file") { json!({"code":0,"data":{"fid":body["file_name"]}}) }
    else if path.ends_with("/save") {
        assert_eq!(body["fid_list"][0], "selected-second", "selected identity reaches the transfer");
        json!({"status":200,"code":0,"data":{"task_id":"transfer"}})
    }
    else if path.ends_with("/task") { json!({"status":200,"code":0,"data":{"status":2,"save_as":{"save_as_top_fids":["COPIED-SECOND"]}}}) }
    else if path.ends_with("/download") {
        if video_fallback { json!({"code":23018,"message":"download file size limit"}) }
        else { json!({"code":0,"data":[{"download_url":format!("https://{marker}.invalid/selected.mp4")} ]}) }
    }
    else if path.ends_with("/file/v2/play") {
        assert_eq!(body["fid"], "COPIED-SECOND");
        json!({"code":0,"data":{"default_resolution":"normal","video_list":[{
            "resolution":"normal","accessable":true,"trans_status":"success",
            "video_info":{"url":format!("https://{marker}.invalid/selected.m3u8")}
        }]}})
    }
    else if path.ends_with("/delete") { json!({"code":0}) }
    else { panic!("unexpected playback route {} {}",request.method,request.uri); };
    axum::Json(value).into_response()
}

async fn selected_playback_routes(kind: PanKind, video_fallback: bool, switch_midway: bool) {
    use crate::provider::MediaProvider;
    use crate::csp::pan_playback_guard as guard;
    use crate::csp::pan_drive;
    let _serial = pan_drive::FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _credentials = crate::pan_auth::debug_override_credentials(vec![crate::pan_auth::PanCredential {
        kind, account:"fixture".into(),cookie:"fixture=selected-playback".into(),saved_at:0,expires_at:None
    }]);
    let origin = serve(move |request| playback_reply(request,"origin",video_fallback)).await;
    let second = serve(move |request| playback_reply(request,"second",video_fallback)).await;
    let switch = std::sync::Arc::new(std::sync::Mutex::new(None::<std::sync::Arc<crate::proxy::ProxyStore>>));
    let changing = switch.clone();
    let next = second.url.clone();
    let first = serve(move |request| {
        if request.uri.path().contains("/checker/") && request.uri.path().ends_with("/token") {
            if let Some(store) = changing.lock().unwrap().take() { custom(&store,&next); }
        }
        playback_reply(request,"first",video_fallback)
    }).await;
    let mut endpoints = crate::pan_check::PanEndpoints::default();
    endpoints.quark_page = format!("{}/checker/quark/page", origin.url);
    endpoints.quark_token = format!("{}/checker/quark/token", origin.url);
    endpoints.quark_detail = format!("{}/checker/quark/detail", origin.url);
    endpoints.uc_page = format!("{}/checker/uc/page", origin.url);
    endpoints.uc_token = format!("{}/checker/uc/token", origin.url);
    endpoints.uc_detail = format!("{}/checker/uc/detail", origin.url);
    let checker = Box::leak(Box::new(PanChecker::with_endpoints(endpoints)));
    let _checker = crate::pan_check::override_global_checker_for_tests(checker);
    let _bases = pan_drive::debug_override_api_bases(vec![
        ("drive-pc.quark.cn".into(),origin.url.clone()),("pc-api.uc.cn".into(),origin.url.clone())]);
    let store = std::sync::Arc::new(crate::proxy::ProxyStore::new());
    custom(&store,&first.url);
    let provider = crate::csp::provider::CspProvider::new("fixture-playback", "fixture", "csp_PanShare", "{}", vec![], true,false).unwrap().with_proxy(store.clone());
    let consumer = format!("route-{}-{video_fallback}-{switch_midway}",kind.code());
    let owner = guard::PlaybackOwner {consumer:consumer.clone(),generation:1};
    let mut req = crate::model::PlayRequest::default();
    req.episode_id = Some(encode_file_id(kind,"episodeFixture","","selected-second"));
    req.episode_title = Some("第02集".into());
    req.extra = Some(json!({"play_consumer":consumer,"play_generation":1}));
    let media = MediaId::new("fixture-playback","fixture");
    if switch_midway { *switch.lock().unwrap() = Some(store.clone()); }
    let plays = provider.resolve(&media,&req).await.unwrap();
    assert_eq!(plays.len(),1);
    assert!(plays[0].url.starts_with("https://first.invalid/"),"full selected playback must use configured proxy: {}",plays[0].url);
    assert!(origin.hits.lock().unwrap().is_empty(),"no direct precheck/list/transfer/download");
    assert!(second.hits.lock().unwrap().is_empty(),"in-flight policy snapshot must survive a settings change");
    if switch_midway { assert!(switch.lock().unwrap().is_none()); }
    let requests = first.hits.lock().unwrap().clone();
    for suffix in ["/token","/detail","/save","/task","/download"] {
        assert!(requests.iter().any(|r| r.uri.path().ends_with(suffix)),"missing {suffix}");
    }
    assert_eq!(requests.iter().any(|r|r.uri.path().ends_with("/file/v2/play")),video_fallback);
    // A subsequent operation takes the new policy; do not re-use the old one.
    custom(&store,&second.url);
    req.extra = Some(json!({"play_consumer":owner.consumer,"play_generation":2}));
    let before = first.hits.lock().unwrap().len();
    assert!(provider.resolve(&media,&req).await.unwrap()[0].url.starts_with("https://second.invalid/"));
    assert_eq!(first.hits.lock().unwrap().len(),before);
    assert!(second.hits.lock().unwrap().iter().any(|r|r.uri.path().ends_with("/delete")),"prior generation cleanup uses next operation route");
    let dead = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}",dead.local_addr().unwrap()); drop(dead);
    custom(&store,&unavailable);
    req.extra = Some(json!({"play_consumer":owner.consumer,"play_generation":3}));
    assert!(provider.resolve(&media,&req).await.is_err());
    assert!(origin.hits.lock().unwrap().is_empty(),"failed proxy must not fall back to origin");
}

#[tokio::test(flavor="current_thread")]
async fn selected_quark_playback_routes_transfer_download_and_next_operation_cleanup() { selected_playback_routes(PanKind::Quark,false,false).await; }
#[tokio::test(flavor="current_thread")]
async fn selected_uc_playback_keeps_proxy_snapshot_until_download() { selected_playback_routes(PanKind::Uc,false,true).await; }
#[tokio::test(flavor="current_thread")]
async fn selected_quark_playback_video_fallback_keeps_selected_fid_and_proxy_snapshot() { selected_playback_routes(PanKind::Quark,true,true).await; }


fn foreign_playback_reply(request: Request, kind: PanKind, marker: &str) -> Response {
    let path = request.uri.path();
    let value = if kind == PanKind::Xunlei {
        match (request.method.as_str(),path) {
            ("GET","/drive/v1/share") => json!({"share_status_text":"OK","pass_code_token":"pctok","files":[{"id":"selected","name":"EP02.mkv","size":123,"kind":"drive#file"}]}),
            ("POST","/drive/v1/files") => json!({"file":{"id":"owned-proxy-directory","kind":"drive#folder"}}),
            ("POST","/drive/v1/share/restore") => {
                let body: Value = serde_json::from_slice(&request.body).unwrap();
                assert_eq!(body["file_ids"],json!(["selected"]));
                assert_eq!(body["parent_id"],"owned-proxy-directory");
                json!({"restore_status":"RESTORE_COMPLETE"})
            }
            ("GET","/drive/v1/files") => json!({"files":[{"id":"copy","name":"EP02.mkv","size":123,"kind":"drive#file"}]}),
            ("GET","/drive/v1/files/copy") => json!({"id":"copy","web_content_link":format!("https://{marker}.invalid/selected.mp4")}),
            ("DELETE","/drive/v1/files/owned-proxy-directory") => json!({}),
            _ => panic!("unexpected xunlei path {} {path}",request.method),
        }
    } else {
        match path {
            "/s/fixtureShare" => return r#"<html><script>locals.mset({"shareid":123,"share_uk":456,"bdstoken":"PAGE_TOKEN"});</script></html>"#.into_response(),
            "/share/list" => json!({"errno":0,"list":[{"fs_id":21,"server_filename":"EP02.mkv","isdir":0,"size":123}]}),
            "/api/loginStatus" => json!({"errno":0,"login_info":{"uk":56,"bdstoken":"viewer","vip_identity":0}}),
            "/share/tplconfig" => json!({"errno":0,"data":{"sign":"fixture","timestamp":123}}),
            "/api/sharedownload" => {
                let fields: std::collections::HashMap<_,_> = reqwest::Url::parse(&format!("http://fixture.invalid/?{}",std::str::from_utf8(&request.body).unwrap())).unwrap().query_pairs().into_owned().collect();
                assert_eq!(fields.get("fid_list").unwrap(),"[21]");
                json!({"errno":0,"list":[{"fs_id":21,"dlink":format!("https://{marker}.invalid/selected.mp4")}]})
            }
            _ => panic!("unexpected baidu path {path}"),
        }
    };
    axum::Json(value).into_response()
}

async fn foreign_playback_routes(kind: PanKind) {
    use crate::csp::{pan_baidu_play as baidu,pan_xunlei_play as xunlei,pan_playback_guard as guard};
    let origin = serve(move |request| foreign_playback_reply(request,kind,"origin")).await;
    let second = serve(move |request| foreign_playback_reply(request,kind,"second")).await;
    let store = std::sync::Arc::new(crate::proxy::ProxyStore::new());
    let changing = store.clone();
    let next = second.url.clone();
    let first = serve(move |request| {
        // Flip routing before transfer/download, while the operation is active.
        if request.uri.path() == "/drive/v1/share" || request.uri.path().starts_with("/s/") { custom(&changing,&next); }
        foreign_playback_reply(request,kind,"first")
    }).await;
    let checker = PanChecker::with_endpoints(crate::pan_check::PanEndpoints::default());
    let owner = guard::PlaybackOwner {consumer:format!("proxy-foreign-{}",kind.code()),generation:1};
    guard::register(Some(owner.clone())).unwrap();
    let _credentials = crate::pan_auth::debug_override_credentials(vec![crate::pan_auth::PanCredential {
        kind,account:"fixture".into(),cookie:"access_token=TESTTOK".into(),saved_at:0,expires_at:None
    }]);
    let _xunlei = xunlei::debug_override_endpoint(format!("{}/drive/v1",origin.url));
    let spec = EpisodeSpec {title:"EP02.mkv".into(),order:Some(2)};
    for marker in ["first","second"] {
        custom(&store, if marker == "first" {&first.url} else {&second.url});
        let operation = checker.for_share_operation(store.clone(),"fixture-foreign").unwrap();
        let play = with_operation(operation,guard::with_scope(Some(owner.clone()),async {
            if kind == PanKind::Xunlei {
                xunlei::resolve_selected_with(&xunlei::XunleiEndpoints {base:format!("{}/drive/v1",origin.url)},Some("access_token=TESTTOK"),"fixtureShare","",Some("selected"),&spec).await
            } else {
                baidu::resolve_selected_with(&baidu::BaiduEndpoints {page:format!("{}/s",origin.url),verify:format!("{}/share/verify",origin.url),list:format!("{}/share/list",origin.url)},Some("BDUSS=FIXTURE"),"fixtureShare","",Some("21"),&spec).await
            }
        })).await.unwrap();
        assert_eq!(play.url,format!("https://{marker}.invalid/selected.mp4"));
        if marker == "first" { assert!(second.hits.lock().unwrap().is_empty(),"whole playback retains its routing snapshot"); }
    }
    assert!(origin.hits.lock().unwrap().is_empty());
    if kind == PanKind::Xunlei {
        let before = second.hits.lock().unwrap().len();
        let operation = checker.for_share_operation(store.clone(),"fixture-foreign").unwrap();
        with_operation(operation,xunlei::purge_for_owner(Some(owner))).await;
        assert!(second.hits.lock().unwrap()[before..].iter().any(|r|r.method == "DELETE"));
    }
    let dead = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}",dead.local_addr().unwrap());drop(dead);
    custom(&store,&unavailable);
    let operation = checker.for_share_operation(store,"fixture-foreign").unwrap();
    let result = with_operation(operation,async {
        if kind == PanKind::Xunlei {
            xunlei::resolve_selected_with(&xunlei::XunleiEndpoints {base:format!("{}/drive/v1",origin.url)},Some("access_token=TESTTOK"),"fixtureShare","",Some("selected"),&spec).await
        } else {
            baidu::resolve_selected_with(&baidu::BaiduEndpoints {page:format!("{}/s",origin.url),verify:format!("{}/share/verify",origin.url),list:format!("{}/share/list",origin.url)},Some("BDUSS=FIXTURE"),"fixtureShare","",Some("21"),&spec).await
        }
    }).await;
    assert!(result.is_err());
    assert!(origin.hits.lock().unwrap().is_empty(),"unavailable proxy never retries direct");
}

#[tokio::test(flavor="current_thread")]
async fn selected_xunlei_playback_routes_restore_download_and_cleanup() { foreign_playback_routes(PanKind::Xunlei).await; }
#[tokio::test(flavor="current_thread")]
async fn selected_baidu_playback_routes_authenticated_download() { foreign_playback_routes(PanKind::Baidu).await; }
