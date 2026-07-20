(** Pure wake/receive guidance for install, managed start, and doctor.

    Idle wake classes match [docs/wake-contract.md]: GUARANTEED / CONDITIONAL /
    NONE. When [manual_inbox_required] is true, operators and agents must arm
    [c2c monitor] or poll with [c2c poll-inbox] for idle receive.
*)

type wake_class =
  | Guaranteed
  | Conditional
  | None_idle

type receive_advice = {
  client : string;
  wake : wake_class;
  primary : string;
  manual_inbox_required : bool;
  warning_lines : string list;
}

val wake_class_label : wake_class -> string

val advice :
  client:string ->
  context:[ `Install | `Managed_start ] ->
  receive_advice

val print_warning_lines : ?oc:out_channel -> receive_advice -> unit
val print_install_receive_footer : client:string -> unit -> unit
val print_managed_start_receive_footer : client:string -> unit -> unit
