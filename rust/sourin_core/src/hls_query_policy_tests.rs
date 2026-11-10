use super::*;

const KEYS: &[&str] = &["pid", "utk", "uk", "spl", "t", "sign", "ip"];

#[test]
fn declared_media_query_preserves_allowed_raw_pairs_and_child_ownership() {
    let parent = "https://media.invalid/a/root.m3u8?other=x&pid=a+b&sign=x%2fY&pid=c%2B&empty=x&t=&ip=127.0.0.1";
    let policy = ScopedHlsQueryPolicy::new(parent, KEYS).unwrap();
    assert_eq!(policy.resolve(parent, "../segment.ts", true).unwrap(),
        "https://media.invalid/segment.ts?pid=a+b&sign=x%2fY&pid=c%2B&t=&ip=127.0.0.1");
    for child in ["segment.ts?own=1+2&sign=child%2f", "segment.ts?"] {
        assert_eq!(policy.resolve(parent, child, true).unwrap(), format!("https://media.invalid/a/{child}"));
    }
    assert_eq!(policy.resolve(parent, "init.bin", false).unwrap(), "https://media.invalid/a/init.bin");
}

#[test]
fn declared_media_query_rejects_origin_changes_and_strips_fragments() {
    let parent = "https://media.invalid/a/root.m3u8?pid=fixture";
    let policy = ScopedHlsQueryPolicy::new(parent, KEYS).unwrap();
    for uri in ["https://other.invalid/s.ts", "//other.invalid/s.ts", "http://media.invalid/s.ts",
        "https://media.invalid:444/s.ts", "https://user:secret@media.invalid/s.ts"] {
        assert!(policy.resolve(parent, uri, true).is_err());
    }
    assert_eq!(policy.resolve(parent, "//media.invalid:443/s.ts#ignore", true).unwrap(),
        "https://media.invalid/s.ts?pid=fixture");
    assert!(policy.resolve("https://other.invalid/root.m3u8?pid=fixture", "s.ts", true).is_err());
}

#[test]
fn declared_media_query_effective_nested_base_and_tag_rules() {
    let parent = "https://media.invalid/final/path/root.m3u8?pid=root&unknown=drop";
    let policy = ScopedHlsQueryPolicy::new(parent, KEYS).unwrap();
    let nested = policy.resolve(parent, "../child.m3u8?sign=nested%2B", true).unwrap();
    assert_eq!(nested, "https://media.invalid/final/child.m3u8?sign=nested%2B");
    assert_eq!(policy.resolve(&nested, "./s.ts", true).unwrap(), "https://media.invalid/final/s.ts?sign=nested%2B");
    let text = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-MAP:URI=\"/init.bin\"\n#EXTINF:2,\n../s%20p.ts\n";
    let rewritten = policy.rewrite(text, parent, "http://127.0.0.1:9/p/T/").unwrap();
    assert!(rewritten.contains("URI=\"http://127.0.0.1:9/p/T/https/media.invalid/final/path/key.bin\""));
    assert!(rewritten.contains("URI=\"http://127.0.0.1:9/p/T/https/media.invalid/init.bin\""));
    assert!(rewritten.contains("/final/s%2520p.ts?pid=root\n"));
}
