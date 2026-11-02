//! Framing: a `u32` little-endian length, then exactly that many bytes. The length is checked
//! against the cap before anything is allocated or read.

use std::{
    fmt,
    io::{self, Read, Write},
};

/// Why a frame could not be read or written. Every variant is fatal for the connection.
#[derive(Debug)]
pub enum FrameError {
    /// The length prefix is 0.
    Empty,
    /// The length prefix (or an outgoing payload) exceeds the cap.
    TooLarge {
        len: u64,
        max: u32,
    },
    /// EOF inside the length prefix or the payload.
    Truncated,
    Io(io::Error),
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => write!(f, "empty frame"),
            Self::TooLarge { len, max } => write!(f, "frame of {len} bytes exceeds the limit of {max} bytes"),
            Self::Truncated => write!(f, "end of input inside a frame"),
            Self::Io(e) => write!(f, "i/o error: {e}"),
        }
    }
}

impl From<io::Error> for FrameError {
    fn from(e: io::Error) -> Self {
        match e.kind() {
            io::ErrorKind::UnexpectedEof => Self::Truncated,
            _ => Self::Io(e),
        }
    }
}

/// Reads the next frame payload. `Ok(None)` is a clean EOF at a frame boundary. The payload
/// buffer grows as bytes arrive, so a lying length prefix costs no more than what was sent.
pub fn read_frame(input: &mut impl Read, max: u32) -> Result<Option<Vec<u8>>, FrameError> {
    let mut prefix = [0u8; 4];
    let mut filled = 0;

    // read the u32LE length
    while filled < prefix.len() {
        match input.read(&mut prefix[filled..]) {
            Ok(0) if filled == 0 => return Ok(None),
            Ok(0) => return Err(FrameError::Truncated),
            Ok(n) => filled += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e.into()),
        }
    }
    let len = u32::from_le_bytes(prefix);
    match len {
        0 => return Err(FrameError::Empty),
        len if len > max => return Err(FrameError::TooLarge { len: len.into(), max }),
        _ => {}
    }
    let mut payload = Vec::new();
    let read = input.take(len.into()).read_to_end(&mut payload)?;
    match read == len as usize {
        true => Ok(Some(payload)),
        false => Err(FrameError::Truncated),
    }
}

/// Writes one frame (the prefix, then the payload, without copying it) and flushes. Nothing is written when the payload is
/// empty or exceeds `max`.
pub fn write_frame(output: &mut impl Write, payload: &[u8], max: u32) -> Result<(), FrameError> {
    let len = u32::try_from(payload.len())
        .ok()
        .filter(|&len| len <= max)
        .ok_or(FrameError::TooLarge {
            len: payload.len() as u64,
            max,
        })?;
    if len == 0 {
        return Err(FrameError::Empty);
    }
    output.write_all(&len.to_le_bytes())?;
    output.write_all(payload)?;
    output.flush()?;
    Ok(())
}
