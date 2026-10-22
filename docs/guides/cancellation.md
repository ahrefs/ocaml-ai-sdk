# Cancellation

This guide covers how to stop a `generate_text` or `stream_text` call before
it finishes, what the SDK does when you stop it, and how to count the tokens
an aborted call used. Each function's exact contract is in its `.mli` file;
start from `lib/ai_provider/abort_signal.mli`.

The snippets use `lwt_ppx` and write module paths in full unless they say
otherwise.

## A signal or `Lwt.cancel`

There are two ways to stop a call.

An abort signal, `Ai_provider.Abort_signal.t`, is something you pass as
`~abort_signal` and abort later. The SDK hands it to every provider request,
to the retry loop and to each tool. When it fires, the call reports the steps
it recorded before failing, so you can still count their usage.

`Lwt.cancel` on the promise that `generate_text` returns also stops the call,
for example through `Lwt_unix.with_timeout` or `Lwt.pick`. The promise fails
with `Lwt.Canceled` at once. The SDK cancels the provider request, the retry
sleep or the tool in progress when that promise is cancelable, and starts no
other model request or tool. A cancel reports no steps.

|                     | Abort signal                                             | `Lwt.cancel`                           |
|---------------------|----------------------------------------------------------|----------------------------------------|
| Stops               | `generate_text`, `stream_text`, `handle_chat`            | `generate_text`                        |
| The call fails with | `Abort_signal.Aborted { reason }`                        | `Lwt.Canceled`                         |
| Recorded steps      | Passed to `on_abort`, and to `outcome` for `stream_text` | Lost                                   |
| Running tool        | Gets the signal; its promise is cancelled                | Its promise is cancelled               |

`stream_text` returns its result at once and has no promise to cancel, so the
signal is the only way to stop it. Use the signal whenever you need the usage
of an aborted call.

## Making a signal

`Abort_signal.create ()` returns a signal and the function that aborts it, as
`AbortController` does in JavaScript:

```ocaml
exception User_pressed_stop

let abort_signal, abort = Ai_provider.Abort_signal.create ()

(* Later, from anywhere: *)
let () = abort ~reason:User_pressed_stop ()
```

Without `~reason`, the abort function resolves the signal. With one, it fails
the signal with that exception. Either way, everything waiting on the signal
has reacted by the time the function returns: hooks have run, races have
failed, and `Abort_signal.is_aborted abort_signal` is true. Calling it again
does nothing.

`Abort_signal.reason signal` is the exception the signal failed with, or
`None` when it resolved, was cancelled or is still pending. The SDK passes it
on everywhere: in `Aborted { reason }`, in `stream_text`'s `Abort` part and in
the UI stream's `abort` chunk, where it appears as `Printexc.to_string` text.
Register a printer for your own reason exceptions with
`Printexc.register_printer`, or the UI gets OCaml's generic rendering, such
as `"Dune__exe__Main.User_pressed_stop"`.

### Timeouts

`Abort_signal.with_timeout after_s f` runs `f signal`, where `signal` fails
with `Abort_signal.Timeout { after_s }` after `after_s` seconds. The timer is
cancelled once `f`'s promise settles. A zero or negative `after_s` fires on
the next turn of the Lwt main loop, after `f` has started, and `nan` raises
`Invalid_argument`.

```ocaml
let summarize ~model text =
  try%lwt
    let%lwt result =
      Ai_provider.Abort_signal.with_timeout 30. (fun abort_signal ->
        Ai_core.Generate_text.generate_text ~model ~prompt:text ~abort_signal ())
    in
    Lwt.return_some result.text
  with Ai_provider.Abort_signal.Aborted { reason = Some (Ai_provider.Abort_signal.Timeout _) } ->
    Lwt.return_none
```

For `stream_text`, the work passed to `with_timeout` must last until the
stream ends. If it returns the result at once, the timer stops right away and
the signal never fires:

```ocaml
let print_story ~model =
  Ai_provider.Abort_signal.with_timeout 30. (fun abort_signal ->
    let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Tell me a story" ~abort_signal () in
    let%lwt () = Lwt_stream.iter_s Lwt_io.print result.text_stream in
    result.outcome)
```

### A signal from a promise

`Abort_signal.of_promise promise` makes a signal that aborts when `promise`
settles, for a source that already is a promise. You abort it by settling
`promise`. `Lwt.cancel` does nothing to a promise from `Lwt.wait`, so
cancelling one never aborts its signal. Prefer `create`.

