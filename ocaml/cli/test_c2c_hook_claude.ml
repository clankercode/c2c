(* test_c2c_hook_claude — end-to-end tests for `c2c hook claude`
   (claude-session-hooks slice).

   Spawns the freshly-built c2c.exe with a hermetic env (env -i) against a
   temp broker root, feeding Claude Code hook payloads on stdin and asserting
   on the hookSpecificOutput JSON contract:
   - SessionStart vanilla session -> auto-register payload sid + onboarding
   - env-first resolution: C2C_MCP_SESSION_ID registration wins, payload UUID
     never forks a duplicate registration
   - env sid present but unregistered -> silent (MCP server owns registration)
   - subagent-quiet guard (C2C_NO_AUTO_REGISTER=1) -> silent, no registration
   - SessionEnd deregisters claude-hook auto-registrations ONLY
   - SessionStart source=compact -> post-compact context block
   - cold-boot context once per session (marker)
   - malformed / unhandled-event payloads -> exit 0, empty stdout *)

open Alcotest

let ( // ) = Filename.concat

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec at i = i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1)) in
    at 0

let alias_looks_generated_for_claude alias =
  match String.split_on_char '-' alias with
  | [ "claude"; w1; w2; suffix ] ->
      w1 <> "" && w2 <> "" && String.length suffix = 4
  | _ -> false

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
  let dir = base // Printf.sprintf "c2c-hook-claude-%08x" (Random.bits ()) in
  let home = dir // "home" in
  let broker_root = dir // "broker" in
  let global_root = dir // "global-broker" in
  mkdir_p home;
  mkdir_p broker_root;
  mkdir_p global_root;
  Fun.protect
    ~finally:(fun () -> try remove_tree dir with _ -> ())
    (fun () -> f { home; broker_root; global_root })

(* Run `c2c hook claude` hermetically: env -i wipes any ambient
   CLAUDE_*/C2C_* identity leaking in from the session running the tests.
   [extra_env] appends KEY=VALUE pairs (e.g. C2C_MCP_SESSION_ID). *)
let run_hook ?(extra_env = []) ctx ~payload =
  let dir = Filename.dirname ctx.home in
  let payload_path = dir // "payload.json" in
  let out_path = dir // "hook.out" in
  let err_path = dir // "hook.err" in
  write_file payload_path payload;
  let extra =
    String.concat " "
      (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (Filename.quote v)) extra_env)
  in
  let cmd =
    Printf.sprintf
      "env -i HOME=%s PATH=%s C2C_MCP_BROKER_ROOT=%s C2C_SESSIONS_BROKER_ROOT=%s %s %s hook claude < %s > %s 2> %s"
      (Filename.quote ctx.home)
      (Filename.quote (Sys.getenv "PATH"))
      (Filename.quote ctx.broker_root)
      (Filename.quote ctx.global_root)
      extra
      (Filename.quote c2c_binary)
      (Filename.quote payload_path)
      (Filename.quote out_path)
      (Filename.quote err_path)
  in
  let rc = Sys.command cmd in
  (rc, read_file out_path, read_file err_path)

let payload ?(event = "SessionStart") ?(session_id = "") ?(cwd = "/tmp") ?source () =
  let fields =
    [ ("hook_event_name", `String event); ("cwd", `String cwd) ]
    @ (if session_id = "" then [] else [ ("session_id", `String session_id) ])
    @ (match source with Some s -> [ ("source", `String s) ] | None -> [])
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

let register ?(pid = Some (Unix.getpid ())) ?(from_auto_gen = false) ctx
    ~session_id ~alias =
  let b = broker ctx in
  let pid_start_time = C2c_mcp.Broker.capture_pid_start_time pid in
  C2c_mcp.Broker.register b ~session_id ~alias ~pid ~pid_start_time
    ~client_type:(Some "claude") ~from_auto_gen ();
  b

let find_reg ctx sid =
  C2c_mcp.Broker.list_registrations (broker ctx)
  |> List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = sid)

(* --- tests -------------------------------------------------------------------- *)

