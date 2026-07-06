(* test_c2c_hook_codex — end-to-end tests for `c2c hook codex` (#5).

   Spawns the freshly-built c2c.exe with a hermetic env (env -i) against a
   temp broker root, feeding codex hook payloads on stdin and asserting on
   the hookSpecificOutput JSON contract:
   - registered session + queued message -> drained + emitted
   - empty inbox -> empty stdout, exit 0
   - unregistered session -> auto-register + onboarding context (once)
   - installer alias hint -> unifies with the MCP-server registration
   - deferrable messages held on PostToolUse, delivered on UserPromptSubmit
   - malformed / missing-event payloads -> exit 0, empty stdout *)

open Alcotest

let ( // ) = Filename.concat

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec at i = i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1)) in
    at 0

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let mkdir_p path =
  let rec loop p =
    if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      Unix.mkdir p 0o755
    end
  in
  if path <> "" && path <> Filename.dirname path then loop path

let read_file path =
  if not (Sys.file_exists path) then ""
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      really_input_string ic (in_channel_length ic))

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)

(* c2c.exe lives next to this test executable under _build. *)
let c2c_binary = Filename.dirname Sys.executable_name // "c2c.exe"

type env_ctx = { home : string; broker_root : string; global_root : string }

let with_ctx f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-hook-codex-%08x" (Random.bits ()) in
  let home = dir // "home" in
  let broker_root = dir // "broker" in
  let global_root = dir // "global-broker" in
  mkdir_p home;
  mkdir_p broker_root;
  mkdir_p global_root;
  Fun.protect
    ~finally:(fun () -> try remove_tree dir with _ -> ())
    (fun () -> f { home; broker_root; global_root })

(* Run `c2c hook codex` hermetically: env -i wipes any ambient
   CLAUDE_*/C2C_* identity leaking in from the session running the tests. *)
let run_hook ctx ~payload =
  let dir = Filename.dirname ctx.home in
  let payload_path = dir // "payload.json" in
  let out_path = dir // "hook.out" in
  let err_path = dir // "hook.err" in
  write_file payload_path payload;
  let cmd =
    Printf.sprintf
      "env -i HOME=%s PATH=%s C2C_MCP_BROKER_ROOT=%s C2C_SESSIONS_BROKER_ROOT=%s %s hook codex < %s > %s 2> %s"
      (Filename.quote ctx.home)
      (Filename.quote (Sys.getenv "PATH"))
      (Filename.quote ctx.broker_root)
      (Filename.quote ctx.global_root)
      (Filename.quote c2c_binary)
      (Filename.quote payload_path)
      (Filename.quote out_path)
      (Filename.quote err_path)
  in
  let rc = Sys.command cmd in
  (rc, read_file out_path, read_file err_path)

let payload ?(event = "PostToolUse") ?(session_id = "") ?(cwd = "/tmp") () =
  let fields =
    [ ("hook_event_name", `String event); ("cwd", `String cwd) ]
    @ (if session_id = "" then [] else [ ("session_id", `String session_id) ])
  in
  Yojson.Safe.to_string (`Assoc fields)

let parse_context stdout =
  match Yojson.Safe.from_string (String.trim stdout) with
  | `Assoc fields ->
      (match List.assoc_opt "hookSpecificOutput" fields with
       | Some (`Assoc hso) ->
           let event =
             match List.assoc_opt "hookEventName" hso with
             | Some (`String e) -> e
             | _ -> ""
           in
           let ctx =
             match List.assoc_opt "additionalContext" hso with
             | Some (`String c) -> c
             | _ -> ""
           in
           Some (event, ctx)
       | _ -> None)
  | _ -> None
  | exception _ -> None

let broker ctx = C2c_mcp.Broker.create ~root:ctx.broker_root

let register ctx ~session_id ~alias =
  let b = broker ctx in
  let pid = Some (Unix.getpid ()) in
  let pid_start_time = C2c_mcp.Broker.capture_pid_start_time pid in
  C2c_mcp.Broker.register b ~session_id ~alias ~pid ~pid_start_time
    ~client_type:(Some "codex") ();
  b

(* --- tests -------------------------------------------------------------------- *)

