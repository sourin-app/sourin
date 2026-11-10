use super::*;

#[test]
fn request_matches_independent_public_wasm_capture_byte_for_byte() {
    // Public module SHA256: 9b342d5503a696caeacbb626bb33bec656cae441d013e394f854c671ea176273.
    // Captured from its create_decode_request export using a synthetic payload.
    // The reference output was generated before this Rust implementation existed.
    let actual = request_at("PAN1-test-payload", "PAN1", 1794272200982,
        "74f913d0167165aff37434375a17d3a2");
    let expected = "0a1150414e312d746573742d7061796c6f6164120450414e31189692d4979c34222037346639313364303136373136356166663337343334333735613137643361322a4042334432393843394433424444423131333041304332353342464133453134433445394530423637383239334132354536373939414434364136464432314239320e636f6d2e7765622e706c617965723801";
    assert_eq!(hex(&actual, false), expected);
}

#[test]
fn request_preserves_selected_line_and_reserved_payload_bytes() {
    let value = "prefix-%2F+keep/&token=synthetic|tail";
    let bytes = request_at(value, "line-with-name", 1234, "00000000000000000000000000000001");
    let mut reader = Reader { bytes: &bytes, at: 0 };
    assert_eq!(reader.varint().unwrap(), 10);
    assert_eq!(reader.text().unwrap(), value);
    assert_eq!(reader.varint().unwrap(), 18);
    assert_eq!(reader.text().unwrap(), "line-with-name");
    assert_ne!(bytes, request_at(value, "line-with-name", 1235, "00000000000000000000000000000001"));
    assert_ne!(bytes, request_at(value, "line-with-name", 1234, "00000000000000000000000000000002"));
}

fn envelope(code: u64, message: &str, url: &str) -> Vec<u8> {
    let mut bytes = Vec::new();
    number(&mut bytes, 1, code);
    string(&mut bytes, 2, message);
    string(&mut bytes, 3, url);
    bytes
}

#[test]
fn response_uses_the_official_data_field_and_keeps_signed_query() {
    // Fields were independently checked against the public parse_decode_response export.
    let url = "https://media.invalid/master.m3u8?a=one%2Btwo&token=synthetic";
    let mut bytes = envelope(1, "success", url);
    number(&mut bytes, 5, 0);
    string(&mut bytes, 30, "unknown forward-compatible field");
    assert_eq!(response(&bytes).unwrap(), url);
    let message_only = [vec![8, 1], {
        let mut out = Vec::new(); string(&mut out, 2, url); out
    }].concat();
    assert!(response(&message_only).is_err(), "a URL in the message is not a media result");
}

#[test]
fn errors_preserve_access_decisions_without_reflecting_sensitive_fields() {
    for (message, expected) in [
        ("PLATFORM_NOT_ALLOWED", "指定客户端"),
        ("LOGIN_REQUIRED", "账号"),
        ("VIP_REQUIRED", "会员权限"),
    ] {
        let error = response(&envelope(401, message, "https://media.invalid/?token=secret")).unwrap_err();
        assert!(error.contains(expected));
        assert!(!error.contains("secret"));
    }
    let error = response(&envelope(401, "denied https://media.invalid/?token=private", "")).unwrap_err();
    assert!(error.contains("code=401"));
    assert!(!error.contains("private"));
    for url in ["", "file:///private/movie", "javascript:payload", "https://user:password@media.invalid/v"] {
        let error = response(&envelope(1, "", url)).unwrap_err();
        assert!(!error.contains(url) || url.is_empty());
        assert!(!error.contains("password"));
    }
}

#[test]
fn response_rejects_malformed_and_oversized_protobuf() {
    for bytes in [vec![], vec![0], vec![8, 128], vec![26, 127], vec![10, 1, 0],
        vec![0xff; 12], vec![8, 1, 26, 1, 0xff]] {
        assert!(response(&bytes).is_err(), "must reject malformed response");
    }
    assert!(response(&vec![0; MAX_RESPONSE + 1]).is_err());
    assert!(request(&"a".repeat(MAX_RESPONSE + 1), "line").is_err());
}
