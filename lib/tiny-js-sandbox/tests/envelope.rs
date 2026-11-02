use minicbor::Encoder;
use tiny_js_sandbox::envelope::{
    decode_incoming, decode_outgoing, encode_incoming, encode_outgoing, Incoming, Outgoing, Payload,
};

fn enc(f: impl FnOnce(&mut Encoder<Vec<u8>>)) -> Vec<u8> {
    let mut e = Encoder::new(Vec::new());
    f(&mut e);
    e.into_writer()
}

fn bad_incoming(bytes: &[u8], needle: &str) {
    let err = decode_incoming(bytes).expect_err("must be rejected").0;
    assert!(err.contains(needle), "{err:?} should mention {needle:?}");
}

#[test]
fn round_trips() {
    let incoming = [
        Incoming::Eval {
            id: 7,
            code: "1+1".into(),
        },
        Incoming::Eval {
            id: (1 << 53) - 1,
            code: String::new(),
        },
        Incoming::Message(Payload::Text("héllo".into())),
        Incoming::Message(Payload::Bytes(vec![0, 255, 1])),
    ];
    for frame in incoming {
        assert_eq!(decode_incoming(&encode_incoming(&frame)).unwrap(), frame);
    }
    let outgoing = [
        Outgoing::Hello { proto: 1 },
        Outgoing::EvalResult {
            id: 1,
            result: Ok(Some(Payload::Text("2".into()))),
        },
        Outgoing::EvalResult {
            id: 2,
            result: Ok(Some(Payload::Bytes(vec![0, 255]))),
        },
        Outgoing::EvalResult {
            id: 3,
            result: Ok(None),
        },
        Outgoing::EvalResult {
            id: 4,
            result: Err("boom".into()),
        },
        Outgoing::Message(Payload::Text("hi".into())),
        Outgoing::Message(Payload::Bytes(vec![1, 2])),
        Outgoing::Log {
            level: "warn".into(),
            text: "x".into(),
        },
        Outgoing::Error {
            message: "bad frame".into(),
        },
    ];
    for frame in outgoing {
        assert_eq!(decode_outgoing(&encode_outgoing(&frame)).unwrap(), frame);
    }
}

/// The hex examples of PROTOCOL.md section 9 (payload part).
#[test]
fn matches_the_documented_examples() {
    let hex = |s: &str| -> Vec<u8> {
        s.split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect()
    };
    assert_eq!(
        encode_outgoing(&Outgoing::Hello { proto: 1 }),
        hex("a2 61 74 65 68 65 6c 6c 6f 65 70 72 6f 74 6f 01")
    );
    assert_eq!(
        encode_incoming(&Incoming::Eval {
            id: 1,
            code: "1+1".into()
        }),
        hex("a3 61 74 64 65 76 61 6c 62 69 64 01 64 63 6f 64 65 63 31 2b 31")
    );
    assert_eq!(
        encode_outgoing(&Outgoing::EvalResult {
            id: 4,
            result: Err("boom".into())
        }),
        hex("a4 61 74 6b 65 76 61 6c 5f 72 65 73 75 6c 74 62 69 64 04 62 6f 6b f4 65 65 72 72 6f 72 64 62 6f 6f 6d")
    );
    assert_eq!(
        encode_outgoing(&Outgoing::Log {
            level: "warn".into(),
            text: "x".into()
        }),
        hex("a3 61 74 63 6c 6f 67 65 6c 65 76 65 6c 64 77 61 72 6e 64 74 65 78 74 61 78")
    );
}

#[test]
fn any_key_order_is_accepted() {
    let bytes = enc(|e| {
        e.map(3).unwrap().str("code").unwrap().str("x").unwrap();
        e.str("id")
            .unwrap()
            .u8(5)
            .unwrap()
            .str("t")
            .unwrap()
            .str("eval")
            .unwrap();
    });
    assert_eq!(
        decode_incoming(&bytes).unwrap(),
        Incoming::Eval {
            id: 5,
            code: "x".into()
        }
    );
}

