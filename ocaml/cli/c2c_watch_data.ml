(* c2c_watch_data.ml — PURE-ish read substrate for `c2c watch` (slice B1).

   This module snapshots all relevant broker state into immutable records
   that the render layer ([c2c_watch_render.ml]) and event loop
   ([c2c_watch.ml]) consume. It is deliberately constrained to:
     - reads via the [C2c_mcp.Broker] API (registry / archive / inbox / rooms),
     - [Unix] readdir for shard enumeration (there is no built-in
       "list archive session_ids" helper).
   NO lambda-term, NO render, NO send, NO printing — keeping it pure-ish is
   what lets the synthetic-fixture tests in [test_c2c_watch_data.ml] assert
   the data joins deterministically with no live peers (spec §9).

   The three projections handle the three documented hazards (spec §3):
     - Peers: liveness tristate straight from [registration_liveness_state]
       (Alive | Dead | Unknown) — never reimplement /proc liveness (§3.1).
     - DM shards: keyed on [session_id] (the archive/inbox filename), NOT a
       1:1 alias join. The session_id → alias resolution is a *display label*
       only; shards whose session_id is absent from the registry are flagged
       as orphans. The [#room] fan-out copies (archive rows whose [to_alias]
       contains '#') are dropped here — they belong to the Rooms tab (§3.2).
     - Rooms: canonical [history.jsonl] timeline; an empty history is the
       COMMON quiet-broker case, NOT an error (§3.3). *)

module Broker = C2c_mcp.Broker

type peer_row = {
  pr_alias        : string;
  pr_session_id   : string;
  pr_liveness     : Broker.liveness_state;
  pr_role         : string option;
  pr_last_activity: float option;
  pr_dnd          : bool;
  pr_compacting   : C2c_mcp.compacting option;
  pr_client_type  : string option;
}

