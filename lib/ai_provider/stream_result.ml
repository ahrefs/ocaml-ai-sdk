type t = {
  stream : Stream_part.t Lwt_stream.t;
  warnings : Warning.t list;
  raw_response : Generate_result.response_info option;
}
