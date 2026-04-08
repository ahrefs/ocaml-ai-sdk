# Retry Logic with Exponential Backoff — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automatically retry provider calls on retryable errors (rate limits, overloaded) with exponential backoff, matching upstream AI SDK behavior.

**Architecture:** Add `is_retryable : bool` field to `Provider_error.t`. Create a new `Retry` module in `ai_core` that wraps an `(unit -> 'a Lwt.t)` thunk with exponential backoff. Wire `?max_retries:int` into `generate_text` and `stream_text` (default 2, matching upstream). A `Retry_error` exception wraps accumulated errors when retries are exhausted.

**Tech Stack:** OCaml, Lwt (`Lwt_unix.sleep` for delay), Alcotest for tests.

**Upstream reference:** `examples/melange_chat/node_modules/ai/src/util/retry-with-exponential-backoff.ts`

**Follow-up (not in this plan):** Respect `retry-after-ms` / `retry-after` response headers. Requires adding headers to error types. Noted in roadmap.

---

## Task 1: Add `is_retryable` to `Provider_error.t`

**Files:**
- Modify: `lib/ai_provider/provider_error.ml`
- Modify: `lib/ai_provider/provider_error.mli`
- Modify: `lib/ai_provider_anthropic/anthropic_error.ml`
- Modify: `lib/ai_provider_openai/openai_error.ml`
- Modify: `test/ai_provider/test_foundation_types.ml`

**Step 1: Write a failing test for `is_retryable` on `Provider_error.t`**

In `test/ai_provider/test_foundation_types.ml`, add:

```ocaml
let test_provider_error_retryable () =
  let e : Ai_provider.Provider_error.t =
    { provider = "test"; kind = Api_error { status = 429; body = "rate limited" }; is_retryable = true }
  in
  (check bool) "is retryable" true e.is_retryable

let test_provider_error_not_retryable () =
  let e : Ai_provider.Provider_error.t =
    { provider = "test"; kind = Api_error { status = 400; body = "bad request" }; is_retryable = false }
  in
  (check bool) "not retryable" false e.is_retryable
```

Add to test list:
```ocaml
test_case "retryable" `Quick test_provider_error_retryable;
test_case "not_retryable" `Quick test_provider_error_not_retryable;
```

**Step 2: Run tests — they fail (field does not exist)**

Run: `dune test test/ai_provider 2>&1 | head -20`
Expected: Compile error — `is_retryable` field doesn't exist on `Provider_error.t`.

**Step 3: Add `is_retryable` to the type**

In `lib/ai_provider/provider_error.mli`, add `is_retryable : bool` to the record:

```ocaml
type t = {
  provider : string;
  kind : error_kind;
  is_retryable : bool;
}
```

