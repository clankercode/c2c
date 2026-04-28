(* relay_nudge.ml — idle-nudge delivery system
   Sends periodic friendly prompts to idle sessions via the broker's inbox.
   Runs as a background Lwt thread started from the MCP server main loop. *)

open C2c_mcp

let src_log = Logs.Src.create "relay_nudge" ~doc:"idle nudge scheduler"
module Log = (val Logs.src_log src_log : Logs.LOG)

(* Default cadence knobs *)
let default_cadence_minutes = 30.0
let default_idle_minutes = 25.0
let nudge_sender_alias = "c2c-nudge"

type nudge_message = { text : string }

let default_messages_json = {|
{
  "messages": [
    { "text": "grab a task? check the swarm-lounge for open items." },
    { "text": "you've been quiet — want to review a PR?" },
    { "text": "write an e2e test for something that's been nagging you?" },
    { "text": "check in on a peer — someone might need a hand." },
    { "text": "your move: pick up a slice or brainstorm an improvement." },
    { "text": "quiet here — drop a status update in swarm-lounge?" }
  ]
}
|}

let ensure_default_messages path =
  let dir = Filename.dirname path in
  try
    (try ignore (Unix.mkdir dir 0o755) with Unix.Unix_error _ -> ());
    if not (Sys.file_exists path) then
      let ch = open_out path in
      output_string ch default_messages_json;
      close_out ch;
      Log.info (fun f -> f "relay_nudge: created default messages at %s" path)
  with e ->
    Log.warn (fun f -> f "relay_nudge: could not create default messages at %s: %s"
                path (Printexc.to_string e))

let load_messages ~broker_root =
  let path = Filename.concat (Filename.concat broker_root "nudge") "messages.json" in
  ensure_default_messages path;
  try
    let json = Yojson.Safe.from_file path in
    let open Yojson.Safe.Util in
    match json |> member "messages" with
    | `List items ->
        List.filter_map
          (function
           | `Assoc _ as msg ->
               (match msg |> member "text" with
                | `String t when String.trim t <> "" -> Some { text = String.trim t }
                | _ -> None)
           | _ -> None)
          items
    | _ -> []
  with e ->
    Log.warn (fun f -> f "relay_nudge: failed to load messages from %s: %s" path (Printexc.to_string e));
    []

let random_message messages =
  match messages with
  | [] -> None
  | [m] -> Some m
  | msgs ->
      let idx = Random.int (List.length msgs) in
      Some (List.nth msgs idx)

(* [is_dnd_active session] returns true if DND is currently active for the session. *)
let is_dnd_active (reg : registration) =
  match reg.dnd with
  | false -> false
  | true ->
      match reg.dnd_until with
      | None -> true  (* manual DND, no expiry *)
      | Some until_ts ->
          let now = Unix.gettimeofday () in
          now < until_ts  (* expired if now >= until_ts *)

(* #335: Classify a registration's pid-state for diagnostic logging.
   - "alive_with_pid"  — pid set, /proc/<pid> exists, pid_start_time matches
   - "alive_no_pid"    — pid is None (legacy zombie row; nudge accumulator)
   - "dead"            — pid set but /proc/<pid> missing or start-time drift
   - "unknown"         — Docker mode or partial state where we can't tell *)
let pid_state_label (reg : registration) =
  match reg.pid with
  | None -> "alive_no_pid"
  | Some _ ->
      match Broker.registration_liveness_state reg with
      | Broker.Alive -> "alive_with_pid"
      | Broker.Dead -> "dead"
      | Broker.Unknown -> "unknown"

(* #335: structured log for each nudge-enqueue attempt. Mirrors the
   `log_handoff_attempt` shape from #327 so a single broker.log parser
   covers both events. Total / never raises. *)
let log_nudge_enqueue ~broker_root ~from_session_id ~to_alias ~to_pid_state ~ok =
  (try
     let path = Filename.concat broker_root "broker.log" in
     let ts = Unix.gettimeofday () in
     let line =
       `Assoc
         [ ("ts", `Float ts)
         ; ("event", `String "nudge_enqueue")
         ; ("from_session_id", `String from_session_id)
         ; ("to_alias", `String to_alias)
         ; ("to_pid_state", `String to_pid_state)
         ; ("ok", `Bool ok)
         ]
       |> Yojson.Safe.to_string
     in
     let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o600 path in
     (try
        output_string oc (line ^ "\n");
        close_out oc
      with _ -> close_out_noerr oc)
   with _ -> ())

(* #335: structured log for each nudge-tick fire. Counts let us verify
   whether the multi-broker amplification hypothesis holds (one tick per
   alive MCP server per cadence period). Total / never raises. *)
