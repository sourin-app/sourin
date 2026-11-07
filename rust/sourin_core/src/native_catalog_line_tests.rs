//! Real HTTP detail parsing and direct-media resolution, without a public parser.
use crate::{model::{MediaId, PlayRequest}, provider::MediaProvider, tvbox::TvboxAppleCmsProvider};
use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

async fn fixture() -> (TvboxAppleCmsProvider, String, Arc<AtomicUsize>, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let body = serde_json::json!({"list":[{"vod_id":"work","vod_name":"Synthetic work",
        "vod_play_from":"Line A$$$Line B",
        "vod_play_url":format!("第1集${base}/one.m3u8#第2集${base}/two.m3u8$$$第01集${base}/one.m3u8#第02集${base}/two.m3u8")}]}).to_string();
    let hits = Arc::new(AtomicUsize::new(0)); let requests=hits.clone();
    let server=tokio::spawn(async move {
        while let Ok((mut socket,_))=listener.accept().await {
            requests.fetch_add(1,Ordering::SeqCst);
            let mut buf=vec![0;4096];let count=socket.read(&mut buf).await.unwrap_or(0);
            let is_parser=String::from_utf8_lossy(&buf[..count]).contains("/parse?");
            let response_body=if is_parser { r#"{"url":"http://media.invalid/fixture.m3u8"}"# } else { &body };
            let response=format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response_body}",response_body.len());
            let _=socket.write_all(response.as_bytes()).await;
        }
    });
    let provider=TvboxAppleCmsProvider::new("fixture-native","Synthetic",&format!("{base}/api"),vec![]).unwrap();
    (provider,base,hits,server)
}

#[tokio::test]
async fn native_catalog_preserves_all_lines_and_distinguishes_shared_urls() {
    let (provider,base,hits,server)=fixture().await;
    let detail=provider.detail(&MediaId::new("fixture-native","work")).await.unwrap();
    assert_eq!(detail.episodes.len(),4,"Every declared line must reach the player");
    assert_eq!(detail.episodes.iter().map(|e|e.flag.as_str()).collect::<Vec<_>>(),["Line A","Line A","Line B","Line B"]);
    assert_eq!(detail.episodes[1].id,format!("{base}/two.m3u8"),"Existing first-line history ids stay stable");
    assert_ne!(detail.episodes[1].id,detail.episodes[3].id,"Shared media URLs still have separate line identity");
    let mut req=PlayRequest::default();req.episode_id=Some(detail.episodes[3].id.clone());
    let streams=provider.resolve(&detail.id,&req).await.unwrap();
    assert_eq!(streams[0].url,format!("{base}/two.m3u8"));
    assert_eq!(hits.load(Ordering::SeqCst),1,"Selecting the episode does not refetch the first line");
    server.abort();
}

#[tokio::test]
async fn native_catalog_direct_mp4_does_not_fetch_binary_as_a_web_page() {
    let (provider,base,hits,server)=fixture().await;
    let direct=format!("{base}/motion.mp4?episode=2");
    let mut req=PlayRequest::default();req.episode_id=Some(direct.clone());
    // A dead local parser keeps the old wrong branch bounded and off the public net.
    let provider=provider.with_parsers(vec![format!("{base}/parse?url=")]);
    let result=tokio::time::timeout(std::time::Duration::from_secs(2),provider.resolve(&MediaId::new("fixture-native","work"),&req)).await;
    assert_eq!(hits.load(Ordering::SeqCst),0,"Direct media must not be downloaded and decoded as HTML");
    assert_eq!(result.unwrap().unwrap()[0].url,direct);
    server.abort();
}
