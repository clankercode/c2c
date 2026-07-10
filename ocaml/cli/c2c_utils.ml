(* c2c_utils.ml — shared helper functions extracted from c2c.ml.
   Goal: eliminate duplicated boilerplate, centralize idioms. *)

let ( // ) = Filename.concat
let likes_shell_substitution = C2c_start.likes_shell_substitution

(** [mkdir_p dir] creates dir and all parents, like Unix mkdir -p.
    Idempotent; uses 0o755 permissions.
    Delegates to [C2c_mcp.mkdir_p] — the single canonical helper
    (#400b, which itself delegates to [C2c_io.mkdir_p]). For
    non-default permission bits, call [C2c_mcp.mkdir_p ~mode] directly. *)
let mkdir_p = C2c_mcp.mkdir_p

(** XDG_STATE_HOME per XDG spec, with HOME fallback. *)
let xdg_state_home () =
  match Sys.getenv_opt "XDG_STATE_HOME" with
  | Some v when String.trim v <> "" -> String.trim v
  | _ ->
      (match Sys.getenv_opt "HOME" with
       | Some h when String.trim h <> "" -> String.trim h // ".local" // "state"
       | _ -> "/tmp")

(** Delegates to the authoritative implementation in C2c_repo_fp (library module).
    C2c_repo_fp.resolve_broker_root uses Digestif.SHA256 for repo fingerprint. *)
let resolve_broker_root () = C2c_repo_fp.resolve_broker_root ()

(** Re-exports of the pure legacy-broker-root detection helpers from
    C2c_broker_root_check (#352). Kept here for call-site convenience;
    the underlying module is dependency-free for unit-testability. *)
let is_legacy_broker_root = C2c_broker_root_check.is_legacy_broker_root
let legacy_broker_warning_text = C2c_broker_root_check.legacy_broker_warning_text

(** [alias_from_env_only ()] returns the alias from [C2C_MCP_AUTO_REGISTER_ALIAS]
    env var, or [None] if unset/empty. Pure env read — no broker IO.
    Use as the fast-path in commands that can resolve from env alone,
    falling back to broker lookup only when this returns [None]. *)
let alias_from_env_only () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

(** [trimmed_env_value env_var] reads [env_var], trims whitespace, and
    returns [None] if the result is empty. This treats an empty-string or
    whitespace-only value as "unset" — the correct semantics for optional
    path overrides like [C2C_MCP_BROKER_ROOT].
    An empty-string value should fall through to the default resolver rather
    than propagate as a bogus empty path (#518). *)
let trimmed_env_value env_var =
  match Sys.getenv_opt env_var with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

(** Canonical whole-file read/write helpers (#388). Delegates to
    [C2c_io] — single source of truth, reachable from the library and
    the executable. Re-exported here so call-sites already using
    [C2c_utils.*] don't need a second [open]. *)
let read_file = C2c_io.read_file
let read_file_opt = C2c_io.read_file_opt
let read_file_trimmed = C2c_io.read_file_trimmed
let write_file = C2c_io.write_file
let write_file_atomic = C2c_io.write_file_atomic
let write_file_atomic_locked = C2c_io.write_file_atomic_locked

(** [atomic_write_json path json] writes json to a temp file then atomically
    renames to [path], ensuring readers never see a partial write.
    The payload is followed by a newline. #388: now delegates to
    [C2c_io.write_file_atomic]. *)
let atomic_write_json path json =
  let payload = Yojson.Safe.to_string json ^ "\n" in
  match C2c_io.write_file_atomic path payload with
  | Ok () -> ()
  | Error _ -> ()

(* ------------------------------------------------------------------ *)
(* J2: canonical schema-v1 adaptation for CLI --json results.

   These helpers migrate the CLI's send / poll-inbox / peek-inbox /
   `relay dm send|poll|peek` JSON representations onto the canonical
   v1 message schema (C2c_schema_v1, slice J1) while preserving every
   pre-existing legacy key additively at its unchanged value.

   J5 unification (the former MERGE-UNIFICATION TODO, J2 <-> J4): the
   CLI-side legacy-append implementation was folded onto the shared
   [C2c_schema_v1.serialize_with_legacy] (introduced by J4 for the MCP
   surfaces). The shared helper carries J2's semantics — dedup of
   colliding legacy keys, and [?delivery_extra] merged inside the
   [delivery] object — so there is exactly ONE legacy-append
   implementation across the CLI and MCP surfaces. *)

(** Classify a recipient string into the v1 [type] discriminator.
    Delegates to the canonical [C2c_mcp_helpers.is_room_recipient]:
    a `<alias>#<12-lowercase-hex>` host-hash suffix is a cross-host DM,
    any other `#` suffix is a room delivery. Never hand-roll a bare
    [String.contains '#'] check. *)
let schema_v1_msg_type_of_recipient ~to_alias : C2c_schema_v1.msg_type =
  if C2c_mcp_helpers.is_room_recipient ~to_alias then C2c_schema_v1.Room
  else C2c_schema_v1.Dm

(** One inbox message row for poll-inbox / peek-inbox / wait-inbox
    [--json]: canonical v1 shape plus the legacy row keys
    ([from_alias], [to_alias], [content], [ts]) at unchanged values.
    [delivery_state] is [Delivered] for drained rows and [Queued] for
    peeked (non-drained) rows. [source] is omitted: the local broker
    does not reliably record transport origin (it assigns
    [message_id]s locally too). *)
let inbox_message_row_json ~(delivery_state : C2c_schema_v1.delivery_state)
    (m : C2c_mcp.message) : Yojson.Safe.t =
  let v1 : C2c_schema_v1.t =
    { C2c_schema_v1.schema_version = C2c_schema_v1.schema_version
    ; msg_type = schema_v1_msg_type_of_recipient ~to_alias:m.C2c_mcp.to_alias
    ; message_id = m.C2c_mcp.message_id
    ; ts = Some m.C2c_mcp.ts
    ; from =
        { C2c_schema_v1.alias = m.C2c_mcp.from_alias
        ; host_id = None
        ; address = None
        }
    ; to_ = m.C2c_mcp.to_alias
    ; source = None
    ; content = m.C2c_mcp.content
    ; in_reply_to = None
    ; delivery_state = Some delivery_state
    }
  in
  C2c_schema_v1.serialize_with_legacy v1
    ~legacy:
      [ ("from_alias", `String m.C2c_mcp.from_alias)
      ; ("to_alias", `String m.C2c_mcp.to_alias)
      ; ("content", `String m.C2c_mcp.content)
      ; ("ts", `Float m.C2c_mcp.ts)
      ]

(** `c2c send --json` receipt: canonical v1 shape plus the legacy
    receipt keys ([queued] bool, [ts], [from_alias],
    [to_alias]/[target_session_id] via [legacy_target_fields],
    [delivery.state] (+ optional [delivery.warning], B088), and optional
    [compacting_warning]) at unchanged values. [content] is additive
    (required by v1; the legacy receipt never carried it). [type] is
    always [dm]: `c2c send` is the DM surface (rooms go via
    `c2c rooms send`), and remote targets may embed `@host` which the
    room classifier must not see. *)
let cli_send_receipt_json ~ts ~from_alias ~to_ ~content
    ~(delivery_state : C2c_schema_v1.delivery_state) ?delivery_warning
    ~(legacy_target_fields : (string * Yojson.Safe.t) list)
    ?compacting_warning () : Yojson.Safe.t =
  let v1 : C2c_schema_v1.t =
    { C2c_schema_v1.schema_version = C2c_schema_v1.schema_version
    ; msg_type = C2c_schema_v1.Dm
    ; message_id = None
    ; ts = Some ts
    ; from = { C2c_schema_v1.alias = from_alias; host_id = None; address = None }
    ; to_
    ; source = None
    ; content
    ; in_reply_to = None
    ; delivery_state = Some delivery_state
    }
  in
  let delivery_extra =
    match delivery_warning with
    | Some w -> [ ("warning", `String w) ]
    | None -> []
  in
  let legacy =
    [ ("queued", `Bool true); ("from_alias", `String from_alias) ]
    @ legacy_target_fields
    @ (match compacting_warning with
       | Some w -> [ ("compacting_warning", `String w) ]
       | None -> [])
  in
  C2c_schema_v1.serialize_with_legacy ~delivery_extra v1 ~legacy

(** Adapt a `c2c relay dm send` relay ACK to the v1 shape. Only a
    successful ACK ([ok:true]) is adapted — the relay accepted the
    message, so [delivery.state] is [accepted] and [source] is [relay]
    (the result demonstrably came from the relay). All legacy response
    keys ([ok], [ts], [duplicate], ...) are preserved additively at
    unchanged values. Error responses pass through untouched so
    exit-code logic and alias hints keep working on the raw shape. *)
let adapt_relay_dm_send_result ~from_alias ~to_alias ~content
    (result : Yojson.Safe.t) : Yojson.Safe.t =
  match result with
  | `Assoc fields when List.assoc_opt "ok" fields = Some (`Bool true) ->
      let ts =
        match List.assoc_opt "ts" fields with
        | Some (`Float f) -> Some f
        | Some (`Int i) -> Some (float_of_int i)
        | _ -> None
      in
      let v1 : C2c_schema_v1.t =
        { C2c_schema_v1.schema_version = C2c_schema_v1.schema_version
        ; msg_type = schema_v1_msg_type_of_recipient ~to_alias
        ; message_id = None
        ; ts
        ; from =
            { C2c_schema_v1.alias = from_alias; host_id = None; address = None }
        ; to_ = to_alias
        ; source = Some C2c_schema_v1.Relay
        ; content
        ; in_reply_to = None
        ; delivery_state = Some C2c_schema_v1.Accepted
        }
      in
      C2c_schema_v1.serialize_with_legacy v1 ~legacy:fields
  | _ -> result

(** Adapt a `c2c relay dm poll|peek` response: each row in [messages]
    becomes the v1 shape ([source] = [relay]; [delivery.state] =
    [Delivered] for poll (drained) rows, [Queued] for peek rows) with
    the legacy row keys ([message_id], [from_alias], [to_alias],
    [content], [ts]) preserved at unchanged values. An empty [messages]
    batch keeps the exact legacy shape ([{"ok":true,"messages":[]}]).
    Rows missing a v1-required field, non-list [messages], and error
    responses pass through untouched. *)
let adapt_relay_dm_inbox_result
    ~(delivery_state : C2c_schema_v1.delivery_state)
    (result : Yojson.Safe.t) : Yojson.Safe.t =
  let adapt_row row =
    match row with
    | `Assoc kv -> (
        match
          ( List.assoc_opt "from_alias" kv
          , List.assoc_opt "to_alias" kv
          , List.assoc_opt "content" kv )
        with
        | Some (`String from_alias), Some (`String to_alias),
          Some (`String content) ->
            let message_id =
              match List.assoc_opt "message_id" kv with
              | Some (`String s) -> Some s
              | _ -> None
            in
            let ts =
              match List.assoc_opt "ts" kv with
              | Some (`Float f) -> Some f
              | Some (`Int i) -> Some (float_of_int i)
              | _ -> None
            in
            let v1 : C2c_schema_v1.t =
              { C2c_schema_v1.schema_version = C2c_schema_v1.schema_version
              ; msg_type = schema_v1_msg_type_of_recipient ~to_alias
              ; message_id
              ; ts
              ; from =
                  { C2c_schema_v1.alias = from_alias
                  ; host_id = None
                  ; address = None
                  }
              ; to_ = to_alias
              ; source = Some C2c_schema_v1.Relay
              ; content
              ; in_reply_to = None
              ; delivery_state = Some delivery_state
              }
            in
            C2c_schema_v1.serialize_with_legacy v1 ~legacy:kv
        | _ -> row)
    | _ -> row
  in
  match result with
  | `Assoc fields when List.assoc_opt "ok" fields = Some (`Bool true) -> (
      match List.assoc_opt "messages" fields with
      | Some (`List rows) ->
          `Assoc
            (List.map
               (fun (k, v) ->
                 if k = "messages" then (k, `List (List.map adapt_row rows))
                 else (k, v))
               fields)
      | _ -> result)
  | _ -> result