let log_nudge_tick ~broker_root ~from_session_id ~alive_total
    ~idle_eligible ~sent ~skipped_dnd ~alive_no_pid
    ~cadence_minutes ~idle_minutes =
  (try
     let path = Filename.concat broker_root "broker.log" in
     let ts = Unix.gettimeofday () in
     let line =
       `Assoc
         [ ("ts", `Float ts)
         ; ("event", `String "nudge_tick")
         ; ("from_session_id", `String from_session_id)
         ; ("alive_total", `Int alive_total)
         ; ("idle_eligible", `Int idle_eligible)
         ; ("sent", `Int sent)
         ; ("skipped_dnd", `Int skipped_dnd)
         ; ("alive_no_pid", `Int alive_no_pid)
         ; ("cadence_minutes", `Float cadence_minutes)
         ; ("idle_minutes", `Float idle_minutes)
         ]
       |> Yojson.Safe.to_string
     in
     let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o600 path in
     (try
        output_string oc (line ^ "\n");
        close_out oc
      with _ -> close_out_noerr oc)
   with _ -> ())

(* #335: nudge_session — sends one nudge and logs the enqueue. Threads
   ~from_session_id so multi-broker amplification is visible in
   broker.log traces. *)
let nudge_session ~broker ~from_session_id ~reg ~message =
  let open Lwt in
  let to_pid_state = pid_state_label reg in
  let broker_root = Broker.root broker in
  try
    Broker.enqueue_message broker
      ~from_alias:nudge_sender_alias
      ~to_alias:reg.alias
      ~content:message.text
      ~deferrable:true
      ();
    Log.info (fun f -> f "relay_nudge: sent to %s" reg.alias);
    log_nudge_enqueue ~broker_root ~from_session_id
      ~to_alias:reg.alias ~to_pid_state ~ok:true;
    true
  with e ->
    Log.warn (fun f -> f "relay_nudge: failed to nudge %s: %s" reg.alias (Printexc.to_string e));
    log_nudge_enqueue ~broker_root ~from_session_id
      ~to_alias:reg.alias ~to_pid_state ~ok:false;
    false

let nudge_tick ?(from_session_id="broker") ~broker ~cadence_minutes ~idle_minutes ~messages () =
  let now = Unix.gettimeofday () in
  let idle_threshold_s = idle_minutes *. 60.0 in
  let regs = Broker.list_registrations broker in
  let alive_total = ref 0 in
  let idle_eligible = ref 0 in
  let sent = ref 0 in
  let skipped_dnd = ref 0 in
  let alive_no_pid = ref 0 in
  List.iter
    (fun (reg : registration) ->
      (* Skip non-alive sessions *)
      if not (Broker.registration_is_alive reg) then ()
      else begin
        incr alive_total;
        (* #335: count pid=None as a sub-category of alive_total. These are
           the zombie-row pattern that accumulates nudges indefinitely.
           NOTE: this is a *count*, not a skip — pidless rows still pass
           through to the DND/idle/nudge_session path under v1a (observe-
           only). v2a is where they become actually skipped. *)
        (if reg.pid = None then incr alive_no_pid);
        if is_dnd_active reg then incr skipped_dnd
        else
          match reg.last_activity_ts with
          | None -> ()  (* no activity data yet *)
          | Some ts ->
              let idle_s = now -. ts in
              if idle_s >= idle_threshold_s then begin
                incr idle_eligible;
                match random_message messages with
                | None -> ()
                | Some msg ->
                    if nudge_session ~broker ~from_session_id ~reg ~message:msg
                    then incr sent
              end else ()
      end)
    regs;
  log_nudge_tick
    ~broker_root:(Broker.root broker)
    ~from_session_id
    ~alive_total:!alive_total
    ~idle_eligible:!idle_eligible
    ~sent:!sent
    ~skipped_dnd:!skipped_dnd
    ~alive_no_pid:!alive_no_pid
    ~cadence_minutes
    ~idle_minutes

let start_nudge_scheduler ~broker_root ~broker
    ?(cadence_minutes = default_cadence_minutes)
    ?(idle_minutes = default_idle_minutes)
    () =
  if idle_minutes >= cadence_minutes then
    invalid_arg
      (Printf.sprintf "relay_nudge: idle_minutes (%.0f) must be less than cadence_minutes (%.0f)"
         idle_minutes cadence_minutes);
  Log.info (fun f -> f "relay_nudge: starting (cadence=%.0fmin, idle=%.0fmin)"
              cadence_minutes idle_minutes);
  let messages = load_messages ~broker_root in
  if messages = [] then
    Log.warn (fun f -> f "relay_nudge: no messages loaded from %s/nudge/messages.json"
                 broker_root);
  (* #335: tag the tick with the session_id of the MCP server running it,
     so multi-broker amplification is visible in broker.log traces. *)
  let from_session_id =
    match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
    | Some v when String.trim v <> "" -> String.trim v
    | _ -> "broker"
  in
  let rec loop () =
    let open Lwt in
    Lwt_unix.sleep (cadence_minutes *. 60.0)
    >>= fun () ->
    nudge_tick ~from_session_id ~broker ~cadence_minutes ~idle_minutes ~messages ();
    loop ()
  in
  Lwt.async (fun () -> loop ())
