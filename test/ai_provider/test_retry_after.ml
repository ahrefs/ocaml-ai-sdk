open Alcotest

module R = Ai_provider.Retry_after

let parse ?(retry_after_ms = None) ?(retry_after = None) () = R.parse ~retry_after_ms ~retry_after

let opt_float = option (float 0.001)

(* retry-after as fractional-or-integer seconds. *)
let test_retry_after_integer_seconds () = (check opt_float) "5 -> 5.0" (Some 5.0) (parse ~retry_after:(Some "5") ())

let test_retry_after_fractional_seconds () =
  (check opt_float) "1.5 -> 1.5" (Some 1.5) (parse ~retry_after:(Some "1.5") ())

let test_retry_after_trims_whitespace () =
  (check opt_float) "' 5 ' -> 5.0" (Some 5.0) (parse ~retry_after:(Some " 5 ") ())

let test_retry_after_plus_sign () = (check opt_float) "+1 -> 1.0" (Some 1.0) (parse ~retry_after:(Some "+1") ())

let test_retry_after_rejects_negative () = (check opt_float) "-1 -> None" None (parse ~retry_after:(Some "-1") ())

let test_retry_after_rejects_empty () = (check opt_float) "'' -> None" None (parse ~retry_after:(Some "") ())

let test_retry_after_rejects_http_date () =
  (check opt_float) "http-date -> None" None (parse ~retry_after:(Some "Wed, 21 Oct 2025 07:28:00 GMT") ())

let test_retry_after_rejects_garbage () =
  (check opt_float) "tomorrow -> None" None (parse ~retry_after:(Some "tomorrow") ())

let test_retry_after_rejects_nan () = (check opt_float) "nan -> None" None (parse ~retry_after:(Some "nan") ())

let test_retry_after_rejects_inf () = (check opt_float) "inf -> None" None (parse ~retry_after:(Some "inf") ())

let test_none_when_absent () = (check opt_float) "absent -> None" None (parse ())

(* retry-after-ms: milliseconds, precedence over retry-after. *)
let test_retry_after_ms_precedence () =
  (check opt_float) "ms wins, /1000" (Some 0.2) (parse ~retry_after_ms:(Some "200") ~retry_after:(Some "5") ())

let test_retry_after_ms_fractional () =
  (check opt_float) "1500ms -> 1.5" (Some 1.5) (parse ~retry_after_ms:(Some "1500") ())

(* Numeric-but-negative retry-after-ms does NOT fall through to retry-after. *)
let test_retry_after_ms_negative_no_fallthrough () =
  (check opt_float) "negative ms -> None (no fall-through)" None
    (parse ~retry_after_ms:(Some "-5") ~retry_after:(Some "3") ())

(* Non-numeric retry-after-ms falls through to retry-after. *)
let test_retry_after_ms_non_numeric_fallthrough () =
  (check opt_float) "garbage ms falls through" (Some 3.0)
    (parse ~retry_after_ms:(Some "oops") ~retry_after:(Some "3") ())

(* NaN retry-after-ms is upstream's non-numeric case: it falls through to
   retry-after (parseFloat yields NaN, treated the same as an absent header). *)
let test_retry_after_ms_nan_fallthrough () =
  (check opt_float) "nan ms falls through" (Some 3.0) (parse ~retry_after_ms:(Some "nan") ~retry_after:(Some "3") ())

(* Infinite retry-after-ms is numeric-but-unreasonable: rejected outright, no
   fall-through (upstream sets ms from it, then the reasonableness gate drops it). *)
let test_retry_after_ms_infinite_no_fallthrough () =
  (check opt_float) "inf ms -> None (no fall-through)" None
    (parse ~retry_after_ms:(Some "inf") ~retry_after:(Some "3") ())

let () =
  run "Retry_after"
    [
      ( "retry_after",
        [
          test_case "integer_seconds" `Quick test_retry_after_integer_seconds;
          test_case "fractional_seconds" `Quick test_retry_after_fractional_seconds;
          test_case "trims_whitespace" `Quick test_retry_after_trims_whitespace;
          test_case "plus_sign" `Quick test_retry_after_plus_sign;
          test_case "rejects_negative" `Quick test_retry_after_rejects_negative;
          test_case "rejects_empty" `Quick test_retry_after_rejects_empty;
          test_case "rejects_http_date" `Quick test_retry_after_rejects_http_date;
          test_case "rejects_garbage" `Quick test_retry_after_rejects_garbage;
          test_case "rejects_nan" `Quick test_retry_after_rejects_nan;
          test_case "rejects_inf" `Quick test_retry_after_rejects_inf;
          test_case "none_when_absent" `Quick test_none_when_absent;
        ] );
      ( "retry_after_ms",
        [
          test_case "precedence" `Quick test_retry_after_ms_precedence;
          test_case "fractional" `Quick test_retry_after_ms_fractional;
          test_case "negative_no_fallthrough" `Quick test_retry_after_ms_negative_no_fallthrough;
          test_case "non_numeric_fallthrough" `Quick test_retry_after_ms_non_numeric_fallthrough;
          test_case "nan_fallthrough" `Quick test_retry_after_ms_nan_fallthrough;
          test_case "infinite_no_fallthrough" `Quick test_retry_after_ms_infinite_no_fallthrough;
        ] );
    ]
