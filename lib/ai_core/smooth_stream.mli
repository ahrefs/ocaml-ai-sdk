(** Smooth text and reasoning streaming output.

    Buffers {!Text_stream_part.Text_delta} and {!Text_stream_part.Reasoning_delta}
    chunks and re-emits them in controlled pieces (word-by-word, line-by-line, or
    custom) with optional inter-chunk delays. Matches the upstream AI SDK's
    [smoothStream] transform.

    All other stream events pass through immediately, flushing any buffered
    text first. *)

(** How to split buffered text into chunks for emission. *)
type chunking =
  | Word  (** Stream word-by-word. Matches non-whitespace followed by whitespace
          (regex [\S+\s+]). Default. *)
  | Line  (** Stream line-by-line. Matches one or more newlines (regex [\n+]). *)
  | Regex of Re2.t
    (** Stream using a custom Re2 pattern. The match (including everything
          before it) is emitted as one chunk — same semantics as upstream
          [RegExp] chunking. *)
  | Segmenter
    (** Unicode UAX#29 word segmentation via [uuseg]. Recommended for
          CJK languages where words are not separated by spaces.
          Equivalent to upstream [Intl.Segmenter]. *)
  | Custom of (string -> string option)
    (** User-provided chunk detector. Receives the buffer, returns the
          prefix to emit as [Some chunk], or [None] to wait for more data.
          The returned string must be a non-empty prefix of the buffer. *)

(** [create ?delay_ms ?chunking ()] returns a stream transformer.

    @param delay_ms Delay in milliseconds between emitted chunks.
      Default is [10]. Pass [0] to disable delays.
    @param chunking Controls how text is split into chunks.
      Default is [Word]. *)
val create :
  ?delay_ms:int -> ?chunking:chunking -> unit -> Text_stream_part.t Lwt_stream.t -> Text_stream_part.t Lwt_stream.t
