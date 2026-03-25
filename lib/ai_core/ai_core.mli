(** OCaml AI SDK — Core SDK layer.

    Provides [generate_text], [stream_text], and UIMessage stream protocol
    for frontend interoperability with [useChat()]. *)

module Core_tool = Core_tool
module Generate_text_result = Generate_text_result
module Text_stream_part = Text_stream_part
module Ui_message_chunk = Ui_message_chunk
module Prompt_builder = Prompt_builder
module Ui_message_stream = Ui_message_stream
module Generate_text = Generate_text
module Stream_text_result = Stream_text_result
module Stream_text = Stream_text
module Server_handler = Server_handler
module Json_schema_validator = Json_schema_validator
