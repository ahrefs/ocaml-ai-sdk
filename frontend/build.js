import esbuild from "esbuild";

await esbuild.build({
  entryPoints: ["client.jsx"],
  bundle: true,
  outfile: "dist/bundle.js",
  format: "esm",
  jsx: "automatic",
  minify: false,
  define: {
    "process.env.NODE_ENV": '"production"',
  },
});

console.log("Built dist/bundle.js");
