//! A sandboxed QuickJS VM that runs one codemode script, speaking JSONL on stdio. The binary
//! (`src/main.rs`) wires these together; the tests live in `tests/`.

pub mod cli;
pub mod protocol;
pub mod sandbox;
pub mod vm;
