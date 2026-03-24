(** Melange bindings for [@ai-sdk/react] v3.0.118.

    Types are exposed at the toplevel: [Ai_sdk_react.ui_message],
    [Ai_sdk_react.chat_status], etc.

    @see <https://ai-sdk.dev/docs/ai-sdk-ui> AI SDK UI documentation *)

include module type of Types

module Use_chat = Use_chat
module Use_completion = Use_completion