In `lib/ai_provider/provider_error.ml`, same change to the record and update `to_string` (no change needed — it doesn't print retryable).

**Step 4: Fix all construction sites**

In `lib/ai_provider_anthropic/anthropic_error.ml` `of_response`, change:

```ocaml
let is_retryable_flag =
  match error_type with
  | Some t -> is_retryable t
  | None -> false
in
{ Ai_provider.Provider_error.provider = "anthropic"; kind = Api_error { status; body }; is_retryable = is_retryable_flag }
```

Remove the `"[retryable] "` prefix hack from body — it's no longer needed.

In `lib/ai_provider_openai/openai_error.ml` `of_response`, same pattern:

```ocaml
let is_retryable_flag =
  match error_type with
  | Some t -> is_retryable t
  | None -> false
in
{ Ai_provider.Provider_error.provider = "openai"; kind = Api_error { status; body = message }; is_retryable = is_retryable_flag }
```

Remove the `"[retryable] "` prefix hack.

In `test/ai_provider/test_foundation_types.ml`, update the two existing test constructions to include `is_retryable = false`.

**Step 5: Run tests — they pass**

Run: `dune test test/ai_provider`
Expected: All pass.

**Step 6: Commit**

```
feat(provider_error): add is_retryable field to Provider_error.t

Replace the "[retryable]" body prefix hack with a proper boolean
field, matching upstream's error.isRetryable pattern. Both Anthropic
and OpenAI error parsers set the field based on error type.
```

---

## Task 2: Create `Retry` module with exponential backoff

**Files:**
- Create: `lib/ai_core/retry.ml`
- Create: `lib/ai_core/retry.mli`
- Create: `test/ai_core/test_retry.ml`
- Modify: `test/ai_core/dune` (add test_retry)

**Step 1: Write failing tests for the retry module**

Create `test/ai_core/test_retry.ml`:

```ocaml
open Alcotest

(* Helper: create a retryable Provider_error *)
let retryable_error ?(status = 429) msg =
  Ai_provider.Provider_error.Provider_error
    { provider = "test"; kind = Api_error { status; body = msg }; is_retryable = true }

(* Helper: create a non-retryable Provider_error *)
let non_retryable_error msg =
  Ai_provider.Provider_error.Provider_error
    { provider = "test"; kind = Api_error { status = 400; body = msg }; is_retryable = false }

let run_lwt f () = Lwt_main.run (f ())

(* Test: successful call is not retried *)
let test_success_no_retry () =
  let call_count = ref 0 in
  let%lwt result =
    Ai_core.Retry.with_retries ~max_retries:2 (fun () ->
      incr call_count;
      Lwt.return "ok")
  in
  (check string) "result" "ok" result;
  (check int) "called once" 1 !call_count;
  Lwt.return_unit

(* Test: retryable error is retried up to max_retries *)
let test_retryable_exhausts_retries () =
  let call_count = ref 0 in
  let result =
    Lwt_main.run
      (Lwt.catch
        (fun () ->
          let%lwt _ =
            Ai_core.Retry.with_retries ~max_retries:2 ~initial_delay_ms:1 (fun () ->
              incr call_count;
              Lwt.fail (retryable_error "overloaded"))
          in
          Lwt.return_none)
        (function
          | Ai_core.Retry.Retry_error { reason; errors; _ } -> Lwt.return_some (reason, errors)
          | exn -> Lwt.fail exn))
  in
  (* 1 initial + 2 retries = 3 calls *)
  (check int) "called 3 times" 3 !call_count;
  match result with
  | Some (reason, errors) ->
    (check string) "reason" "max_retries_exceeded" (Ai_core.Retry.reason_to_string reason);
    (check int) "3 errors" 3 (List.length errors)
  | None -> fail "expected Retry_error"

(* Test: non-retryable error is not retried, re-raised directly on first attempt *)
let test_non_retryable_not_retried () =
  let call_count = ref 0 in
  let caught = ref false in
  Lwt_main.run
    (Lwt.catch
      (fun () ->
        let%lwt _ =
          Ai_core.Retry.with_retries ~max_retries:2 (fun () ->
            incr call_count;
            Lwt.fail (non_retryable_error "bad request"))
        in
        Lwt.return_unit)
      (function
        | Ai_provider.Provider_error.Provider_error _ ->
          caught := true;
          Lwt.return_unit
        | exn -> Lwt.fail exn));
  (check int) "called once" 1 !call_count;
  (check bool) "caught original error" true !caught

(* Test: max_retries=0 disables retry, re-raises directly *)
let test_zero_retries_no_wrap () =
  let call_count = ref 0 in
  let caught_original = ref false in
  Lwt_main.run
    (Lwt.catch
      (fun () ->
        let%lwt _ =
          Ai_core.Retry.with_retries ~max_retries:0 (fun () ->
            incr call_count;
            Lwt.fail (retryable_error "overloaded"))
        in
        Lwt.return_unit)
      (function
        | Ai_provider.Provider_error.Provider_error _ ->
          caught_original := true;
          Lwt.return_unit
        | exn -> Lwt.fail exn));
  (check int) "called once" 1 !call_count;
  (check bool) "original error, not wrapped" true !caught_original

(* Test: succeeds on retry after initial failure *)
let test_succeeds_on_retry () =
  let call_count = ref 0 in
  let%lwt result =
    Ai_core.Retry.with_retries ~max_retries:2 ~initial_delay_ms:1 (fun () ->
      incr call_count;
      match !call_count with
      | 1 -> Lwt.fail (retryable_error "overloaded")
      | _ -> Lwt.return "recovered")
  in
  (check string) "result" "recovered" result;
  (check int) "called twice" 2 !call_count;
  Lwt.return_unit

(* Test: non-Provider errors are re-raised directly, never retried *)
let test_unknown_exception_not_retried () =
  let call_count = ref 0 in
  let caught = ref false in
  Lwt_main.run
    (Lwt.catch
      (fun () ->
        let%lwt _ =
          Ai_core.Retry.with_retries ~max_retries:2 (fun () ->
            incr call_count;
            Lwt.fail (Failure "boom"))
        in
        Lwt.return_unit)
      (function
        | Failure _ ->
          caught := true;
          Lwt.return_unit
        | exn -> Lwt.fail exn));
  (check int) "called once" 1 !call_count;
  (check bool) "caught Failure" true !caught

(* Test: non-retryable error after retryable errors wraps in Retry_error *)
let test_non_retryable_after_retries () =
  let call_count = ref 0 in
  let result =
    Lwt_main.run
      (Lwt.catch
        (fun () ->
          let%lwt _ =
            Ai_core.Retry.with_retries ~max_retries:3 ~initial_delay_ms:1 (fun () ->
              incr call_count;
              match !call_count with
              | 1 -> Lwt.fail (retryable_error "rate limit")
              | _ -> Lwt.fail (non_retryable_error "bad request"))
          in
          Lwt.return_none)
        (function
          | Ai_core.Retry.Retry_error { reason; errors; _ } -> Lwt.return_some (reason, errors)
          | exn -> Lwt.fail exn))
  in
  (check int) "called twice" 2 !call_count;
  match result with
  | Some (reason, errors) ->
    (check string) "reason" "error_not_retryable" (Ai_core.Retry.reason_to_string reason);
    (check int) "2 errors" 2 (List.length errors)
  | None -> fail "expected Retry_error"

let () =
  run "Retry"
    [
      ( "with_retries",
        [
          test_case "success_no_retry" `Quick (run_lwt test_success_no_retry);
          test_case "retryable_exhausts" `Quick test_retryable_exhausts_retries;
          test_case "non_retryable_not_retried" `Quick test_non_retryable_not_retried;
          test_case "zero_retries" `Quick test_zero_retries_no_wrap;
          test_case "succeeds_on_retry" `Quick (run_lwt test_succeeds_on_retry);
          test_case "unknown_exception" `Quick test_unknown_exception_not_retried;
          test_case "non_retryable_after_retries" `Quick test_non_retryable_after_retries;
        ] );
    ]
