//! A sandboxed QuickJS VM, one per process, speaking length-prefixed CBOR frames on stdio (see
//! `PROTOCOL.md`). The binary (`src/main.rs`) wires these together; the tests live in `tests/`.

pub mod cli;
pub mod envelope;
pub mod frame;
pub mod sandbox;
pub mod vm;
