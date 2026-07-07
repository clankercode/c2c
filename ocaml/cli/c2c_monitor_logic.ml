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

(* ---------- B089: relay-inbox watcher source ---------- *)

(* The relay-aware monitor (B089) periodically peeks (NON-draining) the
   registered alias's relay inbox via `POST /peek_inbox`. The relay returns a
   response of shape `{ ok = true, messages = [ ... ] }` where each message has
   the SAME field shape as a local broker message (`message_id`, `from_alias`,
   `to_alias`, `content`, `ts`). That shape parity is what lets the relay source
   reuse the B070 [seen] dedup set verbatim: the connector's local-delivery path
   (`append_to_local_inbox`) writes the relay message JSON — message_id included
   — into the local inbox, so when the local archive/inbox echo of a relay DM
   arrives it is suppressed by the SAME key the relay-peek just recorded.

   These helpers are pure (no network, no broker, no threads) so the watcher
   source's core behaviour — message extraction, dedup across peek cycles, and
   cross-source dedup vs a local echo — is unit-testable in isolation. The
   impure thread + HTTP peek lives in [c2c_monitor_cmd]. *)

(* Pull the `messages` list out of a `/peek_inbox` (or `/poll_inbox`) relay
   response. Tolerant: a missing/non-list `messages` field yields []. Never
   raises — a malformed response just surfaces nothing (the caller logs the
   raw response at debug if needed). *)
let extract_relay_messages (resp : Yojson.Safe.t) : Yojson.Safe.t list =
  match resp with
  | `Assoc fields ->
      (match List.assoc_opt "messages" fields with
       | Some (`List msgs) -> msgs
       | _ -> [])
  | _ -> []

(* Tag a surfaced message with its origin so the user can tell local vs relay.
   Adds a `source` field to the assoc. Idempotent: if `source` is already
   present it is overwritten (so a message never carries a stale tag). Does NOT
   alter [msg_key] — `source` is not one of the identity fields, so the dedup
   key is stable whether or not a message is tagged. Non-assoc JSON passes
   through unchanged (uncomparable, kept by the caller). *)
let tag_source (source : string) (m : Yojson.Safe.t) : Yojson.Safe.t =
  match m with
  | `Assoc fields ->
      `Assoc (("source", `String source)
              :: List.filter (fun (k, _) -> k <> "source") fields)
  | other -> other

(* Surface newly-seen relay messages: filter against the shared [seen] set
   (marking each kept message seen, exactly like the local path's
   [filter_unseen]) and tag each survivor `source:relay`. Order-preserving.

   This is the pure heart of the relay watcher — the impure thread feeds it the
   peek result and emits whatever it returns. Two consecutive calls with the
   same peek result return the messages once then [] (peek does not drain, so
   without this dedup every cycle would re-print the whole pending inbox). A
   message that later echoes through the local path is also suppressed because
   [seen] is shared and keyed on message identity. *)
let relay_msgs_to_surface (seen : seen) (msgs : Yojson.Safe.t list)
  : Yojson.Safe.t list =
  filter_unseen seen msgs |> List.map (tag_source "relay")

(* Decide whether the relay watcher should run, given the resolved inputs.
   Pure so the gating logic (alias resolved? relay configured? identity
   available?) is unit-testable. The watcher needs: an alias to peek as, a relay
   URL, and (for production relays) the relay must be reachable — but identity
   is OPTIONAL: an unsigned peek works against dev/no-auth relays just like
   `relay dm peek` falls back to unsigned. Returns a reason label for the
   startup banner so an operator can see WHY relay watch is off. *)
type relay_watch_decision =
  | Relay_watch of { node_id : string; session_id : string }
  | Relay_watch_off of string

let decide_relay_watch
      ~my_alias
      ~relay_url
      ~identity:_
      ~node_id_override
      ~session_id_override
      () : relay_watch_decision =
  match relay_url with
  | None -> Relay_watch_off "no relay URL configured (c2c relay setup / C2C_RELAY_URL)"
  | Some _ ->
      (match my_alias with
       | None -> Relay_watch_off "no alias resolved (relay watch needs an alias to peek as)"
       | Some alias ->
           (* Default peek key matches the `c2c relay dm peek` / `c2c relay
              register --alias` convention: node_id = session_id = "cli-<alias>".
              Connector-managed aliases (registered by the relay connector under
              the machine's node-id) need an explicit --relay-node-id override —
              documented in --help. *)
           let base = "cli-" ^ alias in
           let node_id =
             match node_id_override with
             | Some n when n <> "" -> n
             | _ -> base
           in
           (* session_id defaults to the node_id when only --relay-node-id is
              overridden, so `--relay-node-id machine-42` peeks
              machine-42/machine-42 (as documented in --help). An explicit
              --relay-session-id always wins; connector-managed aliases
              (per-session session-id under the machine node-id) usually need
              BOTH overrides. *)
           let session_id =
             match session_id_override, node_id_override with
             | (Some s, _) when s <> "" -> s
             | (None, Some n) when n <> "" -> n
             | _ -> base
           in
           Relay_watch { node_id; session_id })
