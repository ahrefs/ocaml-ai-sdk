(** Predicates that control when the multi-step tool loop terminates.

    Matches the upstream AI SDK's [stopWhen] parameter.
    Each condition receives the accumulated steps so far and returns
    whether the loop should stop. Multiple conditions use OR semantics:
    the loop stops when {i any} condition is met. *)

(** A stop condition receives the list of completed steps (most recent last)
    and returns whether the loop should stop. *)
type t = steps:Generate_text_result.step list -> bool Lwt.t

(** [step_count_is n] stops the loop when [n] steps have completed.
    Equivalent to the upstream [stepCountIs(n)]. *)
val step_count_is : int -> t

(** [has_tool_call tool_name] stops the loop when the most recent step
    contains a call to a tool named [tool_name].
    Equivalent to the upstream [hasToolCall(toolName)]. *)
val has_tool_call : string -> t

(** [is_loop_finished] never stops the loop, so passing it is the same as
    passing no condition. The loop still ends when the model answers
    without tool calls, a tool needs approval, the call is aborted, or
    [max_steps] is reached. Named after the upstream [isLoopFinished()],
    which replaces the default [stepCountIs(1)] and so lifts the step
    limit. Here [max_steps] still defaults to 1, so pass a larger
    [~max_steps] with it. *)
val is_loop_finished : t

(** [is_met conditions ~steps] returns [true] when any condition in
    [conditions] is satisfied (OR semantics). Returns [false] for
    an empty condition list. *)
val is_met : t list -> steps:Generate_text_result.step list -> bool Lwt.t
