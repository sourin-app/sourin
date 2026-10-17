// ═══════════════════════════════════════════════════════════════════════
//  task-33：宿主解析契约的三个新字段 —— **向后兼容**验证
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要单独一个测试文件
// ```text
// Lead 的三个条件之一：
//   「做完必须验证『老插件不受影响』——至少一条测试证明
//     不带新字段的候选序列化/反序列化后与原行为一致」
//
// 这正是本仓反复吃亏的点：加字段时忘了 serde default，
// 老插件的 JSON 没这些键 ⇒ 反序列化直接失败 ⇒ 整个插件不可用。
// ```
//
// # 本文件的判据（都是**机械**可判的）
// ```text
// ① 老 JSON（没有三个新键）能反序列化，且字段取默认值
// ② 老 JSON → StreamCandidate → 再序列化，**不新增任何键**（逐字不变）
// ③ 新字段能被正确读取（snake_case）
// ④ 设置了新字段时，序列化会带上（且 is_empty 逻辑正确）
// ⑤ StreamCandidate::new() 的默认值与老行为一致
// ```

use sourin_core::model::{StreamCandidate, StreamFlags};

/// 老插件会给的最朴素 JSON（**没有任何新字段**）
fn legacy_json() -> &'static str {
    r#"{"url":"https://cdn/x.m3u8","kind":"hls"}"#
}

#[test]
fn legacy_json_deserializes_with_defaults() {
    let c: StreamCandidate = serde_json::from_str(legacy_json()).expect(
        "★ 老插件不带新字段时必须能反序列化 —— 否则该插件整体不可用"
    );
    assert!(!c.needs_host_resolve);
    assert!(c.site_id.is_none());
    assert!(c.stream_flags.is_empty());
    assert_eq!(c.url, "https://cdn/x.m3u8");
}

#[test]
fn legacy_json_roundtrip_adds_no_keys() {
    /*
     * ★★ 这是最关键的一条。
     *
     * 若某个新字段忘了 `skip_serializing_if`，序列化结果就会多出键，
     * 下游（Dart fromJson / 插件回读）看到的结构就**变了**。
     * 本仓对「老插件行为逐字不变」的承诺是当真的。
     */
    let c: StreamCandidate = serde_json::from_str(legacy_json()).unwrap();
    let v = serde_json::to_value(&c).unwrap();
    let obj = v.as_object().unwrap();

    for k in ["needs_host_resolve", "site_id", "stream_flags"] {
        assert!(
            !obj.contains_key(k),
            "★ 老数据回序列化后不该多出 `{k}` —— 那样下游看到的结构就变了，"
        );
    }
}

#[test]
fn new_fields_parse_from_snake_case() {
    let j = r#"{
        "url": "https://s1/watch/123",
        "kind": "hls",
        "needs_host_resolve": true,
        "site_id": "S1",
        "stream_flags": {"drm": true, "hdr": false, "codec": "hevc"}
    }"#;
    let c: StreamCandidate = serde_json::from_str(j).expect("新字段必须能读");
    assert!(c.needs_host_resolve);
    assert_eq!(c.site_id.as_deref(), Some("S1"));
    assert!(c.stream_flags.drm);
    assert!(!c.stream_flags.hdr);
    assert_eq!(c.stream_flags.codec.as_deref(), Some("hevc"));
}

#[test]
fn new_fields_serialize_when_set() {
    let mut c = StreamCandidate::new("https://s1/watch/1", sourin_core::model::StreamKind::Hls);
    c.needs_host_resolve = true;
    c.site_id = Some("S1".into());
    c.stream_flags = StreamFlags {
        drm: true,
        hdr: false,
        codec: None,
    };
    let v = serde_json::to_value(&c).unwrap();
    assert_eq!(v["needs_host_resolve"], true);
    assert_eq!(v["site_id"], "S1");
    assert_eq!(v["stream_flags"]["drm"], true);
    // 空的 codec 不该出现
    assert!(
        v["stream_flags"].get("codec").is_none(),
        "codec=None 时不该序列化出这个键"
    );
}

#[test]
fn stream_flags_default_is_empty() {
    let f = StreamFlags::default();
    assert!(f.is_empty());
    assert!(!f.drm && !f.hdr && f.codec.is_none());
}

#[test]
fn new_constructor_matches_legacy_defaults() {
    let c = StreamCandidate::new("https://a.m3u8", sourin_core::model::StreamKind::Hls);
    assert!(!c.needs_host_resolve, "★ new() 必须默认 false，否则所有源瞬间不可播");
    assert!(c.site_id.is_none());
    assert!(c.stream_flags.is_empty());
}

#[test]
fn empty_stream_flags_is_omitted_entirely() {
    /*
     * ★ 最初版本没给 stream_flags 加 skip_serializing_if，
     *   于是全默认时会序列化出 `"stream_flags":{}`。
     *
     * 那虽然不影响语义（Dart 侧 {} 全取默认），
     * 但违背了「老数据回序列化后结构逐字不变」的承诺。
     *
     * ⚠⚠ 这是**测试先红、代码后改**的一条：
     *   `legacy_json_roundtrip_adds_no_keys` 报警后才发现我漏了
     *   skip_serializing_if。正是这个测试文件该抳的作用。
     */
    let c = StreamCandidate::new("https://a.m3u8", sourin_core::model::StreamKind::Hls);
    let v = serde_json::to_value(&c).unwrap();
    assert!(
        v.get("stream_flags").is_none(),
        "全默认时 stream_flags 应被**整个省略**，而不是序列化成空对象"
    );
}
