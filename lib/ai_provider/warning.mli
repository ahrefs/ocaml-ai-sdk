(** Warnings emitted by providers for unsupported features. *)

type t =
  | Unsupported_feature of {
      feature : string;
      details : string option;
    }
  | Other of { message : string }
