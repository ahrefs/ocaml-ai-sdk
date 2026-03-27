module Config = Config
module Model_catalog = Model_catalog
module Openai_options = Openai_options
module Openai_error = Openai_error
module Convert_prompt = Convert_prompt
module Convert_tools = Convert_tools
module Convert_response = Convert_response
module Convert_usage = Convert_usage
module Convert_stream = Convert_stream
module Sse = Sse
module Openai_api = Openai_api
module Openai_model = Openai_model

let language_model ?api_key ?base_url ?headers ?organization ?project ~model () =
  let config = Config.create ?api_key ?base_url ?headers ?organization ?project () in
  Openai_model.create ~config ~model

let model model_id =
  let config = Config.create () in
  Openai_model.create ~config ~model:model_id

let create ?api_key ?base_url ?headers ?organization ?project () =
  let config = Config.create ?api_key ?base_url ?headers ?organization ?project () in
  let module P = struct
    let name = "openai"
    let language_model model_id = Openai_model.create ~config ~model:model_id
  end in
  (module P : Ai_provider.Provider.S)
