(** Parse HTTP rate-limit hints into a retry delay in seconds.

    Mirrors upstream AI SDK header handling: [retry-after-ms] (milliseconds,
    used by e.g. OpenAI) takes precedence over the standard [retry-after]
    header. Both are parsed as machine-oriented numeric values.

    The HTTP-date form of [retry-after] is intentionally NOT supported: a
    non-numeric [retry-after] yields [None] rather than a parsed date. *)

(** [parse ~retry_after_ms ~retry_after] returns the hinted delay in seconds.

    Precedence follows upstream: if [retry_after_ms] is present and numeric,
    it is used (value is milliseconds, divided by 1000) and [retry_after] is
    NOT consulted — even when the millisecond value is rejected as negative or
    non-finite. Only an absent or non-numeric [retry_after_ms] falls through to
    [retry_after], parsed as fractional-or-integer seconds.

    Returns [None] for absent, empty, non-numeric, negative, or non-finite
    values. Surrounding whitespace is tolerated. *)
val parse : retry_after_ms:string option -> retry_after:string option -> float option
