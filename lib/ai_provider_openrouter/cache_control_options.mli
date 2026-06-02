(** Per-content-part cache control via Provider_options for OpenRouter.

    Mirrors [Ai_provider_anthropic.Cache_control_options] but uses
    [Openrouter_cache_control.t]. Resolution follows upstream
    [getCacheControl()] in [src/chat/convert-to-openrouter-chat-messages.ts]:
    look up the OpenRouter key first, then fall back to the Anthropic
    [Cache_control_options.Cache] key for compatibility with prompts
    written against the Anthropic-native provider.

    {b Supported placement today:}
    - {b System message:} pass via
      [Generate_text.system_provider_options] /
      [Stream_text.system_provider_options].
    - {b User text and file parts:} attach to each [Prompt.user_part]'s
      [provider_options].
    - {b Assistant text, file, reasoning, and tool_call parts:} attach to
      each [Prompt.assistant_part]'s [provider_options].
    - {b Tool results:} attach to each [Prompt.tool_result]'s
      [provider_options].

    {b Not yet supported:} Message-level [provider_options] on
    [Prompt.User], [Prompt.Assistant], and [Prompt.Tool] variants.
    Upstream resolves [messagePO ?? partPO], but our [Prompt.message]
    type does not carry [provider_options] on those constructors — only
    on [Prompt.System]. Set the cache marker on the specific part
    (typically the last text part for a multi-part user message) or
    on the [tool_result] instead. Tracked in
    [docs/plans/2026-03-26-v3-roadmap.md] under "Message-level
    [provider_options] on User / Assistant / Tool prompts". *)

type _ Ai_provider.Provider_options.key +=
  | Cache : Cache_control.t Ai_provider.Provider_options.key
      (** GADT key for per-part cache control on OpenRouter requests. *)

(** Add cache control to provider options. No-op if [cache_control] is [None]. *)
val with_cache_control :
  ?cache_control:Cache_control.t -> Ai_provider.Provider_options.t -> Ai_provider.Provider_options.t

(** Extract cache control from provider options.

    Resolution order (mirrors upstream
    [openrouter.cacheControl ?? openrouter.cache_control ?? anthropic.cacheControl ?? anthropic.cache_control]):
    - [Openrouter_cache_control_options.Cache] (this module's key)
    - [Ai_provider_anthropic.Cache_control_options.Cache] (record rebuilt at the boundary) *)
val get_cache_control : Ai_provider.Provider_options.t -> Cache_control.t option
