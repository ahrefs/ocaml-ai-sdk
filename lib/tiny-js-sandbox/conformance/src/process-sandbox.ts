// A pi-codemode sandbox whose VM is the tiny-js-sandbox binary: one child process per execution,
// length-prefixed CBOR on its stdio (PROTOCOL.md). The runner knows nothing about codemode; this
// shim evals js/codemode-wrapper.js in it and translates pi's per-process JSON frames to and from
// CBOR `message` frames carrying JSON text. It is the same seam as pi's own worker, inline and
// remote backends (`VmLauncher`), so pi's host logic runs unchanged on top of the runner.
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { CodemodeSandboxBase, type CodemodeSandboxBaseOptions } from "@earendil-works/pi-codemode";
import { decode, encode } from "./cbor.ts";

type VmLauncher = ConstructorParameters<typeof CodemodeSandboxBase>[1];

export interface RunnerOptions {
	/** Path of the binary. Default: `$RUNNER`, else the release build next to this package. */
	binary?: string;
	/** `--sandbox` mode. Default: `$RUNNER_SANDBOX`, else `full`. */
	sandbox?: "full" | "landlock" | "seccomp" | "none";
	/** `--memory-limit-mb`. Default 256; a smaller `memoryLimitBytes` of the sandbox lowers it. */
	memoryLimitMb?: number;
}

const DEFAULT_BINARY = fileURLToPath(new URL("../../target/release/tiny-js-sandbox", import.meta.url));
const WRAPPER = readFileSync(fileURLToPath(new URL("../../js/codemode-wrapper.js", import.meta.url)), "utf8");
const MAX_FRAME_BYTES = 16 * 1024 * 1024;
const EVAL_ID = 1;

/** Splits a byte stream into frames, checking the length before buffering the payload. */
class FrameReader {
	private chunks: Buffer[] = [];
	private size = 0;
	constructor(private readonly onFrame: (payload: Buffer) => void) {}

	push(chunk: Buffer): void {
		this.chunks.push(chunk);
		this.size += chunk.length;
		for (;;) {
			if (this.size < 4) return;
			const all = this.chunks.length === 1 ? this.chunks[0] : Buffer.concat(this.chunks);
			this.chunks = [all];
			const length = all.readUInt32LE(0);
			if (length === 0 || length > MAX_FRAME_BYTES) throw new Error(`frame length ${length} out of range`);
			if (all.length < 4 + length) return;
			const payload = all.subarray(4, 4 + length);
			const rest = all.subarray(4 + length);
			this.chunks = rest.length > 0 ? [rest] : [];
			this.size = rest.length;
			this.onFrame(payload);
		}
	}
}

function frame(envelope: Parameters<typeof encode>[0]): Buffer {
	const payload = encode(envelope);
	if (payload.length > MAX_FRAME_BYTES) throw new RangeError("frame exceeds the maximum frame size");
	const length = Buffer.alloc(4);
	length.writeUInt32LE(payload.length);
	return Buffer.concat([length, payload]);
}

function runnerLauncher(options: RunnerOptions): VmLauncher {
	const binary = options.binary ?? process.env.RUNNER ?? DEFAULT_BINARY;
	const sandbox = options.sandbox ?? process.env.RUNNER_SANDBOX ?? "full";
	return (data, events) => {
		const defaultMb = options.memoryLimitMb ?? 256;
		const memoryLimitMb =
			data.memoryLimitBytes === undefined ? defaultMb : Math.max(1, Math.min(defaultMb, Math.ceil(data.memoryLimitBytes / 1048576)));
		const args = [`--sandbox=${sandbox}`, `--memory-limit-mb=${memoryLimitMb}`];
		const child = spawn(binary, args, { stdio: ["pipe", "pipe", "pipe"] });
		let stderr = "";
		let dead = false;
		const fail = (message: string, name?: string) => {
			events.failure({ kind: "sandbox", ...(name === undefined ? {} : { name }), message });
		};
		const kill = () => {
			dead = true;
			child.kill("SIGKILL");
		};
		child.stderr.setEncoding("utf8");
		child.stderr.on("data", (chunk: string) => {
			stderr += chunk;
		});
		child.on("error", (error) => fail(error.message, error.name));
		// `close`, not `exit`: it comes after stdout is drained, so a `done` is never lost to the exit.
		child.on("close", (code, signal) =>
			fail(`Runner exited (code ${code}, signal ${signal}) before the script settled${stderr ? `: ${stderr.trim()}` : ""}`),
		);
		child.stdin.on("error", () => {});
		const write = (envelope: Parameters<typeof encode>[0]) => {
			if (!dead) child.stdin.write(frame(envelope));
		};
		const text = (value: unknown) => write({ t: "message", data: JSON.stringify(value) });

		let sawHello = false;
		const onFrame = (payload: Buffer) => {
			const f = decode(payload);
			switch (f.t) {
				case "hello":
					if (sawHello || f.proto !== 1) throw new Error(`bad hello (proto ${String(f.proto)})`);
					sawHello = true;
					write({ t: "eval", id: EVAL_ID, code: WRAPPER });
					text(data);
					text({ type: "check" });
					return;
				case "eval_result":
					if (f.ok !== true) throw new Error(`wrapper eval failed: ${String(f.error)}`);
					return;
				case "message": {
					if (typeof f.data !== "string") throw new Error("runner sent a bytes message");
					events.message(JSON.parse(f.data));
					return;
				}
				case "log":
					return;
				case "error":
					fail(`Runner error: ${String(f.message)}`);
					kill();
					return;
				default:
					throw new Error(`unexpected frame type ${String(f.t)}`);
			}
		};
		const reader = new FrameReader(onFrame);
		child.stdout.on("data", (chunk: Buffer) => {
			try {
				reader.push(chunk);
			} catch (error) {
				fail(`Runner protocol violation: ${error instanceof Error ? error.message : String(error)}`);
				kill();
			}
		});
		return {
			post: (message) => {
				text(message);
				text({ type: "check" });
			},
			stop: async () => {
				kill();
			},
		};
	};
}

export class RunnerSandbox extends CodemodeSandboxBase {
	constructor(options: CodemodeSandboxBaseOptions & RunnerOptions = {}) {
		super(options, runnerLauncher(options));
	}
}