let test_registered_session_drains_message () =
  with_ctx (fun ctx ->
    let sid = "codex-e2e-session-0001" in
    let b = register ctx ~session_id:sid ~alias:"zz-codex-e2e-recv" in
    ignore
      (register ctx ~session_id:"codex-e2e-peer-0001" ~alias:"zz-codex-e2e-peer");
    C2c_mcp.Broker.enqueue_message b ~from_alias:"zz-codex-e2e-peer"
      ~to_alias:"zz-codex-e2e-recv" ~content:"hello from peer" ();
    let rc, stdout, stderr = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "exit 0" 0 rc;
    (match parse_context stdout with
     | Some (event, context) ->
         check string "hookEventName mirrors payload" "PostToolUse" event;
         check bool "c2c envelope present" true
           (contains ~haystack:context ~needle:"<c2c");
         check bool "message body present" true
           (contains ~haystack:context ~needle:"hello from peer")
     | None ->
         failf "expected hookSpecificOutput JSON, got: %S (stderr: %S)" stdout
           stderr);
    (* Drained: second fire yields nothing. *)
    let rc2, stdout2, _ = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "second fire exit 0" 0 rc2;
    check string "second fire empty stdout" "" (String.trim stdout2))

let test_empty_inbox_emits_nothing () =
  with_ctx (fun ctx ->
    let sid = "codex-e2e-session-0002" in
    ignore (register ctx ~session_id:sid ~alias:"zz-codex-e2e-quiet");
    let rc, stdout, _ = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "exit 0" 0 rc;
    check string "empty stdout" "" (String.trim stdout))

let test_unregistered_session_auto_registers_once () =
  with_ctx (fun ctx ->
    let sid = "codex-e2e-vanilla-0003" in
    let rc, stdout, stderr = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "exit 0" 0 rc;
    (* Registration landed with client_type codex. *)
    let regs = C2c_mcp.Broker.list_registrations (broker ctx) in
    let reg =
      List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = sid) regs
    in
    (match reg with
     | None -> failf "expected auto-registration for %s (stderr: %S)" sid stderr
     | Some r ->
         check (option string) "client_type" (Some "codex") r.client_type;
         (* Onboarding context names the alias and the key commands. *)
         (match parse_context stdout with
          | Some (_, context) ->
              check bool "mentions alias" true
                (contains ~haystack:context ~needle:r.alias);
              check bool "mentions wait-inbox" true
                (contains ~haystack:context ~needle:"wait-inbox");
              check bool "mentions send" true
                (contains ~haystack:context ~needle:"c2c send")
          | None -> failf "expected onboarding output, got: %S" stdout));
    (* Statefile persisted so plain `c2c` CLI calls resolve this identity. *)
    let statefile = read_file (ctx.broker_root // "default-session.json") in
    check bool "statefile references session" true
      (contains ~haystack:statefile ~needle:sid);
    (* Loop guard: second fire resolves the existing registration — no second
       onboarding, no duplicate registration. *)
    let rc2, stdout2, _ = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "second fire exit 0" 0 rc2;
    check string "second fire quiet" "" (String.trim stdout2);
    let regs2 = C2c_mcp.Broker.list_registrations (broker ctx) in
    check int "registration count stable" (List.length regs) (List.length regs2))

