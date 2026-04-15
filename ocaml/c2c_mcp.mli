type registration =
  { session_id : string
  ; alias : string
  ; pid : int option
  ; pid_start_time : int option
  ; registered_at : float option
  }
type message = { from_alias : string; to_alias : string; content : string }
type room_member = { rm_alias : string; rm_session_id : string; joined_at : float }
type room_message = { rm_from_alias : string; rm_room_id : string; rm_content : string; rm_ts : float }
type room_visibility = Public | Invite_only
type room_meta = { visibility : room_visibility; invited_members : string list }

module C2c_start : module type of C2c_start

module Broker : sig
  type t
  val create : root:string -> t
  val root : t -> string
  val register : t -> session_id:string -> alias:string -> pid:int option -> pid_start_time:int option -> unit
  val list_registrations : t -> registration list
  val save_registrations : t -> registration list -> unit
  val with_registry_lock : t -> (unit -> 'a) -> 'a
  val registration_is_alive : registration -> bool
  val read_pid_start_time : int -> int option
  val capture_pid_start_time : int option -> int option
  val enqueue_message : t -> from_alias:string -> to_alias:string -> content:string -> unit
  type send_all_result = { sent_to : string list; skipped : (string * string) list }
  val send_all : t -> from_alias:string -> content:string -> exclude_aliases:string list -> send_all_result
  val read_inbox : t -> session_id:string -> message list
  val drain_inbox : t -> session_id:string -> message list
  val with_inbox_lock : t -> session_id:string -> (unit -> 'a) -> 'a
  type sweep_result = { dropped_regs : registration list; deleted_inboxes : string list; preserved_messages : int }
  val sweep : t -> sweep_result
  val dead_letter_path : t -> string
  type archive_entry = { ae_drained_at : float; ae_from_alias : string; ae_to_alias : string; ae_content : string }
  val archive_path : t -> session_id:string -> string
  val append_archive : t -> session_id:string -> messages:message list -> unit
  val read_archive : t -> session_id:string -> limit:int -> archive_entry list
  type liveness_state = Alive | Dead | Unknown
  val registration_liveness_state : registration -> liveness_state
  val int_opt_member : string -> Yojson.Safe.t -> int option
  val valid_room_id : string -> bool
  val load_room_meta : t -> room_id:string -> room_meta
  val save_room_meta : t -> room_id:string -> room_meta -> unit
  val send_room_invite : t -> room_id:string -> from_alias:string -> invitee_alias:string -> unit
  val set_room_visibility : t -> room_id:string -> from_alias:string -> visibility:room_visibility -> unit
  val join_room : t -> room_id:string -> alias:string -> session_id:string -> room_member list
  val leave_room : t -> room_id:string -> alias:string -> room_member list
  val append_room_history : t -> room_id:string -> from_alias:string -> content:string -> float
  val read_room_history : t -> room_id:string -> limit:int -> room_message list
  type send_room_result = { sr_delivered_to : string list; sr_skipped : string list; sr_ts : float }
  val send_room : t -> from_alias:string -> room_id:string -> content:string -> send_room_result
  type room_info = { ri_room_id : string; ri_member_count : int; ri_members : string list; ri_alive_member_count : int; ri_dead_member_count : int; ri_unknown_member_count : int; ri_member_details : room_member_info list; ri_visibility : room_visibility; ri_invited_members : string list }
  and room_member_info = { rmi_alias : string; rmi_session_id : string; rmi_alive : bool option }
  val list_rooms : t -> room_info list
  val my_rooms : t -> session_id:string -> room_info list
  val read_room_members : t -> room_id:string -> room_member list
  val evict_dead_from_rooms : t -> dead_session_ids:string list -> dead_aliases:string list -> (string * string) list
  val prune_rooms : t -> (string * string) list
end

(* Native OCaml relay modules *)
module Relay : module type of Relay

val channel_notification : message -> Yojson.Safe.t
val auto_register_startup : broker_root:string -> unit
val auto_join_rooms_startup : broker_root:string -> unit
val handle_request : broker_root:string -> Yojson.Safe.t -> Yojson.Safe.t option Lwt.t