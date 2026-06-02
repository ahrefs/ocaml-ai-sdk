type _ Ai_provider.Provider_options.key += Cache : Cache_control.t Ai_provider.Provider_options.key

let with_cache_control ?cache_control opts =
  match cache_control with
  | None -> opts
  | Some cc -> Ai_provider.Provider_options.set Cache cc opts

let get_cache_control po =
  match Ai_provider.Provider_options.find Cache po with
  | Some cc -> Some cc
  | None ->
  match Ai_provider.Provider_options.find Ai_provider_anthropic.Cache_control_options.Cache po with
  | Some (a : Ai_provider_anthropic.Cache_control.t) ->
    let ttl =
      match a.ttl with
      | Some Ttl_5m -> Some Cache_control.Ttl_5m
      | Some Ttl_1h -> Some Cache_control.Ttl_1h
      | None -> None
    in
    Some { Cache_control.cache_type = Ephemeral; ttl }
  | None -> None
