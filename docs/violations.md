# Code Quality Violations

Known violations of the project's CLAUDE.md code standards. Track here to fix incrementally.

## Manual JSON construction

**Rule**: Never construct JSON manually with `` `Assoc ``, `` `String ``, etc. Always use typed records with `[@@deriving to_json]` / `[@@deriving of_json]`.

### ai_provider_openai

- `openai_model.ml:48-51` — `build_logit_bias` constructs `Assoc` / `Float` manually for logit bias map.
  - Logit bias is `(int * float) list` with int keys — a dynamic map that cannot be a typed record. May need a custom JSON encoder type or an explicit exception to the rule.
- `openai_model.ml:53-55` — `build_metadata` constructs `Assoc` / `String` manually for string-to-string metadata.
  - Same situation as logit bias — dynamic key-value map.

### ai_provider_openrouter

- `openrouter_options.ml` — multiple `*_to_json` functions construct JSON manually (`provider_prefs_to_json`, `plugin_to_json`, `logit_bias_to_json`, etc.) for dynamic/polymorphic structures.
  - These have dynamic keys, optional fields, or polymorphic shapes that cannot be represented as fixed typed records with derivers. Legitimate exception.

## Duplicated code across providers

Significant code duplication between `ai_provider_openai` and `ai_provider_openrouter`:

- `body_to_line_stream` — identical in both `openai_api.ml` and `openrouter_api.ml`
- `chat_completions` HTTP plumbing — near-identical
- `build_response_format` + associated types (`json_object_format`, `json_schema_detail`, `json_schema_format`) — identical
- `convert_stream.ml` — ~95% identical, OpenRouter adds `reasoning_details` handling
- `convert_response.ml` — ~85% identical, OpenRouter adds `reasoning_details` and `provider_metadata`
- `reasoning_detail_json` type — duplicated between `convert_response.ml` and `convert_stream.ml` within OpenRouter provider

A shared `ai_provider_common` library could extract these.

## TODO

- [ ] Audit other providers (if added) for the same violations
- [ ] Audit other providers for invented behavior not present in upstream (parameter stripping, hardcoded model lists, etc.)
- [ ] Decide whether dynamic key-value maps (logit_bias, metadata, api_keys) get a documented exception or a shared helper
- [ ] Extract shared code into `ai_provider_common` (see duplication section above)