type dm_shard = {
  ds_session_id   : string;
  ds_owner_alias  : string option;  (* None = orphan: sid absent from registry *)
  ds_entries      : Broker.archive_entry list;  (* #room rows filtered out *)
  ds_inflight     : C2c_mcp.message list;  (* undrained inbox, #room-filtered; [] if none — §3.2 in-flight rows *)
  ds_is_orphan    : bool;
}

type room_view = {
  rv_info    : Broker.room_info;
  rv_history : C2c_mcp.room_message list;  (* rv_history=[] is the common quiet case *)
}

type snapshot = {
  peers       : peer_row list;
  shards      : dm_shard list;
  rooms       : room_view list;
  broker_root : string;
}

(* Read newest-N-ish without truncating real swarm history; a large const
   matches the spec's "limit:(large const, e.g. 1000)". The archive/history
   files are append-only, so an over-large limit just returns all rows.
   v1 limitation: a shard exceeding [read_limit] archived rows would silently
   drop the oldest rows with no on-screen marker — the busiest real shard is
   ~32 rows so this is comfortably out of reach today, but the DMs-tab render
   slice (B3) should surface a "showing newest N" hint if a shard ever hits it. *)
let read_limit = 1000

(* A [to_alias] carrying '#' is a [fan_out_room_message] room copy
   (e.g. "alice#swarm-lounge"); the canonical untagged copy lives in the
   room's history.jsonl. The DMs tab must exclude these (spec §3.2). *)
let is_room_copy_to (to_alias : string) : bool = String.contains to_alias '#'

(* --- Peers -------------------------------------------------------------- *)

let build_peers (t : Broker.t) : peer_row list =
  Broker.list_registrations t
  |> List.map (fun (reg : C2c_mcp.registration) ->
         { pr_alias         = reg.alias
         ; pr_session_id    = reg.session_id
         ; pr_liveness      = Broker.registration_liveness_state reg
         ; pr_role          = reg.role
         ; pr_last_activity = reg.last_activity_ts
         ; pr_dnd           = reg.dnd
         ; pr_compacting    = reg.compacting
         ; pr_client_type   = reg.client_type
         })

(* --- DM shards ---------------------------------------------------------- *)

(* Strip a known suffix from [name]; [Some stem] when it matched, else None. *)
let strip_suffix ~(suffix : string) (name : string) : string option =
  let nl = String.length name and sl = String.length suffix in
  if nl >= sl && String.sub name (nl - sl) sl = suffix
  then Some (String.sub name 0 (nl - sl))
  else None

(* All directory entries of [dir] (no leading path), [] if [dir] absent. *)
let readdir_safe (dir : string) : string list =
  match Sys.readdir dir with
  | entries -> Array.to_list entries
  | exception Sys_error _ -> []

(* Deduplicating string set built from a list (preserves no order; the
   caller sorts the final shard list for determinism). *)
module SSet = Set.Make (String)

(* The union of session_ids from:
   (a) the registry (one per live/known registration),
   (b) archive/<session_id>.jsonl filenames,
   (c) <session_id>.inbox.json filenames.
   This is the full set of DM shards to surface — a shard may exist on disk
   (archive/inbox) with no matching registration (orphan), or a registration
   may exist with no archive yet (empty shard). *)
let enumerate_shard_sids (t : Broker.t) : string list =
  let root = Broker.root t in
  let from_registry =
    Broker.list_registrations t
    |> List.map (fun (r : C2c_mcp.registration) -> r.session_id)
  in
  let from_archive =
    readdir_safe (Filename.concat root "archive")
    |> List.filter_map (strip_suffix ~suffix:".jsonl")
  in
  let from_inbox =
    readdir_safe root
    |> List.filter_map (strip_suffix ~suffix:".inbox.json")
  in
  let set =
    List.fold_left
      (fun acc sid -> SSet.add sid acc)
      SSet.empty
      (from_registry @ from_archive @ from_inbox)
  in
  SSet.elements set  (* sorted ascending by SSet — deterministic *)

(* Registry lookup for the DISPLAY label of a session_id. Prefer the
   canonical_alias (fully-qualified) when present, else the bare alias.
   None when the session_id is not registered at all (=> orphan shard). *)
let owner_alias_of_sid (regs : C2c_mcp.registration list) (sid : string)
    : string option =
  match List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = sid) regs with
  | None -> None
  | Some r -> (match r.canonical_alias with Some _ as ca -> ca | None -> Some r.alias)

let build_shards (t : Broker.t) : dm_shard list =
  let regs = Broker.list_registrations t in
  enumerate_shard_sids t
  |> List.map (fun sid ->
         let owner = owner_alias_of_sid regs sid in
         let entries =
           Broker.read_archive t ~session_id:sid ~limit:read_limit
           |> List.filter (fun (e : Broker.archive_entry) ->
                  not (is_room_copy_to e.ae_to_alias))
         in
         let inflight =
           Broker.read_inbox t ~session_id:sid
           |> List.filter (fun (m : C2c_mcp.message) ->
                  not (is_room_copy_to m.to_alias))
         in
         { ds_session_id = sid
         ; ds_owner_alias = owner
         ; ds_entries = entries
         ; ds_inflight = inflight
         ; ds_is_orphan = (owner = None)
         })

(* --- Rooms -------------------------------------------------------------- *)

let build_rooms (t : Broker.t) : room_view list =
  Broker.list_rooms t
  |> List.map (fun (info : Broker.room_info) ->
         let history =
           Broker.read_room_history t ~room_id:info.ri_room_id
             ~limit:read_limit ()
         in
         { rv_info = info; rv_history = history })

(* --- Snapshot ----------------------------------------------------------- *)

let build_snapshot (t : Broker.t) : snapshot =
  { peers       = build_peers t
  ; shards      = build_shards t
  ; rooms       = build_rooms t
  ; broker_root = Broker.root t
  }

(* --- Send wrappers (slice B5) ------------------------------------------- *)

(* The ONE state-mutating part of the watch feature. The cardinal requirement
   (spec §4.3): a send MUST NEVER raise out into the event loop — an unguarded
   [Invalid_argument] from the broker would crash the watcher and leave the
   terminal in raw mode. So both wrappers:
     - guard the CLI-level self-send rule (from = to) BEFORE touching the broker
       (mirrors send_cmd at c2c.ml:504), and
     - wrap the broker call in [try ... with Invalid_argument msg -> ...] so the
       broker's reserved-from / unknown-recipient / dead-recipient / invalid-room
       rejections become a [Send_failed msg] value rather than an exception.
   A belt-and-braces catch-all [with e -> Send_failed (Printexc.to_string e)]
   ensures ANY unexpected exception is still surfaced as a status, never raised.

   These wrappers are the only IO-effecting functions in this module; the read
   projections above stay pure-ish and untouched. *)

type send_result =
  | Sent_dm
  | Sent_dm_offline
  | Sent_room of { delivered : int; skipped : int; warning : string option }
  | Send_failed of string

(* Refuse a send whose [from_alias] is a reserved system alias (e.g. "c2c",
   "c2c-system"). [enqueue_message] rejects these for DMs, but [send_room]
   treats them as PRIVILEGED internal senders (c2c_broker.ml) — so without this
   wrapper-level guard, `c2c watch --as c2c-system` could post system-looking
   room history. Guarding BOTH wrappers keeps the two paths consistent. *)
let reserved_from_guard (from_alias : string) : send_result option =
  if Broker.is_reserved_system_alias from_alias then
    Some
      (Send_failed
         (Printf.sprintf "cannot send as reserved system alias '%s'" from_alias))
  else None

(* DM send. [from_alias] is the operator identity (the --as value, default
   "operator"); the broker stamps it as the sender. Reserved-system and
   self-sends are refused here; any broker rejection -> [Send_failed].
   B127: known offline peers succeed as [Sent_dm_offline] (durable queue). *)
let send_dm (t : Broker.t) ~(from_alias : string) ~(to_alias : string)
    ~(content : string) : send_result =
  match reserved_from_guard from_alias with
  | Some failed -> failed
  | None ->
  if from_alias = to_alias then
    Send_failed
      (Printf.sprintf "cannot send a message to yourself (%s)" from_alias)
  else
    try
      match
        Broker.enqueue_message_with_result t ~from_alias ~to_alias ~content ()
      with
      | Broker.Local_offline _ -> Sent_dm_offline
      | Broker.Local_live _ | Broker.Relay_outbox -> Sent_dm
    with
    | Invalid_argument msg -> Send_failed msg
    | e -> Send_failed (Printexc.to_string e)

(* Room send. Maps [send_room_result]: [sr_delivered_to]/[sr_skipped] become
   counts, [sr_warning] (e.g. 0-member room — a SOFT warning, NOT an exception)
   is surfaced verbatim. An invalid room_id / reserved from raises
   [Invalid_argument] inside the broker -> caught -> [Send_failed]. A reserved
   system [from_alias] is refused HERE (send_room would otherwise treat it as a
   privileged internal sender). *)
let send_room_message (t : Broker.t) ~(from_alias : string)
    ~(room_id : string) ~(content : string) : send_result =
  match reserved_from_guard from_alias with
  | Some failed -> failed
  | None ->
  try
    let r = Broker.send_room t ~from_alias ~room_id ~content in
    Sent_room
      { delivered = List.length r.Broker.sr_delivered_to
      ; skipped = List.length r.Broker.sr_skipped
      ; warning = r.Broker.sr_warning
      }
  with
  | Invalid_argument msg -> Send_failed msg
  | e -> Send_failed (Printexc.to_string e)
