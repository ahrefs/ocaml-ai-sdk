use ai_sdk_quickjs_runner::protocol::parse_result;

#[test]
fn parses_results() {
    let r = parse_result(r#"{"type":"result","id":3,"ok":true,"payload":"{\"a\":1}"}"#).unwrap();
    assert_eq!(
        (r.id, r.ok, r.payload.as_deref(), r.properties),
        (3.0, true, Some("{\"a\":1}"), None)
    );
    let r = parse_result(r#"{"type":"result","id":4,"ok":false,"payload":"boom","properties":"{}"}"#).unwrap();
    assert!(!r.ok);
    assert_eq!(r.properties.as_deref(), Some("{}"));
}

#[test]
fn rejects_other_messages() {
    assert!(parse_result(r#"{"type":"cancel"}"#).is_err());
    assert!(parse_result("not json").is_err());
    assert!(parse_result(r#"{"type":"result","ok":true}"#).is_err());
}
