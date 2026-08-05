(** Convert Anthropic API responses to SDK format. *)

(** A single content block in an Anthropic response. *)
type content_block_json = {
  type_ : string;
  text : string option;
  id : string option;
  name : string option;
  input : Yojson.Basic.t option;
  thinking : string option;
  signature : string option;
  data : string option;
}

(** Parse a content block from JSON. *)
val content_block_json_of_json : Yojson.Basic.t -> content_block_json

(** Convert a content block to JSON. *)
val content_block_json_to_json : content_block_json -> Yojson.Basic.t

(** A full Anthropic Messages API response. *)
type anthropic_response_json = {
  id : string option;
  model : string option;
  content : content_block_json list;
  stop_reason : string option;
  usage : Convert_usage.anthropic_usage;
}

(** Parse an Anthropic response from JSON. *)
val anthropic_response_json_of_json : Yojson.Basic.t -> anthropic_response_json

(** Convert an Anthropic response to JSON. *)
val anthropic_response_json_to_json : anthropic_response_json -> Yojson.Basic.t

(** Map Anthropic stop reasons to SDK finish reasons. *)
val map_stop_reason : string option -> Ai_provider.Finish_reason.t

(** Build provider metadata carrying an Anthropic thinking signature. *)
val reasoning_provider_options : string option -> Ai_provider.Provider_options.t

(** Build provider metadata carrying an Anthropic redacted thinking block. *)
val redacted_reasoning_provider_options : string -> Ai_provider.Provider_options.t

(** Parse a full Anthropic Messages API response into a Generate_result. *)
val parse_response : Yojson.Basic.t -> Ai_provider.Generate_result.t
