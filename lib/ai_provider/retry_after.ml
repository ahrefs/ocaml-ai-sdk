(* Strict numeric parse for machine headers: trims surrounding whitespace,
   rejects NaN/infinity (which [float_of_string_opt] would otherwise accept),
   and rejects negative values. Returns the parsed non-negative finite float. *)
let parse_non_negative_seconds value =
  match float_of_string_opt (String.trim value) with
  | Some f when Float.is_finite f && f >= 0.0 -> Some f
  | Some _ | None -> None

(* retry-after-ms is milliseconds. A present, numeric value wins outright:
   upstream sets [ms] from it and never falls through to retry-after, so a
   negative or infinite millisecond value resolves to [None] overall rather than
   deferring to retry-after. A missing, non-numeric, or NaN value falls through
   (upstream's [parseFloat] yields NaN for non-numeric input, which its
   [!isNaN] guard treats the same as absent). *)
let of_retry_after_ms value =
  match float_of_string_opt (String.trim value) with
  | Some ms when Float.is_nan ms -> `Fall_through
  | Some ms when Float.is_finite ms && ms >= 0.0 -> `Seconds (ms /. 1000.0)
  | Some _ -> `Rejected
  | None -> `Fall_through

let parse ~retry_after_ms ~retry_after =
  let from_ms =
    match retry_after_ms with
    | Some value -> of_retry_after_ms value
    | None -> `Fall_through
  in
  match from_ms with
  | `Seconds s -> Some s
  | `Rejected -> None
  | `Fall_through -> Option.bind retry_after parse_non_negative_seconds
