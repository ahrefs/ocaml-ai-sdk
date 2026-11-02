(** Length-prefixed frames: [u32] little-endian payload length, then exactly that many bytes (one CBOR item, see
    {!Cbor}). The length is compared with the cap before anything is allocated or read. *)

(** 16 MiB, the runner's default. *)
val default_max_frame_bytes : int

(** 1 GiB, the largest cap the runner accepts. *)
val max_allowed_frame_bytes : int

type write_error =
  | Too_large of {
      size : int;
      max : int;
    }  (** nothing was written *)
  | Empty  (** zero-length payloads are not valid frames; nothing was written *)
  | Io_error of string  (** the channel failed; the stream may hold a partial frame *)

val string_of_write_error : write_error -> string

(** Write one frame and flush. *)
val write : max_frame_bytes:int -> Lwt_io.output_channel -> string -> (unit, write_error) result Lwt.t

(** Read one frame payload. [Ok None] is a clean EOF at a frame boundary. A zero or over-cap length, EOF inside the
    length prefix or the payload, and I/O errors are [Error _] (fatal for the stream: there is no resynchronisation). *)
val read : max_frame_bytes:int -> Lwt_io.input_channel -> (string option, string) result Lwt.t
