(* C2c_monitor_ndjson — J3: canonical v1 shaping for `c2c monitor --json`
   message events.

   `c2c monitor --json` streams NDJSON: one JSON object per line, flushed
   immediately after each event so a line-by-line consumer (Claude Code's
   Monitor tool, the GUI sidecar, `jq -c`) never waits on a buffered
   partial line. Pre-J3 the `event_type:"message"` line was a hand-rolled
   spread of the raw broker message fields; J3 converges it on the
   canonical lean v1 schema (C2c_schema_v1, see
   docs/reference/message-schema-v1.md) while preserving every legacy key
   ADDITIVELY so pre-J3 readers (gui/src/types.ts MessageEvent,
   tests/test_c2c_monitor.py) keep working unchanged.

   Representation only: which events fire, when they fire, filtering,
   dedup, and exit codes are all owned by c2c_monitor_cmd/c2c_monitor_logic
   (H3/B089) and are NOT touched here.

   This module lives in the c2c_mcp library (not ocaml/cli/) because the
   shaping MUST go through C2c_schema_v1 — constructing the typed record
   and serializing via the module, never a parallel hand-rolled v1 JSON —
   and C2c_schema_v1 is a library module the cli-side pure-logic test
   executable cannot link. Tests: ocaml/test/test_c2c_schema_v1.ml
   ("monitor-ndjson (J3)" sections). *)

let jstr fields key =
  match List.assoc_opt key fields with
  | Some (`String s) -> Some s
  | _ -> None

let jnum fields key =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

(* Room detection for a raw monitor message. Two shapes exist in the wild:
   - archive/room-history entries carry an explicit "room_id" field;
   - room-fanout inbox copies tag to_alias per-peer as "<alias>#<room>"
     (see C2c_monitor_logic.normalize_to / parse_to_alias).
   The '#'-suffix path is gated by [C2c_mcp_helpers.is_room_recipient] —
   the canonical classifier — so a "<alias>#<12hexhash>" relay host-hash
   form is a DM, never a room (same fix family as J4's inbox rows). *)
let room_of_fields fields to_alias =
  match jstr fields "room_id" with
  | Some r when r <> "" -> Some r
  | _ when C2c_mcp_helpers.is_room_recipient ~to_alias -> (
      match String.split_on_char '#' to_alias with
      | [ _alias; room ] when room <> "" -> Some room
      | _ -> None)
  | _ -> None

(* Shape one raw monitor message (legacy broker JSON: from_alias, to_alias,
   content, ts, message_id, ...) into the J3 NDJSON message-event object:

     { "event_type":"message", "monitor_ts":<ts>,
       <canonical v1 fields via C2c_schema_v1.serialize>,
       <remaining legacy fields, additively> }

   Field-key collisions between v1 and the raw message (content, ts,
   message_id, source) resolve in favour of the v1 serialization — same
   key, same value for well-formed broker messages. A raw field the v1
   serialization does NOT emit (e.g. a non-numeric legacy "ts", or extras
   like "deferrable", "room_id", "event") is preserved verbatim so no
   information is lost. from_alias/to_alias are always preserved (they are
   not v1 keys) — that is the legacy old-reader contract.

   Non-object messages pass through unchanged (pre-J3 behaviour: the
   monitor printed them raw). *)
let message_event ~monitor_ts ~source (m : Yojson.Safe.t) : Yojson.Safe.t =
  match m with
  | `Assoc fields ->
      let from_alias =
        match jstr fields "from_alias" with
        | Some a when String.trim a <> "" -> a
        | _ -> "?" (* matches the human path's unknown-sender default *)
      in
      let to_alias = Option.value (jstr fields "to_alias") ~default:"" in
      let msg_type, to_ =
        match room_of_fields fields to_alias with
        | Some room -> (C2c_schema_v1.Room, room)
        | None -> (C2c_schema_v1.Dm, to_alias)
      in
      let record : C2c_schema_v1.t =
        { schema_version = C2c_schema_v1.schema_version
        ; msg_type
        ; message_id = jstr fields "message_id"
        ; ts = jnum fields "ts"
        ; from = { alias = from_alias; host_id = None; address = None }
        ; to_
        ; source = C2c_schema_v1.source_of_string source
        ; content = Option.value (jstr fields "content") ~default:""
        ; in_reply_to = None
        ; delivery_state = None
        }
      in
      let v1_fields =
        match C2c_schema_v1.serialize record with
        | `Assoc kvs -> kvs
        | _ -> [] (* serialize always yields `Assoc; total fallback *)
      in
      let taken = List.map fst v1_fields in
      let legacy =
        List.filter
          (fun (k, _) ->
            (not (List.mem k taken)) && k <> "event_type" && k <> "monitor_ts")
          fields
      in
      `Assoc
        (("event_type", `String "message")
         :: ("monitor_ts", `String monitor_ts)
         :: (v1_fields @ legacy))
  | other -> other

(* Emit one NDJSON line: exactly one compact JSON object, one trailing
   newline, flushed immediately. This is THE writer for monitor --json
   message events — the flush is what makes the stream safe to consume
   line-by-line from a subprocess (pinned by the J3 tests). *)
let emit_line oc (j : Yojson.Safe.t) =
  output_string oc (Yojson.Safe.to_string j);
  output_char oc '\n';
  flush oc
