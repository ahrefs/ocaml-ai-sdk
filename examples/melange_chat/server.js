import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";

const app = new Hono();

const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>OCaml AI SDK Chat (Melange)</title>
</head>
<body>
  <div id="root"></div>
  <script type="module" src="/bundle.js"></script>
</body>
</html>`;

app.use("/bundle.js", serveStatic({ path: "./dist/bundle.js" }));

app.get("/", (c) => {
  return c.html(html);
});

const port = 28600;
console.log(`Frontend: http://localhost:${port}`);
console.log(`Expects OCaml chat server at: http://localhost:28601/chat`);
console.log(
  `Start it with: ANTHROPIC_API_KEY=... dune exec examples/chat_server/main.exe`
);

serve({ fetch: app.fetch, port });
