//! Public bare-directory contracts through real loopback requests.
//! A child test module of csp::provider can exercise restored category state.
//! Captured classes/filter shape is minimized to synthetic public categories.
use super::*;
use crate::csp::bili::Bili;
use crate::csp::http_context::test_support::{custom, serve, Fixture, Request};
use crate::csp::CspSite;
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use md5::{Digest, Md5};
use serde_json::{json, Value};
use std::{collections::BTreeMap, time::{SystemTime, UNIX_EPOCH}};

const WORD: &str = "fixture-opera + 合集";

struct DirectoryFixture {
    origin: Fixture,
    proxy: Fixture,
    store: Arc<crate::proxy::ProxyStore>,
    resource: String,
}

impl DirectoryFixture {
    async fn new(mut body: Value) -> Self {
        let origin = serve(|_| panic!("configured directory route must not fall back to origin")).await;
        if body.get("cookie").is_some_and(Value::is_string) {
            body["cookie"] = json!(format!("{}/must-not-follow-account-resource", origin.url));
        }
        let proxy = serve(move |request| {
            assert!(request.headers.get("cookie").is_none(), "public directories never forward account data");
            assert!(request.headers.get("authorization").is_none());
            if request.method == Method::CONNECT {
                return StatusCode::FORBIDDEN.into_response();
            }
            assert_eq!(request.method, Method::GET);
            let response = match request.uri.path() {
                "/theme.json" => body.clone(),
                "/x/web-interface/ranking/v2" => json!({"code":0,"data":{"list":[
                    {"bvid":"BVgeneral","title":"General catalog"}
                ]}}),
                "/x/web-interface/newlist" => json!({"code":0,"data":{
                    "archives":[{"bvid":"BVregion","title":"Region result"}],
                    "page":{"count":1,"size":20}
                }}),
                "/x/web-interface/nav" => json!({"code":-101,"data":{"wbi_img":{
                    "img_url":"https://image.invalid/7cd084941338484aae1ad9425b84077c.png",
                    "sub_url":"https://image.invalid/4932caff0ff746eab6f01bf08b70ac45.png"
                }}}),
                "/x/web-interface/wbi/search/type" => json!({"code":0,"data":{
                    "result":[{"bvid":"BVkeyword","title":"Keyword result"}],
                    "numResults":1,"numPages":1
                }}),
                _ => panic!("unexpected request, including forbidden cookie/resource follow-up"),
            };
            axum::Json(response).into_response()
        }).await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &proxy.url);
        let resource = format!("{}/theme.json", origin.url);
        Self { origin, proxy, store, resource }
    }

    fn site(&self) -> Bili {
        let site = Bili::with_base(&self.origin.url);
        site.set_http_context(self.store.clone(), "bare-directory-fixture");
        site
    }

    fn restored_provider(&self) -> CspProvider {
        let classes = vec![TvboxCategoryEntry { id:"4".into(),name:"Legacy general region".into(),pid:None }];
        let mut provider = CspProvider::new(
            "bare-directory-fixture", "Public directory", "csp_Bili", &self.resource,
            classes, true, true,
        ).unwrap();
        provider.site = Arc::new(Bili::with_base(&self.origin.url));
        provider.with_proxy(self.store.clone())
    }

    fn assert_proxy_only(&self) {
        assert!(self.origin.hits.lock().unwrap().is_empty(), "no origin fallback");
        for hit in self.proxy.hits.lock().unwrap().iter() {
            assert!(hit.headers.get("cookie").is_none());
            assert!(hit.headers.get("authorization").is_none());
        }
    }
}

fn classes_body(ids: &[&str]) -> Value {
    json!({
        "classes":ids.iter().enumerate().map(|(index,id)|json!({
            "type_id":id,"type_name":format!("Synthetic category {index}")
        })).collect::<Vec<_>>(),
        "cookie":"synthetic-public-resource-trap",
        "filter":{"order":"must-not-use","duration":"must-not-use","cookie":"must-not-use"}
    })
}

fn fields(hit: &Request) -> BTreeMap<String,String> {
    reqwest::Url::parse(&hit.uri.to_string()).unwrap().query_pairs().into_owned().collect()
}

