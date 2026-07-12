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

(* ---------- claude-full-delivery: full-body burst rendering ---------- *)

(* Truncate a subject to [max_len], appending "…" if clipped. Mirrors the
   monitor command's legacy snippet behaviour. *)
let truncate_subject s max_len =
  let s = String.trim s in
  if String.length s > max_len then String.sub s 0 max_len ^ "…" else s

(* Render the subject strings for one sender's burst of messages.

   Full-body mode (the monitor default): one subject per message,
   untruncated. The Monitor is a first-class full-delivery surface for
   vanilla claude, so bodies must arrive whole — the legacy burst collapse
   truncated the first body to 60 chars and dropped bodies 2..N entirely.

   Snippet mode (--snippet) keeps the legacy shape: a single message gets an
   80-char preview; a burst collapses to a count + 60-char preview of the
   first message. *)
let burst_subjects ~full_body (bodies : string list) : string list =
  match bodies with
  | [] -> []
  | [ body ] ->
      [ Printf.sprintf "\"%s\""
          (if full_body then String.trim body else truncate_subject body 80) ]
  | bodies when full_body ->
      List.map (fun b -> Printf.sprintf "\"%s\"" (String.trim b)) bodies
  | first :: _ ->
      [ Printf.sprintf "(%d msgs) \"%s\""
          (List.length bodies) (truncate_subject first 60) ]

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

(* ---------- H3: connector-managed relay peek key resolution ---------- *)

(* The relay CONNECTOR (`c2c relay connect`) registers every local broker
   session on the relay under the MACHINE node-id with that session's OWN
   session-id — NOT the `cli-<alias>` convention that `c2c relay register
   --alias` uses. A cross-host DM to `alias@host` therefore lands in the relay
   inbox keyed (connector_node_id, local_session_id). A monitor that peeks
   `cli-<alias>/cli-<alias>` would see an empty inbox forever while messages
   pile up under the connector's key — a silent receive black hole (A014/A015).

   [connector_key] is [Some { node_id; session_id }] when a connector is known
   to manage the resolved alias (the impure caller reads connector-state.json +
   the alias's local session-id). When present it becomes the DEFAULT peek key,
   so a bare `c2c monitor` on a connector-managed broker "just works" without
   the operator hand-supplying --relay-node-id / --relay-session-id. Explicit
   overrides always win over the connector-managed default. *)
type relay_key = { node_id : string; session_id : string }

let resolve_relay_peek_key
      ~alias
      ~node_id_override
      ~session_id_override
      ~connector_key
      () : relay_key =
  let base = "cli-" ^ alias in
  (* Default (no operator override): connector-managed key when a connector
     manages this alias, else the cli-<alias> direct-register convention. *)
  let default_node, default_session =
    match connector_key with
    | Some k -> k.node_id, k.session_id
    | None -> base, base
  in
  let node_id =
    match node_id_override with
    | Some n when n <> "" -> n
    | _ -> default_node
  in
  (* session_id: explicit --relay-session-id wins; else `--relay-node-id X`
     alone implies X/X (documented in --help); else the resolved default
     (connector session-id, or cli-<alias>). *)
  let session_id =
    match session_id_override, node_id_override with
    | (Some s, _) when s <> "" -> s
    | (None, Some n) when n <> "" -> n
    | _ -> default_session
  in
  { node_id; session_id }

(* Decide whether the relay watcher should run, given the resolved inputs.
   Pure so the gating logic (alias resolved? relay configured? identity
   available?) is unit-testable. The watcher needs: an alias to peek as, a relay
   URL, and (for production relays) the relay must be reachable — but identity
   is OPTIONAL: an unsigned peek works against dev/no-auth relays just like
   `relay dm peek` falls back to unsigned. Returns a reason label for the
   startup banner so an operator can see WHY relay watch is off.

   [connector_key] (H3) is the connector-managed peek key for [my_alias] when a
   relay connector manages this broker; it becomes the default peek key over the
   `cli-<alias>` convention (see [resolve_relay_peek_key]). *)
type relay_watch_decision =
  | Relay_watch of { node_id : string; session_id : string }
  | Relay_watch_off of string

let decide_relay_watch
      ~my_alias
      ~relay_url
      ~identity:_
      ~node_id_override
      ~session_id_override
      ?(connector_key = None)
      () : relay_watch_decision =
  match relay_url with
  | None -> Relay_watch_off "no relay URL configured (c2c relay setup / C2C_RELAY_URL)"
  | Some _ ->
      (match my_alias with
       | None -> Relay_watch_off "no alias resolved (relay watch needs an alias to peek as)"
       | Some alias ->
           let { node_id; session_id } =
             resolve_relay_peek_key ~alias ~node_id_override
               ~session_id_override ~connector_key ()
           in
           Relay_watch { node_id; session_id })

(* ---------- H3: relay /peek_inbox response classification ---------- *)

(* The friction report's core receive-honesty defect (B027/B181/B182/B190,
   A038): the relay watcher extracted `messages` and threw away the `ok` flag,
   so an `{ ok:false, error_code, error }` response — an auth/identity failure,
   a bad request, a connection error — surfaced NOTHING and the monitor spun
   forever reporting a healthy-looking but dead relay stream ("misleading
   success"). Classify every response so the caller can surface the error and
   distinguish a transient blip (retry, may recover) from a terminal failure
   (auth/identity — will not self-heal; the monitor's local-watch policy
   decides whether to exit non-zero or disable only relay watching).

   The relay's own JSON contract (relay_server_json.ml): success is
   `{ ok:true, ... }`; every error is `{ ok:false, error_code, error }`. The
   client wrapper (relay_client.ml [connection_error]) maps network/timeout/
   invalid-JSON to `{ ok:false, error_code:"connection_error", error }`. A
   legacy relay that omits `ok` entirely is treated as success (messages are
   data) for backward compatibility. *)
type relay_peek_outcome =
  | Peek_ok of Yojson.Safe.t list  (* ok:true / legacy: pending messages *)
  | Peek_transient of string       (* retry, may recover (network/5xx/rate-limit) *)
  | Peek_terminal of string        (* auth/identity — terminal policy applies *)

(* Error codes that mean the peek can NEVER succeed by retrying with the same
   identity/key: the operator must re-register, fix the clock, fix the key, or
   fix the request. The monitor applies its terminal policy to these errors:
   pure-relay monitoring exits non-zero, while a local watch disables only its
   relay loop. Anything not listed defaults to transient — better to keep
   retrying an unrecognized/blip error than to kill a monitor on a code we did
   not anticipate. *)
let is_terminal_error_code = function
  | "unauthorized"
  | "signature_invalid"
  | "timestamp_out_of_window"
  | "missing_proof_field"
  | "not_found"
  | "unknown_node"
  | "not_registered"
  | "bad_request" -> true
  | _ -> false

let classify_relay_response (resp : Yojson.Safe.t) : relay_peek_outcome =
  match resp with
  | `Assoc fields ->
      let ok =
        match List.assoc_opt "ok" fields with
        | Some (`Bool b) -> Some b
        | _ -> None
      in
      (match ok with
       | Some false ->
           let code = jstr fields "error_code" "" in
           let emsg = jstr fields "error" "" in
           let detail =
             match code, emsg with
             | "", "" -> "unknown relay error"
             | "", m -> m
             | c, "" -> c
             | c, m -> Printf.sprintf "%s: %s" c m
           in
           if is_terminal_error_code code then Peek_terminal detail
           else Peek_transient detail
       | Some true | None ->
           (* ok:true, or a legacy relay with no `ok` field — messages are
              data. Absent `messages` yields [] (nothing new this cycle). *)
           Peek_ok (extract_relay_messages resp))
  | _ -> Peek_transient "malformed relay response (non-object)"

(* Exit codes for `c2c monitor` terminal conditions. Distinct from the generic
   usage/startup exit 1 so a supervisor can tell an auth/identity relay failure
   apart from a bad-invocation or broker-root error (A038/B182/B196). *)
let exit_relay_terminal = 3

(* B142: on a relay-peek TERMINAL failure, decide whether to tear the WHOLE
   monitor process down. The relay-peek watcher runs in a background thread; a
   terminal auth/identity/config failure there must NOT kill the main-thread
   local inbox/archive inotify watch — a relay-side problem taking down local
   receive (the primary CLI receive path) is the B142 defect.

   Policy: exit non-zero ONLY when relay-watch is the SOLE reason the monitor is
   running — i.e. no local watch is active — so a supervisor still notices a
   dead pure-relay monitor. When a local watch is active, the caller logs the
   terminal message once and stops ONLY the relay loop; the local watch keeps
   running. Pure + unit-tested so the exit-vs-continue policy is decoupled from
   the impure thread. *)
let should_exit_on_relay_terminal ~local_watch_active = not local_watch_active