`Abort_signal.t` is a private `unit Lwt.t`, so your code can't bind on a
signal or put it in `Lwt.pick` by accident. `Lwt.pick` cancels the promises
that lose, which would abort a cancelable signal for every call sharing it.
Read a signal with `Abort_signal.wait`, `race` or `guard` instead.

## Combining sources with `choose`

A call often has more than one reason to stop, such as a deadline and the
process shutting down. `Abort_signal.choose signals f` runs `f signal`, where
`signal` aborts when the first of `signals` does, with that signal's reason.
This example assumes `open Ai_provider`:

```ocaml
Abort_signal.with_timeout timeout @@ fun deadline ->
Abort_signal.choose [ deadline; Abort_signal.of_promise (Daemon.wait_exit ()) ] @@ fun abort_signal ->
Agent_runner.run ~abort_signal ~model cfg
```

`Daemon.wait_exit ()` stands for a promise that settles when your app shuts
down, which `of_promise` turns into a signal, and `Agent_runner.run` for
your own function that passes `abort_signal` to `generate_text` or
`stream_text`. When the deadline fires first, the call fails with
`Aborted { reason = Some (Timeout _) }`. When the daemon exits first, the
reason is whatever the daemon's signal carries. Matching on the
reason tells the two apart, with no flags of your own. When several inputs
have already fired, the first in the list gives the reason, and `choose []`
never aborts.

The name follows Lwt: like `Lwt.choose`, `choose` never cancels its inputs.
Unlike it, it removes the callbacks it put on them once `f`'s promise
settles, so a long-lived signal such as the daemon's doesn't collect one
callback per call. The combined signal stops following its inputs then, so,
as with `with_timeout`, work given to `choose` must last until a
`stream_text` stream ends.

To run your own code when a signal settles, use
`Abort_signal.with_on_abort signal hook f`. It runs `f ()` with `hook`
attached and removes `hook` once `f`'s promise settles. `hook` must not raise:
an exception from it goes to `Lwt.async_exception_hook`, which exits the
process by default.

## Tools and the signal

A tool's `execute` gets its arguments and a `Core_tool.execute_options`
record, as upstream's tools get `ToolExecutionOptions`. It holds
`tool_call_id`, the step's `messages` without the system prompt and without
that step's response, as upstream passes them, and the `abort_signal` given
to `generate_text` or `stream_text`. The record is private. To call a tool's
`execute` directly, for example in a test, build it with
`Core_tool.execute_options ~tool_call_id ()`, which also takes `?messages`
and `?abort_signal`.

Both functions follow one rule: a tool's result counts only if its `execute`
returned before the signal fired. An abort from the code that reports the
result, such as telemetry or `on_chunk` on the `Tool_result` part, does not
drop it. No tool starts once the signal has fired. When it fires while a
tool runs, the call fails at once and cancels the tool's promise, even when
the tool ignores the signal, and a result the tool returns later is
dropped.

Cancelling the promise stops work built on cancelable promises, such as
`Lwt_unix.sleep` or a provider request. Work that ignores `Lwt.cancel` keeps
running in the background, so it must watch the signal itself. If it goes
through a function that takes a signal, such as
`Ai_provider.Http_client.post`, pass the signal on.

`generate_text` and `stream_text` already race every tool against the
signal. Where the SDK doesn't race, such as a direct
`Core_tool.execute_tool` call or a tool's own sub-steps, race the work with
`Abort_signal.race` to stop waiting at the abort and cancel the work:

```ocaml
let lookup_order =
  Ai_core.Core_tool.create ~description:"Look up an order" ~parameters:order_schema
    ~execute:(fun args (opts : Ai_core.Core_tool.execute_options) ->
      Ai_provider.Abort_signal.race opts.abort_signal (fun () -> Orders.lookup args))
    ()
```

`Orders.lookup` and `order_schema` stand for your own code. The race stops
the lookup at the abort even when the tool runs through `execute_tool`.
`race` fails with `Aborted` as soon as the signal fires and cancels the
work. Cancelling `race` cancels the work too, and never the signal.

`Core_tool.execute_tool` turns an exception from a tool into an error result
for the model. That includes an `Aborted` or `Lwt.Canceled` from the tool's
own work, such as a sub-agent's own timeout, which therefore doesn't fail a
call that had no signal. Two failures are not the tool's. Once the call's
signal has fired, any failure of the tool is the abort, so a tool that
cancels its own work when the signal fires ends the call as an abort. And a
cancel of the call itself fails it with `Lwt.Canceled`.

## Accounting for an aborted call

