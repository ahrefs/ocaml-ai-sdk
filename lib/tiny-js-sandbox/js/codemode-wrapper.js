// pi-codemode on tiny-js-sandbox. GENERATED into codemode-wrapper.js by conformance/gen-wrapper.mjs
// (`pnpm gen-wrapper`): this template with the marker below replaced by the source of js/prelude.js as a JSON string.
//
// js/prelude.js is PRELUDE_SOURCE of @earendil-works/pi-codemode 1.4.0 (tag v1.4.0 of
// https://github.com/earendil-works/pi, MIT, Copyright (c) 2025 Mario Zechner), included UNMODIFIED.
// The glue around it is ours.
//
// Usage: send this file's contents as ONE `eval` frame to tiny-js-sandbox (it evaluates to undefined),
// then drive it with `message` frames carrying JSON text (all values below are JSON strings):
//
//   parent -> VM  start data   pi's VmStartData: {code, tools, globals, store, memoryLimitBytes?}. Must be
//                              the first message. `memoryLimitBytes` is not applied here: pass the runner
//                              --memory-limit-mb. `deterministic` is not supported (crash).
//   parent -> VM  {"type":"result","id","ok","payload"?,"properties"?}   pi's HostToWorkerMessage
//   parent -> VM  {"type":"check"}   SEND ONE AFTER EVERY start data AND EVERY result. The runner handles
//                                    frames in order and drains promise jobs after each, so when the check
//                                    runs the VM is quiescent: if no tool call is pending, the script is
//                                    waiting on a promise that can never settle and is failed (pi's
//                                    `stalled()`; there is no way to detect quiescence from inside JS).
//   VM -> parent  pi's WorkerToHostMessage: call / output / done / crash, via host.post.
//
// After `done` the run is over: the VM ignores everything and sends nothing more. A script that keeps
// running after `done` cannot be interrupted from inside, so the embedder must kill the process on
// `done` (this used to be a Rust interrupt handler). The script gets no access to `host`: it is
// captured in this closure and removed from the global object before any user code is compiled.
(function () {
	"use strict";
	const host = globalThis.host;
	const { stringify, parse } = JSON;
	const toString = String;
	delete globalThis.host;
	// The prelude defines its own `console` global (user console output becomes `output` items).
	delete globalThis.console;

	// The prelude is compiled as its own script, named so that it filters its frames out of stacks.
	const prelude = host.evalAs("(function (bridge, toolsJson, globalsJson, storeJson) {\n\t\"use strict\";\n\n\t// Freeze every object reachable from the built-in globals, plus the intrinsics that are only\n\t// reachable from instances (iterator and generator prototypes, %TypedArray%).\n\t//\n\t// Freezing alone breaks ordinary code through the \"override mistake\": a data property that is\n\t// read-only on a prototype cannot be assigned on an instance either, so\n\t// this.name = \"MyError\" in an Error subclass would throw. Commonly overridden properties\n\t// become accessors whose setter defines an own property on the instance instead.\n\t(function lockdown() {\n\t\tconst OVERRIDABLE = new Set([\"constructor\", \"name\", \"message\", \"toString\", \"toLocaleString\", \"valueOf\", \"toJSON\"]);\n\t\tconst seen = new Set([globalThis]);\n\t\tconst queue = [];\n\t\tconst add = (value) => {\n\t\t\tif ((typeof value === \"object\" && value !== null) || typeof value === \"function\") {\n\t\t\t\tif (!seen.has(value)) {\n\t\t\t\t\tseen.add(value);\n\t\t\t\t\tqueue.push(value);\n\t\t\t\t}\n\t\t\t}\n\t\t};\n\n\t\t// Accessors from an object literal have no own prototype object, unlike function expressions,\n\t\t// whose prototype.constructor would be converted again without end.\n\t\tfunction allowOverride(object, key, value, enumerable) {\n\t\t\tconst { get, set } = Object.getOwnPropertyDescriptor(\n\t\t\t\t{\n\t\t\t\t\tget accessor() {\n\t\t\t\t\t\treturn value;\n\t\t\t\t\t},\n\t\t\t\t\tset accessor(next) {\n\t\t\t\t\t\tif (this === object) {\n\t\t\t\t\t\t\tthrow new TypeError(\"Cannot assign to read only property '\" + String(key) + \"' of a built-in\");\n\t\t\t\t\t\t}\n\t\t\t\t\t\tif ((typeof this !== \"object\" || this === null) && typeof this !== \"function\") return;\n\t\t\t\t\t\tObject.defineProperty(this, key, { value: next, writable: true, enumerable: true, configurable: true });\n\t\t\t\t\t},\n\t\t\t\t},\n\t\t\t\t\"accessor\",\n\t\t\t);\n\t\t\tObject.defineProperty(object, key, { get, set, enumerable, configurable: false });\n\t\t\tadd(get);\n\t\t\tadd(set);\n\t\t}\n\n\t\tfor (const key of Reflect.ownKeys(globalThis)) {\n\t\t\tconst descriptor = Object.getOwnPropertyDescriptor(globalThis, key);\n\t\t\tadd(descriptor.value);\n\t\t\tadd(descriptor.get);\n\t\t\tadd(descriptor.set);\n\t\t\tif (\"value\" in descriptor && descriptor.configurable) {\n\t\t\t\tObject.defineProperty(globalThis, key, { writable: false, configurable: false });\n\t\t\t}\n\t\t}\n\t\tadd(Object.getPrototypeOf(function* () {}));\n\t\tadd(Object.getPrototypeOf(async function () {}));\n\t\tadd(Object.getPrototypeOf(async function* () {}));\n\t\tadd(Object.getPrototypeOf(Int8Array));\n\t\tadd(Object.getPrototypeOf([][Symbol.iterator]()));\n\t\tadd(Object.getPrototypeOf(new Map()[Symbol.iterator]()));\n\t\tadd(Object.getPrototypeOf(new Set()[Symbol.iterator]()));\n\t\tadd(Object.getPrototypeOf(\"\"[Symbol.iterator]()));\n\t\tadd(Object.getPrototypeOf(/a/[Symbol.matchAll](\"\")));\n\t\tif (typeof Iterator === \"function\") {\n\t\t\tif (typeof Iterator.prototype.map === \"function\") add(Object.getPrototypeOf([].values().map((x) => x)));\n\t\t\tif (typeof Iterator.from === \"function\") add(Object.getPrototypeOf(Iterator.from({ next() {} })));\n\t\t}\n\n\t\twhile (queue.length > 0) {\n\t\t\tconst object = queue.pop();\n\t\t\tadd(Object.getPrototypeOf(object));\n\t\t\tconst descriptors = Object.getOwnPropertyDescriptors(object);\n\t\t\tfor (const key of Reflect.ownKeys(descriptors)) {\n\t\t\t\tconst descriptor = descriptors[key];\n\t\t\t\tif (\"value\" in descriptor) {\n\t\t\t\t\tadd(descriptor.value);\n\t\t\t\t\tif (\n\t\t\t\t\t\tdescriptor.writable &&\n\t\t\t\t\t\tdescriptor.configurable &&\n\t\t\t\t\t\t(object === Object.prototype || OVERRIDABLE.has(key))\n\t\t\t\t\t) {\n\t\t\t\t\t\tallowOverride(object, key, descriptor.value, descriptor.enumerable);\n\t\t\t\t\t}\n\t\t\t\t} else {\n\t\t\t\t\tadd(descriptor.get);\n\t\t\t\t\tadd(descriptor.set);\n\t\t\t\t}\n\t\t\t}\n\t\t\tObject.freeze(object);\n\t\t}\n\t})();\n\tconst stringify = JSON.stringify;\n\tconst parse = JSON.parse;\n\tconst promiseThen = Promise.prototype.then;\n\tconst ErrorCtor = Error;\n\tconst TypeErrorCtor = TypeError;\n\tconst RangeErrorCtor = RangeError;\n\tconst pending = new Map();\n\tlet nextId = 1;\n\tlet finished = false;\n\t// Thrown by exit() to unwind the script after it already reported success.\n\tconst EXIT = Object.freeze({});\n\n\tfunction done(ok, payload, writes) {\n\t\tif (finished) return;\n\t\tfinished = true;\n\t\tbridge(\"done\", ok, payload, writes);\n\t}\n\n\tfunction serialize(value) {\n\t\treturn value === undefined ? undefined : stringify(value);\n\t}\n\n\t// QuickJS stacks list frames only. Prefix \"Name: message\" like V8 so the\n\t// text reads the same as a Node error, and drop this prelude's frames.\n\tfunction errorText(error) {\n\t\tconst head = error.message ? error.name + \": \" + error.message : String(error.name);\n\t\tconst frames =\n\t\t\ttypeof error.stack === \"string\"\n\t\t\t\t? error.stack.split(\"\\n\").filter((line) => line.trim() && !line.includes(\"codemode-prelude.js\"))\n\t\t\t\t: [];\n\t\treturn [head, ...frames].join(\"\\n\");\n\t}\n\n\tfunction format(value) {\n\t\tif (typeof value === \"string\") return value;\n\t\tif (value instanceof ErrorCtor) return errorText(value);\n\t\ttry {\n\t\t\tconst json = stringify(value);\n\t\t\treturn json === undefined ? String(value) : json;\n\t\t} catch {\n\t\t\treturn String(value);\n\t\t}\n\t}\n\n\t// The host requires string fields. A script can set an error's name or message to anything, so\n\t// they are coerced, and a value whose coercion throws gets a placeholder.\n\tfunction describeError(error) {\n\t\ttry {\n\t\t\tif (error instanceof ErrorCtor) {\n\t\t\t\treturn stringify({ name: String(error.name), message: String(error.message), stack: errorText(error) });\n\t\t\t}\n\t\t\treturn stringify({ message: String(format(error)) });\n\t\t} catch {\n\t\t\treturn stringify({ message: \"The script threw a value that cannot be described\" });\n\t\t}\n\t}\n\n\tfunction caller(kind, name, spread) {\n\t\treturn (...args) =>\n\t\t\tnew Promise((resolve, reject) => {\n\t\t\t\tlet json;\n\t\t\t\ttry {\n\t\t\t\t\tjson = serialize(spread ? args : args[0]);\n\t\t\t\t} catch (error) {\n\t\t\t\t\treject(error);\n\t\t\t\t\treturn;\n\t\t\t\t}\n\t\t\t\tconst id = nextId++;\n\t\t\t\tpending.set(id, { resolve, reject });\n\t\t\t\tbridge(kind, id, name, json);\n\t\t\t});\n\t}\n\n\tconst tools = Object.create(null);\n\tconst allTools = [];\n\tfor (const { name, jsName, description } of parse(toolsJson)) {\n\t\tconst fn = caller(\"call\", name);\n\t\t// The first tool wins when two names normalize to the same identifier.\n\t\tif (!(jsName in tools)) {\n\t\t\ttools[jsName] = fn;\n\t\t\tallTools.push(Object.freeze({ name: jsName, description }));\n\t\t}\n\t\tif (!(name in tools)) tools[name] = fn;\n\t}\n\tObject.freeze(tools);\n\tObject.freeze(allTools);\n\n\t// Reading a member that does not exist throws an error that names the close matches, instead of\n\t// a later \"not a function\". `in` checks still work.\n\tconst comparable = (name) => name.toLowerCase().replace(/[^a-z0-9]/g, \"\");\n\tfunction guard(target, label, names, hint) {\n\t\treturn new Proxy(target, {\n\t\t\tget(object, property, receiver) {\n\t\t\t\tif (typeof property !== \"string\" || property in object || property in Object.prototype || property === \"then\" || property === \"toJSON\") {\n\t\t\t\t\treturn Reflect.get(object, property, receiver);\n\t\t\t\t}\n\t\t\t\tconst wanted = comparable(property);\n\t\t\t\tconst exact = names.filter((name) => comparable(name) === wanted);\n\t\t\t\tconst close = exact.length > 0 ? exact : names.filter((name) => wanted && (comparable(name).includes(wanted) || wanted.includes(comparable(name))));\n\t\t\t\tlet message = label + \".\" + property + \" does not exist.\";\n\t\t\t\tif (close.length > 0) message += \" Did you mean \" + close.slice(0, 5).map((name) => label + \".\" + name).join(\", \") + \"?\";\n\t\t\t\telse if (names.length <= 20) message += \" Available: \" + names.join(\", \") + \".\";\n\t\t\t\tif (hint) message += \" \" + hint;\n\t\t\t\tmessage += ' Check for a member with \"' + property + '\" in ' + label + \".\";\n\t\t\t\tthrow new TypeErrorCtor(message);\n\t\t\t},\n\t\t});\n\t}\n\tconst toolsProxy = guard(\n\t\ttools,\n\t\t\"tools\",\n\t\tallTools.map((tool) => tool.name),\n\t\t\"ALL_TOOLS lists every tool; searchTools(query) finds tools by topic.\",\n\t);\n\n\tconst namespaces = new Map();\n\tfor (const { name, spread } of parse(globalsJson)) {\n\t\tconst fn = caller(\"global\", name, spread);\n\t\tconst dot = name.indexOf(\".\");\n\t\tif (dot === -1) {\n\t\t\tObject.defineProperty(globalThis, name, { value: fn, enumerable: true });\n\t\t\tcontinue;\n\t\t}\n\t\tconst namespace = name.slice(0, dot);\n\t\tif (!namespaces.has(namespace)) namespaces.set(namespace, Object.create(null));\n\t\tnamespaces.get(namespace)[name.slice(dot + 1)] = fn;\n\t}\n\tfor (const [namespace, members] of namespaces) {\n\t\tObject.freeze(members);\n\t\tconst value = guard(members, namespace, Object.keys(members));\n\t\tObject.defineProperty(globalThis, namespace, { value, enumerable: true });\n\t}\n\n\t// key -> JSON text. Sizes count key and JSON characters.\n\tconst stored = new Map(Object.entries(parse(storeJson)));\n\tconst writes = new Map();\n\tlet storedChars = 0;\n\tfor (const [key, json] of stored) storedChars += key.length + json.length;\n\n\tconst STORE_HINT =\n\t\t\"store() is for small state such as IDs or summaries. Show images with image(), keep large data in variables, or write it to a file with a tool.\";\n\n\tfunction checkKey(name, key) {\n\t\tif (typeof key !== \"string\") throw new TypeError(name + \"() key must be a string\");\n\t}\n\n\tfunction store(key, value) {\n\t\tcheckKey(\"store\", key);\n\t\tconst previous = stored.has(key) ? key.length + stored.get(key).length : 0;\n\t\tif (value === undefined) {\n\t\t\tstored.delete(key);\n\t\t\tstoredChars -= previous;\n\t\t\twrites.set(key, undefined);\n\t\t\treturn;\n\t\t}\n\t\tlet json;\n\t\ttry {\n\t\t\tjson = stringify(value);\n\t\t} catch (error) {\n\t\t\tthrow new TypeError(\"store(\" + stringify(key) + \") value is not JSON-serializable: \" + format(error));\n\t\t}\n\t\tif (json === undefined) {\n\t\t\tthrow new TypeError(\"store(\" + stringify(key) + \") value is not JSON-serializable\");\n\t\t}\n\t\tif (json.length > 262144) {\n\t\t\tthrow new RangeError(\n\t\t\t\t\"store(\" + stringify(key) + \") value has \" + json.length + \" characters of JSON, more than the limit of 262144. \" +\n\t\t\t\t\tSTORE_HINT,\n\t\t\t);\n\t\t}\n\t\tconst next = storedChars - previous + key.length + json.length;\n\t\tif (next > 1048576) {\n\t\t\tthrow new RangeError(\n\t\t\t\t\"store is full: stored values would exceed 1048576 characters of JSON. Delete keys with store(key, undefined). \" +\n\t\t\t\t\tSTORE_HINT,\n\t\t\t);\n\t\t}\n\t\tstored.set(key, json);\n\t\tstoredChars = next;\n\t\twrites.set(key, json);\n\t}\n\n\tfunction load(key) {\n\t\tcheckKey(\"load\", key);\n\t\tconst json = stored.get(key);\n\t\treturn json === undefined ? undefined : parse(json);\n\t}\n\n\tfunction serializeWrites() {\n\t\tconst entries = [];\n\t\tfor (const [key, json] of writes) entries.push(json === undefined ? [key] : [key, json]);\n\t\treturn stringify(entries);\n\t}\n\n\tObject.defineProperty(globalThis, \"store\", { value: store, enumerable: true });\n\tObject.defineProperty(globalThis, \"load\", { value: load, enumerable: true });\n\n\tlet outputChars = 0;\n\tlet outputItems = 0;\n\n\t// Past the output limits the script fails: done() reports the error, so catching it does not\n\t// resume output, and the host ends the script.\n\tfunction output(kind, data, mimeType) {\n\t\tif (finished) return;\n\t\toutputChars += data.length;\n\t\toutputItems++;\n\t\tif (outputChars > 16777216 || outputItems > 100000) {\n\t\t\tconst error = new RangeErrorCtor(\n\t\t\t\t\"script output exceeded the limit of 16777216 characters or 100000 text(), image(), and console calls. \" +\n\t\t\t\t\t\"Print a summary instead, or write large data to a file with a tool.\",\n\t\t\t);\n\t\t\tdone(false, describeError(error));\n\t\t\tthrow error;\n\t\t}\n\t\tbridge(\"output\", kind, data, mimeType);\n\t}\n\n\t// Primitives become their string form, everything else JSON.\n\tfunction outputText(value) {\n\t\tif (value === undefined || value === null || typeof value !== \"object\" && typeof value !== \"function\") {\n\t\t\treturn String(value);\n\t\t}\n\t\tconst json = stringify(value);\n\t\treturn json === undefined ? String(value) : json;\n\t}\n\n\tfunction text(value) {\n\t\tlet rendered;\n\t\ttry {\n\t\t\trendered = outputText(value);\n\t\t} catch (error) {\n\t\t\tthrow new TypeErrorCtor(error instanceof ErrorCtor ? error.message : String(error));\n\t\t}\n\t\toutput(\"text\", rendered);\n\t}\n\n\tfunction imageUrl(value) {\n\t\tif (typeof value === \"string\") return value;\n\t\tif (typeof value !== \"object\" || value === null || Array.isArray(value)) {\n\t\t\tthrow new TypeErrorCtor(\"image expects a non-empty image URL string, an object with image_url, or an image block { type: \\\"image\\\", data, mimeType }\");\n\t\t}\n\t\tif (value.image_url !== undefined) {\n\t\t\tif (typeof value.image_url !== \"string\") throw new TypeErrorCtor(\"image expects a non-empty image URL string, an object with image_url, or an image block { type: \\\"image\\\", data, mimeType }\");\n\t\t\treturn value.image_url;\n\t\t}\n\t\tif (typeof value.type !== \"string\") throw new TypeErrorCtor(\"image expects a non-empty image URL string, an object with image_url, or an image block { type: \\\"image\\\", data, mimeType }\");\n\t\tif (value.type !== \"image\") {\n\t\t\tthrow new TypeErrorCtor('image only accepts image blocks, got \"' + value.type + '\"');\n\t\t}\n\t\tif (typeof value.data !== \"string\" || value.data === \"\") throw new TypeErrorCtor(\"image expected image block data\");\n\t\tif (value.data.toLowerCase().startsWith(\"data:\")) return value.data;\n\t\treturn \"data:;base64,\" + value.data;\n\t}\n\n\t// Base64 of the signatures of the formats providers accept inline (PNG, JPEG except\n\t// JPEG-LS, GIF, \"RIFF....WEBP\"). Signatures start at byte 0, so their encodings are prefixes.\n\tconst IMAGE_SIGNATURES = [\n\t\t[\"image/png\", /^iVBORw0KGg/],\n\t\t[\"image/jpeg\", /^[/]9j[/](?!9)/],\n\t\t[\"image/gif\", /^R0lGOD[dl]h/],\n\t\t[\"image/webp\", /^UklG.{8}RUJQ/],\n\t];\n\n\tfunction image(value) {\n\t\tconst url = imageUrl(value);\n\t\tif (url === \"\") throw new TypeErrorCtor(\"image expects a non-empty image URL string, an object with image_url, or an image block { type: \\\"image\\\", data, mimeType }\");\n\t\tconst colon = url.indexOf(\":\");\n\t\tconst scheme = colon === -1 ? \"\" : url.slice(0, colon).toLowerCase();\n\t\tif (scheme === \"http\" || scheme === \"https\") {\n\t\t\tthrow new TypeErrorCtor(\"remote image URLs are not supported in tool outputs. Pass a base64 data URI instead\");\n\t\t}\n\t\tconst comma = url.indexOf(\",\");\n\t\tconst header = comma === -1 ? [] : url.slice(colon + 1, comma).split(\";\");\n\t\tif (scheme !== \"data\" || comma === -1 || header.slice(1).every((part) => part.toLowerCase() !== \"base64\")) {\n\t\t\tthrow new TypeErrorCtor(\"invalid image output. Pass a base64 data URI instead\");\n\t\t}\n\t\t// Providers reject the whole request on a bad image, and a persisted image block would be\n\t\t// resent on every later turn. Line breaks from wrapped base64 are dropped. The declared type\n\t\t// is ignored in favor of the detected one, as providers also reject mismatches.\n\t\tconst data = url.slice(comma + 1).replace(/\\s+/g, \"\");\n\t\tif (data.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(data)) {\n\t\t\tthrow new TypeErrorCtor(\"invalid image output. The image data is not valid base64 (truncated or corrupted?)\");\n\t\t}\n\t\tconst head = data.slice(0, 16);\n\t\tconst signature = IMAGE_SIGNATURES.find(([, pattern]) => pattern.test(head));\n\t\tif (!signature) {\n\t\t\tthrow new TypeErrorCtor(\"invalid image output. The image data is not a PNG, JPEG, GIF, or WebP image\");\n\t\t}\n\t\toutput(\"image\", data, signature[0]);\n\t}\n\n\tfunction exit() {\n\t\tlet writesJson;\n\t\ttry {\n\t\t\twritesJson = serializeWrites();\n\t\t} catch (error) {\n\t\t\tdone(false, describeError(error));\n\t\t\tthrow EXIT;\n\t\t}\n\t\tdone(true, undefined, writesJson);\n\t\tthrow EXIT;\n\t}\n\n\tconst console = {};\n\tfor (const level of [\"log\", \"info\", \"warn\", \"error\", \"debug\"]) {\n\t\tconsole[level] = (...args) => {\n\t\t\toutput(\"console\", args.map(format).join(\" \"));\n\t\t};\n\t}\n\tObject.freeze(console);\n\n\tObject.defineProperty(globalThis, \"tools\", { value: toolsProxy, enumerable: true });\n\tObject.defineProperty(globalThis, \"ALL_TOOLS\", { value: allTools, enumerable: true });\n\tObject.defineProperty(globalThis, \"console\", { value: console, enumerable: true });\n\tObject.defineProperty(globalThis, \"text\", { value: text, enumerable: true });\n\tObject.defineProperty(globalThis, \"image\", { value: image, enumerable: true });\n\tObject.defineProperty(globalThis, \"exit\", { value: exit, enumerable: true });\n\n\treturn {\n\t\tsettle(id, ok, payload, propertiesJson) {\n\t\t\tconst entry = pending.get(id);\n\t\t\tif (!entry) return;\n\t\t\tpending.delete(id);\n\t\t\tif (!ok) {\n\t\t\t\tconst error = new ErrorCtor(payload);\n\t\t\t\tif (propertiesJson !== undefined) {\n\t\t\t\t\tconst properties = parse(propertiesJson);\n\t\t\t\t\tfor (const key of Object.keys(properties)) {\n\t\t\t\t\t\tif (key === \"name\" || key === \"message\" || key === \"stack\") continue;\n\t\t\t\t\t\tObject.defineProperty(error, key, { value: properties[key], writable: true, enumerable: true, configurable: true });\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t\tentry.reject(error);\n\t\t\t\treturn;\n\t\t\t}\n\t\t\tlet value;\n\t\t\ttry {\n\t\t\t\tvalue = payload === undefined ? undefined : parse(payload);\n\t\t\t} catch (error) {\n\t\t\t\tentry.reject(error);\n\t\t\t\treturn;\n\t\t\t}\n\t\t\tentry.resolve(value);\n\t\t},\n\t\trun(fn) {\n\t\t\tlet promise;\n\t\t\ttry {\n\t\t\t\tpromise = fn(toolsProxy, console);\n\t\t\t} catch (error) {\n\t\t\t\tdone(false, describeError(error));\n\t\t\t\treturn;\n\t\t\t}\n\t\t\tpromiseThen.call(\n\t\t\t\tpromise,\n\t\t\t\t(value) => {\n\t\t\t\t\tlet json;\n\t\t\t\t\ttry {\n\t\t\t\t\t\tjson = serialize(value);\n\t\t\t\t\t} catch (error) {\n\t\t\t\t\t\tdone(false, describeError(error));\n\t\t\t\t\t\treturn;\n\t\t\t\t\t}\n\t\t\t\t\tdone(true, json, serializeWrites());\n\t\t\t\t},\n\t\t\t\t(error) => {\n\t\t\t\t\tdone(false, describeError(error));\n\t\t\t\t},\n\t\t\t);\n\t\t},\n\t\tstalled() {\n\t\t\tif (finished || pending.size > 0) return false;\n\t\t\tdone(\n\t\t\t\tfalse,\n\t\t\t\tstringify({\n\t\t\t\t\tname: \"Error\",\n\t\t\t\t\tmessage:\n\t\t\t\t\t\t\"The script is waiting on a promise that can never settle: no tool call is pending, and timers do not exist here.\",\n\t\t\t\t}),\n\t\t\t);\n\t\t\treturn true;\n\t\t},\n\t};\n})", "codemode-prelude.js");

	let finished = false;
	let started = false;
	let api;

	const post = (message) => host.post(stringify(message));
	const crash = (message) => {
		finished = true;
		try {
			post({ type: "crash", message: toString(message) });
		} catch (_) {
			// The frame cannot be sent (too large, or the runner is gone): the process exit tells the host.
		}
	};
	const str = (value) => (typeof value === "string" ? value : undefined);

	// An exception as JSON {name, message, stack}, with the stack prefixed by `name: message` like V8.
	const describeException = (error) => {
		const own = (key) => {
			try {
				const value = error !== null && typeof error === "object" ? error[key] : undefined;
				return typeof value === "string" ? value : "";
			} catch (_) {
				return "";
			}
		};
		const name = own("name");
		const message = own("message");
		const head = message === "" ? name : name + ": " + message;
		const frames = own("stack").trimEnd();
		return stringify({ name, message, stack: frames === "" ? head : head + "\n" + frames });
	};

	const send = (message) => {
		if (finished) return;
		if (message.type === "done") finished = true;
		try {
			post(message);
		} catch (error) {
			crash("cannot send " + message.type + ": " + toString(error));
		}
	};

	// The prelude's native bridge: bridge(kind, a, b, c), the messages of WorkerToHostMessage.
	const bridge = (kind, a, b, c) => {
		if (finished) return;
		switch (kind) {
			case "call":
			case "global":
				send({ type: "call", id: a, target: kind === "call" ? "tool" : "global", name: str(b) ?? "", args: str(c) });
				return;
			case "output":
				send({
					type: "output",
					item:
						a === "image"
							? { type: "image", data: str(b) ?? "", mimeType: str(c) ?? "" }
							: a === "console"
								? { type: "text", text: str(b) ?? "", console: true }
								: { type: "text", text: str(b) ?? "" },
				});
				return;
			case "done":
				send(
					a === true
						? { type: "done", ok: true, value: str(b), writes: str(c) ?? "[]" }
						: { type: "done", ok: false, error: str(b) ?? "" },
				);
				return;
			default:
				crash("unknown bridge kind " + stringify(kind));
		}
	};

	const start = (data) => {
		if (data.deterministic !== undefined && data.deterministic !== null) {
			crash("deterministic mode is not supported");
			return;
		}
		if (typeof data.code !== "string") {
			crash("start data without a string `code`");
			return;
		}
		const field = (name, fallback) => (data[name] === undefined || data[name] === null ? fallback : stringify(data[name]));
		api = prelude(bridge, field("tools", "[]"), field("globals", "[]"), field("store", "{}"));
		let script;
		try {
			// The prefix shares the first line with the script so reported line numbers match.
			script = host.evalAs("(async (tools, console) => {" + data.code + "\n})", "codemode.js");
		} catch (error) {
			send({ type: "done", ok: false, error: describeException(error) });
			return;
		}
		api.run(script);
	};

	host.onmessage = (text) => {
		if (finished) return;
		try {
			const message = parse(text);
			switch (started ? message.type : "start") {
				case "start":
					started = true;
					start(message);
					return;
				case "result":
					api.settle(message.id, message.ok, message.payload, message.properties);
					return;
				case "check":
					api.stalled();
					return;
				default:
					crash("unexpected message type " + stringify(message.type));
			}
		} catch (error) {
			crash(describeException(error));
		}
	};
})();
