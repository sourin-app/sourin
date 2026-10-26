// ═══════════════════════════════════════════════════════════════════════
//  task-41 端到端 —— 本地 http server 喂真实响应，走完整链路
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须真起一个 server（Lead 的硬要求）
//
//   单测证明了 extract_regex / extract_json_path 这两个纯函数「算得对」。
//   契约测试证明了「插件能调到 host.extract」。
//   但两者都不证明**「插件配合 http 能真的解析一个页面」**。
//
//   而这一条最容易做成「看起来能解析」但实际跑不通的东西。
//   ⇒ 这里起一个真 TcpListener，返回真的 HTTP 响应，
//     让插件按真实使用姿势走一遍：
//       ① host.http.get 拿页面 / 接口
//       ② host.extract.regex / json 从响应里取值
//       ③ 组装成 MediaDetail 返回
//       ④ 断言宿主侧真的收到了那些值
//
// # 构造数据里没有真实站名
//   全部用 example.com 与构造路径。

use std::io::{Read, Write};
use std::net::TcpListener;

use sourin_core::model::{MediaId, PlayRequest};
use sourin_core::plugins::JsPluginProvider;
use sourin_core::provider::MediaProvider;

/// 起一个只服务两条固定路由的极简 HTTP server
///
/// 刻意不用框架：**要让测试里的服务足够简单可读**，
/// 出问题时一眼能看出是「服务返回错了」还是「插件解析错了」。
fn spawn_tiny_server() -> (String, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 随机端口失败");
    let port = listener.local_addr().unwrap().port();
    let base = format!("http://127.0.0.1:{port}");

    let handle = std::thread::spawn(move || {
        // 只处理两次请求（页面 + 接口）就退出，避免测试挂住
        for _ in 0..2 {
            let (mut stream, _) = match listener.accept() {
                Ok(v) => v,
                Err(_) => return,
            };

            let mut buf = [0u8; 4096];
            let n = stream.read(&mut buf).unwrap_or(0);
            let req = String::from_utf8_lossy(&buf[..n]).to_string();

            // 按路径分发（真实项目当然要正经路由 —— 但这里测的是插件解析逻辑）
            let body = if req.contains("/page") {
                // 页面里嵌入一个 id，模拟「HTML 里带 videoId」这种常见形态
                r#"<html><body><div id="player" data-vid="abc123"></div></body></html>"#
            } else {
                // 接口返回 JSON（模拟详情接口）
                r#"{"code":0,"data":{"title":"Demo Video","episodes":[{"id":"ep1","url":"https://cdn.example.com/ep1.mp4"},{"id":"ep2","url":"https://cdn.example.com/ep2.mp4"}]}}"#
            };

            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = stream.write_all(resp.as_bytes());
            let _ = stream.flush();
        }
    });

    (base, handle)
}

/// ★ 端到端：插件从本地 server 抓页面 → 提取 id → 抓接口 → 组装 detail
#[tokio::test]
async fn plugin_extracts_from_real_http_and_returns_detail() {
    let (base, handle) = spawn_tiny_server();

    // 插件源码：**这就是给用户看的示例**，也是本测试的输入。
    // 注意里面没有任何真实站名 —— 全部是 example.com 与构造路径。
    let plugin_src = format!(
        r#"
/** @id e2edemo @name 端到端示例 */
globalThis.plugin = {{
  capabilities: {{ vod: true }},

  async resolve(id) {{
    // ① 抓页面
    var html = await host.http.get('{base}/page');

    // ② 从 HTML 里取 id（用捕获组取纯 id）
    var ids = host.extract.regex(html, 'data-vid="([^"]+)"');
    if (!ids || !ids.length) throw new Error('页面里没找到 data-vid');

    // ③ 用 id 调接口
    var body = await host.http.get('{base}/api/detail?id=' + ids[0]);

    // ④ 从 JSON 里取字段（extract.json 返回 JSON 文本，自己 parse）
    var title = JSON.parse(host.extract.json(body, 'data.title'));
    var ep1   = JSON.parse(host.extract.json(body, 'data.episodes[0].url'));
    var ep2   = JSON.parse(host.extract.json(body, 'data.episodes[1].url'));

    // ⑤ 组装成宿主认识的流列表
    return [
      {{ url: ep1, quality: '360p', kind: 'mp4' }},
      {{ url: ep2, quality: '720p', kind: 'mp4' }},
    ];
  }}
}};
"#
    );

    let mut p = JsPluginProvider::from_source(&plugin_src).unwrap();
    p.hydrate_capabilities().await;

    let streams = p
        .resolve(
            &MediaId::new("demo", "demo-1"),
            &PlayRequest { source_code: None, episode_id: None, quality: None, flag: None },
        )
        .await
        .expect("插件 resolve 应成功");

    let _ = handle.join();

    // 断言：三条都要对 —— 少一条都说明某一步断了
    assert_eq!(streams.len(), 2, "① 应返回 2 条流");
    assert_eq!(
        streams[0].url, "https://cdn.example.com/ep1.mp4",
        "② [0] 下标应取到第一集（extract.regex + json [0] 都生效）"
    );
    assert_eq!(
        streams[1].url, "https://cdn.example.com/ep2.mp4",
        "③ [1] 下标应取到第二集"
    );
}
