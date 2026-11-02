//! Deterministic fuzzing of the frame and envelope decoders: random bytes, mutated valid frames
//! and deep nesting must never panic, and no single allocation may be much larger than the input.
//! The counting allocator tracks the largest allocation per thread, so the tests can run in parallel.

use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
    io::Cursor,
};
use tiny_js_sandbox::{
    envelope::{decode_incoming, decode_outgoing, encode_incoming, encode_outgoing, Incoming, Outgoing, Payload},
    frame::read_frame,
};

struct Counting;
thread_local! {
    static LARGEST: Cell<usize> = const { Cell::new(0) };
}

fn note(size: usize) {
    let _ = LARGEST.try_with(|c| c.set(c.get().max(size)));
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        note(layout.size());
        System.alloc(layout)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        note(new_size);
        System.realloc(ptr, layout, new_size)
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    fn bytes(&mut self, len: usize) -> Vec<u8> {
        (0..len).map(|_| self.next() as u8).collect()
    }
}

/// Runs `f` and returns the largest single allocation it made.
fn largest_allocation(f: impl FnOnce()) -> usize {
    LARGEST.with(|c| c.set(0));
    f();
    LARGEST.with(Cell::get)
}

fn corpus() -> Vec<Vec<u8>> {
    vec![
        encode_incoming(&Incoming::Eval {
            id: 3,
            code: "host.post('x')".into(),
        }),
        encode_incoming(&Incoming::Message(Payload::Bytes(vec![1, 2, 3]))),
        encode_outgoing(&Outgoing::Hello { proto: 1 }),
        encode_outgoing(&Outgoing::EvalResult {
            id: 9,
            result: Err("boom".into()),
        }),
        encode_outgoing(&Outgoing::Log {
            level: "warn".into(),
            text: "x".into(),
        }),
    ]
}

#[test]
fn decoders_never_panic_and_stay_proportional() {
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    let corpus = corpus();
    for round in 0..20_000 {
        // Random bytes, or a mutated valid frame.
        let input = match round % 3 {
            0 => {
                let len = rng.below(64);
                rng.bytes(len)
            }
            _ => {
                let mut bytes = corpus[rng.below(corpus.len())].clone();
                for _ in 0..1 + rng.below(3) {
                    let i = rng.below(bytes.len());
                    bytes[i] = rng.next() as u8;
                }
                if rng.below(4) == 0 {
                    bytes.truncate(rng.below(bytes.len() + 1));
                }
                bytes
            }
        };
        let largest = largest_allocation(|| {
            let _ = decode_incoming(&input);
            let _ = decode_outgoing(&input);
        });
        assert!(
            largest <= 4 * input.len() + 4096,
            "allocated {largest} bytes for {} bytes of input {input:?}",
            input.len()
        );
    }
}

#[test]
fn frame_reader_stays_proportional_to_what_was_sent() {
    let mut rng = Rng(42);
    for round in 0..2_000 {
        // Any prefix, including lying ones up to 1 GiB, followed by a short body.
        let claimed = match round % 4 {
            0 => rng.next() as u32,
            1 => 1 << 30,
            _ => rng.below(5000) as u32,
        };
        let body_len = rng.below(4096);
        let mut input = claimed.to_le_bytes().to_vec();
        input.extend(rng.bytes(body_len));
        let largest = largest_allocation(|| {
            let _ = read_frame(&mut Cursor::new(&input), 1 << 30);
        });
        assert!(
            largest <= 2 * body_len + 4096,
            "claimed {claimed}, sent {body_len}, allocated {largest}"
        );
        // Over the cap: rejected without allocating.
        let largest = largest_allocation(|| {
            let _ = read_frame(&mut Cursor::new(&input), 1024);
        });
        assert!(largest <= 2 * body_len.min(1024) + 4096);
    }
}

#[test]
fn deep_nesting_is_rejected_cheaply() {
    for opener in [0x81u8, 0xa1, 0xc1, 0x9f, 0xbf] {
        for depth in [1usize, 1000, 1_000_000] {
            let mut input = vec![opener; depth];
            input.push(0);
            let largest = largest_allocation(|| {
                assert!(decode_incoming(&input).is_err());
                assert!(decode_outgoing(&input).is_err());
            });
            assert!(largest <= 4096, "allocated {largest} bytes for nesting {depth}");
        }
    }
}