let test_vanilla_session_start_auto_registers_once () =
  with_ctx (fun ctx ->
    let sid = "claude-e2e-vanilla-0001" in
    let rc, stdout, stderr = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "exit 0" 0 rc;
    (match find_reg ctx sid with
     | None -> failf "expected auto-registration for %s (stderr: %S)" sid stderr
     | Some r ->
         check (option string) "client_type" (Some "claude") r.client_type;
         check (option string) "registered_by" (Some "claude-hook") r.registered_by;
         check bool "alias has generated claude shape" true
           (alias_looks_generated_for_claude r.alias);
         (match parse_context stdout with
          | Some (event, context) ->
              check string "hookEventName is SessionStart" "SessionStart" event;
              check bool "onboarding mentions alias" true
                (contains ~haystack:context ~needle:r.alias);
              check bool "onboarding shows the session id" true
                (contains ~haystack:context ~needle:sid);
              check bool "onboarding directs user to the /c2c skill" true
                (contains ~haystack:context ~needle:"`/c2c`");
              check bool "mentions wait-inbox" true
                (contains ~haystack:context ~needle:"wait-inbox");
              check bool "mentions send" true
                (contains ~haystack:context ~needle:"c2c send")
          | None -> failf "expected onboarding output, got: %S" stdout));
    (* Statefile persisted so plain `c2c` CLI calls resolve this identity. *)
    let statefile = read_file (ctx.broker_root // "default-session.json") in
    check bool "statefile references session" true
      (contains ~haystack:statefile ~needle:sid);
    (* Loop guard: second fire resolves the existing registration — wake note,
       no duplicate registration, no second onboarding. *)
    let regs = C2c_mcp.Broker.list_registrations (broker ctx) in
    let rc2, stdout2, _ = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "second fire exit 0" 0 rc2;
    let regs2 = C2c_mcp.Broker.list_registrations (broker ctx) in
    check int "registration count stable" (List.length regs) (List.length regs2);
    (match parse_context stdout2 with
     | Some (_, context) ->
         check bool "second fire is wake note, not onboarding" true
           (contains ~haystack:context ~needle:"connected as");
         check bool "no second onboarding" false
           (contains ~haystack:context ~needle:"now registered")
     | None -> failf "expected wake output on second fire, got: %S" stdout2))

let test_env_first_no_duplicate_registration () =
  with_ctx (fun ctx ->
    (* Managed session: C2C_MCP_SESSION_ID names an existing registration.
       The payload UUID must NOT get a second registration; queued messages
       for the managed identity are delivered. *)
    let managed_sid = "managed-claude-e2e-0001" in
    let payload_sid = "claude-e2e-uuid-0001" in
    let b = register ctx ~session_id:managed_sid ~alias:"zz-claude-e2e-managed" in
    ignore (register ctx ~session_id:"claude-e2e-peer-0001" ~alias:"zz-claude-e2e-peer");
    C2c_mcp.Broker.enqueue_message b ~from_alias:"zz-claude-e2e-peer"
      ~to_alias:"zz-claude-e2e-managed" ~content:"hello managed claude" ();
    let rc, stdout, stderr =
      run_hook ctx
        ~extra_env:[ ("C2C_MCP_SESSION_ID", managed_sid) ]
        ~payload:(payload ~session_id:payload_sid ())
    in
    check int "exit 0" 0 rc;
    check bool "no registration forked from payload UUID" true
      (find_reg ctx payload_sid = None);
    (match parse_context stdout with
     | Some (_, context) ->
         check bool "wake note names managed alias" true
           (contains ~haystack:context ~needle:"zz-claude-e2e-managed");
         check bool "wake note shows managed session id" true
           (contains ~haystack:context ~needle:managed_sid);
         check bool "wake note directs managed session to the /c2c skill" true
           (contains ~haystack:context ~needle:"`/c2c`");
         check bool "queued message delivered" true
           (contains ~haystack:context ~needle:"hello managed claude")
     | None ->
         failf "expected wake + message output, got: %S (stderr %S)" stdout stderr))

let test_env_sid_unregistered_blocks_auto_register () =
  with_ctx (fun ctx ->
    (* C2C_MCP_SESSION_ID set but not (yet) registered: the MCP server owns
       registration; the hook must stay silent and must not auto-register the
       payload UUID. *)
    let rc, stdout, _ =
      run_hook ctx
        ~extra_env:[ ("C2C_MCP_SESSION_ID", "managed-claude-e2e-notyet") ]
        ~payload:(payload ~session_id:"claude-e2e-uuid-0002" ())
    in
    check int "exit 0" 0 rc;
    check string "silent stdout" "" (String.trim stdout);
    check int "no registrations created" 0
      (List.length (C2c_mcp.Broker.list_registrations (broker ctx))))

let test_subagent_quiet_guard () =
  with_ctx (fun ctx ->
    let rc, stdout, _ =
      run_hook ctx
        ~extra_env:[ ("C2C_NO_AUTO_REGISTER", "1") ]
        ~payload:(payload ~session_id:"claude-e2e-subagent-0001" ())
    in
    check int "exit 0" 0 rc;
    check string "silent stdout" "" (String.trim stdout);
    check int "no registrations created" 0
      (List.length (C2c_mcp.Broker.list_registrations (broker ctx))))

(* B130: a dispatched Claude Code subagent inherits the parent session's env
   (including C2C_MCP_SESSION_ID) and fires the same c2c hooks. Claude Code
   marks such child processes with CLAUDE_CODE_CHILD_SESSION=1. The hook must
   treat that as a subagent context and stay silent — it must NOT drain/inject
   the owner session's queued DMs into the subagent's transcript. Regression
   for the inbox-leak where a coordinator DM surfaced inside an unrelated
   dispatched subagent. *)
let test_child_session_no_inbox_leak () =
  with_ctx (fun ctx ->
    let owner_sid = "managed-claude-e2e-b130-0001" in
    let b = register ctx ~session_id:owner_sid ~alias:"zz-claude-b130-owner" in
    ignore (register ctx ~session_id:"claude-e2e-b130-peer" ~alias:"zz-claude-b130-peer");
    C2c_mcp.Broker.enqueue_message b ~from_alias:"zz-claude-b130-peer"
      ~to_alias:"zz-claude-b130-owner" ~content:"secret coordinator DM" ();
    (* Subagent fires the hook: it resolves the owner identity via the inherited
       C2C_MCP_SESSION_ID env, but CLAUDE_CODE_CHILD_SESSION=1 marks it as a
       dispatched child. *)
    let rc, stdout, stderr =
      run_hook ctx
        ~extra_env:
          [ ("C2C_MCP_SESSION_ID", owner_sid)
          ; ("CLAUDE_CODE_CHILD_SESSION", "1")
          ]
        ~payload:(payload ~session_id:"claude-e2e-b130-subagent" ())
    in
    check int "exit 0" 0 rc;
    check string "subagent gets no injected context" "" (String.trim stdout);
    check bool "DM body must not leak into subagent stdout" false
      (contains ~haystack:stdout ~needle:"secret coordinator DM");
    (* The DM must remain undrained in the owner inbox for real delivery. *)
    let remaining = C2c_mcp.Broker.read_inbox b ~session_id:owner_sid in
    check int "owner DM not drained by subagent" 1 (List.length remaining);
    ignore stderr)

(* B130: unit-cover the canonical dispatched-subagent detector that every c2c
   hook / injection entrypoint now delegates to (hook_lib, MCP auto-register,
   standalone cold-boot + post-compact binaries). Locks both signals and the
   fail-safe parse (falsy spellings must never silence a top-level session). *)
let with_env_saved names f =
  let saved = List.map (fun n -> (n, Sys.getenv_opt n)) names in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (n, v) ->
          match v with Some s -> Unix.putenv n s | None -> Unix.putenv n "")
        saved)
    f

