(* c2c_host_cmd - host setup and broker smoke command assembly.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open C2c_cli_helpers
open C2c_types
open Cmdliner.Term.Syntax

let setcap_cmd =
  let apply =
    Cmdliner.Arg.(value & flag & info [ "apply" ]
                    ~doc:"Exec `sudo setcap cap_sys_ptrace=ep <interp>` (needs tty + sudo).")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Machine-readable output.")
  in
  let+ apply = apply
  and+ json = json in
  match find_python_script "c2c_setcap.py" with
  | None ->
      Printf.eprintf "error: cannot find c2c_setcap.py. Run from inside the c2c git repo.\n%!";
      exit 1
  | Some script ->
      let args = [ "python3"; script ] in
      let args = if apply then args @ [ "--apply" ] else args in
      let args = if json then args @ [ "--json" ] else args in
      Unix.execvp "python3" (Array.of_list args)

let setcap : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "setcap"
       ~doc:"Grant CAP_SYS_PTRACE to the c2c Python interpreter (only needed for Codex PTY notify daemon; OpenCode + Kimi use non-PTY delivery).")
    setcap_cmd

let smoke_test_cmd =
  let+ json = json_flag in
  let tmp_dir = Filename.temp_file "c2c-smoke-" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  let broker_root = tmp_dir // "broker" in
  Unix.mkdir broker_root 0o755;
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let session_a = "smoke-session-a" in
  let session_b = "smoke-session-b" in
  let alias_a = "smoke-a" in
  let alias_b = "smoke-b" in
  let pid = Some (Unix.getpid ()) in
  let pid_start_time = C2c_mcp.Broker.capture_pid_start_time pid in
  C2c_mcp.Broker.register broker ~session_id:session_a ~alias:alias_a ~pid ~pid_start_time ();
  C2c_mcp.Broker.register broker ~session_id:session_b ~alias:alias_b ~pid ~pid_start_time ();
  let marker =
    Printf.sprintf "c2c-smoke-%d-%d"
      (Unix.gettimeofday () |> int_of_float)
      (Random.int 100000)
  in
  C2c_mcp.Broker.enqueue_message broker ~from_alias:alias_a ~to_alias:alias_b ~content:marker ();
  let messages = C2c_mcp.Broker.drain_inbox broker ~session_id:session_b in
  let ok = List.exists (fun (m : C2c_mcp.message) -> m.content = marker) messages in
  let rec rm_rf path =
    if Sys.is_directory path then (
      let entries = Sys.readdir path in
      Array.iter (fun e -> rm_rf (path // e)) entries;
      Unix.rmdir path)
    else Sys.remove path
  in
  rm_rf tmp_dir;
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`Assoc [ ("ok", `Bool ok); ("marker", `String marker) ])
  | Human ->
      if ok then
        Printf.printf "smoke-test passed (marker: %s)\n" marker
      else (
        Printf.eprintf "smoke-test failed: marker not received (marker: %s)\n%!" marker;
        exit 1)

let smoke_test : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "smoke-test" ~doc:"Run an end-to-end broker smoke test.")
    smoke_test_cmd

(* Host mailbox commands deliberately have no implicit agent identity. Every
   operation supplies the logical T3 identity and every mutation is fenced. *)
let host_mailbox =
  let open Cmdliner in
  let required name doc = Arg.(required & opt (some string) None & info [name] ~doc) in
  let environment_id = required "environment-id" "Stable host environment ID." in
  let thread_id = required "thread-id" "Stable logical host thread ID." in
  let generation = required "generation" "Opaque current binding generation." in
  let broker_root = required "broker-root" "Broker root returned by bind." in
  let output f =
    try print_json (f ()) with
    | C2c_host_mailbox.Rejected reason ->
        print_json (C2c_host_mailbox.response ["error", `String reason]); exit 1
    | C2c_broker.Registry_state_untrusted _ ->
        print_json (C2c_host_mailbox.response ["error", `String "registry_untrusted"]); exit 1
    | Sys_error _ | Unix.Unix_error _ | Yojson.Json_error _
    | Yojson.Safe.Util.Type_error _ | Invalid_argument _ | Failure _ ->
        print_json (C2c_host_mailbox.response ["error", `String "storage_error"]); exit 1
  in
  let bind =
    let workspace = required "workspace" "Workspace directory used to resolve the broker." in
    let owner_id = required "owner-id" "Host server incarnation ID." in
    let owner_pid = Arg.(value & opt int (Unix.getppid ()) & info ["owner-pid"]
      ~doc:"Long-lived owner PID (default: direct parent); start time is verified by the broker.") in
    let alias = Arg.(value & opt (some string) None & info ["alias"] ~doc:"Optional stable alias.") in
    let root = Arg.(value & opt (some string) None & info ["broker-root"] ~doc:"Explicit broker root override.") in
    let term =
      let+ environment_id = environment_id and+ thread_id = thread_id
      and+ workspace = workspace and+ owner_id = owner_id and+ owner_pid = owner_pid and+ alias = alias and+ broker_root = root in
      output (fun () -> C2c_host_mailbox.bind ~environment_id ~thread_id ~workspace
        ~owner_id ~owner_pid ?alias ?broker_root ()) in
    Cmd.v (Cmd.info "bind" ~doc:"Bind a stable host-owned mailbox; JSON response.") term in
  let operation name doc f =
    let term =
      let+ environment_id = environment_id and+ thread_id = thread_id
      and+ broker_root = broker_root and+ generation = generation in
      output (fun () -> f ~environment_id ~thread_id ~broker_root ~generation) in
    Cmd.v (Cmd.info name ~doc) term in
  let peek =
    let limit = Arg.(value & opt int 64 & info ["limit"]
      ~doc:"Maximum messages in this page (1 to 64, default 64); also bounded by 4 MiB encoded JSON.") in
    let term =
      let+ environment_id = environment_id and+ thread_id = thread_id
      and+ broker_root = broker_root and+ generation = generation and+ limit = limit in
      output (fun () -> C2c_host_mailbox.peek ~environment_id ~thread_id ~broker_root
        ~generation ~limit ()) in
    Cmd.v (Cmd.info "peek" ~doc:"Peek a bounded page without draining; JSON response.") term in
  let send =
    let to_alias = required "to" "Recipient alias; the sender comes only from the fenced binding." in
    let content = required "content" "Literal peer DATA, at most 65536 UTF-8 bytes." in
    let term =
      let+ environment_id = environment_id and+ thread_id = thread_id
      and+ broker_root = broker_root and+ generation = generation
      and+ to_alias = to_alias and+ content = content in
      output (fun () -> C2c_host_mailbox.send ~environment_id ~thread_id ~broker_root
        ~generation ~to_alias ~content) in
    Cmd.v (Cmd.info "send" ~doc:"Send peer DATA from the current fenced binding; JSON response.") term in
  let ack =
    let message_ids = Arg.(value & opt_all string [] & info ["message-id"]
      ~doc:"Durably accepted message ID; repeat for each selected message.") in
    let term =
      let+ environment_id = environment_id and+ thread_id = thread_id
      and+ broker_root = broker_root and+ generation = generation and+ message_ids = message_ids in
      output (fun () -> C2c_host_mailbox.ack ~environment_id ~thread_id ~broker_root
        ~generation ~message_ids) in
    Cmd.v (Cmd.info "ack" ~doc:"Archive and remove only selected accepted IDs; JSON response.") term in
  Cmd.group (Cmd.info "host" ~doc:"Host-owned durable mailboxes (JSON transport v1).")
    [bind; peek; send;
     ack; operation "unbind" "Release registration, retaining pending messages; JSON response." C2c_host_mailbox.unbind]
