(** OpenRouter response conversion. *)

(** Provider metadata key for the OpenRouter provider name. *)
type _ Ai_provider.Provider_options.key +=
  | Openrouter_provider : string Ai_provider.Provider_options.key

(** JSON representation of a reasoning detail (text, encrypted, or summary). *)
type reasoning_detail_json = {
  type_ : string; [@json.key "type"] [@json.default ""]
  text : string option; [@json.default None]
  signature : string option; [@json.default None]
  data : string option; [@json.default None]
  summary : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

(** Convert a single reasoning detail to an SDK content part. *)
val convert_reasoning_detail : reasoning_detail_json -> Ai_provider.Content.t option

(** Check whether any reasoning details contain encrypted reasoning. *)
val has_encrypted_reasoning : reasoning_detail_json list -> bool

(** Map OpenRouter finish reason string to SDK finish reason. *)
val map_finish_reason : string option -> Ai_provider.Finish_reason.t

(** Parse a JSON response into a generate result. *)
val parse_response : Yojson.Basic.t -> Ai_provider.Generate_result.t
