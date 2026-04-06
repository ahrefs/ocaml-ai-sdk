type provider =
  | Anthropic
  | Openai

let provider_to_string = function
  | Anthropic -> "anthropic"
  | Openai -> "openai"

let provider_label = function
  | Anthropic -> "Anthropic"
  | Openai -> "OpenAI"

type context = {
  provider : provider;
  set_provider : (provider -> provider) -> unit;
}

let default_context = { provider = Anthropic; set_provider = (fun _ -> ()) }
let react_context = React.createContext default_context
let use_provider () = React.useContext react_context

let context_provider = React.Context.provider react_context

let make_provider ~value children = React.createElement context_provider (React.Context.makeProps ~value ~children ())
