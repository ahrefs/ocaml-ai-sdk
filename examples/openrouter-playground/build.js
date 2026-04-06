const esbuild = require("esbuild");
esbuild.build({
  entryPoints: ["output/examples/openrouter-playground/main.js"],
  bundle: true,
  outdir: "dist",
  format: "esm",
  splitting: true,
  minify: false,
  sourcemap: true,
  external: [],
}).catch(() => process.exit(1));