```

Add `test_retry` to `test/ai_core/dune` names list.

**Step 2: Run tests — they fail (module doesn't exist)**

Run: `dune test test/ai_core/test_retry.exe 2>&1 | head -20`
Expected: Compile error — `Ai_core.Retry` doesn't exist.

**Step 3: Implement the Retry module**

Create `lib/ai_core/retry.mli`:

```ocaml
(** Retry with exponential backoff for provider calls.

    Wraps a thunk and retries on retryable [Provider_error] exceptions.
    Non-retryable errors and non-Provider exceptions are re-raised
    immediately. Matches upstream AI SDK retry behavior. *)

type retry_reason =
  | Max_retries_exceeded
  | Error_not_retryable

type retry_error = {
  message : string;
  reason : retry_reason;
  errors : exn list;
  last_error : exn;
}

exception Retry_error of retry_error

val reason_to_string : retry_reason -> string

(** Retry a thunk with exponential backoff.

    @param max_retries Maximum number of retries (default 2, matching upstream).
      Set to 0 to disable retries.
    @param initial_delay_ms Initial delay in milliseconds (default 2000).
    @param backoff_factor Multiplier applied to delay after each retry (default 2). *)
val with_retries :
  ?max_retries:int ->
  ?initial_delay_ms:int ->
  ?backoff_factor:int ->
  (unit -> 'a Lwt.t) ->
  'a Lwt.t
```

Create `lib/ai_core/retry.ml`:

```ocaml
type retry_reason =
  | Max_retries_exceeded
  | Error_not_retryable

type retry_error = {
  message : string;
  reason : retry_reason;
  errors : exn list;
  last_error : exn;
}

exception Retry_error of retry_error

let () =
  Printexc.register_printer (function
    | Retry_error { message; _ } -> Some (Printf.sprintf "Retry_error: %s" message)
    | _ -> None)

let reason_to_string = function
  | Max_retries_exceeded -> "max_retries_exceeded"
  | Error_not_retryable -> "error_not_retryable"

let is_retryable_provider_error = function
  | Ai_provider.Provider_error.Provider_error { is_retryable; _ } -> is_retryable
  | _ -> false

let with_retries ?(max_retries = 2) ?(initial_delay_ms = 2000) ?(backoff_factor = 2) f =
  let rec loop ~delay_ms ~errors =
    let try_number = List.length errors + 1 in
    Lwt.catch f (fun exn ->
      match max_retries with
      | 0 -> Lwt.fail exn
      | _ ->
        let new_errors = errors @ [ exn ] in
        let try_count = List.length new_errors in
        match try_count > max_retries with
        | true ->
          Lwt.fail
            (Retry_error
               {
                 message =
                   Printf.sprintf "Failed after %d attempts. Last error: %s" try_count (Printexc.to_string exn);
                 reason = Max_retries_exceeded;
                 errors = new_errors;
                 last_error = exn;
               })
        | false ->
          (match is_retryable_provider_error exn with
          | true ->
            let%lwt () = Lwt_unix.sleep (Float.of_int delay_ms /. 1000.0) in
            loop ~delay_ms:(backoff_factor * delay_ms) ~errors:new_errors
          | false ->
            (match try_number with
            | 1 -> Lwt.fail exn
            | _ ->
              Lwt.fail
                (Retry_error
                   {
                     message =
                       Printf.sprintf "Failed after %d attempts with non-retryable error: '%s'" try_count
                         (Printexc.to_string exn);
                     reason = Error_not_retryable;
                     errors = new_errors;
                     last_error = exn;
                   }))))
  in
  loop ~delay_ms:initial_delay_ms ~errors:[]
```

**Step 4: Run tests — they pass**

Run: `dune test test/ai_core/test_retry.exe`
Expected: All 7 tests pass.

**Step 5: Commit**

```
feat(retry): add Retry module with exponential backoff

New Retry.with_retries wraps provider calls, retrying on retryable
Provider_error exceptions with exponential backoff. Matches upstream
AI SDK retry semantics: default 2 retries, 2s initial delay, 2x
backoff factor. Wraps exhausted retries in Retry_error exception.
```

---

## Task 3: Wire retry into `generate_text`

**Files:**
- Modify: `lib/ai_core/generate_text.ml`
- Modify: `lib/ai_core/generate_text.mli`
- Modify: `test/ai_core/test_generate_text.ml`

**Step 1: Write a failing test for retry in generate_text**

In `test/ai_core/test_generate_text.ml`, add a mock model that fails then succeeds:

```ocaml
(* Mock model that fails N times with retryable error, then succeeds *)
let make_retry_model ~fail_count =
  let call_count = ref 0 in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-retry"

    let generate _opts =
      incr call_count;
      if !call_count <= fail_count then
        Lwt.fail
          (Ai_provider.Provider_error.Provider_error
             { provider = "mock"; kind = Api_error { status = 429; body = "rate limited" }; is_retryable = true })
      else
        Lwt.return
          {
            Ai_provider.Generate_result.content = [ Ai_provider.Content.Text { text = "recovered" } ];
            finish_reason = Ai_provider.Finish_reason.Stop;
            usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
            warnings = [];
            provider_metadata = Ai_provider.Provider_options.empty;
            request = { body = `Null };
            response = { id = Some "r1"; model = Some "mock-retry"; headers = []; body = `Null };
          }

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  call_count, (module M : Ai_provider.Language_model.S)
```

Tests:

```ocaml
let test_generate_retries_on_retryable_error () =
  let call_count, model = make_retry_model ~fail_count:1 in
  let%lwt result =
    Ai_core.Generate_text.generate_text ~model ~max_retries:2
      ~prompt:"test" ()
  in
  (check string) "recovered" "recovered" result.text;
  (check int) "called twice" 2 !call_count;
  Lwt.return_unit

let test_generate_no_retry_by_default_on_non_retryable () =
  let model =
    let module M : Ai_provider.Language_model.S = struct
      let specification_version = "V3"
      let provider = "mock"
      let model_id = "mock-fail"
      let generate _opts =
        Lwt.fail
          (Ai_provider.Provider_error.Provider_error
             { provider = "mock"; kind = Api_error { status = 400; body = "bad" }; is_retryable = false })
      let stream _opts =
        let s, p = Lwt_stream.create () in p None;
        Lwt.return { Ai_provider.Stream_result.stream = s; warnings = []; raw_response = None }
    end in
    (module M : Ai_provider.Language_model.S)
  in
  Lwt.catch
    (fun () ->
      let%lwt _ = Ai_core.Generate_text.generate_text ~model ~prompt:"test" () in
      Alcotest.fail "expected error";
      Lwt.return_unit)
    (function
      | Ai_provider.Provider_error.Provider_error _ -> Lwt.return_unit
      | exn -> Lwt.fail exn)
```

**Step 2: Run test — fails (no `max_retries` parameter)**

Run: `dune test test/ai_core/test_generate_text.exe 2>&1 | head -20`
Expected: Compile error — unknown `~max_retries` parameter.

**Step 3: Add `?max_retries` parameter and wrap the provider call**

In `lib/ai_core/generate_text.mli`, add `?max_retries:int` after `?max_steps`:

```ocaml
?max_retries:int ->
```

In `lib/ai_core/generate_text.ml`, add `?max_retries` to the function signature, then wrap the provider call at line 67:

Change:
```ocaml
let%lwt result = Ai_provider.Language_model.generate model opts in
```
To:
```ocaml
let%lwt result =
  Retry.with_retries ?max_retries (fun () ->
    Ai_provider.Language_model.generate model opts)
in
```

**Step 4: Run tests — they pass**

Run: `dune test test/ai_core/test_generate_text.exe`
Expected: All pass (old and new).

**Step 5: Commit**

```
feat(generate_text): add retry with backoff on provider calls

generate_text now accepts ?max_retries (default 2) and wraps the
provider call with exponential backoff via Retry.with_retries.
```

---

## Task 4: Wire retry into `stream_text`

**Files:**
- Modify: `lib/ai_core/stream_text.ml`
- Modify: `lib/ai_core/stream_text.mli`
- Modify: `test/ai_core/test_stream_text.ml`

**Step 1: Write a failing test for retry in stream_text**

In `test/ai_core/test_stream_text.ml`, add a mock model that fails then succeeds on stream:

```ocaml
(* Mock model that fails N times with retryable error on stream, then succeeds *)
let make_stream_retry_model ~fail_count =
  let call_count = ref 0 in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-stream-retry"
    let generate _opts = Lwt.return { (* minimal — not used *) ... }
    let stream _opts =
      incr call_count;
      if !call_count <= fail_count then
        Lwt.fail
          (Ai_provider.Provider_error.Provider_error
             { provider = "mock"; kind = Api_error { status = 529; body = "overloaded" }; is_retryable = true })
      else begin
        let stream, push = Lwt_stream.create () in
        push (Some (Ai_provider.Stream_part.Text { text = "streamed" }));
        push (Some (Ai_provider.Stream_part.Finish {
          finish_reason = Ai_provider.Finish_reason.Stop;
          usage = { input_tokens = 5; output_tokens = 3; total_tokens = Some 8 };
        }));
        push None;
        Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
      end
  end in
  call_count, (module M : Ai_provider.Language_model.S)
```

Test:

```ocaml
let test_stream_retries_on_retryable_error () =
  let call_count, model = make_stream_retry_model ~fail_count:1 in
  let result =
    Ai_core.Stream_text.stream_text ~model ~max_retries:2 ~prompt:"test" ()
  in
  (* Consume the text stream to completion *)
  let%lwt texts = Lwt_stream.to_list result.text_stream in
  let text = String.concat "" texts in
  (check string) "streamed text" "streamed" text;
  (check int) "called twice" 2 !call_count;
  Lwt.return_unit
```

**Step 2: Run test — fails (no `max_retries` parameter)**

Run: `dune test test/ai_core/test_stream_text.exe 2>&1 | head -20`
Expected: Compile error.

**Step 3: Add `?max_retries` and wrap the provider call**

In `lib/ai_core/stream_text.mli`, add `?max_retries:int` after `?max_steps`.

In `lib/ai_core/stream_text.ml`, add `?max_retries` to the function signature and wrap the call at line 215:

Change:
```ocaml
let%lwt stream_result = Ai_provider.Language_model.stream model opts in
```
To:
```ocaml
let%lwt stream_result =
  Retry.with_retries ?max_retries (fun () ->
    Ai_provider.Language_model.stream model opts)
in
```

**Step 4: Run tests — they pass**

Run: `dune test test/ai_core/test_stream_text.exe`
Expected: All pass.

**Step 5: Commit**

```
feat(stream_text): add retry with backoff on provider calls

stream_text now accepts ?max_retries (default 2) and wraps the
provider stream call with exponential backoff via Retry.with_retries.
```

---

## Task 5: Wire `?max_retries` through `server_handler`

**Files:**
- Modify: `lib/ai_core/server_handler.ml`
- Modify: `lib/ai_core/server_handler.mli`

**Step 1: Add `?max_retries:int` to `handle_chat` signature**

In `lib/ai_core/server_handler.mli`, add `?max_retries:int` to the `handle_chat` signature (after `?max_steps`).

In `lib/ai_core/server_handler.ml`, add `?max_retries` to `handle_chat` and pass it through to the `Stream_text.stream_text` call:

```ocaml
Stream_text.stream_text ~model ~messages ?tools ?max_steps ?max_retries ?stop_when ?output ?provider_options
  ~pending_tool_approvals ()
```

**Step 2: Run the full test suite to confirm no regressions**

Run: `dune test`
Expected: All pass.

**Step 3: Commit**

```
feat(server_handler): thread max_retries through handle_chat
```

---

## Task 6: Update roadmap

**Files:**
- Modify: `docs/plans/2026-03-26-v2-roadmap.md`

**Step 1: Update item #9 status to Done, add follow-up note about retry-after headers**

Mark item #9 as Done with a description of what was implemented. Add a note about the `retry-after` header follow-up under a new item or as a sub-note.

**Step 2: Commit**

```
docs: mark retry with backoff (#9) as done in v2 roadmap
```

---

## Task 7: Full test suite validation

**Step 1: Run the entire test suite**

Run: `dune test`
Expected: All tests pass with zero failures.

**Step 2: Run formatting**

Run: `dune build @fmt` or `ocamlformat` as appropriate.
Fix any formatting issues.

**Step 3: Final commit if needed**

```
chore: run formatter
```
