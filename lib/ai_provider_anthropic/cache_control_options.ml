type _ Ai_provider.Provider_options.key += Cache : Cache_control.t Ai_provider.Provider_options.key

let with_cache_control ?cache_control opts =
  match cache_control with
  | None -> opts
  | Some cc -> Ai_provider.Provider_options.set Cache cc opts

let get_cache_control opts = Ai_provider.Provider_options.find Cache opts
