import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** The prelude the runner embeds, which the tests also check parses as JavaScript. */
export const PRELUDE_SOURCE = readFileSync(fileURLToPath(new URL("../../src/prelude.js", import.meta.url)), "utf8");
