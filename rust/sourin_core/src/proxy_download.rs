//! Local streaming bridge for Flutter downloads using the shared proxy policy.
use crate::proxy::ProxyStore;
use axum::{
    body::Body,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use serde_json::{json, Value};
use std::{
    collections::{hash_map::RandomState, HashMap},
    hash::BuildHasher,
    sync::{Arc, Mutex, Weak},
    time::{Duration, Instant},
};

struct Ticket {
    url: reqwest::Url,
    headers: HeaderMap,
    created: Instant,
}
pub struct DownloadBridge {
    port: u16,
    tickets: Mutex<HashMap<String, Ticket>>,
    store: Weak<ProxyStore>,
}

pub async fn register(store: Arc<ProxyStore>, args: Value) -> Result<Value, String> {
    // Validate before allocating a local endpoint; no request falls back to direct.
    store.download_client().map_err(|e| e.message)?;
    let url = reqwest::Url::parse(args["url"].as_str().ok_or("缺少下载地址")?)
        .map_err(|_| "下载地址无效")?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err("下载地址仅支持 HTTP/HTTPS".into());
    }
    let mut headers = HeaderMap::new();
    if let Some(values) = args["headers"].as_object() {
        for (name, value) in values {
            let name = reqwest::header::HeaderName::from_bytes(name.as_bytes())
                .map_err(|_| "请求头无效")?;
            let value = reqwest::header::HeaderValue::from_str(value.as_str().ok_or("请求头无效")?)
                .map_err(|_| "请求头无效")?;
            headers.insert(name, value);
        }
    }
    let bridge = store
        .download_bridge
        .get_or_try_init(|| async {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
                .await
                .map_err(|_| "无法建立本机下载连接")?;
            let bridge = Arc::new(DownloadBridge {
                port: listener
                    .local_addr()
                    .map_err(|_| "本机下载连接无效")?
                    .port(),
                tickets: Mutex::new(HashMap::new()),
                store: Arc::downgrade(&store),
            });
            let app = Router::new()
                .route("/download/{token}", get(fetch))
                .with_state(bridge.clone());
            let weak = Arc::downgrade(&store);
            tokio::spawn(async move {
                let _ = axum::serve(listener, app)
                    .with_graceful_shutdown(async move {
                        loop {
                            tokio::time::sleep(Duration::from_secs(30)).await;
                            if weak.upgrade().is_none() {
                                break;
                            }
                        }
                    })
                    .await;
            });
            Ok::<_, String>(bridge)
        })
        .await?;
    let token = format!(
        "{:016x}{:016x}",
        RandomState::new().hash_one(Instant::now()),
        RandomState::new().hash_one(&url)
    );
    let mut tickets = bridge.tickets.lock().map_err(|_| "下载队列忙")?;
    tickets.retain(|_, ticket| ticket.created.elapsed() < Duration::from_secs(30));
    if tickets.len() >= 32 {
        return Err("下载请求过多，请稍后重试".into());
    }
    tickets.insert(
        token.clone(),
        Ticket {
            url,
            headers,
            created: Instant::now(),
        },
    );
    Ok(json!({"url":format!("http://127.0.0.1:{}/download/{token}",bridge.port)}))
}

async fn fetch(State(bridge): State<Arc<DownloadBridge>>, Path(token): Path<String>) -> Response {
    let ticket = bridge
        .tickets
        .lock()
        .ok()
        .and_then(|mut t| t.remove(&token));
    let Some(ticket) = ticket.filter(|t| t.created.elapsed() < Duration::from_secs(30)) else {
        return (StatusCode::NOT_FOUND, "下载请求已过期").into_response();
    };
    let Some(store) = bridge.store.upgrade() else {
        return (StatusCode::SERVICE_UNAVAILABLE, "应用正在退出").into_response();
    };
    let client = match store.download_client() {
        Ok(c) => c,
        Err(_) => return (StatusCode::BAD_GATEWAY, "全局代理不可用").into_response(),
    };
    let upstream = match tokio::time::timeout(
        Duration::from_secs(20),
        client
            .get(ticket.url)
            .headers(ticket.headers)
            .header(reqwest::header::ACCEPT_ENCODING, "identity")
            .send(),
    )
    .await
    {
        Ok(Ok(r)) => r,
        _ => return (StatusCode::BAD_GATEWAY, "下载连接失败，请检查全局代理").into_response(),
    };
    let mut response = Response::builder().status(upstream.status());
    for key in [
        "content-type",
        "content-length",
        "content-encoding",
        "content-range",
        "accept-ranges",
    ] {
        if let Some(value) = upstream.headers().get(key) {
            response = response.header(key, value);
        }
    }
    response
        .body(Body::from_stream(upstream.bytes_stream()))
        .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proxy::{ProxyConfig, ProxyMode, GLOBAL_PROXY};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    #[tokio::test]
    async fn downloads_use_global_proxy_with_single_use_tickets_and_no_direct_fallback() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let store = Arc::new(ProxyStore::new());
        store
            .set(
                GLOBAL_PROXY,
                ProxyConfig {
                    mode: ProxyMode::Custom,
                    url: Some(format!("http://{}", listener.local_addr().unwrap())),
                    ..Default::default()
                },
            )
            .unwrap();
        let serve = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut bytes = vec![0; 2048];
            let n = socket.read(&mut bytes).await.unwrap();
            assert!(String::from_utf8_lossy(&bytes[..n])
                .starts_with("GET http://updates.invalid/package.zip "));
            socket
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\npayload",
                )
                .await
                .unwrap();
        });
        let endpoint = register(
            store.clone(),
            json!({"url":"http://updates.invalid/package.zip"}),
        )
        .await
        .unwrap();
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let url = endpoint["url"].as_str().unwrap();
        assert_eq!(
            client.get(url).send().await.unwrap().bytes().await.unwrap(),
            "payload"
        );
        assert_eq!(client.get(url).send().await.unwrap().status(), 404);
        serve.await.unwrap();
        store
            .set(
                GLOBAL_PROXY,
                ProxyConfig {
                    mode: ProxyMode::Custom,
                    url: Some("http://127.0.0.1:1".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        let endpoint = register(
            store.clone(),
            json!({"url":"http://updates.invalid/package.zip"}),
        )
        .await
        .unwrap();
        assert_eq!(
            client
                .get(endpoint["url"].as_str().unwrap())
                .send()
                .await
                .unwrap()
                .status(),
            502
        );
    }
}
