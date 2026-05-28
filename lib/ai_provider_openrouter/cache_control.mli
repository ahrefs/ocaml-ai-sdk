(** Prompt caching control for OpenRouter requests.

    Mirrors the per-part [cache_control] shape used by upstream
    [@openrouter/ai-sdk-provider]. The upstream TypeScript type is
    [{ type: 'ephemeral' }] (see
    [src/chat/convert-to-openrouter-chat-messages.ts]); the OpenRouter
    documentation additionally accepts an optional [ttl] field
    (["5m"] default, ["1h"] explicit) for Anthropic upstreams, which
    we surface here. *)

type breakpoint = Ephemeral  (** Cache control type. Currently only [Ephemeral] is supported. *)

(** Cache TTL. OpenRouter (Anthropic upstreams) accepts ["5m"] (default) or ["1h"]. *)
type ttl =
  | Ttl_5m
  | Ttl_1h

type t = {
  cache_type : breakpoint;
  ttl : ttl option;
}

(** Ephemeral cache control with default 5-minute TTL. *)
val ephemeral : t

(** Ephemeral cache control with explicit 1-hour TTL. *)
val ephemeral_1h : t

val to_json : t -> Yojson.Basic.t
val of_json : Yojson.Basic.t -> t
