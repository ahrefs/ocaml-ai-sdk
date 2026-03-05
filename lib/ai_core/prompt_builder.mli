(** Build provider-layer prompt messages from user-friendly inputs. *)

(** Convert a simple string prompt to provider messages.
    Prepends a system message if [system] is provided. *)
val messages_of_prompt : ?system:string -> prompt:string -> unit -> Ai_provider.Prompt.message list

(** Convert [(role, content)] pairs to provider messages.
    Roles: ["system"], ["user"], ["assistant"].
    Prepends a system message if [system] is provided. *)
val messages_of_string_messages :
  ?system:string -> messages:(string * string) list -> unit -> Ai_provider.Prompt.message list

(** Append an assistant response and tool results to the message list
    for the next iteration of the tool loop. *)
val append_assistant_and_tool_results :
  messages:Ai_provider.Prompt.message list ->
  assistant_content:Ai_provider.Content.t list ->
  tool_results:Generate_text_result.tool_result list ->
  Ai_provider.Prompt.message list

(** Convert Core SDK tools to provider-layer tool definitions. *)
val tools_to_provider : (string * Core_tool.t) list -> Ai_provider.Tool.t list
