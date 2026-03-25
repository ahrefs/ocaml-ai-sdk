(** Results from text generation, including multi-step tool loops. *)

type tool_call = {
  tool_call_id : string;
  tool_name : string;
  args : Yojson.Basic.t;
}

type tool_result = {
  tool_call_id : string;
  tool_name : string;
  result : Yojson.Basic.t;
  is_error : bool;
}

type step = {
  text : string;
  reasoning : string;
  tool_calls : tool_call list;
  tool_results : tool_result list;
  finish_reason : Ai_provider.Finish_reason.t;
  usage : Ai_provider.Usage.t;
}

type t = {
  text : string;
  reasoning : string;
  tool_calls : tool_call list;
  tool_results : tool_result list;
  steps : step list;
  finish_reason : Ai_provider.Finish_reason.t;
  usage : Ai_provider.Usage.t;
  response : Ai_provider.Generate_result.response_info;
  warnings : Ai_provider.Warning.t list;
  output : Yojson.Basic.t option;
}

(** Concatenate text from all steps, separated by newlines. *)
val join_text : step list -> string

(** Concatenate reasoning from all steps, separated by newlines. *)
val join_reasoning : step list -> string

(** Combine two usage records, summing tokens. *)
val add_usage : Ai_provider.Usage.t -> Ai_provider.Usage.t -> Ai_provider.Usage.t
