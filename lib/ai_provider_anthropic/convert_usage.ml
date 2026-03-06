type anthropic_usage = {
  input_tokens : int;
  output_tokens : int;
  cache_read_input_tokens : int option;
  cache_creation_input_tokens : int option;
}

let int_or_default json key default =
  match Yojson.Safe.Util.(member key json) with
  | `Int n -> n
  | _ -> default

let int_opt json key =
  match Yojson.Safe.Util.(member key json) with
  | `Int n -> Some n
  | _ -> None

let anthropic_usage_of_yojson json =
  {
    input_tokens = int_or_default json "input_tokens" 0;
    output_tokens = int_or_default json "output_tokens" 0;
    cache_read_input_tokens = int_opt json "cache_read_input_tokens";
    cache_creation_input_tokens = int_opt json "cache_creation_input_tokens";
  }

let to_usage u =
  {
    Ai_provider.Usage.input_tokens = u.input_tokens;
    output_tokens = u.output_tokens;
    total_tokens = Some (u.input_tokens + u.output_tokens);
  }

type _ Ai_provider.Provider_options.key += Cache_metrics : anthropic_usage Ai_provider.Provider_options.key

let to_provider_metadata u = Ai_provider.Provider_options.set Cache_metrics u Ai_provider.Provider_options.empty
