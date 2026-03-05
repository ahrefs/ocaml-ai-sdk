type t =
  | Unsupported_feature of {
      feature : string;
      details : string option;
    }
  | Other of { message : string }
