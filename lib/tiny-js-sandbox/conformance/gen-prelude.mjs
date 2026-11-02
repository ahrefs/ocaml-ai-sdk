// Writes the evaluated PRELUDE_SOURCE of the pinned @earendil-works/pi-codemode package to
// ../src/prelude.js, or with --check compares it to the committed file.
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
// The package does not export the prelude, so it is loaded by path.
const preludeModule = join(here, "node_modules/@earendil-works/pi-codemode/dist/runtime/prelude-source.js");
const module = await import(pathToFileURL(preludeModule).href);
const target = join(here, "../src/prelude.js");

if (process.argv.includes("--check")) {
	const committed = await readFile(target, "utf8");
	if (committed !== module.PRELUDE_SOURCE) {
		console.error("src/prelude.js differs from the pinned @earendil-works/pi-codemode; run `pnpm gen-prelude`");
		process.exit(1);
	}
} else {
	await writeFile(target, module.PRELUDE_SOURCE);
}
