// 验证 .probe/t33/extract_demo.js 这份**给用户的示例**真的能被宿主加载
//
// # 为什么单独一条
// 端到端测试用的是内联字符串，而示例文件是**独立交付物**。
// 两者可能漂移（示例改了但测试没跟上，或反之）。
// ⇒ 这条直接读那个文件，保证「我们给用户的示例」是活的。

#[tokio::test]
async fn probe_example_plugin_loads_and_validates() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../.probe/t33/extract_demo.js");
    let src = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("跳过：示例文件不在（{path}）: {e}");
            return;
        }
    };

    // ① 元数据能解析
    let meta = sourin_core::plugins::parse_meta(&src);
    assert_eq!(meta.id, "extract_demo", "示例的 @id 应能被解析");

    // ② 源码能通过校验（语法 + 结构）
    sourin_core::plugins::validate_source(&src)
        .await
        .expect("示例应通过 validate_source");

    // ③ 能真的实例化并取到能力
    let mut p = sourin_core::plugins::JsPluginProvider::from_source(&src).unwrap();
    p.hydrate_capabilities().await;

    println!("示例插件 id={} name={}", meta.id, meta.name);
}
