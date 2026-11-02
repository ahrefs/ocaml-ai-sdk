// Writes ../js/codemode-wrapper.js: ../js/codemode-wrapper.in.js with its `/*@PRELUDE@*/` marker replaced
// by the text of ../js/prelude.js (unmodified) as a JSON string literal, or with --check compares it to the committed file. Deterministic.
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const js = join(dirname(fileURLToPath(import.meta.url)), "../js");
const template = await readFile(join(js, "codemode-wrapper.in.js"), "utf8");
const prelude = await readFile(join(js, "prelude.js"), "utf8");
const marker = "/*@PRELUDE@*/";
if (template.split(marker).length !== 2) throw new Error("the template needs exactly one marker");
const generated = template.replace(marker, () => JSON.stringify(prelude));
const target = join(js, "codemode-wrapper.js");

if (process.argv.includes("--check")) {
	if ((await readFile(target, "utf8")) !== generated) {
		console.error("js/codemode-wrapper.js is stale; run `pnpm gen-wrapper`");
		process.exit(1);
	}
} else {
	await writeFile(target, generated);
}
