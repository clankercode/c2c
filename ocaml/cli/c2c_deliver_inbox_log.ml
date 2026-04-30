(* c2c_deliver_inbox_log — structured daemon-side audit logger
   #562: persist deliver-inbox daemon events to <broker_root>/deliver-inbox.log

   Mirrors log_broker_event conventions:
   - JSONL, one line per event, appended only
   - ts (Unix.gettimeofday) + event discriminator + typed fields
   - Best-effort: write failures are swallowed so they never block the
     primary delivery path.

   Log file is sidecar to broker.log at the same path level, same 0o600
   permissions (contains session message content). *)

let ( // ) = Filename.concat

(* Best-effort JSONL append. Never raises; audit failures are silent. *)
let append_jsonl_log ~(broker_root : string) ~(event : string) (fields : (string * Yojson.Safe.t) list) =
  try
    let path = broker_root // "deliver-inbox.log" in
    let line =
      `Assoc (("ts", `Float (Unix.gettimeofday ())) :: ("event", `String event) :: fields)
      |> Yojson.Safe.to_string
    in
    C2c_io.append_jsonl path line
  with _ -> ()

(* ---------------------------------------------------------------------------
 * Event emitters — called by the daemon after each poll iteration.
 * --------------------------------------------------------------------------- *)

(* deliver_inbox_drain: emitted after poll_once_generic drains messages.
   session_id = target session, count = messages drained, client = client type,
   drained_by = hardcoded "deliver-inbox", drained_by_pid = daemon's own PID. *)
let log_drain ~broker_root ~session_id ~client ~count ~drained_by_pid =
  append_jsonl_log ~broker_root ~event:"deliver_inbox_drain"
    [ ("session_id", `String session_id)
    ; ("client", `String client)
    ; ("count", `Int count)
    ; ("drained_by", `String "deliver-inbox")
    ; ("drained_by_pid", `Int drained_by_pid) ]

(* deliver_inbox_kimi: emitted after poll_once_kimi returns.
   count = number of notifications written to kimi's store.
   ok = true means kimi notifier succeeded (count may still be 0 if no new mail). *)
let log_kimi ~broker_root ~session_id ~who ~count ~ok =
  append_jsonl_log ~broker_root ~event:"deliver_inbox_kimi"
    [ ("session_id", `String session_id)
    ; ("alias", `String who)
    ; ("count", `Int count)
    ; ("ok", `Bool ok) ]

(* deliver_inbox_no_session: emitted when drain_inbox is called for an
   unknown session_id (e.g. stale PID file after a restart). *)
let log_no_session ~broker_root ~session_id ~error =
  append_jsonl_log ~broker_root ~event:"deliver_inbox_no_session"
    [ ("session_id", `String session_id)
    ; ("error", `String error) ]