fn assert_signed_keyword(hit: &Request, keyword: &str, page: u32) {
    assert_eq!(hit.uri.path(), "/x/web-interface/wbi/search/type");
    let sent=fields(hit);
    assert_eq!(sent.get("keyword").map(String::as_str),Some(keyword));
    assert_eq!(sent.get("page"),Some(&page.to_string()));
    assert_eq!(sent.get("order").map(String::as_str),Some("totalrank"));
    assert_eq!(sent.get("duration").map(String::as_str),Some("0"));
    assert_eq!(sent.get("search_type").map(String::as_str),Some("video"));
    assert_eq!(sent.len(),7,"directory cookie/filter fields must not become request fields");
    let stamp=sent.get("wts").unwrap().parse::<u64>().unwrap();
    let now=SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    assert!(stamp.abs_diff(now)<=3);
    let unsigned=hit.uri.query().unwrap().split('&').filter(|pair|!pair.starts_with("w_rid=")).collect::<Vec<_>>();
    let mut ordered=unsigned.clone();ordered.sort_unstable();
    assert_eq!(unsigned,ordered,"actual sent signature fields must be sorted");
    let expected=format!("{:x}",Md5::digest(format!("{}ea1db124af3c7062474693fa704f4ff8",ordered.join("&")).as_bytes()));
    assert_eq!(sent.get("w_rid"),Some(&expected),"independent known mixin vector");
}

#[tokio::test]
async fn bare_directory_http_classes_replaces_persisted_regions_without_cookie_followup() {
    let fixture=DirectoryFixture::new(classes_body(&[WORD,"other-keyword"])).await;
    let provider=fixture.restored_provider();
    let categories=provider.categories().await.unwrap();
    assert_eq!(categories.iter().map(|category|category.id.as_str()).collect::<Vec<_>>(),[WORD,"other-keyword"]);
    let page=provider.list(crate::provider::ListRequest{
        category_id:WORD.into(),page:2,..Default::default()
    }).await.unwrap();
    assert_eq!(page.items[0].id.native,"BVkeyword");
    fixture.assert_proxy_only();
    let hits=fixture.proxy.hits.lock().unwrap();
    assert_eq!(hits.iter().filter(|hit|hit.uri.path()=="/theme.json").count(),1);
    assert!(!hits.iter().any(|hit|hit.uri.path().contains("newlist")||hit.uri.path().contains("ranking")));
    let search=hits.iter().find(|hit|hit.uri.path()=="/x/web-interface/wbi/search/type").unwrap();
    assert_signed_keyword(search,WORD,2);
}

#[tokio::test]
async fn bare_directory_https_rejection_uses_configured_connect_without_general_fallback() {
    let fixture=DirectoryFixture::new(classes_body(&[WORD])).await;
    let resource=fixture.resource.replacen("http:","https:",1);
    let result=fixture.site().home(&resource).await;
    assert!(result.is_err(),"declared HTTPS refusal must remain an error");
    fixture.assert_proxy_only();
    let hits=fixture.proxy.hits.lock().unwrap();
    assert_eq!(hits.len(),1);
    assert_eq!(hits[0].method,Method::CONNECT);
    let expected_authority=format!("127.0.0.1:{}",reqwest::Url::parse(&fixture.origin.url).unwrap().port().unwrap());
    assert_eq!(hits[0].uri.authority().map(|value|value.as_str()),Some(expected_authority.as_str()));
}

#[tokio::test]
async fn bare_directory_control_object_json_class_retains_the_existing_directory_shape() {
    for body in [
        json!({"class":[{"type_id":WORD,"type_name":"Existing object category"}],"filters":{}}),
        json!({"class":[{"type_id":WORD,"type_name":"Existing object category"}],
            "classes":[{"type_id":"must-not-win","type_name":"Different alias catalog"}],
            "cookie":{"ignored":"opaque"},"filter":["ignored"]})
    ] {
        let fixture=DirectoryFixture::new(body).await;
        let home=fixture.site().home(&json!({"json":fixture.resource.clone()}).to_string()).await.unwrap();
        assert_eq!(home.categories.len(),1);
        assert_eq!(home.categories[0].id,WORD);
        assert_eq!(home.categories[0].name,"Existing object category");
        assert!(home.items.is_empty());
        fixture.assert_proxy_only();
        let hits=fixture.proxy.hits.lock().unwrap();
        assert_eq!(hits.len(),1);assert_eq!(hits[0].uri.path(),"/theme.json");
    }
}

#[tokio::test]
async fn bare_directory_numeric_category_is_a_keyword_from_its_declared_mode() {
    let fixture=DirectoryFixture::new(classes_body(&["4"])).await;
    let page=fixture.site().list("4",1,&fixture.resource).await.unwrap();
    assert_eq!(page.items[0].id,"BVkeyword");
    fixture.assert_proxy_only();
    let hits=fixture.proxy.hits.lock().unwrap();
    assert!(!hits.iter().any(|hit|hit.uri.path().contains("newlist")));
    assert_signed_keyword(hits.iter().find(|hit|hit.uri.path()=="/x/web-interface/wbi/search/type").unwrap(),"4",1);
}

