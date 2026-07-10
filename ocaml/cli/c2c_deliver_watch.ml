(* c2c_deliver_watch: CLI deliver --watch subcommand (#482 S6).

   P4: also drains the global sessions broker
   (C2C_SESSIONS_BROKER_ROOT / resolve_sessions_broker_root) alongside the
   per-repo broker, so messages sent via `c2c send --session <id>` reach
   codex/opencode sessions too. *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

(* xml_escape sourced from C2c_mcp (c2c_mcp_helpers.ml) — canonical def *)

type output_mode =
  | Stdout
  | XmlFd of Unix.file_descr
  | Null

(* Canonical resolution (env override → repo-fingerprint path), same chain
   every other c2c command uses. The old fallback here hardcoded
   repos/default/broker, so `c2c deliver wake-watch --alias <a>` run from a
   repo checkout could not see the repo broker's registry (live-caught
   2026-07-10: "alias ... is not registered in this broker"). *)
let default_broker_root () : string =
  try C2c_repo_fp.resolve_broker_root ()
  with _ ->
    let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
    home // ".c2c" // "repos" // "default" // "broker"

(* P4: Check if a global session inbox exists for the given session_id. *)
let global_inbox_exists ~root ~session_id =
  Sys.file_exists (Filename.concat root (session_id ^ ".inbox.json"))

(* P4: Drain messages from the global sessions broker.
   Returns [] if no global inbox exists. *)
let drain_global_messages ~session_id =
  if not (C2c_name.is_valid session_id) then []
  else
  let root = C2c_repo_fp.resolve_sessions_broker_root () in
  if global_inbox_exists ~root ~session_id then
    let broker = C2c_mcp.Broker.create ~root in
    C2c_mcp.Broker.drain_inbox ~drained_by:"deliver-watch-global" broker ~session_id
  else []

let watch_loop
    ~(broker_root : string)
    ~(session_id : string)
    ~(interval : float)
    (mode : output_mode) : unit =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let iterations = ref 0 in
  let total = ref 0 in
  let rec loop () =
    incr iterations;
    let repo_messages =
      C2c_mcp.Broker.drain_inbox ~drained_by:"deliver-watch" broker ~session_id
    in
    let global_messages = drain_global_messages ~session_id in
    let messages = repo_messages @ global_messages in
    total := !total + List.length messages;
    (if List.length repo_messages > 0 then
       C2c_deliver_inbox_log.log_drain
         ~broker_root
         ~session_id
         ~client:"deliver-watch"
         ~count:(List.length repo_messages)
         ~drained_by_pid:(Unix.getpid ()));
    (if List.length global_messages > 0 then
       C2c_deliver_inbox_log.log_drain
         ~broker_root:(C2c_repo_fp.resolve_sessions_broker_root ())
         ~session_id
         ~client:"deliver-watch-global"
         ~count:(List.length global_messages)
         ~drained_by_pid:(Unix.getpid ()));
    List.iter
      (fun (msg : C2c_mcp.message) ->
        match mode with
        | Stdout ->
            Printf.printf "[%s] %s\n%!" msg.from_alias msg.content;
            flush stdout
        | XmlFd fd ->
            let tag = C2c_mcp.extract_tag_from_content msg.content in
            let envelope =
              C2c_mcp.format_c2c_envelope
                ~from_alias:msg.from_alias
                ~to_alias:msg.to_alias
                ?tag
                ?reply_via:msg.reply_via
                ~with_reply_hint:true
                ~escape_content_for_xml:true
                ~content:msg.content
                ()
            in
            let frame =
              Printf.sprintf
                "<message type=\"user\" queue=\"AfterAnyItem\">%s</message>\n"
                envelope
            in
            let oc = Unix.out_channel_of_descr fd in
            (try output_string oc frame; flush oc
             with exn ->
               Printf.eprintf "[c2c-deliver-watch] xml write failed: %s\n%!"
                 (Printexc.to_string exn))
        | Null -> ()
      ) messages;
    (if List.length messages > 0 then
       Printf.printf "[c2c-deliver-watch] iteration %d: %d message(s)\n%!"
         !iterations (List.length messages)
     else
       Printf.printf "[c2c-deliver-watch] iteration %d: no messages\n%!"
         !iterations);
    flush stdout;
    ignore (Unix.select [] [] [] interval);
    loop ()
  in
  loop ()  (* unreachable: loop recurses forever; next lines are dead code *)

open Cmdliner

let deliver_watch_cmd =
  let session_id_flag =
    Arg.(required & opt (some string) None
         & info ["session-id"] ~docv:"ID"
         ~doc:"Broker session ID to deliver (required).")
  in
  let broker_root_flag =
    Arg.(value & opt (some string) None
         & info ["broker-root"] ~docv:"DIR"
         ~doc:"Broker root directory.")
  in
  let interval_flag =
    Arg.(value & opt (some float) (Some 1.0)
         & info ["interval"] ~docv:"SECS"
         ~doc:"Polling interval in seconds (default: 1.0).")
  in
  let xml_fd_flag =
    Arg.(value & opt (some int) None
         & info ["xml-fd"] ~docv:"N"
         ~doc:"Write XML frames to this fd.")
  in
  let man = [
    `S "DESCRIPTION";
    `P "c2c deliver --watch polls the broker inbox continuously.";
    `S "OUTPUT MODES";
    `P "Default: one line per message: [from_alias] body";
    `P "--xml-fd N: XML frames in the legacy Codex sideband format (the \
        upstream --xml-input-fd consumer was removed; the codex-headless \
        bridge still reads this frame format).";
  ] in
  let info = Cmdliner.Cmd.info "watch" ~doc:"Watch mode" ~man in
  let term =
    let+ () = Cmdliner.Term.const ()
    and+ session_id = session_id_flag
    and+ broker_root_opt = broker_root_flag
    and+ interval_opt = interval_flag
    and+ xml_fd_opt = xml_fd_flag
    in
    let broker_root =
      match broker_root_opt with
      | Some b when String.trim b <> "" -> String.trim b
      | _ -> default_broker_root ()
    in
    let mode =
      match xml_fd_opt with
      | Some fd ->
          let fd_obj : Unix.file_descr = Obj.magic fd in
          XmlFd fd_obj
      | None -> Stdout
    in
    let interval = match interval_opt with Some f -> f | None -> 1.0 in
    watch_loop ~broker_root ~session_id ~interval mode
  in
  Cmdliner.Cmd.v info term

(* --- wake-watch (codex-wake-inject) ------------------------------------------

   Standalone idle-wake watcher for vanilla codex sessions running inside
   tmux or herdr. Watches the session's broker inbox and, on growth, injects
   a one-line wake nudge into the registered pane (C2c_wake_inject). It
   NEVER drains the inbox — submitting the nudge fires the codex
   UserPromptSubmit hook, which performs the actual delivery. Managed
   sessions (`c2c start codex`) get the same watcher automatically via the
   deliver-inbox sidecar; this command is the vanilla-session equivalent. *)

let resolve_wake_session_id ~(broker_root : string) ~(alias : string) :
    (string, string) result =
  try
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    let alias_norm = String.lowercase_ascii alias in
    match
      C2c_mcp.Broker.list_registrations broker
      |> List.filter (fun (r : C2c_mcp.registration) ->
             String.lowercase_ascii r.alias = alias_norm)
    with
    | [] ->
        Error (Printf.sprintf "alias %s is not registered in this broker" alias)
    | regs ->
        let live =
          List.filter
            (fun r ->
              C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive)
            regs
        in
        let chosen = match live with r :: _ -> r | [] -> List.hd regs in
        Ok chosen.session_id
  with e -> Error (Printexc.to_string e)

let wake_watch_cmd =
  let alias_flag =
    Arg.(value & opt (some string) None
         & info ["alias"; "a"] ~docv:"ALIAS"
         ~doc:"Alias whose session to wake-watch (resolved via the broker registry).")
  in
  let session_id_flag =
    Arg.(value & opt (some string) None
         & info ["session-id"] ~docv:"ID"
         ~doc:"Broker session ID to wake-watch.")
  in
  let broker_root_flag =
    Arg.(value & opt (some string) None
         & info ["broker-root"] ~docv:"DIR"
         ~doc:"Broker root directory.")
  in
  let once_flag =
    Arg.(value & flag
         & info ["once"]
         ~doc:"Attempt a single wake-inject and exit (prints the outcome).")
  in
  let max_iterations_flag =
    Arg.(value & opt (some int) None
         & info ["max-iterations"] ~docv:"N"
         ~doc:"Stop the watch loop after N inject attempts (testing).")
  in
  let man = [
    `S "DESCRIPTION";
    `P "Idle-wake watcher for codex sessions running inside tmux or herdr. \
        Watches the session's broker inbox; when it grows and the session \
        looks idle, types a one-line wake nudge into the session's \
        registered pane (herdr: 'herdr pane run'; tmux: send-keys literal \
        text then Enter) and submits it. The injected turn fires codex's \
        UserPromptSubmit hook, which drains and delivers the messages.";
    `P "The watcher itself NEVER drains the broker inbox — double delivery \
        is impossible by construction.";
    `P "tmux/herdr only: sessions without a registered wake target \
        (tmux_location / herdr_pane on the broker registration, captured \
        automatically by `c2c hook codex` on SessionStart) are skipped. \
        Idle gates: herdr agent_status must be idle; tmux requires broker \
        last_activity_ts older than C2C_WAKE_IDLE_THRESHOLD_S (default 90s). \
        Re-inject backoff: C2C_WAKE_BACKOFF_S (default 120s), and only when \
        a NEWER message arrived since the last inject.";
  ] in
  let info =
    Cmdliner.Cmd.info "wake-watch"
      ~doc:"Wake an idle codex session in tmux/herdr when its inbox grows (never drains)."
      ~man
  in
  let term =
    let+ () = Cmdliner.Term.const ()
    and+ alias_opt = alias_flag
    and+ session_id_opt = session_id_flag
    and+ broker_root_opt = broker_root_flag
    and+ once = once_flag
    and+ max_iterations = max_iterations_flag
    in
    let broker_root =
      match broker_root_opt with
      | Some b when String.trim b <> "" -> String.trim b
      | _ -> default_broker_root ()
    in
    let session_id =
      match session_id_opt, alias_opt with
      | Some _, Some _ ->
          Printf.eprintf "error: --session-id and --alias are mutually exclusive\n%!";
          exit 2
      | Some sid, None -> sid
      | None, Some alias -> (
          match resolve_wake_session_id ~broker_root ~alias with
          | Ok sid -> sid
          | Error e ->
              Printf.eprintf "error: %s\n%!" e;
              exit 1)
      | None, None ->
          Printf.eprintf "error: --session-id or --alias required\n%!";
          exit 2
    in
    if once then begin
      let outcome =
        C2c_wake_inject.maybe_inject ~broker_root ~session_id ()
      in
      Printf.printf "[c2c-wake-watch] %s\n%!"
        (C2c_wake_inject.outcome_to_string outcome);
      match outcome with
      | C2c_wake_inject.Failed _ -> exit 1
      | _ -> exit 0
    end
    else begin
      Printf.printf
        "[c2c-wake-watch] watching %s for %s (tmux/herdr nudge only; codex \
         hooks deliver bodies)\n%!"
        broker_root session_id;
      C2c_wake_inject.watch_loop ~broker_root ~session_id ?max_iterations ()
    end
  in
  Cmdliner.Cmd.v info term

let deliver_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "deliver" ~doc:"Message delivery commands.")
    [ deliver_watch_cmd; wake_watch_cmd ]
