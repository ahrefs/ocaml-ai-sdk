type t = {
  description : string option;
  parameters : Yojson.Safe.t;
  execute : Yojson.Safe.t -> Yojson.Safe.t Lwt.t;
}
