module Config = Config
module Model_catalog = Model_catalog
module Openrouter_options = Openrouter_options
module Openrouter_error = Openrouter_error
module Convert_prompt = Convert_prompt
module Convert_tools = Convert_tools
module Convert_response = Convert_response
module Convert_usage = Convert_usage
module Convert_stream = Convert_stream
module Sse = Sse
module Openrouter_api = Openrouter_api
module Openrouter_model = Openrouter_model

let language_model ?api_key ?base_url ?headers ?app_title ?app_url ~model () =
  let config = Config.create ?api_key ?base_url ?headers ?app_title ?app_url () in
  Openrouter_model.create ~config ~model

let model model_id =
  let config = Config.create () in
  Openrouter_model.create ~config ~model:model_id

let create ?api_key ?base_url ?headers ?app_title ?app_url () =
  let config = Config.create ?api_key ?base_url ?headers ?app_title ?app_url () in
  let module P = struct
    let name = "openrouter"
    let language_model model_id = Openrouter_model.create ~config ~model:model_id
  end in
  (module P : Ai_provider.Provider.S)
