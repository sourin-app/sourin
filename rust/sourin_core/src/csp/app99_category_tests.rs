use super::*;
use crate::csp::http_context::test_support::{serve, Fixture, Request};
use axum::{http::Method, response::IntoResponse};

const UUID: &str = "aabbccddeeff00112233445566778899";
const TOKEN: &str = "fixture-category-token";

fn ext(host: &str) -> String {
    serde_json::json!({
        "host":host,"name":"fixture-app","buildSignature":"FIXTURE-SIG",
        "buildNumber":"2001","versionName":"3.5.8","package":"com.fixture",
        "uuid":UUID
    }).to_string()
}

fn open_wire_request(request: &Request) -> serde_json::Value {
    assert_eq!(request.method, Method::POST);
    let plain = super::tests::open_request(
        &key_of(UUID).unwrap(), std::str::from_utf8(&request.body).unwrap(),
    );
    let header = |name| request.headers.get(name).unwrap().to_str().unwrap();
    assert_eq!(header("uuid"), UUID);
    assert_eq!(plain["timestamp"], header("timestamp"));
    assert_eq!(plain["nonce"], header("nonce"));
    let signature_input = format!(
        "{}:{}:{}:{}", std::str::from_utf8(&request.body).unwrap(),
        header("timestamp"), header("nonce"), plain["token"].as_str().unwrap(),
    );
    let digest = ring::digest::digest(&ring::digest::SHA256, signature_input.as_bytes());
    let expected: String = digest.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
    assert_eq!(header("sign"), expected);
    plain
}

fn business_payload(request: &Request) -> serde_json::Value {
    assert_eq!(request.uri.path(), "/vod/search");
    let mut plain = open_wire_request(request);
    let object = plain.as_object_mut().unwrap();
    assert_eq!(object.remove("token").unwrap(), TOKEN);
    assert!(object.remove("timestamp").unwrap().as_str().unwrap().parse::<u64>().is_ok());
    assert_eq!(b64_decode(object.remove("nonce").unwrap().as_str().unwrap()).unwrap().len(), 16);
    plain
}

async fn directory_fixture() -> Fixture {
    serve(|request| {
        let plain = open_wire_request(&request);
        let response = match request.uri.path() {
            "/app/systemInit" => serde_json::json!({
                "code":0,"categorys":{"data":[
                    {"id":"1","name":"分类甲"},{"id":"2","name":"分类乙"}
                ]}
            }),
            "/app/userInfo" => serde_json::json!({
                "code":0,"userInfo":{"user_token":TOKEN}
            }),
            "/vod/search" if plain["isCategory"] == 1 => serde_json::json!({
                "code":0,"data":[{"id":201,"name":"目录作品"}]
            }),
            "/vod/search" => serde_json::json!({
                "code":0,"data":[{"id":902,"name":"关键词 2"}]
            }),
            _ => serde_json::json!({"code":1,"msg":"unexpected fixture route"}),
        };
        super::tests::seal_fixture(&key_of(UUID).unwrap(), &response).into_response()
    }).await
}

// Independent reference contract: categoryContent(String tid, String page, ...)
// puts kw="", page=p2, pid=p1, limit=21, orderBy="time", isCategory=1.
// The two IDs/page values are strings; the limit/category flag are integers.
// searchContent instead puts the actual keyword, numeric page=1 and
// orderBy="vod_hits_month"/sort="desc". These expected values do not call
// production request builders or derive themselves from the observed request.

#[tokio::test]
async fn app99_category_numeric_id_uses_reference_directory_payload() {
    let fixture = directory_fixture().await;
    let ext = ext(&fixture.url);
    let site = App99::new();
    let home = site.home(&ext).await.unwrap();
    assert_eq!(home.categories[1].id, "2");
    let list = tokio::time::timeout(Duration::from_secs(5), site.list(" 2 ", 3, &ext))
        .await.unwrap().unwrap();
    let requests = fixture.hits.lock().unwrap();
    assert_eq!(requests.iter().map(|request| request.uri.path()).collect::<Vec<_>>(),
        vec!["/app/systemInit", "/app/userInfo", "/vod/search"]);
    assert_eq!(business_payload(&requests[2]), serde_json::json!({
        "kw":"","page":"3","limit":21,"pid":"2","orderBy":"time","isCategory":1
    }), "directory ID must not become the search keyword");
    assert_eq!(list.page, 3);
    assert_eq!(list.items[0].title, "目录作品");
}

#[tokio::test]
async fn app99_category_switch_and_page_zero_stay_in_directory_scope() {
    let fixture = directory_fixture().await;
    let ext = ext(&fixture.url);
    let site = App99::new();
    site.home(&ext).await.unwrap();
    let (first, second) = tokio::time::timeout(Duration::from_secs(5), async {
        let first = site.list("1", 0, &ext).await?;
        let second = site.list("2", 2, &ext).await?;
        Ok::<_, String>((first, second))
    }).await.unwrap().unwrap();
    let requests = fixture.hits.lock().unwrap();
    assert_eq!(requests.len(), 4, "category changes must reuse the authenticated session");
    assert_eq!(business_payload(&requests[2]), serde_json::json!({
        "kw":"","page":"1","limit":21,"pid":"1","orderBy":"time","isCategory":1
    }));
    assert_eq!(business_payload(&requests[3]), serde_json::json!({
        "kw":"","page":"2","limit":21,"pid":"2","orderBy":"time","isCategory":1
    }));
    assert_eq!(first.page, 1);
    assert_eq!(second.page, 2);
    assert_eq!(first.items[0].title, "目录作品");
    assert_eq!(second.items[0].title, "目录作品");
}

#[tokio::test]
async fn app99_category_search_keeps_a_numeric_user_keyword() {
    let fixture = directory_fixture().await;
    let ext = ext(&fixture.url);
    let site = App99::new();
    let list = tokio::time::timeout(Duration::from_secs(5), site.search(" 2 ", 1, &ext))
        .await.unwrap().unwrap();
    let requests = fixture.hits.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert_eq!(business_payload(&requests[2]), serde_json::json!({
        "kw":"2","page":1,"limit":21,"orderBy":"vod_hits_month","sort":"desc"
    }), "a numeric user query must remain a real search rather than a category");
    assert_eq!(list.items[0].title, "关键词 2");
}