let test_is_subagent_context_signals () =
  with_env_saved [ "C2C_NO_AUTO_REGISTER"; "CLAUDE_CODE_CHILD_SESSION" ] (fun () ->
    let set = Unix.putenv in
    let is () = C2c_mcp_helpers_post_broker.is_subagent_context () in
    set "C2C_NO_AUTO_REGISTER" "";
    set "CLAUDE_CODE_CHILD_SESSION" "";
    check bool "empty env is not a subagent" false (is ());
    set "CLAUDE_CODE_CHILD_SESSION" "1";
    check bool "CHILD_SESSION=1 is a subagent" true (is ());
    set "CLAUDE_CODE_CHILD_SESSION" "  TRUE  ";
    check bool "CHILD_SESSION=TRUE (padded) is a subagent" true (is ());
    List.iter
      (fun v ->
        set "CLAUDE_CODE_CHILD_SESSION" v;
        check bool
          (Printf.sprintf "CHILD_SESSION=%S is not a subagent" v)
          false (is ()))
      [ "0"; "false"; "no"; "off"; "" ];
    set "CLAUDE_CODE_CHILD_SESSION" "";
    set "C2C_NO_AUTO_REGISTER" "1";
    check bool "C2C_NO_AUTO_REGISTER=1 is a subagent" true (is ()))

