import esbuild from "esbuild";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// The melange output lands in _build/default/examples/openrouter-playground/output/
// Melange runtime modules are in output/node_modules/
// npm packages (react, @ai-sdk/react, ai) are in this example's node_modules/
const outputDir = path.resolve(
  __dirname,
  "../../_build/default/examples/openrouter-playground/output"
);

// Force all React imports to resolve from the local node_modules to avoid
// duplicates (the repo root also has react, and esbuild can pick it up for
// dependencies whose entry points live under _build/default/).
const localNM = path.resolve(__dirname, "node_modules");

await esbuild.build({
  entryPoints: [`${outputDir}/examples/openrouter-playground/main.js`],
  bundle: true,
  outfile: "dist/bundle.js",
  format: "esm",
  minify: false,
  nodePaths: [
    `${outputDir}/node_modules`,
    localNM,
  ],
  alias: {
    "react": path.resolve(localNM, "react"),
    "react-dom": path.resolve(localNM, "react-dom"),
  },
  define: {
    "process.env.NODE_ENV": '"development"',
  },
});

console.log("Built dist/bundle.js");
