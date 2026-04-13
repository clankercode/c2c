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

module Broker : sig
  type t

  val create : root:string -> t
  val root : t -> string
  val register :
    t
    -> session_id:string
    -> alias:string
    -> pid:int option
    -> pid_start_time:int option
    -> unit

  val list_registrations : t -> registration list
  val registration_is_alive : registration -> bool
  val read_pid_start_time : int -> int option
  val capture_pid_start_time : int option -> int option
  val enqueue_message : t -> from_alias:string -> to_alias:string -> content:string -> unit

  type send_all_result =
    { sent_to : string list
    ; skipped : (string * string) list
    }

  val send_all :
    t
    -> from_alias:string
    -> content:string
    -> exclude_aliases:string list
    -> send_all_result
  val read_inbox : t -> session_id:string -> message list
  val drain_inbox : t -> session_id:string -> message list
  val with_inbox_lock : t -> session_id:string -> (unit -> 'a) -> 'a

  type sweep_result =
    { dropped_regs : registration list
    ; deleted_inboxes : string list
    ; preserved_messages : int
    }

  val sweep : t -> sweep_result
  val dead_letter_path : t -> string

  (** {2 Inbox archive} *)

  type archive_entry =
    { ae_drained_at : float
    ; ae_from_alias : string
    ; ae_to_alias : string
    ; ae_content : string
    }

  val archive_path : t -> session_id:string -> string
  val append_archive : t -> session_id:string -> messages:message list -> unit
  val read_archive : t -> session_id:string -> limit:int -> archive_entry list

  (** {2 N:N rooms (phase 2)} *)

  type liveness_state = Alive | Dead | Unknown
  val registration_liveness_state : registration -> liveness_state
  val int_opt_member : string -> Yojson.Safe.t -> int option

  val valid_room_id : string -> bool
  val join_room : t -> room_id:string -> alias:string -> session_id:string -> room_member list
  val leave_room : t -> room_id:string -> alias:string -> room_member list
  val append_room_history : t -> room_id:string -> from_alias:string -> content:string -> float
  val read_room_history : t -> room_id:string -> limit:int -> room_message list

  type send_room_result =
    { sr_delivered_to : string list
    ; sr_skipped : string list
    ; sr_ts : float
    }

  val send_room : t -> from_alias:string -> room_id:string -> content:string -> send_room_result

  type room_info =
    { ri_room_id : string
    ; ri_member_count : int
    ; ri_members : string list
    }

  val list_rooms : t -> room_info list
  val my_rooms : t -> session_id:string -> room_info list
end

val channel_notification : message -> Yojson.Safe.t
val auto_register_startup : broker_root:string -> unit
val auto_join_rooms_startup : broker_root:string -> unit
val handle_request : broker_root:string -> Yojson.Safe.t -> Yojson.Safe.t option Lwt.t
