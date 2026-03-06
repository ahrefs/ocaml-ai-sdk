import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { readFileSync } from "fs";

const app = new Hono();

const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>OCaml AI SDK Chat</title>
</head>
<body>
  <div id="root"></div>
  <script type="module" src="/bundle.js"></script>
</body>
</html>`;

// Serve the bundled JS
app.get("/bundle.js", (c) => {
  const js = readFileSync(new URL("./dist/bundle.js", import.meta.url), "utf-8");
  return c.body(js, 200, { "content-type": "application/javascript" });
});

// Serve the HTML shell
app.get("/", (c) => {
  return c.html(html);
});

const port = 28600;
console.log(`Frontend: http://localhost:${port}`);
console.log(`Expects OCaml chat server at: http://localhost:8080/chat`);
console.log(`Start it with: ANTHROPIC_API_KEY=... dune exec examples/chat_server.exe`);

serve({ fetch: app.fetch, port });