#[test]
fn rejects_indefinite_lengths() {
    // indefinite map
    bad_incoming(
        &[0xbf, 0x61, b't', 0x65, b'e', b'v', b'a', b'l', b'l', 0xff],
        "indefinite",
    );
    // indefinite text value
    let mut bytes = enc(|e| {
        e.map(2)
            .unwrap()
            .str("t")
            .unwrap()
            .str("message")
            .unwrap()
            .str("data")
            .unwrap();
    });
    bytes.extend_from_slice(&[0x7f, 0x61, b'a', 0xff]);
    bad_incoming(&bytes, "indefinite");
    // indefinite bytes value
    let mut bytes = enc(|e| {
        e.map(2)
            .unwrap()
            .str("t")
            .unwrap()
            .str("message")
            .unwrap()
            .str("data")
            .unwrap();
    });
    bytes.extend_from_slice(&[0x5f, 0x41, 1, 0xff]);
    bad_incoming(&bytes, "indefinite");
}

#[test]
fn rejects_tags() {
    let mut bytes = enc(|e| {
        e.map(2)
            .unwrap()
            .str("t")
            .unwrap()
            .str("message")
            .unwrap()
            .str("data")
            .unwrap();
    });
    bytes.extend_from_slice(&[0xc1, 0x61, b'a']);
    bad_incoming(&bytes, "tag");
}

#[test]
fn rejects_floats_undefined_and_simple_values() {
    for tail in [
        &[0xf9, 0x3c, 0x00][..],
        &[0xfa, 0, 0, 0, 0],
        &[0xfb, 0, 0, 0, 0, 0, 0, 0, 0],
        &[0xf7],
        &[0xf0],
        &[0xf8, 0xff],
    ] {
        let mut bytes = enc(|e| {
            e.map(2)
                .unwrap()
                .str("t")
                .unwrap()
                .str("message")
                .unwrap()
                .str("data")
                .unwrap();
        });
        bytes.extend_from_slice(tail);
        assert!(decode_incoming(&bytes).is_err(), "{tail:?}");
    }
}

#[test]
fn rejects_negative_and_huge_integers() {
    let mut bytes = enc(|e| {
        e.map(3)
            .unwrap()
            .str("t")
            .unwrap()
            .str("eval")
            .unwrap()
            .str("code")
            .unwrap()
            .str("")
            .unwrap();
        e.str("id").unwrap();
    });
    bytes.push(0x20); // -1
    bad_incoming(&bytes, "negative");
    let bytes = enc(|e| {
        e.map(3)
            .unwrap()
            .str("t")
            .unwrap()
            .str("eval")
            .unwrap()
            .str("code")
            .unwrap()
            .str("")
            .unwrap();
        e.str("id").unwrap().u64(1 << 53).unwrap();
    });
    bad_incoming(&bytes, "2^53");
}

#[test]
fn rejects_invalid_utf8() {
    let bytes = enc(|e| {
        e.map(2)
            .unwrap()
            .str("t")
            .unwrap()
            .str("eval")
            .unwrap()
            .str("id")
            .unwrap()
            .u8(1)
            .unwrap();
    });
    // code: text(1) 0xff
    let mut with_bad = bytes.clone();
    with_bad[0] = 0xa3;
    with_bad.extend_from_slice(&[0x64, b'c', b'o', b'd', b'e', 0x61, 0xff]);
    assert!(decode_incoming(&with_bad).is_err());
    // a bad key
    let key = [0xa1, 0x61, 0xff, 0x01];
    assert!(decode_incoming(&key).is_err());
}

#[test]
fn rejects_unknown_keys_and_types() {
    let extra = enc(|e| {
        e.map(3).unwrap().str("t").unwrap().str("message").unwrap();
        e.str("data")
            .unwrap()
            .str("x")
            .unwrap()
            .str("extra")
            .unwrap()
            .u8(1)
            .unwrap();
    });
    bad_incoming(&extra, "unknown key");
    let unknown = enc(|e| {
        e.map(1).unwrap().str("t").unwrap().str("hello").unwrap();
    });
    bad_incoming(&unknown, "unknown frame type");
    // runner-to-parent types are not accepted from the parent
    let hello = encode_outgoing(&Outgoing::Hello { proto: 1 });
    assert!(decode_incoming(&hello).is_err());
    // and vice versa
    assert!(decode_outgoing(&encode_incoming(&Incoming::Message(Payload::Text("x".into())))).is_ok());
    assert!(decode_outgoing(&encode_incoming(&Incoming::Eval { id: 1, code: "".into() })).is_err());
}

