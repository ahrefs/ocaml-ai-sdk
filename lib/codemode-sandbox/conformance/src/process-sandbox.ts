// A pi-codemode sandbox whose VM is the ai-sdk-quickjs-runner binary: one child process per
// execution, JSONL on its stdio. This is the same seam as pi's own worker, inline and remote
// backends (`VmLauncher`), so pi's host logic runs unchanged on top of the runner.
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { CodemodeSandboxBase, type CodemodeSandboxBaseOptions } from "@earendil-works/pi-codemode";

type VmLauncher = ConstructorParameters<typeof CodemodeSandboxBase>[1];

export interface RunnerOptions {
	/** Path of the binary. Default: `$RUNNER`, else the release build next to this package. */
	binary?: string;
	/** `--sandbox` mode. Default: `$RUNNER_SANDBOX`, else `full`. */
	sandbox?: "full" | "seccomp" | "none";
	/** `--memory-limit-mb`. Default 256. */
	memoryLimitMb?: number;
}

const DEFAULT_BINARY = fileURLToPath(new URL("../../target/release/ai-sdk-quickjs-runner", import.meta.url));

function runnerLauncher(options: RunnerOptions): VmLauncher {
	const binary = options.binary ?? process.env.RUNNER ?? DEFAULT_BINARY;
	const sandbox = options.sandbox ?? process.env.RUNNER_SANDBOX ?? "full";
	const args = [`--sandbox=${sandbox}`, `--memory-limit-mb=${options.memoryLimitMb ?? 256}`];
	return (data, events) => {
		const child = spawn(binary, args, { stdio: ["pipe", "pipe", "pipe"] });
		let stderr = "";
		child.stderr.setEncoding("utf8");
		child.stderr.on("data", (chunk: string) => {
			stderr += chunk;
		});
		child.on("error", (error) => events.failure({ kind: "sandbox", name: error.name, message: error.message }));
		// `close`, not `exit`: it comes after stdout is drained, so a `done` is never lost to the exit.
		child.on("close", (code, signal) =>
			events.failure({
				kind: "sandbox",
				message: `Runner exited (code ${code}, signal ${signal}) before the script settled${stderr ? `: ${stderr.trim()}` : ""}`,
			}),
		);
		createInterface({ input: child.stdout }).on("line", (line) => {
			let message: unknown;
			try {
				message = JSON.parse(line);
			} catch {
				events.failure({ kind: "sandbox", message: `Runner sent a line that is not JSON: ${line.slice(0, 200)}` });
				return;
			}
			events.message(message);
		});
		child.stdin.on("error", () => {});
		const write = (value: unknown) => child.stdin.write(`${JSON.stringify(value)}\n`);
		write(data);
		return {
			post: (message) => {
				write(message);
			},
			stop: async () => {
				child.kill("SIGKILL");
			},
		};
	};
}

export class RunnerSandbox extends CodemodeSandboxBase {
	constructor(options: CodemodeSandboxBaseOptions & RunnerOptions = {}) {
		super(options, runnerLauncher(options));
	}
}