let test_installer_alias_hint_unifies_identity () =
  with_ctx (fun ctx ->
    (* Simulate `c2c install codex` + a running MCP server that registered
       the pinned alias under its own session id. *)
    let mcp_sid = "codex-mcp-derived-0004" in
    let alias = "zz-codex-e2e-hinted" in
    let b = register ctx ~session_id:mcp_sid ~alias in
    ignore (register ctx ~session_id:"codex-e2e-peer-0004" ~alias:"zz-codex-e2e-peer4");
    mkdir_p (ctx.home // ".codex");
    write_file (ctx.home // ".codex" // "config.toml")
      (Printf.sprintf
         "[mcp_servers.c2c]\ncommand = \"c2c-mcp-server\"\n\n[mcp_servers.c2c.env]\nC2C_MCP_AUTO_REGISTER_ALIAS = \"%s\"\n"
         alias);
    C2c_mcp.Broker.enqueue_message b ~from_alias:"zz-codex-e2e-peer4"
      ~to_alias:alias ~content:"for the hinted alias" ();
    (* Payload sid is a fresh codex thread id with NO registration: the hook
       must unify with the alias-hint registration instead of forking a new
       identity. *)
    let rc, stdout, stderr =
      run_hook ctx ~payload:(payload ~session_id:"codex-thread-fresh-0004" ())
    in
    check int "exit 0" 0 rc;
    (match parse_context stdout with
     | Some (_, context) ->
         check bool "drained the hinted alias' message" true
           (contains ~haystack:context ~needle:"for the hinted alias")
     | None ->
         failf "expected drained message via alias hint, got: %S (stderr %S)"
           stdout stderr);
    let regs = C2c_mcp.Broker.list_registrations (broker ctx) in
    check bool "no forked registration for the thread id" false
      (List.exists
         (fun (r : C2c_mcp.registration) -> r.session_id = "codex-thread-fresh-0004")
         regs))

let test_deferrable_held_until_turn_boundary () =
  with_ctx (fun ctx ->
    let sid = "codex-e2e-session-0005" in
    let b = register ctx ~session_id:sid ~alias:"zz-codex-e2e-defer" in
    ignore (register ctx ~session_id:"codex-e2e-peer-0005" ~alias:"zz-codex-e2e-peer5");
    C2c_mcp.Broker.enqueue_message b ~from_alias:"zz-codex-e2e-peer5"
      ~to_alias:"zz-codex-e2e-defer" ~content:"no rush" ~deferrable:true ();
    (* Mid-turn PostToolUse: deferrable message must stay queued. *)
    let rc, stdout, _ = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "post-tool exit 0" 0 rc;
    check string "post-tool holds deferrable" "" (String.trim stdout);
    (* Turn boundary UserPromptSubmit: deferrable message is delivered. *)
    let rc2, stdout2, stderr2 =
      run_hook ctx ~payload:(payload ~event:"UserPromptSubmit" ~session_id:sid ())
    in
    check int "ups exit 0" 0 rc2;
    (match parse_context stdout2 with
     | Some (event, context) ->
         check string "hookEventName is UserPromptSubmit" "UserPromptSubmit" event;
         check bool "deferrable delivered" true
           (contains ~haystack:context ~needle:"no rush")
     | None ->
         failf "expected deferrable delivery on UserPromptSubmit, got: %S (stderr %S)"
           stdout2 stderr2))

let test_session_start_wake_note () =
  with_ctx (fun ctx ->
    let sid = "codex-e2e-session-0006" in
    ignore (register ctx ~session_id:sid ~alias:"zz-codex-e2e-wake");
    let rc, stdout, stderr =
      run_hook ctx ~payload:(payload ~event:"SessionStart" ~session_id:sid ())
    in
    check int "exit 0" 0 rc;
    (match parse_context stdout with
     | Some (event, context) ->
         check string "hookEventName is SessionStart" "SessionStart" event;
         check bool "wake note names alias" true
           (contains ~haystack:context ~needle:"zz-codex-e2e-wake")
     | None -> failf "expected SessionStart wake note, got: %S (stderr %S)" stdout stderr))

let test_malformed_payloads_are_silent () =
  with_ctx (fun ctx ->
    List.iter
      (fun bad ->
        let rc, stdout, _ = run_hook ctx ~payload:bad in
        check int (Printf.sprintf "exit 0 for %S" bad) 0 rc;
        check string (Printf.sprintf "empty stdout for %S" bad) ""
          (String.trim stdout))
      [ "not json at all"
      ; "{\"no_event\": true}"
      ; "{\"hook_event_name\": \"Stop\", \"session_id\": \"codex-e2e-x\"}"
      ; ""
      ; "{\"hook_event_name\": \"PostToolUse\"}"
      ])

let () =
  Random.self_init ();
  run "c2c_hook_codex"
    [ ( "hook-codex"
      , [ test_case "registered session drains message" `Quick
            test_registered_session_drains_message
        ; test_case "empty inbox emits nothing" `Quick test_empty_inbox_emits_nothing
        ; test_case "auto-register once + onboarding" `Quick
            test_unregistered_session_auto_registers_once
        ; test_case "installer alias hint unifies identity" `Quick
            test_installer_alias_hint_unifies_identity
        ; test_case "deferrable held until turn boundary" `Quick
            test_deferrable_held_until_turn_boundary
        ; test_case "session-start wake note" `Quick test_session_start_wake_note
        ; test_case "malformed payloads are silent" `Quick
            test_malformed_payloads_are_silent
        ] )
    ]
