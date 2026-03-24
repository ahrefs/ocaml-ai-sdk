import esbuild from "esbuild";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// The melange output lands in _build/default/examples/melange_chat/output/
// Melange runtime modules are in output/node_modules/
// npm packages (react, @ai-sdk/react, ai) are in this example's node_modules/
const outputDir = path.resolve(
  __dirname,
  "../../_build/default/examples/melange_chat/output"
);

await esbuild.build({
  entryPoints: [`${outputDir}/examples/melange_chat/main.js`],
  bundle: true,
  outfile: "dist/bundle.js",
  format: "esm",
  minify: false,
  nodePaths: [
    `${outputDir}/node_modules`,
    path.resolve(__dirname, "node_modules"),
  ],
  define: {
    "process.env.NODE_ENV": '"development"',
  },
});

console.log("Built dist/bundle.js");