let test_session_end_deregisters_hook_auto_registration () =
  with_ctx (fun ctx ->
    let sid = "claude-e2e-session-end-0001" in
    let rc, _, stderr = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "auto-register exit 0" 0 rc;
    check bool "auto-registration exists before SessionEnd" true
      (find_reg ctx sid <> None);
    let rc2, stdout2, stderr2 =
      run_hook ctx ~payload:(payload ~event:"SessionEnd" ~session_id:sid ())
    in
    check int "SessionEnd exits 0" 0 rc2;
    check string "SessionEnd stdout is quiet" "" (String.trim stdout2);
    check bool
      (Printf.sprintf "auto-registration removed (stderr before=%S after=%S)"
         stderr stderr2)
      true
      (find_reg ctx sid = None))

let test_session_end_keeps_explicit_registration () =
  with_ctx (fun ctx ->
    let sid = "claude-e2e-session-end-explicit" in
    ignore (register ctx ~session_id:sid ~alias:"zz-claude-end-explicit");
    let rc, stdout, _ =
      run_hook ctx ~payload:(payload ~event:"SessionEnd" ~session_id:sid ())
    in
    check int "SessionEnd exits 0" 0 rc;
    check string "SessionEnd stdout is quiet" "" (String.trim stdout);
    check bool "explicit registration remains" true (find_reg ctx sid <> None))

let test_session_start_wake_note_and_cold_boot_once () =
  with_ctx (fun ctx ->
    let sid = "claude-e2e-session-0006" in
    ignore (register ctx ~session_id:sid ~alias:"zz-claude-e2e-wake");
    let rc, stdout, stderr = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "exit 0" 0 rc;
    (match parse_context stdout with
     | Some (event, context) ->
         check string "hookEventName is SessionStart" "SessionStart" event;
         check bool "wake note names alias" true
           (contains ~haystack:context ~needle:"zz-claude-e2e-wake");
         check bool "wake note shows the session id" true
           (contains ~haystack:context ~needle:sid);
         check bool "wake note directs user to the /c2c skill" true
           (contains ~haystack:context ~needle:"`/c2c`");
         check bool "cold-boot context on first start" true
           (contains ~haystack:context ~needle:"kind=\"cold-boot\"")
     | None ->
         failf "expected SessionStart wake note, got: %S (stderr %S)" stdout stderr);
    (* Second SessionStart: marker set -> no cold-boot block. *)
    let rc2, stdout2, _ = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "second fire exit 0" 0 rc2;
    (match parse_context stdout2 with
     | Some (_, context) ->
         check bool "cold-boot emitted once only" false
           (contains ~haystack:context ~needle:"kind=\"cold-boot\"")
     | None -> ()))

let test_hook_adopts_mcp_first_registration () =
  (* B119 reverse direction: when the MCP server registered the payload
     session_id FIRST (pid set, registered_by=None), a later SessionStart
     hook fire must ADOPT that identity — wake note with the existing
     alias, no re-register, no alias clobber. *)
  with_ctx (fun ctx ->
    let sid = "claude-e2e-b119-rev-0001" in
    ignore (register ctx ~session_id:sid ~alias:"zz-claude-e2e-mcpfirst");
    let rc, stdout, stderr = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "exit 0" 0 rc;
    let regs = C2c_mcp.Broker.list_registrations (broker ctx) in
    check int "no duplicate registration" 1 (List.length regs);
    (match find_reg ctx sid with
     | None -> failf "registration vanished (stderr: %S)" stderr
     | Some r ->
         check string "alias preserved (hook adopted, did not clobber)"
           "zz-claude-e2e-mcpfirst" r.alias;
         check (option string) "not converted to a hook registration"
           None r.registered_by);
    (match parse_context stdout with
     | Some (_, context) ->
         check bool "wake note names the adopted alias" true
           (contains ~haystack:context ~needle:"zz-claude-e2e-mcpfirst")
     | None -> failf "expected wake note, got: %S" stdout))

let test_compact_source_emits_post_compact_context () =
  with_ctx (fun ctx ->
    let sid = "claude-e2e-compact-0001" in
    ignore (register ctx ~session_id:sid ~alias:"zz-claude-e2e-compact");
    let repo = Filename.dirname ctx.home // "repo" in
    mkdir_p repo;
    let rc, stdout, stderr =
      run_hook ctx
        ~extra_env:[ ("C2C_REPO_ROOT", repo) ]
        ~payload:(payload ~session_id:sid ~source:"compact" ())
    in
    check int "exit 0" 0 rc;
    (match parse_context stdout with
     | Some (_, context) ->
         check bool "post-compact context block present" true
           (contains ~haystack:context ~needle:"kind=\"post-compact\"");
         check bool "reflex reminder present" true
           (contains ~haystack:context ~needle:"READ-ONLY")
     | None ->
         failf "expected post-compact output, got: %S (stderr %S)" stdout stderr))

