module type S = sig
  val specification_version : string
  val provider : string
  val model_id : string
  val generate : Call_options.t -> Generate_result.t Lwt.t
  val stream : Call_options.t -> Stream_result.t Lwt.t
end

type t = (module S)

(* A provider can raise before returning a promise, for instance from request
   preparation or a [match%lwt] on a request that failed before it started (see
   [Http_client.body_string]). [Lwt.apply] turns that into a failed promise for
   every caller. *)
let generate (module M : S) opts = Lwt.apply M.generate opts
let stream (module M : S) opts = Lwt.apply M.stream opts
let provider (module M : S) = M.provider
let model_id (module M : S) = M.model_id
let specification_version (module M : S) = M.specification_version
