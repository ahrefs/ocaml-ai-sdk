(** HTTP client for provider API calls, built on libcurl through [Curl_lwt].

    Only [http] and [https] URLs are accepted. Server certificates are verified
    against libcurl's default CA file and directory. The [SSL_CERT_FILE] and
    [SSL_CERT_DIR] environment variables, when set, replace the default file and
    directory respectively. A file that cannot be read is skipped, and so is
    [SSL_CERT_DIR] on a TLS backend without CA directory support. A readable
    file that holds no usable certificate fails every HTTPS request with a
    non-retryable [Network_error]. Requests never go through a proxy: the
    [http_proxy], [https_proxy] and [all_proxy] environment variables are
    ignored. libcurl built with OpenSSL writes TLS session keys to the file
    named by [SSLKEYLOGFILE] when that variable is set. Requests send
    [User-Agent: ocaml-ai-sdk/<version>] unless the caller passes its own
    [User-Agent] header, and enable TCP keepalive.

    [timeouts.connect_timeout] bounds connection setup,
    [timeouts.request_timeout] the wait for response headers and
    [timeouts.stream_idle_timeout] the gap between body chunks. Timeouts and
    transport failures fail with [Provider_error.Provider_error]. *)

type response

(** POSTs [body] to the URL and resolves once the final (non-1xx) response
    headers arrive. Fails with a [Request_headers] timeout after
    [timeouts.request_timeout], or with [Network_error] when the transfer fails
    before headers. A transfer option that libcurl rejects, such as a URL over
    its 8 MB string limit, fails with a non-retryable [Network_error].
    Cancelling the returned promise aborts the transfer. *)
val post :
  timeouts:Http_timeouts.t ->
  provider:string ->
  headers:(string * string) list ->
  body:string ->
  string ->
  response Lwt.t

val status : response -> int

(** Case-insensitive header lookup. *)
val header : response -> string -> string option

(** Reads the whole body. Fails with [Network_error] on a transport failure, or
    with a [Stream_idle] timeout when no chunk arrives within
    [timeouts.stream_idle_timeout]; both abort the transfer. *)
val body_string : response -> string Lwt.t

(** Reads the body of an error response, at most 64 KiB within 10 seconds. A
    transport failure, a timeout or either limit ends the read instead of
    failing it, so the caller keeps the status and headers and gets whatever
    part of the body arrived. The rest of the transfer is aborted. *)
val error_body : response -> string Lwt.t

(** The body as lines (split on LF, CR stripped), read on demand. The idle timer
    runs only while a read waits for the next chunk, so a stream nobody reads is
    never timed out or aborted. A trailing line without LF is
    emitted at end of body. A read fails with the same errors as [body_string];
    the transfer is then aborted and later reads return [None]. *)
val body_lines : response -> string Lwt_stream.t

module For_testing : sig
  (** A response whose body comes from in-memory chunks; [body_string] and
      [body_lines] behave as for a network response. *)
  val response_of_chunks :
    timeouts:Http_timeouts.t ->
    provider:string ->
    status:int ->
    headers:(string * string) list ->
    string Lwt_stream.t ->
    response
end