Providers bill for a response even when the call is aborted later. The SDK
records a step as soon as its model response is complete, so no completed
step goes missing. That includes the step whose tools were running when the
abort came. It keeps the results of the tools that returned before the
signal fired, and its other calls stay in `tool_calls` with no result. A
response that the abort cuts off mid-stream is billed too, but its usage
never arrives, so no step records it. `on_step_finish` is not called for a
step whose tools an abort stopped, so usage counted only in `on_step_finish`
misses that step.

Both `generate_text` and `stream_text` take
`?on_abort:(steps:Generate_text_result.step list -> unit)`. It runs once when
the signal stops the call, with the steps recorded so far, in order, and
before any result promise fails. `Generate_text_result.total_usage` adds up
their usage. A step with no `total_tokens` counts as its input plus output
tokens, so the sum does not depend on the order of the steps.

`on_abort`'s steps start with the ones `on_step_finish` already got. To
charge each step once, charge it in `on_step_finish`, and in `on_abort`
charge only the steps past those. Inside `on_abort`,
`Abort_signal.reason` of the signal is already the reason the call fails
with, so it needs no catch around the call:

```ocaml
let answer ~model ~abort_signal ~charge prompt =
  let charged = ref 0 in
  let charge_step (step : Ai_core.Generate_text_result.step) =
    charge step.usage;
    incr charged
  in
  Ai_core.Generate_text.generate_text ~model ~prompt ~abort_signal ~on_step_finish:charge_step
    ~on_abort:(fun ~steps ->
      List.iteri (fun i step -> if i >= !charged then charge_step step) steps;
      match Ai_provider.Abort_signal.reason abort_signal with
      | Some reason -> Printf.eprintf "aborted: %s\n%!" (Printexc.to_string reason)
      | None -> Printf.eprintf "aborted\n%!")
    ()
```

`charge` stands for your own billing code. The call still fails with
`Aborted`, with that same reason.

`on_abort` is not called for `Lwt.cancel`, once the call has been cancelled,
or for a failure other than the abort. An exception it raises is ignored.

`stream_text`'s result also has `outcome`, a promise that never fails and
says how the call ended. It resolves after the other promises have settled:

```ocaml
let usage_of_call (result : Ai_core.Stream_text_result.t) =
  match%lwt result.outcome with
  | Ai_core.Stream_text_result.Finished final -> Lwt.return_some final.usage
  | Ai_core.Stream_text_result.Aborted { steps; reason = _ } ->
    Lwt.return_some (Ai_core.Generate_text_result.total_usage steps)
  | Ai_core.Stream_text_result.Failed _ -> Lwt.return_none
```

`Finished` holds the same result that `on_finish` gets, and `Aborted` holds
the steps that `on_abort` got and the signal's reason. `Failed` holds the
exception the call failed with.

## What `stream_text` emits on abort

When the signal fires during a `stream_text` call, in this order:

1. `on_abort` runs with the steps recorded so far.
2. `full_stream` gets an `Abort { reason }` part and closes. No `Finish_step`,
   `Finish` or `Error` follows, and `text_stream` closes too. `reason` is the
   signal's reason as `Printexc.to_string` text, such as
   `"Abort_signal.Timeout(30s)"`. `on_chunk` doesn't get the `Abort` part,
   as upstream's `onChunk` doesn't.
3. `usage`, `finish_reason`, `steps`, `output` and `provider_metadata` fail
   with `Aborted { reason }`, even when steps were recorded. The steps reach
   you through `on_abort` and `outcome`. Upstream resolves `steps` from the
   recorded steps in that case, with an empty total usage, and its `onAbort`
   never sees a step whose tools were running.
4. `outcome` resolves to `Aborted { steps; reason }`.

After that, no model call, tool or step starts, `on_step_finish` and
`on_finish` are not called, and no further provider part is read, even from a
model that ignores the signal. If the signal had fired before the call, the
model is never called: the stream holds `Start` then `Abort`, and `on_abort`
runs with no steps before `stream_text` returns.

`Stream_text_result.to_ui_message_stream` turns the `Abort` part into an
`abort` chunk, `{"type":"abort","reason":"..."}`, with no `reason` field when
the signal has none, and sends no `finish` chunk. The SSE stream then ends
with `data: [DONE]`.

To learn how a call ended, wait for `outcome`. `Finish` and `Abort` always
come last in `full_stream`. A failed call ends with an `Error` part, but a
provider can also report an error inside a step, and the step goes on, so an
`Error` part does not mean the call is over. A consumer that matches `Finish`
and `Error` and sends everything else to `| _ ->` silently drops an abort.

### Inside `Ui_message_stream_writer`

