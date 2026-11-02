// Evaluated once by tiny-js-sandbox at startup (before the sandbox is entered), as an expression
// yielding a function. It receives the two native functions of the runner and installs the `host`
// and `console` globals; it returns the helpers the runner itself needs, which stay out of reach
// of scripts.
//
//   post(x)        native: 0 sent, 1 not a string/ArrayBuffer/Uint8Array, 2 frame too large
//   max            the frame cap in bytes; larger payloads are refused before anything is copied
//   log(level, s)  native: emits a log frame
//   evalNamed(code, filename)  native: evaluates a global sloppy script under a filename, for stacks
(function (post, log, evalNamed, max) {
  "use strict";
  const U8 = Uint8Array;
  const isView = ArrayBuffer.isView;
  const str = String;
  const join = Array.prototype.join;

  const isBuffer = (x) => x instanceof ArrayBuffer;
  const lone = /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g;

  // A lower bound of the encoded size in bytes (a UTF-16 unit takes at least one UTF-8 byte), or -1
  // when the value is not a string, ArrayBuffer or typed array. Lets the runner refuse a huge
  // payload before copying it.
  const size = (x) => {
    switch (typeof x) {
      case "string":
        return x.length;
      case "object":
        return isView(x) || isBuffer(x) ? x.byteLength : -1;
      default:
        return -1;
    }
  };

  // Typed arrays and DataViews are passed on as a Uint8Array over the viewed bytes. Lone
  // surrogates, which have no UTF-8 encoding, become U+FFFD (strings always go as text).
  const norm = (x) => {
    switch (typeof x) {
      case "string":
        return x.replace(lone, "\ufffd");
      case "object":
        return isView(x) ? new U8(x.buffer, x.byteOffset, x.byteLength) : x;
      default:
        return x;
    }
  };

  const host = {
    onmessage: undefined,
    // Like an `eval` frame, but under a chosen filename (the one that appears in stacks).
    evalAs(code, filename) {
      return evalNamed(str(code), str(filename));
    },
    post(x) {
      const n = size(x);
      if (n < 0) throw new TypeError("host.post expects a string, an ArrayBuffer or a typed array");
      if (n > max) throw new RangeError("message exceeds the maximum frame size");
      switch (post(norm(x))) {
        case 0:
          return undefined;
        case 1:
          throw new TypeError("host.post expects a string, an ArrayBuffer or a typed array");
        default:
          throw new RangeError("message exceeds the maximum frame size");
      }
    },
  };

  const show = (v) => {
    try {
      return str(v);
    } catch (_) {
      return "[unprintable]";
    }
  };
  const describe = (e) => {
    try {
      return e !== null && typeof e === "object" && e.stack ? show(e) + "\n" + e.stack : show(e);
    } catch (_) {
      return "[exception]";
    }
  };
  const logger = (level) =>
    function (...args) {
      const parts = [];
      for (let i = 0; i < args.length; i++) parts.push(show(args[i]));
      log(level, join.call(parts, " "));
    };
  globalThis.console = {
    log: logger("log"),
    info: logger("info"),
    debug: logger("debug"),
    warn: logger("warn"),
    error: logger("error"),
  };
  globalThis.host = host;

  const deliver = (data) => {
    const handler = host.onmessage;
    if (typeof handler !== "function") {
      log("warn", "message dropped: host.onmessage is not a function");
      return;
    }
    try {
      const r = handler.call(host, data);
      if (r !== null && typeof r === "object" && typeof r.then === "function") {
        r.then(undefined, (e) => log("error", describe(e)));
      }
    } catch (e) {
      log("error", describe(e));
    }
  };

  return { deliver, norm, size };
})
