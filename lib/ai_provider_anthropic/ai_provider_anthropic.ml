module Config = Config
module Model_catalog = Model_catalog
module Thinking = Thinking
module Cache_control = Cache_control
module Anthropic_options = Anthropic_options
module Cache_control_options = Cache_control_options
module Convert_prompt = Convert_prompt
module Convert_tools = Convert_tools
module Convert_response = Convert_response
module Convert_usage = Convert_usage
module Anthropic_error = Anthropic_error
module Sse = Sse
module Convert_stream = Convert_stream
module Beta_headers = Beta_headers
module Anthropic_api = Anthropic_api
module Anthropic_model = Anthropic_model

let language_model ?api_key ?base_url ?headers ~model () =
  let config = Config.create ?api_key ?base_url ?headers () in
  Anthropic_model.create ~config ~model

let model model_id =
  let config = Config.create () in
  Anthropic_model.create ~config ~model:model_id

let create ?api_key ?base_url ?headers () =
  let config = Config.create ?api_key ?base_url ?headers () in
  let module P = struct
    let name = "anthropic"
    let language_model model_id = Anthropic_model.create ~config ~model:model_id
  end in
  (module P : Ai_provider.Provider.S)
