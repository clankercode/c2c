(* c2c_wake_inject — idle-wake nudge injector for codex sessions (codex-wake-inject slice).

   Problem: an idle codex session cannot be woken — codex hooks only fire on
   activity, so heartbeat/schedule self-DMs rot in the broker inbox until the
   operator types something. PTY injection is unreliable and rejected.

   Decision: idle wake for codex is supported ONLY when the session runs
   inside tmux or herdr. This module injects a short wake nudge (plain text +
   Enter) into the session's pane; submitting the nudge fires codex's
   UserPromptSubmit hook, which performs the actual full inbox drain.

   INVARIANT — the injector NEVER drains the broker inbox. It only peeks
   (read-only) to count messages and types a one-line nudge into the pane.
   Delivery of message bodies is exclusively the hook's job, which makes
   double-delivery impossible by construction.

   Backends:
   - herdr: `herdr agent get <pane>` for a real idle/working status gate,
     then `herdr pane run <pane> <text>` (documented as "command text plus
     Enter" — see `herdr agent --help`: "agent send writes literal text;
     use pane run when you want command text plus Enter").
   - tmux: `tmux send-keys -l -t <target> <text>` then
     `tmux send-keys -t <target> Enter` — the exact sequence
     scripts/c2c_tmux.py `send` uses. Idle gate is the broker's
     last_activity_ts (no true busy-signal in tmux).

   Safety rails:
   - Idle-gating: never inject into a herdr pane whose agent_status is not
     "idle"; for tmux require last_activity_ts older than
     C2C_WAKE_IDLE_THRESHOLD_S (default 90s).
   - Backoff/dedupe: per-session state file <broker_root>/wake-inject/<sid>.json
     records last inject time + newest message ts at inject time. No re-inject
     within C2C_WAKE_BACKOFF_S (default 120s) and never unless a NEWER message
     has arrived since the last inject.
   - Fixture gate: C2C_WAKE_INJECT_FIXTURE=<path> records the exact command
     argv (one JSON line per command, {"argv":[...],"env":{...}}) instead of
     executing — all tests use this; no live pane is ever touched in CI.
   - Total: maybe_inject never raises; failures are logged to broker.log via
     Broker_log.append_json, not stdout. *)

let ( // ) = Filename.concat

(* ---------------------------------------------------------------------------
 * Env knobs
 * --------------------------------------------------------------------------- *)

let fixture_path () =
  match Sys.getenv_opt "C2C_WAKE_INJECT_FIXTURE" with
  | Some p when String.trim p <> "" -> Some (String.trim p)
  | _ -> None

let float_env name default =
  match Sys.getenv_opt name with
  | Some s -> (try float_of_string (String.trim s) with _ -> default)
  | None -> default

(* Tmux idle gate: broker last_activity_ts must be older than this. *)
let idle_threshold_s () = float_env "C2C_WAKE_IDLE_THRESHOLD_S" 90.0

(* Minimum seconds between injects for the same session. *)
let backoff_s () = float_env "C2C_WAKE_BACKOFF_S" 120.0

(* Watch-loop periodic re-attempt cadence (also the inotify select timeout,
   so a message that arrived while the session was busy still gets a nudge
   once the session goes idle). *)
let watch_poll_s () = float_env "C2C_WAKE_POLL_S" 20.0

(* Pause between typing the nudge text and sending Enter. Agent TUIs
   paste-detect rapid input: text+Enter arriving in the same burst is
   treated as a paste and the Enter becomes a newline instead of a submit
   (live-caught 2026-07-10 — the nudge sat unsubmitted in the codex
   composer; an Enter sent later submitted fine). Same reason the legacy
   pty_inject path did "bracketed paste + delay + Enter". *)
let enter_delay_s () = float_env "C2C_WAKE_ENTER_DELAY_S" 0.35

(* ---------------------------------------------------------------------------
 * Wake-target selection
 * --------------------------------------------------------------------------- *)

type backend =
  | Herdr of { pane : string; socket : string option }
  | Tmux of string

let backend_name = function Herdr _ -> "herdr" | Tmux _ -> "tmux"

(* Innermost surface wins when both targets are registered. A session
   running inside tmux always captures $TMUX_PANE — that pane id names the
   exact pane the session lives in. A HERDR_PANE_ID seen alongside it was
   inherited from the *outer* herdr pane hosting the tmux client: injecting
   there types into whatever tmux window happens to be active (live-verified
   2026-07-10 — the herdr probe on the outer pane also reports
   agent_status=unknown, so every wake was skipped). herdr is used only when
   it is the sole target, i.e. the session really runs directly in a herdr
   pane, where its idle/working agent_status signal beats the tmux
   activity-age heuristic. *)
let backend_of_registration (r : C2c_mcp_helpers.registration) : backend option =
  match r.tmux_location with
  | Some target -> Some (Tmux target)
  | None ->
      (match r.herdr_pane with
       | Some pane -> Some (Herdr { pane; socket = r.herdr_socket })
       | None -> None)

(* Env-derived wake targets, used at capture points (`c2c hook codex`, MCP
   register fallback). Raw $TMUX_PANE pane id (e.g. "%5") is preferred for
   the tmux target: it is stable across window renumbering and tmux
   send-keys accepts it directly — no resolution shell-out needed. $TMUX is
   also required so a pane id inherited from a dead tmux ancestor is not
   trusted. *)
let wake_targets_from_env () :
    string option (* tmux_location *)
    * string option (* herdr_pane *)
    * string option (* herdr_socket *) =
  let nonempty name =
    match Sys.getenv_opt name with
    | Some v when String.trim v <> "" -> Some (String.trim v)
    | _ -> None
  in
  let tmux_location =
    match nonempty "TMUX", nonempty "TMUX_PANE" with
    | Some _, Some pane -> Some pane
    | _ -> None
  in
  (nonempty "HERDR_PANE_ID", nonempty "HERDR_SOCKET_PATH")
  |> fun (pane, socket) -> (tmux_location, pane, socket)

(* ---------------------------------------------------------------------------
 * Command execution (fixture-gated)
 * --------------------------------------------------------------------------- *)

let record_fixture ~path ~(argv : string list) ~(env_extra : (string * string) list) =
  try
    let json =
      `Assoc
        ([ ("argv", `List (List.map (fun a -> `String a) argv)) ]
         @
         match env_extra with
         | [] -> []
         | kvs ->
             [ ("env", `Assoc (List.map (fun (k, v) -> (k, `String v)) kvs)) ])
    in
    let oc =
      open_out_gen [ Open_wronly; Open_creat; Open_append ] 0o644 path
    in
    Fun.protect
      ~finally:(fun () -> try close_out oc with _ -> ())
      (fun () ->
        output_string oc (Yojson.Safe.to_string json);
        output_char oc '\n')
  with _ -> ()

let env_with_extra (env_extra : (string * string) list) : string array =
  let keys = List.map fst env_extra in
  let base =
    Array.to_list (Unix.environment ())
    |> List.filter (fun e ->
           let k = try String.sub e 0 (String.index e '=') with Not_found -> e in
           not (List.mem k keys))
  in
  Array.of_list (base @ List.map (fun (k, v) -> k ^ "=" ^ v) env_extra)

(* Run argv; discard output; true iff exit 0. Fixture mode records instead. *)
let run_command ?(env_extra = []) (argv : string list) : bool =
  match fixture_path () with
  | Some path ->
      record_fixture ~path ~argv ~env_extra;
      true
  | None -> (
      match argv with
      | [] -> false
      | cmd :: _ -> (
          try
            let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
            Fun.protect
              ~finally:(fun () -> try Unix.close devnull with _ -> ())
              (fun () ->
                let pid =
                  Unix.create_process_env cmd (Array.of_list argv)
                    (env_with_extra env_extra) devnull devnull devnull
                in
                match Unix.waitpid [] pid with
                | _, Unix.WEXITED 0 -> true
                | _ -> false)
          with _ -> false))

(* Run argv; capture stdout; Some output iff exit 0. Fixture mode records
   the command and returns None (callers use their own fixture response). *)
let run_command_capture ?(env_extra = []) (argv : string list) : string option =
  match fixture_path () with
  | Some path ->
      record_fixture ~path ~argv ~env_extra;
      None
  | None -> (
      match argv with
      | [] -> None
      | cmd :: _ -> (
          try
            let stdout_r, stdout_w = Unix.pipe ~cloexec:false () in
            let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
            let pid =
              Unix.create_process_env cmd (Array.of_list argv)
                (env_with_extra env_extra) devnull stdout_w devnull
            in
            Unix.close stdout_w;
            (try Unix.close devnull with _ -> ());
            let ic = Unix.in_channel_of_descr stdout_r in
            let buf = Buffer.create 256 in
            (try
               while true do
                 Buffer.add_channel buf ic 1
               done
             with End_of_file -> ());
            (try close_in ic with _ -> ());
            match Unix.waitpid [] pid with
            | _, Unix.WEXITED 0 -> Some (Buffer.contents buf)
            | _ -> None
          with _ -> None))

(* ---------------------------------------------------------------------------
 * herdr status
 * --------------------------------------------------------------------------- *)

let herdr_env_extra ~(socket : string option) =
  match socket with
  | Some s -> [ ("HERDR_SOCKET_PATH", s) ]
  | None -> []

(* Parse `herdr agent get` stdout into an agent_status string. The CLI wraps
   the payload: {"id":"cli:agent:get","result":{"agent":{"agent_status":...,
   ...},"type":"agent_info"}} (verified live 2026-07-10). Search the JSON
   tree for the first "agent_status" member so top-level, result.agent, and
   future wrapper drift all resolve. Unparseable → "unknown" (never inject
   blind). *)
let parse_herdr_agent_status (out : string) : string =
  let rec find (j : Yojson.Safe.t) : string option =
    match j with
    | `Assoc fields -> (
        match List.assoc_opt "agent_status" fields with
        | Some (`String s) -> Some s
        | _ -> List.find_map (fun (_, v) -> find v) fields)
    | `List items -> List.find_map find items
    | _ -> None
  in
  try
    match find (Yojson.Safe.from_string (String.trim out)) with
    | Some s -> s
    | None -> "unknown"
  with _ -> "unknown"

(* Statuses safe to inject into. herdr reports idle | working | blocked |
   unknown | done; "done" is a pane whose agent finished its last turn and
   is sitting at the composer (observed live for at-rest codex panes) —
   exactly the state a wake nudge is for. working/blocked/unknown are never
   injected. *)
let herdr_status_injectable status = status = "idle" || status = "done"

(* agent_status for the pane. Any failure (herdr missing, socket dead,
   unparseable output) → "unknown", which the gate treats as not-injectable.
   Fixture mode: the `herdr agent get` argv is recorded, and the status is
   read from C2C_WAKE_INJECT_HERDR_STATUS (default "idle"). *)
let herdr_agent_status ~(pane : string) ~(socket : string option) : string =
  match fixture_path () with
  | Some path ->
      record_fixture ~path
        ~argv:[ "herdr"; "agent"; "get"; pane ]
        ~env_extra:(herdr_env_extra ~socket);
      (match Sys.getenv_opt "C2C_WAKE_INJECT_HERDR_STATUS" with
       | Some s when String.trim s <> "" -> String.trim s
       | _ -> "idle")
  | None -> (
      match
        run_command_capture
          ~env_extra:(herdr_env_extra ~socket)
          [ "herdr"; "agent"; "get"; pane ]
      with
      | None -> "unknown"
      | Some out -> parse_herdr_agent_status out)

(* ---------------------------------------------------------------------------
 * Per-session inject state (backoff / dedupe)
 * --------------------------------------------------------------------------- *)

type state = { last_inject_ts : float; last_msg_ts : float }

let empty_state = { last_inject_ts = 0.0; last_msg_ts = 0.0 }

let state_dir ~broker_root = broker_root // "wake-inject"

let state_path ~broker_root ~session_id =
  state_dir ~broker_root // (session_id ^ ".json")

let read_state ~broker_root ~session_id : state =
  try
    let path = state_path ~broker_root ~session_id in
    if not (Sys.file_exists path) then empty_state
    else
      match Yojson.Safe.from_file path with
      | `Assoc fields ->
          let f name =
            match List.assoc_opt name fields with
            | Some (`Float x) -> x
            | Some (`Int n) -> float_of_int n
            | _ -> 0.0
          in
          { last_inject_ts = f "last_inject_ts"; last_msg_ts = f "last_msg_ts" }
      | _ -> empty_state
  with _ -> empty_state

let write_state ~broker_root ~session_id (st : state) : unit =
  try
    let dir = state_dir ~broker_root in
    (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let path = state_path ~broker_root ~session_id in
    let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
    let oc = open_out tmp in
    Fun.protect
      ~finally:(fun () -> try close_out oc with _ -> ())
      (fun () ->
        Yojson.Safe.to_channel oc
          (`Assoc
            [ ("last_inject_ts", `Float st.last_inject_ts)
            ; ("last_msg_ts", `Float st.last_msg_ts)
            ]));
    Unix.rename tmp path
  with _ -> ()

(* ---------------------------------------------------------------------------
 * Broker log
 * --------------------------------------------------------------------------- *)

(* Call sites pass the event pair with a literal string so the #442
   catalog gate's static scan can see every event name. *)
let log_event ~broker_root ~session_id fields =
  Broker_log.append_json ~broker_root
    ~json:
      (`Assoc
        (("ts", `Float (Unix.gettimeofday ()))
         :: fields
        @ [ ("session_id", `String session_id) ]))

(* ---------------------------------------------------------------------------
 * The injector
 * --------------------------------------------------------------------------- *)

type outcome =
  | Injected of { backend : string; message_count : int }
  | Skipped of string
  | Failed of string

let outcome_to_string = function
  | Injected { backend; message_count } ->
      Printf.sprintf "injected backend=%s messages=%d" backend message_count
  | Skipped reason -> "skipped: " ^ reason
  | Failed reason -> "failed: " ^ reason

(* Short and boring on purpose: the nudge only has to start a codex turn —
   the UserPromptSubmit hook then delivers the actual message bodies. *)
let nudge_text ~count =
  Printf.sprintf "c2c: %d message(s) waiting - poll your inbox" count

let inject_via_backend ~count = function
  | Herdr { pane; socket } ->
      (* `herdr pane run` = command text plus Enter (see module header). *)
      if
        run_command
          ~env_extra:(herdr_env_extra ~socket)
          [ "herdr"; "pane"; "run"; pane; nudge_text ~count ]
      then Ok ()
      else Error "herdr_pane_run_failed"
  | Tmux target ->
      (* Mirror scripts/c2c_tmux.py `send` + `c2c-tmux-enter.sh`: literal
         text, then Enter with `extended-keys` toggled off around it. With
         `set -s extended-keys on` a plain send-keys Enter encodes as CSI-u
         (^[[27;5;109~) which agent TUIs read as Ctrl+Shift+M — the nudge
         then sits unsubmitted in the composer (live-caught 2026-07-10; see
         .collab/findings/2026-04-19T06-22-47Z-opus-host-tmux-extended-keys-eats-enter.md).
         Restore is best-effort: worst case extended-keys stays off, which
         only disables CSI-u encoding for other panes until reset. *)
      if run_command [ "tmux"; "send-keys"; "-l"; "-t"; target; nudge_text ~count ]
      then begin
        (* Let the TUI's paste-detection window expire before Enter, or the
           Enter is coalesced into the text burst as a newline (see
           enter_delay_s). Skipped in fixture mode — no real TUI. *)
        (if fixture_path () = None then
           try Unix.sleepf (enter_delay_s ()) with _ -> ());
        let prev =
          match run_command_capture [ "tmux"; "show"; "-sv"; "extended-keys" ] with
          | Some v when String.trim v <> "" -> String.trim v
          | _ -> "off"
        in
        ignore (run_command [ "tmux"; "set"; "-s"; "extended-keys"; "off" ]);
        let ok = run_command [ "tmux"; "send-keys"; "-t"; target; "Enter" ] in
        ignore (run_command [ "tmux"; "set"; "-s"; "extended-keys"; prev ]);
        if ok then Ok () else Error "tmux_send_keys_failed"
      end
      else Error "tmux_send_keys_failed"

(* One inject attempt. Read-only against the broker inbox (peek + count);
   drains nothing. Total: never raises. *)
let maybe_inject ?now ~(broker_root : string) ~(session_id : string) () : outcome =
  try
    let now = match now with Some t -> t | None -> Unix.gettimeofday () in
    let broker = C2c_broker.create ~root:broker_root in
    let reg_opt =
      List.find_opt
        (fun (r : C2c_mcp_helpers.registration) -> r.session_id = session_id)
        (C2c_broker.list_registrations broker)
    in
    match reg_opt with
    | None -> Skipped "no_registration"
    | Some reg -> (
        (* READ-ONLY peek — the injector must never drain (see header). *)
        match C2c_broker.read_inbox broker ~session_id with
        | [] -> Skipped "inbox_empty"
        | msgs -> (
            let count = List.length msgs in
            let newest_ts =
              List.fold_left
                (fun acc (m : C2c_mcp_helpers.message) -> max acc m.ts)
                0.0 msgs
            in
            let st = read_state ~broker_root ~session_id in
            if newest_ts <= st.last_msg_ts then
              Skipped "no_new_messages_since_last_inject"
            else if now -. st.last_inject_ts < backoff_s () then Skipped "backoff"
            else
              match backend_of_registration reg with
              | None -> Skipped "no_wake_target"
              | Some backend -> (
                  let idle_check =
                    match backend with
                    | Herdr { pane; socket } ->
                        let status = herdr_agent_status ~pane ~socket in
                        if herdr_status_injectable status then Ok ()
                        else Error ("herdr_not_idle:" ^ status)
                    | Tmux _ -> (
                        match reg.last_activity_ts with
                        | Some ts when now -. ts < idle_threshold_s () ->
                            Error "recent_activity"
                        | _ -> Ok ())
                  in
                  match idle_check with
                  | Error reason -> Skipped reason
                  | Ok () -> (
                      match inject_via_backend ~count backend with
                      | Ok () ->
                          write_state ~broker_root ~session_id
                            { last_inject_ts = now; last_msg_ts = newest_ts };
                          log_event ~broker_root ~session_id
                            [ ("event", `String "wake_inject")
                            ; ("backend", `String (backend_name backend))
                            ; ("message_count", `Int count)
                            ];
                          Injected
                            { backend = backend_name backend
                            ; message_count = count
                            }
                      | Error reason ->
                          log_event ~broker_root ~session_id
                            [ ("event", `String "wake_inject_error")
                            ; ("backend", `String (backend_name backend))
                            ; ("reason", `String reason)
                            ];
                          Failed reason))))
  with e ->
    (try
       log_event ~broker_root ~session_id
         [ ("event", `String "wake_inject_error")
         ; ("reason", `String (Printexc.to_string e)) ]
     with _ -> ());
    Failed (Printexc.to_string e)

(* ---------------------------------------------------------------------------
 * B120: managed-codex resume identity split — follow the hook registration
 * ---------------------------------------------------------------------------
 *
 * `c2c start codex -n <name>` registers the deliver sidecar keyed by the
 * instance NAME and watches <name>.inbox.json. On resume (`codex resume
 * --last`), the codex SessionStart hook cannot map the resumed conversation's
 * thread-id back to the managed instance, so it auto-registers the resumed
 * conversation's session UUID as a hook auto-registration (registered_by =
 * "codex-hook") — and THAT is the identity peers' DMs route to. The sidecar
 * then watches an inbox nobody writes to while the real inbox has no watcher:
 * managed codex idle-wake is broken on resume.
 *
 * Both registrations share the same wake target: the managed startup captures
 * tmux_location / herdr_pane from the pane env, and the hook captures the
 * SAME pane env on SessionStart. So the sidecar can FOLLOW the hook-maintained
 * registration by matching the wake target. This mirrors B119, where the MCP
 * server ADOPTS the hook auto-registration as the identity authority
 * (Broker.is_hook_auto_registration) instead of clobbering it — here the
 * deliver/wake sidecar adopts it as its watch target.
 *)

(* The EFFECTIVE wake target of a registration, using the same "innermost
   surface wins" rule as [backend_of_registration]: a session in tmux inside a
   herdr-hosted terminal captures BOTH its real $TMUX_PANE and the OUTER herdr
   pane (env leak), and the tmux pane is the one to inject into. So tmux
   takes precedence; herdr is the target only when no tmux pane is present.
   cwd is deliberately never a target: two codex sessions can share a cwd. *)
let effective_wake_target (r : C2c_mcp_helpers.registration) :
    [ `Tmux of string | `Herdr of string ] option =
  let nonempty = function
    | Some s when String.trim s <> "" -> Some (String.trim s)
    | _ -> None
  in
  match nonempty r.tmux_location with
  | Some t -> Some (`Tmux t)
  | None -> (match nonempty r.herdr_pane with Some h -> Some (`Herdr h) | None -> None)

(* Two registrations name the same pane when their EFFECTIVE targets are equal.
   Comparing effective targets (not OR-ing tmux/herdr independently) prevents
   cross-wiring two different tmux panes that both inherited the same outer
   herdr pane: their tmux targets differ, so they do not match. *)
let wake_target_shared
    (a : C2c_mcp_helpers.registration) (b : C2c_mcp_helpers.registration) : bool =
  match effective_wake_target a, effective_wake_target b with
  | Some x, Some y -> x = y
  | _ -> false

let has_wake_target (r : C2c_mcp_helpers.registration) : bool =
  effective_wake_target r <> None

(* Given the sidecar's configured session_id, return the session_id it should
   actually watch:
   - if the configured session_id's own registration is itself a hook
     auto-registration, it IS the identity authority (the standalone
     `c2c deliver wake-watch --alias` path resolves an alias straight to its
     hook registration) — return it unchanged.
   - otherwise (a managed instance-name registration), adopt a hook
     auto-registration that shares this session's wake target. Prefer alive
     rows, then the most-recently-active one.
   Total: any failure, missing registration, or absent/ambiguous target
   returns the input session_id unchanged, so fresh starts (where the hook and
   startup agree, or no hook row exists yet) and the standalone path are
   unaffected. *)
let resolve_wake_watch_target ~(broker_root : string) ~(session_id : string) :
    string =
  try
    let broker = C2c_broker.create ~root:broker_root in
    let regs = C2c_broker.list_registrations broker in
    match
      List.find_opt
        (fun (r : C2c_mcp_helpers.registration) -> r.session_id = session_id)
        regs
    with
    | None -> session_id
    | Some self when C2c_broker.is_hook_auto_registration self -> session_id
    | Some self when not (has_wake_target self) -> session_id
    | Some self ->
        let candidates =
          List.filter
            (fun (r : C2c_mcp_helpers.registration) ->
              r.session_id <> session_id
              && C2c_broker.is_hook_auto_registration r
              && wake_target_shared self r)
            regs
        in
        (match candidates with
         | [] -> session_id
         | _ ->
             let anchor (r : C2c_mcp_helpers.registration) =
               match r.last_activity_ts with
               | Some t -> t
               | None -> (match r.registered_at with Some t -> t | None -> 0.0)
             in
             let alive (r : C2c_mcp_helpers.registration) =
               C2c_broker.registration_liveness_state r = C2c_broker.Alive
             in
             let alive_candidates = List.filter alive candidates in
             let pool =
               if alive_candidates <> [] then alive_candidates else candidates
             in
             let best =
               List.fold_left
                 (fun acc r ->
                   match acc with
                   | None -> Some r
                   | Some a -> if anchor r >= anchor a then Some r else acc)
                 None pool
             in
             (match best with Some r -> r.session_id | None -> session_id))
  with _ -> session_id

(* ---------------------------------------------------------------------------
 * Watch loop — inotify on the broker dir with periodic fallback attempts
 * --------------------------------------------------------------------------- *)

let pid_is_alive pid =
  if pid <= 0 then false
  else
    try
      Unix.kill pid 0;
      true
    with
    | Unix.Unix_error (Unix.ESRCH, _, _) -> false
    | Unix.Unix_error (Unix.EPERM, _, _) -> true

(* Watch the broker dir for inbox growth of <session_id>.inbox.json and
   attempt an inject on every event; ALSO re-attempt every C2C_WAKE_POLL_S
   so a message that arrived while the session was busy still gets its nudge
   once the session goes idle (the injector's own gates make the periodic
   attempt cheap and safe). Falls back to pure polling when inotifywait is
   unavailable. Stops when [watched_pid] exits or [max_iterations] attempts
   have run (tests). *)
let watch_loop ~(broker_root : string) ~(session_id : string)
    ?(watched_pid : int option) ?(max_iterations : int option) () : unit =
  let iterations = ref 0 in
  (* B120: re-resolve the watch target on every attempt so the sidecar FOLLOWS
     the hook-maintained registration once it appears (the codex SessionStart
     hook may register the resumed conversation's identity slightly after
     startup — the race is handled by re-resolving here rather than binding the
     target once). Resolves to [session_id] when there is no hook row to adopt,
     so fresh starts and the standalone path are unchanged. *)
  let attempt () =
    incr iterations;
    let target = resolve_wake_watch_target ~broker_root ~session_id in
    match maybe_inject ~broker_root ~session_id:target () with
    | Injected { backend; message_count } ->
        Printf.printf "[c2c-wake-inject] injected via %s (%d message(s))\n%!"
          backend message_count
    | Skipped _ -> ()
    | Failed reason ->
        Printf.printf "[c2c-wake-inject] inject failed: %s\n%!" reason
  in
  let should_stop () =
    (match max_iterations with Some m -> !iterations >= m | None -> false)
    || (match watched_pid with Some p -> not (pid_is_alive p) | None -> false)
  in
  let rec poll_only () =
    if should_stop () then ()
    else begin
      attempt ();
      if should_stop () then ()
      else begin
        Unix.sleepf (max 0.01 (watch_poll_s ()));
        poll_only ()
      end
    end
  in
  let inotify_loop () =
    let cmd =
      Printf.sprintf
        "exec inotifywait -m -q -e close_write,modify,create,moved_to --format '%%f' %s 2>/dev/null"
        (Filename.quote broker_root)
    in
    let ic = Unix.open_process_in cmd in
    let fd = Unix.descr_of_in_channel ic in
    Fun.protect
      ~finally:(fun () -> try ignore (Unix.close_process_in ic) with _ -> ())
      (fun () ->
        (* Drain anything already queued before waiting on events. *)
        attempt ();
        let rec loop () =
          if should_stop () then ()
          else
            let timeout = max 0.01 (watch_poll_s ()) in
            match Unix.select [ fd ] [] [] timeout with
            | [], _, _ ->
                (* Periodic re-attempt: covers busy-at-arrival messages. *)
                attempt ();
                loop ()
            | _ :: _, _, _ -> (
                match input_line ic with
                | line ->
                    (* B120: fire on ANY inbox-file event, not just
                       <session_id>.inbox.json. On resume the identity DMs
                       route to is the hook-registered session UUID, whose
                       inbox basename differs from the managed instance name;
                       matching only the configured basename would miss those
                       events (leaving the periodic re-attempt as the sole,
                       slower path). attempt() re-resolves + injects for its
                       own target only, and stays cheap + gated, so reacting to
                       unrelated inbox writes is safe. *)
                    if Filename.check_suffix (String.trim line) ".inbox.json"
                    then attempt ();
                    loop ()
                | exception (End_of_file | Sys_error _) ->
                    (* inotifywait died — degrade to polling. *)
                    poll_only ())
            | exception _ -> poll_only ()
        in
        loop ())
  in
  try inotify_loop () with _ -> poll_only ()