`create_ui_message_stream` treats an `Aborted` raised by `execute` as an
abort, not an error. That is what happens when `execute` merges a
`stream_text` UI stream and then waits on one of its result promises:

```ocaml
let ui_stream ~model ~messages ~abort_signal =
  Ai_core.Ui_message_stream_writer.create_ui_message_stream
    ~execute:(fun writer ->
      let result = Ai_core.Stream_text.stream_text ~model ~messages ~abort_signal () in
      Ai_core.Ui_message_stream_writer.merge writer (Ai_core.Stream_text_result.to_ui_message_stream result);
      let%lwt usage = result.usage in
      Lwt_io.eprintf "used %d output tokens\n" usage.output_tokens)
    ()
```

On an abort, `result.usage` fails with `Aborted` and `execute` raises it. The
writer sends no `error` chunk. The stream holds the chunks merged so far and
then the merged `abort` chunk, and `on_finish` gets `~is_aborted:true`.
Upstream's createUIMessageStream sends an `error` chunk here instead.

## When `generate_text` returns after an abort

`generate_text` fails with `Aborted` only when the abort stops work the call
still had to do: a provider request in flight, a tool batch or the next step.
It fails at once even when the model or a tool ignores the signal, because it
races them against the signal. An abort that comes after the final model
response, or once `stop_when` is met, stops nothing, and the call returns its
result, as upstream's generateText does.

If you must not act on a result once the signal fired, check it:

```ocaml
let%lwt result = Ai_core.Generate_text.generate_text ~model ~prompt ~abort_signal () in
match Ai_provider.Abort_signal.is_aborted abort_signal with
| true -> Lwt.return_unit
| false -> publish result
```

## Stopping generation when a web client disconnects

`Server_handler.handle_chat` returns a response for your web server to send,
and it doesn't know about the connection. When the client goes away, after
`useChat().stop()` or a closed tab, the generation goes on unless you pass a
signal that your server settles on disconnect. Upstream behaves the same way:
a route stops only when it passes its request's signal as `abortSignal`.

```ocaml
exception Client_disconnected

let chat ~model ~on_disconnect body =
  let abort_signal, abort = Ai_provider.Abort_signal.create () in
  on_disconnect (fun () -> abort ~reason:Client_disconnected ());
  Ai_core.Server_handler.handle_chat ~model ~abort_signal body
```

`on_disconnect` stands for the hook your server offers. With cohttp, for
example, `Cohttp_lwt_unix.Server.make ~conn_closed` calls `conn_closed` when a
connection closes. The SSE stream then ends with an `abort` chunk and
`data: [DONE]`, and no further model call or tool starts.

A signal may outlive the request, such as one for server shutdown. Once a
request's stream ends, the SDK removes the callbacks it put on the signal,
except that a provider request keeps its callback until its transfer ends.
On abort, that happens at once. After an error, such as a raising telemetry
integration, a streaming transfer may run on until its body ends.

## Custom `fetch` functions

A provider `Config` can take a custom `fetch`, mostly for tests. It gets
`~abort_signal` and should stop when the signal fires. A call whose signal
fires before `fetch` fails with `Aborted` without calling it. One whose
signal fires during `fetch` fails with `Aborted` at once and cancels
`fetch`'s promise, even when `fetch` ignores the signal.

## Testing aborts

The `ocaml-ai-sdk.ai_mock` library has a language model for tests, modelled on
upstream's `MockLanguageModelV3`. Two helpers stand in for a slow provider:

- `Ai_mock.Language_model.hang ()` gives a model call that never returns and
  fails with `Aborted` once the call's signal settles.
- `Ai_mock.Language_model.hanging_stream parts` gives a stream that sends
  `parts` and then waits. It ends, with no `Finish` part, once the signal
  settles.

Both take `~ignore_abort:true` to act like a model that ignores the signal.

```ocaml
let test_deadline () =
  let model, mock = Ai_mock.Language_model.(create ~generate:(Respond (hang ())) ()) in
  try%lwt
    let%lwt (_ : Ai_core.Generate_text_result.t) =
      Ai_provider.Abort_signal.with_timeout 0.1 (fun abort_signal ->
        Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~abort_signal ())
    in
    Lwt.fail_with "expected a timeout"
  with Ai_provider.Abort_signal.Aborted { reason = Some (Ai_provider.Abort_signal.Timeout _) } ->
    let calls = List.length (Ai_mock.Language_model.generate_calls mock) in
    if Int.equal calls 1 then Lwt.return_unit else Lwt.fail_with "expected one model call"
```