#[tokio::test]
async fn bare_directory_bad_schema_cannot_fall_back_to_a_general_catalog() {
    for invalid_class in [json!(null),json!([]),json!({}),json!([{"type_id":WORD}])] {
        let fixture=DirectoryFixture::new(json!({"class":invalid_class,
            "classes":[{"type_id":WORD,"type_name":"Valid alias must not hide invalid class"}]})).await;
        let ext=json!({"json":fixture.resource.clone()}).to_string();
        assert!(fixture.site().home(&ext).await.is_err(),"present invalid class is authoritative; no classes fallback");
        fixture.assert_proxy_only();
        let hits=fixture.proxy.hits.lock().unwrap();
        assert_eq!(hits.len(),1);assert_eq!(hits[0].uri.path(),"/theme.json");
    }
    for body in [
        json!({"classes":null}),json!({"classes":[]}),json!({"classes":[{"type_id":"valid"}]}),
        json!({"classes":[{"type_id":" ","type_name":"Invalid"}]}),json!({"unexpected":[]})
    ] {
        let fixture=DirectoryFixture::new(body).await;
        assert!(fixture.site().home(&fixture.resource).await.is_err());
        fixture.assert_proxy_only();
        let hits=fixture.proxy.hits.lock().unwrap();
        assert_eq!(hits.len(),1);assert_eq!(hits[0].uri.path(),"/theme.json");
    }
}

#[tokio::test]
async fn bare_directory_control_empty_ext_keeps_the_numeric_region_recipe() {
    let fixture=DirectoryFixture::new(classes_body(&[WORD])).await;
    let page=fixture.site().list("4",1,"").await.unwrap();
    assert_eq!(page.items[0].id,"BVregion");
    fixture.assert_proxy_only();
    let hits=fixture.proxy.hits.lock().unwrap();
    assert_eq!(hits.len(),1);assert_eq!(hits[0].uri.path(),"/x/web-interface/newlist");
    assert_eq!(fields(&hits[0]).get("rid").map(String::as_str),Some("4"));
}

#[tokio::test]
async fn bare_directory_special_entries_stay_visible_but_selected_requests_are_unsupported() {
    let special=["我的关注","bili_up_42","历史记录","最新动态","其他分区"];
    let mut ids=vec![WORD];ids.extend(special);
    for object_mode in [true,false] {
        let mut body=classes_body(&ids);
        if object_mode {
            let classes=body.as_object_mut().unwrap().remove("classes").unwrap();
            body["class"]=classes;
        }
        let fixture=DirectoryFixture::new(body).await;
        let site=fixture.site();
        let ext=if object_mode {json!({"json":fixture.resource.clone()}).to_string()} else {fixture.resource.clone()};
        let home=site.home(&ext).await.unwrap();
        assert_eq!(home.categories.iter().map(|category|category.id.as_str()).collect::<Vec<_>>(),ids);
        for id in special {
            let result=site.list(id,1,&ext).await;
            assert!(result.is_err(),"unsupported special entry must never become an ordinary keyword result");
            assert!(result.err().unwrap().starts_with("unsupported:"));
        }
        fixture.assert_proxy_only();
        let hits=fixture.proxy.hits.lock().unwrap();
        assert_eq!(hits.len(),1,"cached special selections must not request nav, search, account or resource URLs");
        assert_eq!(hits[0].uri.path(),"/theme.json");
    }
}

#[tokio::test]
async fn bare_directory_near_special_words_remain_ordinary_keywords() {
    let ordinary=["我的关注专题","历史记录片","最新动态解说","其他分区介绍","bili_up"];
    for object_mode in [true,false] {
        let mut body=classes_body(&ordinary);
        if object_mode {
            let classes=body.as_object_mut().unwrap().remove("classes").unwrap();
            body["class"]=classes;
        }
        let fixture=DirectoryFixture::new(body).await;
        let site=fixture.site();
        let ext=if object_mode {json!({"json":fixture.resource.clone()}).to_string()} else {fixture.resource.clone()};
        for word in ordinary {assert_eq!(site.list(word,1,&ext).await.unwrap().items[0].id,"BVkeyword");}
        fixture.assert_proxy_only();
        let hits=fixture.proxy.hits.lock().unwrap();
        let searches=hits.iter().filter(|hit|hit.uri.path()=="/x/web-interface/wbi/search/type").collect::<Vec<_>>();
        assert_eq!(searches.len(),ordinary.len());
        for (hit,word) in searches.into_iter().zip(ordinary) {assert_signed_keyword(hit,word,1);}
        assert!(!hits.iter().any(|hit|hit.uri.path().contains("newlist")));
    }
}
