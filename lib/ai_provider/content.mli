(** Response content parts returned by model generation. *)

type t =
  | Text of { text : string }
  | Tool_call of {
      tool_call_type : string;  (** Always ["function"] for now. *)
      tool_call_id : string;
      tool_name : string;
      args : string;  (** Raw JSON string -- consumer decides when to parse. *)
    }
  | Reasoning of {
      text : string;
      signature : string option;
      provider_options : Provider_options.t;
    }
  | File of {
      data : bytes;
      media_type : string;
    }
