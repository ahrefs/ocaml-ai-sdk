type t =
  | Start of {
      message_id : string option;
      message_metadata : Yojson.Safe.t option;
    }
  | Finish of {
      finish_reason : Ai_provider.Finish_reason.t option;
      message_metadata : Yojson.Safe.t option;
    }
  | Abort of { reason : string option }
  | Start_step
  | Finish_step
  | Text_start of { id : string }
  | Text_delta of {
      id : string;
      delta : string;
    }
  | Text_end of { id : string }
  | Reasoning_start of { id : string }
  | Reasoning_delta of {
      id : string;
      delta : string;
    }
  | Reasoning_end of { id : string }
  | Tool_input_start of {
      tool_call_id : string;
      tool_name : string;
    }
  | Tool_input_delta of {
      tool_call_id : string;
      input_text_delta : string;
    }
  | Tool_input_available of {
      tool_call_id : string;
      tool_name : string;
      input : Yojson.Safe.t;
    }
  | Tool_output_available of {
      tool_call_id : string;
      output : Yojson.Safe.t;
    }
  | Tool_output_error of {
      tool_call_id : string;
      error_text : string;
    }
  | Source_url of {
      source_id : string;
      url : string;
      title : string option;
    }
  | File of {
      url : string;
      media_type : string;
    }
  | Message_metadata of { message_metadata : Yojson.Safe.t }
  | Tool_input_error of {
      tool_call_id : string;
      tool_name : string;
      input : Yojson.Safe.t;
      error_text : string;
    }
  | Tool_output_denied of { tool_call_id : string }
  | Source_document of {
      source_id : string;
      media_type : string;
      title : string;
      filename : string option;
    }
  | Error of { error_text : string }
  | Data of {
      data_type : string;
      id : string option;
      data : Yojson.Safe.t;
    }

(* Helper: build JSON object, omitting None fields *)
let obj fields = `Assoc (List.filter_map Fun.id fields)
let some (k, v) = Some (k, v)

let opt_string k = function
  | Some s -> Some (k, `String s)
  | None -> None

let opt_json k = function
  | Some j -> Some (k, j)
  | None -> None

let to_yojson = function
  | Start { message_id; message_metadata } ->
    obj
      [ some ("type", `String "start"); opt_string "messageId" message_id; opt_json "messageMetadata" message_metadata ]
  | Finish { finish_reason; message_metadata } ->
    obj
      [
        some ("type", `String "finish");
        Option.map (fun r -> "finishReason", `String (Ai_provider.Finish_reason.to_string r)) finish_reason;
        opt_json "messageMetadata" message_metadata;
      ]
  | Abort { reason } -> obj [ some ("type", `String "abort"); opt_string "reason" reason ]
  | Start_step -> `Assoc [ "type", `String "start-step" ]
  | Finish_step -> `Assoc [ "type", `String "finish-step" ]
  | Text_start { id } -> `Assoc [ "type", `String "text-start"; "id", `String id ]
  | Text_delta { id; delta } -> `Assoc [ "type", `String "text-delta"; "id", `String id; "delta", `String delta ]
  | Text_end { id } -> `Assoc [ "type", `String "text-end"; "id", `String id ]
  | Reasoning_start { id } -> `Assoc [ "type", `String "reasoning-start"; "id", `String id ]
  | Reasoning_delta { id; delta } ->
    `Assoc [ "type", `String "reasoning-delta"; "id", `String id; "delta", `String delta ]
  | Reasoning_end { id } -> `Assoc [ "type", `String "reasoning-end"; "id", `String id ]
  | Tool_input_start { tool_call_id; tool_name } ->
    `Assoc [ "type", `String "tool-input-start"; "toolCallId", `String tool_call_id; "toolName", `String tool_name ]
  | Tool_input_delta { tool_call_id; input_text_delta } ->
    `Assoc
      [
        "type", `String "tool-input-delta";
        "toolCallId", `String tool_call_id;
        "inputTextDelta", `String input_text_delta;
      ]
  | Tool_input_available { tool_call_id; tool_name; input } ->
    `Assoc
      [
        "type", `String "tool-input-available";
        "toolCallId", `String tool_call_id;
        "toolName", `String tool_name;
        "input", input;
      ]
  | Tool_output_available { tool_call_id; output } ->
    `Assoc [ "type", `String "tool-output-available"; "toolCallId", `String tool_call_id; "output", output ]
  | Tool_output_error { tool_call_id; error_text } ->
    `Assoc [ "type", `String "tool-output-error"; "toolCallId", `String tool_call_id; "errorText", `String error_text ]
  | Source_url { source_id; url; title } ->
    obj
      [
        some ("type", `String "source-url");
        some ("sourceId", `String source_id);
        some ("url", `String url);
        opt_string "title" title;
      ]
  | File { url; media_type } -> `Assoc [ "type", `String "file"; "url", `String url; "mediaType", `String media_type ]
  | Message_metadata { message_metadata } ->
    `Assoc [ "type", `String "message-metadata"; "messageMetadata", message_metadata ]
  | Tool_input_error { tool_call_id; tool_name; input; error_text } ->
    `Assoc
      [
        "type", `String "tool-input-error";
        "toolCallId", `String tool_call_id;
        "toolName", `String tool_name;
        "input", input;
        "errorText", `String error_text;
      ]
  | Tool_output_denied { tool_call_id } ->
    `Assoc [ "type", `String "tool-output-denied"; "toolCallId", `String tool_call_id ]
  | Source_document { source_id; media_type; title; filename } ->
    obj
      [
        some ("type", `String "source-document");
        some ("sourceId", `String source_id);
        some ("mediaType", `String media_type);
        some ("title", `String title);
        opt_string "filename" filename;
      ]
  | Error { error_text } -> `Assoc [ "type", `String "error"; "errorText", `String error_text ]
  | Data { data_type; id; data } ->
    obj [ some ("type", `String (Printf.sprintf "data-%s" data_type)); opt_string "id" id; some ("data", data) ]
