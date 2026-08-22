(** Thinking configuration for Claude models. *)

(** Thinking budget — always >= 1024 tokens.
    Use [budget] or [budget_exn] to construct. *)
type budget_tokens = private int

(** Returns [Error] if budget < 1024. *)
val budget : int -> (budget_tokens, string) result

(** Raises [Invalid_argument] if budget < 1024. *)
val budget_exn : int -> budget_tokens

(** Extract the integer value. *)
val to_int : budget_tokens -> int

type display =
  | Summarized
  | Omitted

(** How a model should think.

    Which constructors a model accepts depends on its catalog capabilities, and
    passing an unsupported one raises [Invalid_argument] before the request is
    sent, mirroring the 400 the API would return.

    Leaving thinking unset is not the same as [Disabled]. Whether omission
    leaves thinking on depends on the model: Fable 5, Mythos 5, Opus 5, and
    Sonnet 5 think by default, while Opus 4.8 and Haiku 4.5 do not. Only
    [Disabled] asks for thinking to be turned off explicitly. *)
type t =
  | Enabled of {
      budget_tokens : budget_tokens;
      display : display option;
    }
    (** Manual thinking with an explicit token budget. Among the models the
          catalog knows, only pre-adaptive ones accept it, and Claude Haiku 4.5
          is the last of those; the adaptive generation (Fable 5, Mythos 5,
          Opus 5, Opus 4.8, Sonnet 5) rejects it, so use [Adaptive] with an
          effort level there. A custom model id has unknown capabilities, so
          the SDK passes manual budgets through untouched and the API decides.
          Manual thinking also cannot be combined with a forced tool choice. *)
  | Adaptive of { display : display option }
    (** Adaptive thinking: the model decides how much to think, and
          [Anthropic_options.effort] sets how hard. This pair is the successor
          to [Enabled]'s token budgets. There is no faithful conversion from a
          budget to an effort level, so the caller picks the level rather than
          the SDK guessing one. Pre-adaptive models reject [Adaptive]. *)
  | Disabled
    (** Turn thinking off. Not universally accepted: some models always
          think and reject it outright. On Claude Opus 5 it is accepted at any
          effort, but pairing it with [Xhigh] or [Max] lowers the effort to
          [High] and emits a warning rather than raising. *)
