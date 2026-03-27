type reasoning_effort =
  | Re_none
  | Minimal
  | Low
  | Medium
  | High
  | Xhigh

type service_tier =
  | St_auto
  | Flex
  | Priority
  | St_default

type prediction = {
  type_ : string;
  content : string;
}

type t = {
  logit_bias : (int * float) list;
  logprobs : int option;
  parallel_tool_calls : bool option;
  user : string option;
  reasoning_effort : reasoning_effort option;
  max_completion_tokens : int option;
  store : bool option;
  metadata : (string * string) list;
  prediction : prediction option;
  service_tier : service_tier option;
  strict_json_schema : bool;
  system_message_mode : Model_catalog.system_message_mode option;
}

let default =
  {
    logit_bias = [];
    logprobs = None;
    parallel_tool_calls = None;
    user = None;
    reasoning_effort = None;
    max_completion_tokens = None;
    store = None;
    metadata = [];
    prediction = None;
    service_tier = None;
    strict_json_schema = true;
    system_message_mode = None;
  }

type _ Ai_provider.Provider_options.key += Openai : t Ai_provider.Provider_options.key

let to_provider_options opts = Ai_provider.Provider_options.set Openai opts Ai_provider.Provider_options.empty

let of_provider_options opts = Ai_provider.Provider_options.find Openai opts

let reasoning_effort_to_string = function
  | Re_none -> "none"
  | Minimal -> "minimal"
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Xhigh -> "xhigh"

let service_tier_to_string = function
  | St_auto -> "auto"
  | Flex -> "flex"
  | Priority -> "priority"
  | St_default -> "default"
