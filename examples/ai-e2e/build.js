import esbuild from "esbuild";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const outputDir = path.resolve(
  __dirname,
  "../../_build/default/examples/ai-e2e/output"
);

await esbuild.build({
  entryPoints: [`${outputDir}/examples/ai-e2e/main.js`],
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
