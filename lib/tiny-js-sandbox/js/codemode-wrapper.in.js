// pi-codemode on tiny-js-sandbox. GENERATED into codemode-wrapper.js by conformance/gen-wrapper.mjs
// (`pnpm gen-wrapper`): this template with the marker below replaced by the source of js/prelude.js as a JSON string.
//
// js/prelude.js is PRELUDE_SOURCE of @earendil-works/pi-codemode 1.4.0 (tag v1.4.0 of
// https://github.com/earendil-works/pi, MIT, Copyright (c) 2025 Mario Zechner), included UNMODIFIED.
// The glue around it is ours.
//
// Usage: send this file's contents as ONE `eval` frame to tiny-js-sandbox (it evaluates to undefined),
// then drive it with `message` frames carrying JSON text (all values below are JSON strings):
//
//   parent -> VM  start data   pi's VmStartData: {code, tools, globals, store, memoryLimitBytes?}. Must be
//                              the first message. `memoryLimitBytes` is not applied here: pass the runner
//                              --memory-limit-mb. `deterministic` is not supported (crash).
//   parent -> VM  {"type":"result","id","ok","payload"?,"properties"?}   pi's HostToWorkerMessage
//   parent -> VM  {"type":"check"}   SEND ONE AFTER EVERY start data AND EVERY result. The runner handles
//                                    frames in order and drains promise jobs after each, so when the check
//                                    runs the VM is quiescent: if no tool call is pending, the script is
//                                    waiting on a promise that can never settle and is failed (pi's
//                                    `stalled()`; there is no way to detect quiescence from inside JS).
//   VM -> parent  pi's WorkerToHostMessage: call / output / done / crash, via host.post.
//
// After `done` the run is over: the VM ignores everything and sends nothing more. A script that keeps
// running after `done` cannot be interrupted from inside, so the embedder must kill the process on
// `done` (this used to be a Rust interrupt handler). The script gets no access to `host`: it is
// captured in this closure and removed from the global object before any user code is compiled.
(function () {
	"use strict";
	const host = globalThis.host;
	const { stringify, parse } = JSON;
	const toString = String;
	delete globalThis.host;
	// The prelude defines its own `console` global (user console output becomes `output` items).
	delete globalThis.console;

	// The prelude is compiled as its own script, named so that it filters its frames out of stacks.
	const prelude = host.evalAs(/*@PRELUDE@*/, "codemode-prelude.js");

	let finished = false;
	let started = false;
	let api;

	const post = (message) => host.post(stringify(message));
	const crash = (message) => {
		finished = true;
		try {
			post({ type: "crash", message: toString(message) });
		} catch (_) {
			// The frame cannot be sent (too large, or the runner is gone): the process exit tells the host.
		}
	};
	const str = (value) => (typeof value === "string" ? value : undefined);

	// An exception as JSON {name, message, stack}, with the stack prefixed by `name: message` like V8.
	const describeException = (error) => {
		const own = (key) => {
			try {
				const value = error !== null && typeof error === "object" ? error[key] : undefined;
				return typeof value === "string" ? value : "";
			} catch (_) {
				return "";
			}
		};
		const name = own("name");
		const message = own("message");
		const head = message === "" ? name : name + ": " + message;
		const frames = own("stack").trimEnd();
		return stringify({ name, message, stack: frames === "" ? head : head + "\n" + frames });
	};

	const send = (message) => {
		if (finished) return;
		if (message.type === "done") finished = true;
		try {
			post(message);
		} catch (error) {
			crash("cannot send " + message.type + ": " + toString(error));
		}
	};

	// The prelude's native bridge: bridge(kind, a, b, c), the messages of WorkerToHostMessage.
	const bridge = (kind, a, b, c) => {
		if (finished) return;
		switch (kind) {
			case "call":
			case "global":
				send({ type: "call", id: a, target: kind === "call" ? "tool" : "global", name: str(b) ?? "", args: str(c) });
				return;
			case "output":
				send({
					type: "output",
					item:
						a === "image"
							? { type: "image", data: str(b) ?? "", mimeType: str(c) ?? "" }
							: a === "console"
								? { type: "text", text: str(b) ?? "", console: true }
								: { type: "text", text: str(b) ?? "" },
				});
				return;
			case "done":
				send(
					a === true
						? { type: "done", ok: true, value: str(b), writes: str(c) ?? "[]" }
						: { type: "done", ok: false, error: str(b) ?? "" },
				);
				return;
			default:
				crash("unknown bridge kind " + stringify(kind));
		}
	};

	const start = (data) => {
		if (data.deterministic !== undefined && data.deterministic !== null) {
			crash("deterministic mode is not supported");
			return;
		}
		if (typeof data.code !== "string") {
			crash("start data without a string `code`");
			return;
		}
		const field = (name, fallback) => (data[name] === undefined || data[name] === null ? fallback : stringify(data[name]));
		api = prelude(bridge, field("tools", "[]"), field("globals", "[]"), field("store", "{}"));
		let script;
		try {
			// The prefix shares the first line with the script so reported line numbers match.
			script = host.evalAs("(async (tools, console) => {" + data.code + "\n})", "codemode.js");
		} catch (error) {
			send({ type: "done", ok: false, error: describeException(error) });
			return;
		}
		api.run(script);
	};

	host.onmessage = (text) => {
		if (finished) return;
		try {
			const message = parse(text);
			switch (started ? message.type : "start") {
				case "start":
					started = true;
					start(message);
					return;
				case "result":
					api.settle(message.id, message.ok, message.payload, message.properties);
					return;
				case "check":
					api.stalled();
					return;
				default:
					crash("unexpected message type " + stringify(message.type));
			}
		} catch (error) {
			crash(describeException(error));
		}
	};
})();