let test_non_compact_source_no_post_compact_context () =
  with_ctx (fun ctx ->
    let sid = "claude-e2e-startup-0001" in
    ignore (register ctx ~session_id:sid ~alias:"zz-claude-e2e-startup");
    let repo = Filename.dirname ctx.home // "repo" in
    mkdir_p repo;
    let rc, stdout, _ =
      run_hook ctx
        ~extra_env:[ ("C2C_REPO_ROOT", repo) ]
        ~payload:(payload ~session_id:sid ~source:"startup" ())
    in
    check int "exit 0" 0 rc;
    (match parse_context stdout with
     | Some (_, context) ->
         check bool "no post-compact block on startup" false
           (contains ~haystack:context ~needle:"kind=\"post-compact\"")
     | None -> ()))

let test_session_start_refreshes_claude_skill () =
  with_ctx (fun ctx ->
    let sid = "claude-e2e-skill-0001" in
    let skill_path = ctx.home // ".claude" // "skills" // "c2c" // "SKILL.md" in
    check bool "skill absent before hook" false (Sys.file_exists skill_path);
    let rc, _, _ = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "exit 0" 0 rc;
    check bool "skill written by SessionStart hook" true (Sys.file_exists skill_path))

let test_malformed_and_unhandled_payloads_are_silent () =
  with_ctx (fun ctx ->
    List.iter
      (fun bad ->
        let rc, stdout, _ = run_hook ctx ~payload:bad in
        check int (Printf.sprintf "exit 0 for %S" bad) 0 rc;
        check string (Printf.sprintf "empty stdout for %S" bad) ""
          (String.trim stdout))
      [ "not json at all"
      ; "{\"no_event\": true}"
      ; "{\"hook_event_name\": \"Stop\", \"session_id\": \"claude-e2e-x\"}"
      ; "{\"hook_event_name\": \"PostToolUse\", \"session_id\": \"claude-e2e-x\"}"
      ; "{\"hook_event_name\": \"UserPromptSubmit\", \"session_id\": \"claude-e2e-x\"}"
      ; ""
      ; "{\"hook_event_name\": \"SessionStart\"}"
      ];
    check int "no registrations created" 0
      (List.length (C2c_mcp.Broker.list_registrations (broker ctx))))

let () =
  Random.self_init ();
  run "c2c_hook_claude"
    [ ( "hook-claude"
      , [ test_case "vanilla SessionStart auto-registers once + onboarding" `Quick
            test_vanilla_session_start_auto_registers_once
        ; test_case "env-first: managed identity wins, no duplicate" `Quick
            test_env_first_no_duplicate_registration
        ; test_case "env sid unregistered blocks auto-register" `Quick
            test_env_sid_unregistered_blocks_auto_register
        ; test_case "subagent-quiet guard" `Quick test_subagent_quiet_guard
        ; test_case "B130: CLAUDE_CODE_CHILD_SESSION subagent no inbox leak" `Quick
            test_child_session_no_inbox_leak
        ; test_case "B130: is_subagent_context signals + fail-safe parse" `Quick
            test_is_subagent_context_signals
        ; test_case "SessionEnd deregisters hook auto-registration" `Quick
            test_session_end_deregisters_hook_auto_registration
        ; test_case "SessionEnd keeps explicit registration" `Quick
            test_session_end_keeps_explicit_registration
        ; test_case "SessionStart wake note + cold-boot once" `Quick
            test_session_start_wake_note_and_cold_boot_once
        ; test_case "hook adopts MCP-first registration (B119 reverse)" `Quick
            test_hook_adopts_mcp_first_registration
        ; test_case "compact source emits post-compact context" `Quick
            test_compact_source_emits_post_compact_context
        ; test_case "non-compact source has no post-compact context" `Quick
            test_non_compact_source_no_post_compact_context
        ; test_case "SessionStart refreshes claude skill" `Quick
            test_session_start_refreshes_claude_skill
        ; test_case "malformed / unhandled payloads are silent" `Quick
            test_malformed_and_unhandled_payloads_are_silent
        ] )
    ]
