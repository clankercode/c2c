(* c2c_monitor_logic — pure, unit-testable helpers for `c2c monitor`.

   Two concerns are extracted here so their behaviour can be tested without
   spawning inotifywait or a broker:

   - B069: the alias-resolution ORDER for a bare `c2c monitor`. The live bug
     was that a machine-global default-alias file (clobbered by any agent's
     `c2c init`) shadowed the session's own registration, so the monitor
     silently filtered by another agent's alias. [resolve_alias] encodes the
     corrected order — the session's own registration wins over the file.

   - B070: message de-duplication between the inbox-watch path (peek) and the
     archive-echo path. When the monitor surfaces a live-inbox message and some
     other consumer later drains it into the archive, the archive event must
     not re-print the same message. [msg_key] + the bounded FIFO [seen] set
     provide that dedup. *)

(* ---------- B069: alias resolution order ---------- *)

type alias_source =
  | Flag                    (* --alias flag *)
  | Auto_env                (* C2C_MCP_AUTO_REGISTER_ALIAS *)
  | Session_reg of string   (* this session's own broker registration (sid) *)
  | Default_alias_file      (* ~/.config/c2c/default-alias — machine-global *)
  | Session_id_env          (* raw C2C_MCP_SESSION_ID as a sender label *)
  | Single_alive            (* the sole alive registration in the broker *)
  | Unresolved

let source_label = function
  | Flag -> "--alias flag"
  | Auto_env -> "C2C_MCP_AUTO_REGISTER_ALIAS"
  | Session_reg sid -> Printf.sprintf "session %s registration" sid
  | Default_alias_file -> "default-alias file (fallback — may be another agent's)"
  | Session_id_env -> "C2C_MCP_SESSION_ID (fallback)"
  | Single_alive -> "single alive registration (fallback)"
  | Unresolved -> "unresolved"

(* Fallback sources are the ones that CAN misresolve (B069): the operator
   should see how the alias was chosen when it came from one of these. *)
let is_fallback_source = function
  | Default_alias_file | Session_id_env | Single_alive -> true
  | Flag | Auto_env | Session_reg _ | Unresolved -> false

(* Resolve the monitor alias from pre-resolved candidate sources, in priority
   order. Pure: the caller does the env/broker/file IO and passes results in,
   so the ORDER — the actual defect in B069 — is unit-testable in isolation.

   [session_reg] is [Some (alias, session_id)] when this session's own
   registration was found in the broker; it deliberately outranks
   [default_alias_file]. *)
let resolve_alias
      ~flag
      ~auto_env
      ~session_reg
      ~default_alias_file
      ~session_id_env
      ~single_alive
      () : string option * alias_source =
  match flag with
  | Some a -> Some a, Flag
  | None ->
    match auto_env with
    | Some a -> Some a, Auto_env
    | None ->
      match session_reg with
      | Some (a, sid) -> Some a, Session_reg sid
      | None ->
        match default_alias_file with
        | Some a -> Some a, Default_alias_file
        | None ->
          match session_id_env with
          | Some a -> Some a, Session_id_env
          | None ->
            match single_alive with
            | Some a -> Some a, Single_alive
            | None -> None, Unresolved

(* ---------- B070: inbox/archive message de-duplication ---------- *)

let jstr fields key def =
  match List.assoc_opt key fields with Some (`String s) -> s | _ -> def

(* Normalize a room-fanout to_alias so the N per-peer archive copies of one
   room message collapse to a single identity: "coder1#lounge" -> "#lounge".
   Plain 1:1 aliases pass through unchanged. Mirrors [parse_to_alias] in the
   monitor command. *)
let normalize_to s =
  match String.split_on_char '#' s with
  | [_alias; room] -> "#" ^ room
  | _ -> s

(* Stable identity key for a message JSON object. Prefers the relay-assigned
   [message_id]; otherwise falls back to from | normalized-to | ts | content.
   Returns "" for non-objects (uncomparable — the caller keeps them). *)
let msg_key (m : Yojson.Safe.t) : string =
  match m with
  | `Assoc fields ->
      (match List.assoc_opt "message_id" fields with
       | Some (`String mid) when mid <> "" -> "id:" ^ mid
       | _ ->
           let ts =
             match List.assoc_opt "ts" fields with
             | Some (`Float f) -> Printf.sprintf "%.3f" f
             | Some (`Int i) -> string_of_int i
             | _ -> ""
           in
           Printf.sprintf "c:%s|%s|%s|%s"
             (jstr fields "from_alias" "")
             (normalize_to (jstr fields "to_alias" ""))
             ts
             (jstr fields "content" ""))
  | _ -> ""

(* Bounded FIFO set of message keys already surfaced by the monitor. Bounded so
   a long-running monitor never leaks: once [cap] keys are held, the oldest is
   evicted. [cap] is generous relative to the inbox-peek → archive-drain race
   window (usually sub-second to minutes). *)
type seen = {
  tbl : (string, unit) Hashtbl.t;
  order : string Queue.t;
  cap : int;
}

let create_seen ?(cap = 8192) () =
  { tbl = Hashtbl.create 256; order = Queue.create (); cap }

let is_seen seen k = k <> "" && Hashtbl.mem seen.tbl k

let mark seen k =
  if k <> "" && not (Hashtbl.mem seen.tbl k) then begin
    Hashtbl.replace seen.tbl k ();
    Queue.push k seen.order;
    if Queue.length seen.order > seen.cap then
      (let old = Queue.pop seen.order in Hashtbl.remove seen.tbl old)
  end

(* Keep only messages not previously seen, marking each kept one as seen.
   Order-preserving. Messages with an empty key (non-objects) are always kept
   and never recorded. *)
let filter_unseen seen (msgs : Yojson.Safe.t list) : Yojson.Safe.t list =
  List.filter
    (fun m ->
      let k = msg_key m in
      if k = "" then true
      else if Hashtbl.mem seen.tbl k then false
      else (mark seen k; true))
    msgs

(* Archive files are keyed by session id in the current broker layout, while
   operator-facing monitor filters are keyed by alias. Prefer session-id
   comparison when it is available; keep an alias fallback for legacy/named
   sessions where the archive id and alias are intentionally the same string. *)
let archive_owner_is_mine ~archive_id ~my_alias ~my_session_id () =
  match my_session_id with
  | Some sid when sid = archive_id -> true
  | Some _ -> false
  | None ->
      (match my_alias with
       | Some alias -> alias = archive_id
       | None -> true)
