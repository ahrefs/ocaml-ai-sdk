type route =
  | Basic_chat
  | Tool_use
  | Reasoning
  | Structured_output
  | Abort_stop
  | Retry_regenerate
  | Client_tools
  | Completion
  | Tool_approval
  | Web_search
  | File_attachments

let all_routes =
  [
    Basic_chat;
    Tool_use;
    Reasoning;
    Structured_output;
    Abort_stop;
    Retry_regenerate;
    Client_tools;
    Completion;
    Tool_approval;
    Web_search;
    File_attachments;
  ]

let hash_of_route = function
  | Basic_chat -> "basic-chat"
  | Tool_use -> "tool-use"
  | Reasoning -> "reasoning"
  | Structured_output -> "structured-output"
  | Abort_stop -> "abort-stop"
  | Retry_regenerate -> "retry-regenerate"
  | Client_tools -> "client-tools"
  | Completion -> "completion"
  | Tool_approval -> "tool-approval"
  | Web_search -> "web-search"
  | File_attachments -> "file-attachments"

let route_of_hash = function
  | "basic-chat" -> Basic_chat
  | "tool-use" -> Tool_use
  | "reasoning" -> Reasoning
  | "structured-output" -> Structured_output
  | "abort-stop" -> Abort_stop
  | "retry-regenerate" -> Retry_regenerate
  | "client-tools" -> Client_tools
  | "completion" -> Completion
  | "tool-approval" -> Tool_approval
  | "web-search" -> Web_search
  | "file-attachments" -> File_attachments
  | _ -> Basic_chat

let route_label = function
  | Basic_chat -> "Basic Chat"
  | Tool_use -> "Tool Use"
  | Reasoning -> "Reasoning"
  | Structured_output -> "Structured Output"
  | Abort_stop -> "Abort / Stop"
  | Retry_regenerate -> "Retry / Regenerate"
  | Client_tools -> "Client-side Tools"
  | Completion -> "Completion"
  | Tool_approval -> "Tool Approval"
  | Web_search -> "Web Search"
  | File_attachments -> "File Attachments"

let is_stub = function
  | Client_tools | Web_search | File_attachments -> true
  | Basic_chat | Tool_use | Reasoning | Structured_output | Abort_stop | Retry_regenerate | Completion
  | Tool_approval -> false

let route_description = function
  | Basic_chat -> "Simple streaming chat with useChat hook"
  | Tool_use -> "Server-side tool execution with weather and search tools"
  | Reasoning -> "Extended thinking with collapsible reasoning blocks"
  | Structured_output -> "Schema-validated JSON output rendered as cards"
  | Abort_stop -> "Stop generation mid-stream"
  | Retry_regenerate -> "Regenerate the last assistant response"
  | Client_tools -> "Browser-side tool execution with user confirmation"
  | Completion -> "Text completion with useCompletion hook"
  | Tool_approval -> "Human-in-the-loop tool approval workflow"
  | Web_search -> "Provider built-in web search tools"
  | File_attachments -> "Image and file attachments in messages"
