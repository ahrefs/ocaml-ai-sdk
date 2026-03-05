type t =
  | System of Types.system_message
  | Assistant of Types.assistant_message
  | Result of Types.result_message
  | User of Types.user_message
  | Control_request of Types.control_request
  | Control_response of Types.control_response
  | Unknown of Yojson.Safe.t

let of_json json =
  match Yojson.Safe.Util.(member "type" json |> to_string) with
  | "system" -> begin
    match Types.system_message_of_yojson json with
    | Ok m -> System m
    | Error _ -> Unknown json
  end
  | "assistant" -> begin
    match Types.assistant_message_of_yojson json with
    | Ok m -> Assistant m
    | Error _ -> Unknown json
  end
  | "result" -> begin
    match Types.result_message_of_yojson json with
    | Ok m -> Result m
    | Error _ -> Unknown json
  end
  | "user" -> begin
    match Types.user_message_of_yojson json with
    | Ok m -> User m
    | Error _ -> Unknown json
  end
  | "control_request" -> begin
    match Types.control_request_of_yojson json with
    | Ok m -> Control_request m
    | Error _ -> Unknown json
  end
  | "control_response" -> begin
    match Types.control_response_of_yojson json with
    | Ok m -> Control_response m
    | Error _ -> Unknown json
  end
  | _ -> Unknown json
  | exception _ -> Unknown json

let is_result = function
  | Result _ -> true
  | _ -> false

let result_text = function
  | Result r -> r.result
  | _ -> None

let assistant_text = function
  | Assistant a ->
    let texts =
      List.filter_map
        (function
          | Types.Text { text } -> Some text
          | _ -> None)
        a.message.content
    in
    if texts = [] then None else Some (String.concat "" texts)
  | _ -> None

let session_id = function
  | System s -> s.session_id
  | Assistant a -> a.session_id
  | Result r -> r.session_id
  | _ -> None