#[test]
fn rejects_missing_wrong_type_and_duplicate_keys() {
    let missing = enc(|e| {
        e.map(2)
            .unwrap()
            .str("t")
            .unwrap()
            .str("eval")
            .unwrap()
            .str("id")
            .unwrap()
            .u8(1)
            .unwrap();
    });
    bad_incoming(&missing, "missing key");
    let no_t = enc(|e| {
        e.map(1).unwrap().str("data").unwrap().str("x").unwrap();
    });
    bad_incoming(&no_t, "missing key");
    let wrong = enc(|e| {
        e.map(2)
            .unwrap()
            .str("t")
            .unwrap()
            .str("message")
            .unwrap()
            .str("data")
            .unwrap()
            .u8(1)
            .unwrap();
    });
    bad_incoming(&wrong, "text or bytes");
    let null_data = enc(|e| {
        e.map(2)
            .unwrap()
            .str("t")
            .unwrap()
            .str("message")
            .unwrap()
            .str("data")
            .unwrap()
            .null()
            .unwrap();
    });
    bad_incoming(&null_data, "text or bytes");
    let dup = enc(|e| {
        e.map(3).unwrap().str("t").unwrap().str("message").unwrap();
        e.str("data")
            .unwrap()
            .str("a")
            .unwrap()
            .str("data")
            .unwrap()
            .str("b")
            .unwrap();
    });
    bad_incoming(&dup, "duplicate");
    let non_text_key = enc(|e| {
        e.map(1).unwrap().u8(1).unwrap().str("x").unwrap();
    });
    bad_incoming(&non_text_key, "keys must be text");
    let too_many = enc(|e| {
        e.map(5).unwrap();
        for k in ["t", "a", "b", "c", "d"] {
            e.str(k).unwrap().null().unwrap();
        }
    });
    bad_incoming(&too_many, "keys");
}

#[test]
fn rejects_trailing_bytes_and_truncation() {
    let mut bytes = encode_incoming(&Incoming::Message(Payload::Text("x".into())));
    let full = bytes.clone();
    bytes.push(0);
    bad_incoming(&bytes, "trailing");
    for cut in 0..full.len() {
        assert!(decode_incoming(&full[..cut]).is_err(), "cut at {cut}");
    }
}

#[test]
fn rejects_containers_and_deep_nesting_without_recursing() {
    // not a map
    bad_incoming(&[0x80], "must be a map");
    bad_incoming(&[0x01], "must be a map");
    // a container as a value
    let mut bytes = enc(|e| {
        e.map(2)
            .unwrap()
            .str("t")
            .unwrap()
            .str("message")
            .unwrap()
            .str("data")
            .unwrap();
    });
    bytes.extend_from_slice(&[0x81, 0x01]);
    bad_incoming(&bytes, "containers");
    // enormous nesting, as a top-level item and as a value
    let deep = vec![0x81u8; 4 * 1024 * 1024];
    assert!(decode_incoming(&deep).is_err());
    let mut bytes = enc(|e| {
        e.map(2)
            .unwrap()
            .str("t")
            .unwrap()
            .str("message")
            .unwrap()
            .str("data")
            .unwrap();
    });
    bytes.extend_from_slice(&deep);
    assert!(decode_incoming(&bytes).is_err());
    let mut maps = enc(|e| {
        e.map(2)
            .unwrap()
            .str("t")
            .unwrap()
            .str("message")
            .unwrap()
            .str("data")
            .unwrap();
    });
    maps.extend(std::iter::repeat_n([0xa1u8, 0x61, b'k'], 100_000).flatten());
    assert!(decode_incoming(&maps).is_err());
}

#[test]
fn rejects_lying_lengths() {
    // text claims 1 GiB but the frame ends
    let bytes = [0xa1, 0x61, b't', 0x7a, 0x40, 0, 0, 0, b'a'];
    assert!(decode_incoming(&bytes).is_err());
    // a map claiming 2^64-1 entries
    let bytes = [0xbb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff];
    assert!(decode_incoming(&bytes).is_err());
    let bytes = [0xbb, 0, 0, 0, 0, 0, 0, 0, 0x04, 0x61, b't'];
    assert!(decode_incoming(&bytes).is_err());
}
