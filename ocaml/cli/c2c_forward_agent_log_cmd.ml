(* c2c_forward_agent_log_cmd — Cmdliner wiring for `c2c forward-agent-log`
   (B193). The filtering / tail / forwarding core lives in
   [C2c_forward_agent_log] (kept CLI-helper-free so it is unit-testable). *)

open Cmdliner.Term.Syntax
open C2c_cli_helpers
module F = C2c_forward_agent_log

let forward_agent_log_term =
  let to_arg =
    Cmdliner.Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"TO"
          ~doc:
            "Recipient c2c address — a registered peer alias, or \
             $(b,alias@host) for a cross-host peer (relayed asynchronously, \
             same addressing as $(b,c2c send)).")
  in
  let file_arg =
    Cmdliner.Arg.(
      required
      & opt (some string) None
      & info [ "file"; "f" ] ~docv:"SESSION_JSONL"
          ~doc:
            "Path to the session transcript to follow, e.g. a Claude Code \
             session file under \
             ~/.claude*/projects/<project-slug>/<session-id>.jsonl.")
  in
  let format_arg =
    Cmdliner.Arg.(
      value
      & opt string "claude"
      & info [ "format" ] ~docv:"FORMAT"
          ~doc:
            "Transcript format. Currently supported: $(b,claude) (Claude \
             Code session jsonl). Other clients' formats can be added later.")
  in
  let from_override =
    Cmdliner.Arg.(
      value
      & opt (some string) None
      & info [ "from"; "F" ] ~docv:"ALIAS"
          ~doc:
            "Forward as this sender alias (must already be registered — same \
             rules as $(b,c2c send --from)).")
  in
  let broker_root_opt =
    Cmdliner.Arg.(
      value
      & opt (some string) None
      & info [ "broker-root"; "root" ] ~docv:"DIR"
          ~doc:"Broker root dir (default: auto-resolve via env/git).")
  in
  let interval_arg =
    Cmdliner.Arg.(
      value
      & opt float 2.0
      & info [ "interval" ] ~docv:"SECS"
          ~doc:"Polling interval in seconds (default: 2.0).")
  in
  let max_bytes_arg =
    Cmdliner.Arg.(
      value
      & opt int 2000
      & info [ "max-bytes" ] ~docv:"N"
          ~doc:
            "Truncate each forwarded message body to at most N bytes \
             (UTF-8-safe cut, with a '[truncated: …]' note). Keeps a chatty \
             session from flooding the recipient. Default: 2000.")
  in
  let from_start_flag =
    Cmdliner.Arg.(
      value
      & flag
      & info [ "from-start" ]
          ~doc:
            "Replay the transcript from the beginning before following. \
             Default: start at the current end of file and forward only new \
             events (attaching to a long-running session does not flood the \
             recipient with its whole history).")
  in
  let once_flag =
    Cmdliner.Arg.(
      value
      & flag
      & info [ "once" ]
          ~doc:
            "Process the whole current transcript once (implies \
             $(b,--from-start)) and exit instead of following. Exits \
             non-zero if any forward failed.")
  in
  let dry_run_flag =
    Cmdliner.Arg.(
      value
      & flag
      & info [ "dry-run" ]
          ~doc:
            "Print each message that would be forwarded instead of sending \
             it.")
  in
  let+ to_alias = to_arg
  and+ file = file_arg
  and+ format = format_arg
  and+ from_override = from_override
  and+ broker_root_opt = broker_root_opt
  and+ interval = interval_arg
  and+ max_bytes = max_bytes_arg
  and+ from_start = from_start_flag
  and+ once = once_flag
  and+ dry_run = dry_run_flag in
  let classify =
    match F.classifier_for_format format with
    | Some c -> c
    | None ->
        Printf.eprintf
          "error: unsupported transcript format '%s' (supported: %s)\n%!"
          format
          (String.concat ", " F.supported_formats);
        exit 2
  in
  if max_bytes < 64 then begin
    Printf.eprintf "error: --max-bytes must be at least 64 (got %d)\n%!"
      max_bytes;
    exit 2
  end;
  if interval <= 0.0 then begin
    Printf.eprintf "error: --interval must be positive\n%!";
    exit 2
  end;
  if not (Sys.file_exists file) then begin
    Printf.eprintf "error: transcript file not found: %s\n%!" file;
    exit 1
  end;
  let dry_run = dry_run || F.send_fixture_mode () in
  let send =
    if dry_run then fun body ->
      Printf.printf "[c2c-forward-agent-log] would send -> %s: %s\n%!"
        to_alias body;
      Ok ()
    else begin
      let broker =
        C2c_mcp.Broker.create
          ~root:
            (resolve_effective_broker_root ~explicit_root:broker_root_opt
               ~cross_repo:false ())
      in
      let from_alias = resolve_alias ~override:from_override broker in
      fun body ->
        F.deliver_via_broker ~broker ~from_alias ~to_alias body
    end
  in
  if not once then
    Printf.eprintf
      "[c2c-forward-agent-log] following %s (format=%s) -> %s; user input \
       and agent text only\n%!"
      file format to_alias;
  let stats =
    F.run ~path:file ~classify ~max_bytes ~interval ~from_start ~once ~send
  in
  if once then begin
    Printf.printf
      "[c2c-forward-agent-log] forwarded %d message(s), %d failure(s)\n%!"
      stats.F.forwarded stats.F.send_failures;
    if stats.F.send_failures > 0 then exit 1
  end

let forward_agent_log =
  let man =
    [ `S "DESCRIPTION"
    ; `P
        "Follow a coding-agent session transcript (jsonl) and forward the \
         human-visible conversation to a c2c peer: human user input is \
         forwarded prefixed $(b,[user]), assistant plaintext chat output \
         prefixed $(b,[agent])."
    ; `P
        "All transcript noise is filtered out: tool calls and tool results, \
         thinking blocks, system/meta/summary events, hook and \
         system-reminder injections, local-command output echoes, subagent \
         (sidechain) lines, and c2c-envelope-delivered messages. Malformed \
         or partially-written lines are skipped without crashing; only \
         newline-complete lines are consumed, so a live mid-write transcript \
         never produces garbage."
    ; `P
        "Intended for observation/monitoring — e.g. mirroring a local \
         session to a colleague's agent on another machine via \
         $(b,alias@host). Forwarded content is plain message DATA on the \
         c2c bus; it carries no approval or RPC semantics."
    ; `S "EXAMPLES"
    ; `P
        "c2c forward-agent-log --file \
         ~/.claude/projects/-home-me-src-proj/<session-id>.jsonl \
         observer-alias"
    ; `Noblank
    ; `P
        "c2c forward-agent-log --file session.jsonl --from-start \
         --max-bytes 1000 colleague@a1b2c3d4e5f6"
    ]
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "forward-agent-log"
       ~doc:
         "Follow a session transcript (jsonl) and forward user input + \
          agent text to a c2c address."
       ~man)
    forward_agent_log_term
