use std::io::Cursor;
use tiny_js_sandbox::frame::{read_frame, write_frame, FrameError};

fn framed(payload: &[u8]) -> Vec<u8> {
    let mut v = (payload.len() as u32).to_le_bytes().to_vec();
    v.extend_from_slice(payload);
    v
}

#[test]
fn round_trip_and_clean_eof() {
    let mut buffer = Vec::new();
    write_frame(&mut buffer, b"abc", 16).unwrap();
    write_frame(&mut buffer, b"de", 16).unwrap();
    assert_eq!(&buffer[..4], &[3, 0, 0, 0]);
    let mut input = Cursor::new(buffer);
    assert_eq!(read_frame(&mut input, 16).unwrap(), Some(b"abc".to_vec()));
    assert_eq!(read_frame(&mut input, 16).unwrap(), Some(b"de".to_vec()));
    assert_eq!(read_frame(&mut input, 16).unwrap(), None);
}

#[test]
fn length_is_little_endian() {
    let mut input = Cursor::new([1u8, 1, 0, 0].into_iter().chain(vec![9; 257]).collect::<Vec<_>>());
    assert_eq!(read_frame(&mut input, 1000).unwrap().unwrap().len(), 257);
}

#[test]
fn zero_length_is_rejected() {
    let mut input = Cursor::new(vec![0, 0, 0, 0]);
    assert!(matches!(read_frame(&mut input, 16), Err(FrameError::Empty)));
}

#[test]
fn oversize_length_is_rejected_before_reading() {
    // The prefix claims 17 bytes against a cap of 16; the payload is never touched.
    let mut input = Cursor::new(framed(&[0; 17]));
    assert!(matches!(
        read_frame(&mut input, 16),
        Err(FrameError::TooLarge { len: 17, max: 16 })
    ));
    assert_eq!(input.position(), 4);
    let mut input = Cursor::new(u32::MAX.to_le_bytes().to_vec());
    assert!(matches!(
        read_frame(&mut input, 1 << 30),
        Err(FrameError::TooLarge { .. })
    ));
}

#[test]
fn exactly_the_cap_is_accepted() {
    let mut input = Cursor::new(framed(&[7; 16]));
    assert_eq!(read_frame(&mut input, 16).unwrap().unwrap().len(), 16);
}

#[test]
fn truncation_is_rejected() {
    for bytes in [vec![1], vec![1, 0, 0], vec![5, 0, 0, 0], vec![5, 0, 0, 0, 1, 2]] {
        let mut input = Cursor::new(bytes);
        assert!(matches!(read_frame(&mut input, 16), Err(FrameError::Truncated)));
    }
}

#[test]
fn writes_respect_the_cap() {
    let mut buffer = Vec::new();
    assert!(matches!(
        write_frame(&mut buffer, &[0; 17], 16),
        Err(FrameError::TooLarge { .. })
    ));
    assert!(matches!(write_frame(&mut buffer, &[], 16), Err(FrameError::Empty)));
    assert!(buffer.is_empty(), "nothing is written on failure");
}
