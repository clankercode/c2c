(* test_c2c_hook_muse — end-to-end tests for `c2c hook muse` (B355).

   Spawns the freshly-built c2c.exe with a hermetic env (env -i) against a
   temp broker root, feeding Muse hook payloads (B352 A2 shapes) on stdin
   and asserting on the hookSpecificOutput JSON contract:
   - SessionStart vanilla -> auto-register payload sid (muse-hook) + onboarding
   - second SessionStart -> wake note, no duplicate registration
   - SessionStart drains backlog into additionalContext
   - env-first resolution: C2C_MCP_SESSION_ID / MUSE_SESSION_ID win
   - managed marker -> registered_by None; SessionEnd spares managed rows
   - Stop / PostToolUse -> touch-only: anchor advances, row survives, silent
   - PostToolUse under an unknown (subagent) sid mints no row (ignore)
   - SessionEnd deregisters muse-hook rows ONLY; Stop is never teardown (#61)
   - B130 defensive agent_id gate: no register, no drain
   - subagent-quiet guard (C2C_NO_AUTO_REGISTER=1) -> silent, no registration
   - malformed / invalid-sid / unhandled-event payloads -> exit 0, silent
   - camelCase spellings accepted (hookEventName / sessionId)
   - vanilla run from a workspace cwd lands in the workspace broker (no chdir) *)

open Alcotest

let ( // ) = Filename.concat

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec at i = i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1)) in
    at 0

let alias_looks_generated_for_muse alias =
  match String.split_on_char '-' alias with
  | [ "muse"; w1; w2; suffix ] ->
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
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)

(* c2c.exe lives next to this test executable under _build. *)
let c2c_binary = Filename.dirname Sys.executable_name // "c2c.exe"

type env_ctx = { dir : string; home : string; broker_root : string; global_root : string }

let with_ctx f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-hook-muse-%08x" (Random.bits ()) in
  let home = dir // "home" in
  let broker_root = dir // "broker" in
  let global_root = dir // "global-broker" in
  mkdir_p home;
  mkdir_p broker_root;
  mkdir_p global_root;
  Fun.protect
    ~finally:(fun () -> try remove_tree dir with _ -> ())
    (fun () -> f { dir; home; broker_root; global_root })

(* Run `c2c hook muse` hermetically: env -i wipes any ambient identity
   leaking in from the session running the tests. *)
let run_hook ?(extra_env = []) ctx ~payload =
  let payload_path = ctx.dir // "payload.json" in
  let out_path = ctx.dir // "hook.out" in
  let err_path = ctx.dir // "hook.err" in
  write_file payload_path payload;
  let extra =
    String.concat " "
      (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (Filename.quote v)) extra_env)
  in
  let cmd =
    Printf.sprintf
      "env -i HOME=%s PATH=%s C2C_MCP_BROKER_ROOT=%s C2C_SESSIONS_BROKER_ROOT=%s %s %s hook muse < %s > %s 2> %s"
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

(* B352 A2 SessionStart shape (+ optional agent_id / camelCase variants). *)
let payload ?(event = "SessionStart") ?(session_id = "") ?(cwd = "/tmp/proj")
    ?agent_id ?(camel = false) ?turn_id () =
  let event_key, sid_key =
    if camel then ("hookEventName", "sessionId") else ("hook_event_name", "session_id")
  in
  let fields =
    [ (event_key, `String event)
    ; ("cwd", `String cwd)
    ; ("model", `String "unknown")
    ; ("permission_mode", `String "default")
    ]
    @ (if session_id = "" then [] else [ (sid_key, `String session_id) ])
    @ (match agent_id with Some a -> [ ("agent_id", `String a) ] | None -> [])
    @ (match turn_id with Some t -> [ ("turn_id", `String t) ] | None -> [])
  in
  Yojson.Safe.to_string (`Assoc fields)

let parse_context stdout =
  match Yojson.Safe.from_string (String.trim stdout) with
  | `Assoc fields -> (
      match List.assoc_opt "hookSpecificOutput" fields with
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

let find_reg ctx sid =
  C2c_mcp.Broker.list_registrations (broker ctx)
  |> List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = sid)

let count_regs ctx = List.length (C2c_mcp.Broker.list_registrations (broker ctx))

(* --- tests ------------------------------------------------------------ *)

let test_session_start_registers_with_onboarding () =
  with_ctx (fun ctx ->
    let sid = "muse-e2e-vanilla-0001" in
    let rc, stdout, stderr =
      run_hook ctx ~payload:(payload ~session_id:sid ~cwd:"/tmp/muse-proj" ())
    in
    check int "exit 0" 0 rc;
    (match find_reg ctx sid with
     | None -> failf "expected auto-registration for %s (stderr: %S)" sid stderr
     | Some r ->
         check (option string) "client_type" (Some "muse") r.client_type;
         check (option string) "registered_by" (Some "muse-hook") r.registered_by;
         check bool "alias has generated muse shape" true
           (alias_looks_generated_for_muse r.alias);
         check (option string) "payload cwd recorded" (Some "/tmp/muse-proj") r.cwd;
         (match parse_context stdout with
          | Some (event, context) ->
              check string "hookEventName is SessionStart" "SessionStart" event;
              check bool "onboarding mentions alias" true
                (contains ~haystack:context ~needle:r.alias);
              check bool "onboarding shows the session id" true
                (contains ~haystack:context ~needle:sid);
              check bool "mentions wait-inbox" true
                (contains ~haystack:context ~needle:"wait-inbox");
              check bool "mentions send" true
                (contains ~haystack:context ~needle:"c2c send");
              (* Delivery honesty (B355 review): must NOT claim automatic
                 mid-session delivery — muse hooks are touch-only (B352 D1). *)
              check bool "honest: no automatic mid-session delivery" true
                (contains ~haystack:context
                   ~needle:"does NOT arrive automatically");
              check bool "honest: points at poll-inbox" true
                (contains ~haystack:context ~needle:"c2c poll-inbox")
          | None -> failf "expected onboarding output, got: %S" stdout));
    (* Statefile persisted so plain `c2c` CLI calls resolve this identity. *)
    let statefile = read_file (ctx.broker_root // "default-session.json") in
    check bool "statefile references session" true
      (contains ~haystack:statefile ~needle:sid))

let test_second_session_start_is_wake_no_duplicate () =
  with_ctx (fun ctx ->
    let sid = "muse-e2e-wake-0001" in
    let rc1, _, stderr1 = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "first fire exit 0" 0 rc1;
    (match find_reg ctx sid with
     | None -> failf "first fire registered nothing (stderr: %S)" stderr1
     | Some _ -> ());
    let n_before = count_regs ctx in
    let rc2, stdout2, _ = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "second fire exit 0" 0 rc2;
    check int "registration count stable" n_before (count_regs ctx);
    (match parse_context stdout2 with
     | Some (_, context) ->
         check bool "second fire is wake note, not onboarding" true
           (contains ~haystack:context ~needle:"connected as");
         check bool "no second onboarding" false
           (contains ~haystack:context ~needle:"now registered");
         check bool "wake is honest about mid-session delivery" true
           (contains ~haystack:context ~needle:"does NOT arrive automatically")
     | None -> failf "expected wake output on second fire, got: %S" stdout2))

let test_session_start_drains_backlog () =
  with_ctx (fun ctx ->
    let sid = "muse-e2e-drain-0001" in
    let peer_sid = "muse-e2e-drain-peer" in
    let b = broker ctx in
    C2c_mcp.Broker.register b ~session_id:peer_sid ~alias:"zz-muse-drain-peer"
      ~pid:None ~pid_start_time:None ~client_type:(Some "muse") ();
    C2c_mcp.Broker.register b ~session_id:sid ~alias:"zz-muse-drain-self"
      ~pid:None ~pid_start_time:None ~client_type:(Some "muse")
      ~registered_by:(Some "muse-hook") ();
    C2c_mcp.Broker.enqueue_message b ~from_alias:"zz-muse-drain-peer"
      ~to_alias:"zz-muse-drain-self" ~content:"hello muse backlog" ();
    let rc, stdout, stderr = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "exit 0" 0 rc;
    (match parse_context stdout with
     | Some (_, context) ->
         check bool "backlog delivered" true
           (contains ~haystack:context ~needle:"hello muse backlog")
     | None -> failf "expected wake + message output, got: %S (stderr %S)" stdout stderr);
    check int "drain is destructive" 0
      (List.length (C2c_mcp.Broker.read_inbox b ~session_id:sid)))

(* B188/B191: a sid already registered on another broker fingerprint keeps
   its sticky alias instead of minting a fresh one. Seeded via
   C2C_BROKER_SCAN_DIRS (the test hook for the cross-broker scan). *)
let test_session_start_reuses_sticky_alias_across_repos () =
  with_ctx (fun ctx ->
    let sid = "muse-e2e-sticky-0001" in
    let other_root = ctx.dir // "other-repo" // "broker" in
    mkdir_p other_root;
    let ob = C2c_mcp.Broker.create ~root:other_root in
    C2c_mcp.Broker.register ob ~session_id:sid ~alias:"zz-muse-sticky-keep"
      ~pid:None ~pid_start_time:None ~client_type:(Some "muse")
      ~registered_by:(Some "muse-hook") ();
    let rc, stdout, stderr =
      run_hook ctx
        ~extra_env:[ ("C2C_BROKER_SCAN_DIRS", other_root) ]
        ~payload:(payload ~session_id:sid ())
    in
    check int "exit 0" 0 rc;
    (match find_reg ctx sid with
     | None -> failf "expected registration for %s (stderr: %S)" sid stderr
     | Some r ->
         check string "sticky alias reused, not minted" "zz-muse-sticky-keep"
           r.alias;
         check (option string) "registered_by" (Some "muse-hook") r.registered_by;
         (match parse_context stdout with
          | Some (_, context) ->
              check bool "onboarding names the sticky alias" true
                (contains ~haystack:context ~needle:"zz-muse-sticky-keep")
          | None -> failf "expected onboarding output, got: %S" stdout)))

(* The global sessions-broker drain arm: a regression there is swallowed by
   `with _ -> []`, so without this test it would be invisible (B355 review). *)
let test_session_start_drains_global_backlog () =
  with_ctx (fun ctx ->
    let sid = "muse-e2e-global-0001" in
    let b = broker ctx in
    C2c_mcp.Broker.register b ~session_id:sid ~alias:"zz-muse-global-self"
      ~pid:None ~pid_start_time:None ~client_type:(Some "muse")
      ~registered_by:(Some "muse-hook") ();
    let gb = C2c_mcp.Broker.create ~root:ctx.global_root in
    C2c_mcp.Broker.register gb ~session_id:sid ~alias:"zz-muse-global-self"
      ~pid:None ~pid_start_time:None ~client_type:(Some "muse") ();
    C2c_mcp.Broker.register gb ~session_id:"muse-e2e-global-peer"
      ~alias:"zz-muse-global-peer" ~pid:None ~pid_start_time:None
      ~client_type:(Some "muse") ();
    C2c_mcp.Broker.enqueue_message gb ~from_alias:"zz-muse-global-peer"
      ~to_alias:"zz-muse-global-self" ~content:"hello muse global backlog" ();
    let rc, stdout, stderr = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "exit 0" 0 rc;
    (match parse_context stdout with
     | Some (_, context) ->
         check bool "global backlog delivered" true
           (contains ~haystack:context ~needle:"hello muse global backlog")
     | None -> failf "expected wake + message output, got: %S (stderr %S)" stdout stderr);
    check int "global drain is destructive" 0
      (List.length (C2c_mcp.Broker.read_inbox gb ~session_id:sid)))

let test_env_first_no_duplicate_registration () =
  with_ctx (fun ctx ->
    (* Managed session: env names an existing registration. The payload sid
       must NOT get a second registration. *)
    let managed_sid = "muse-e2e-managed-0001" in
    let payload_sid = "muse-e2e-uuid-0001" in
    let b = broker ctx in
    C2c_mcp.Broker.register b ~session_id:managed_sid
      ~alias:"zz-muse-e2e-managed" ~pid:None ~pid_start_time:None
      ~client_type:(Some "muse") ();
    List.iter
      (fun env_key ->
        let rc, stdout, stderr =
          run_hook ctx
            ~extra_env:[ (env_key, managed_sid) ]
            ~payload:(payload ~session_id:payload_sid ())
        in
        check int (env_key ^ ": exit 0") 0 rc;
        check bool (env_key ^ ": no registration forked from payload sid") true
          (find_reg ctx payload_sid = None);
        (match parse_context stdout with
         | Some (_, context) ->
             check bool (env_key ^ ": wake note names managed alias") true
               (contains ~haystack:context ~needle:"zz-muse-e2e-managed")
         | None ->
             failf "%s: expected wake output, got: %S (stderr %S)" env_key stdout stderr))
      [ "C2C_MCP_SESSION_ID"; "MUSE_SESSION_ID" ])

(* #51 blocker 2 must not regress: with a managed launcher marker present the
   row carries NO hook label, so it is invisible to the SessionEnd teardown
   selector. Asserted for both markers. *)
let test_managed_marker_suppresses_hook_label () =
  List.iter
    (fun (marker, value) ->
      with_ctx (fun ctx ->
        let sid =
          if marker = "C2C_MCP_SESSION_ID" then value else "muse-e2e-mid-0001"
        in
        let rc, _, stderr =
          run_hook ctx ~payload:(payload ~session_id:sid ())
            ~extra_env:[ (marker, value) ]
        in
        check int (marker ^ ": exit 0") 0 rc;
        (match find_reg ctx sid with
         | None -> failf "%s: registered no row (stderr: %S)" marker stderr
         | Some row ->
             check bool (marker ^ ": managed row carries no hook label") true
               (row.registered_by = None));
        let rc2, _, _ =
          run_hook ctx ~payload:(payload ~event:"SessionEnd" ~session_id:sid ())
            ~extra_env:[ (marker, value) ]
        in
        check int (marker ^ ": SessionEnd exit 0") 0 rc2;
        check bool (marker ^ ": managed row survives SessionEnd") true
          (find_reg ctx sid <> None)))
    [ ("C2C_MCP_SESSION_ID", "muse-e2e-managed-0002")
    ; ("C2C_MCP_AUTO_REGISTER_ALIAS", "musetest-managed-qx42")
    ]

(* Seed one pid-less hook row whose anchor sits [age_s] in the past, as raw
   registry JSON so the backdated anchor is exactly what the hook must move. *)
let seed_hook_row ctx ~session_id ~alias ~registered_by ~age_s =
  let ts = Unix.gettimeofday () -. age_s in
  let row =
    `Assoc
      [ ("session_id", `String session_id)
      ; ("alias", `String alias)
      ; ("registered_at", `Float ts)
      ; ("last_activity_ts", `Float ts)
      ; ("client_type", `String "muse")
      ; ("registered_by", `String registered_by)
      ]
  in
  write_file (ctx.broker_root // "registry.json")
    (Yojson.Safe.to_string (`List [ row ]));
  ts

let read_anchor ctx ~session_id =
  match find_reg ctx session_id with
  | Some r -> r.last_activity_ts
  | None -> None

(* Stop is turn-end activity (#61): it must advance the anchor, keep the row
   addressable, and stay silent — never register, deregister, or drain. *)
let test_stop_touches_anchor_keeps_row_silent () =
  with_ctx (fun ctx ->
    let sid = "muse-e2e-stop-0001" in
    let before =
      seed_hook_row ctx ~session_id:sid ~alias:"zz-muse-stop-peer"
        ~registered_by:"muse-hook" ~age_s:3600.0
    in
    let n_before = count_regs ctx in
    let rc, stdout, _ =
      run_hook ctx
        ~payload:(payload ~event:"Stop" ~session_id:sid ~turn_id:"turn-1" ())
    in
    check int "Stop exit 0" 0 rc;
    check string "Stop stdout silent" "" (String.trim stdout);
    check bool "row survives Stop" true (find_reg ctx sid <> None);
    check int "Stop mints no row" n_before (count_regs ctx);
    (match read_anchor ctx ~session_id:sid with
     | None -> fail "anchor missing after Stop"
     | Some after ->
         check bool
           (Printf.sprintf "Stop advances anchor (before=%.3f after=%.3f)" before after)
           true (after > before +. 60.0)))

let test_repeated_stops_keep_row () =
  with_ctx (fun ctx ->
    let sid = "muse-e2e-stoprep-0001" in
    let rc1, _, stderr1 = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "SessionStart exit 0" 0 rc1;
    (match find_reg ctx sid with
     | None -> failf "SessionStart registered nothing (stderr: %S)" stderr1
     | Some _ -> ());
    for i = 1 to 3 do
      let rc, stdout, _ =
        run_hook ctx
          ~payload:
            (payload ~event:"Stop" ~session_id:sid
               ~turn_id:(Printf.sprintf "turn-%d" i) ())
      in
      check int (Printf.sprintf "Stop %d exit 0" i) 0 rc;
      check string (Printf.sprintf "Stop %d silent" i) "" (String.trim stdout);
      check bool (Printf.sprintf "row survives Stop %d" i) true
        (find_reg ctx sid <> None)
    done)

(* B352 U9: subagent tool calls arrive as PostToolUse under a DISTINCT
   session_id with no agent_id marker. Mid-session events never mint, so no
   subagent row is created (ignore); the touch of the unknown sid is a
   registry no-op. *)
let test_posttooluse_unknown_sid_mints_nothing () =
  with_ctx (fun ctx ->
    let subagent_sid = "muse-e2e-subagent-0001" in
    let rc, stdout, _ =
      run_hook ctx
        ~payload:
          (payload ~event:"PostToolUse" ~session_id:subagent_sid
             ~turn_id:subagent_sid ())
    in
    check int "exit 0" 0 rc;
    check string "silent" "" (String.trim stdout);
    check bool "no subagent row minted" true (find_reg ctx subagent_sid = None);
    check int "registry untouched" 0 (count_regs ctx))

let test_posttooluse_known_sid_touches_silently () =
  with_ctx (fun ctx ->
    let sid = "muse-e2e-ptu-0001" in
    let before =
      seed_hook_row ctx ~session_id:sid ~alias:"zz-muse-ptu-peer"
        ~registered_by:"muse-hook" ~age_s:3600.0
    in
    let rc, stdout, _ =
      run_hook ctx ~payload:(payload ~event:"PostToolUse" ~session_id:sid ())
    in
    check int "exit 0" 0 rc;
    check string "silent" "" (String.trim stdout);
    check bool "row survives PostToolUse" true (find_reg ctx sid <> None);
    (match read_anchor ctx ~session_id:sid with
     | None -> fail "anchor missing after PostToolUse"
     | Some after ->
         check bool "PostToolUse advances anchor" true (after > before +. 60.0)))

let test_session_end_deregisters_hook_owned_only () =
  with_ctx (fun ctx ->
    let hook_sid = "muse-e2e-end-0001" in
    let managed_sid = "muse-e2e-end-managed" in
    let b = broker ctx in
    C2c_mcp.Broker.register b ~session_id:managed_sid
      ~alias:"zz-muse-end-managed" ~pid:None ~pid_start_time:None
      ~client_type:(Some "muse") ();
    let rc1, _, stderr1 =
      run_hook ctx ~payload:(payload ~session_id:hook_sid ())
    in
    check int "SessionStart exit 0" 0 rc1;
    (match find_reg ctx hook_sid with
     | None -> failf "SessionStart registered nothing (stderr: %S)" stderr1
     | Some _ -> ());
    let rc2, stdout2, _ =
      run_hook ctx ~payload:(payload ~event:"SessionEnd" ~session_id:hook_sid ())
    in
    check int "SessionEnd exit 0" 0 rc2;
    check string "SessionEnd silent" "" (String.trim stdout2);
    check bool "hook row deregistered" true (find_reg ctx hook_sid = None);
    (* A managed (hook-label-free) row is invisible to the teardown selector. *)
    let rc3, _, _ =
      run_hook ctx
        ~payload:(payload ~event:"SessionEnd" ~session_id:managed_sid ())
    in
    check int "managed SessionEnd exit 0" 0 rc3;
    check bool "managed row survives SessionEnd" true
      (find_reg ctx managed_sid <> None))

(* B130 defensive gate: a non-empty stdin agent_id (no muse ships it today)
   must suppress onboarding AND drain, so owner DMs never leak into a
   subagent transcript. *)
let test_agent_id_gate_no_register_no_drain () =
  with_ctx (fun ctx ->
    let owner_sid = "muse-e2e-b130-owner" in
    let b = broker ctx in
    C2c_mcp.Broker.register b ~session_id:owner_sid ~alias:"zz-muse-b130-owner"
      ~pid:None ~pid_start_time:None ~client_type:(Some "muse")
      ~registered_by:(Some "muse-hook") ();
    C2c_mcp.Broker.register b ~session_id:"muse-e2e-b130-peer"
      ~alias:"zz-muse-b130-peer" ~pid:None ~pid_start_time:None
      ~client_type:(Some "muse") ();
    C2c_mcp.Broker.enqueue_message b ~from_alias:"zz-muse-b130-peer"
      ~to_alias:"zz-muse-b130-owner" ~content:"owner-private-dm" ();
    let fresh_sid = "muse-e2e-b130-fresh" in
    let rc, stdout, _ =
      run_hook ctx
        ~payload:(payload ~session_id:fresh_sid ~agent_id:"subagent-1" ())
    in
    check int "exit 0" 0 rc;
    check string "silent" "" (String.trim stdout);
    check bool "no registration for agent_id turn" true
      (find_reg ctx fresh_sid = None);
    let rc2, stdout2, _ =
      run_hook ctx
        ~payload:(payload ~session_id:owner_sid ~agent_id:"subagent-2" ())
    in
    check int "owner agent_id turn exit 0" 0 rc2;
    check string "owner agent_id turn silent" "" (String.trim stdout2);
    check int "owner DM not drained by subagent turn" 1
      (List.length (C2c_mcp.Broker.read_inbox b ~session_id:owner_sid)))

let test_subagent_quiet_is_silent_noop () =
  with_ctx (fun ctx ->
    let rc, stdout, _ =
      run_hook ctx
        ~extra_env:[ ("C2C_NO_AUTO_REGISTER", "1") ]
        ~payload:(payload ~session_id:"muse-e2e-quiet-0001" ())
    in
    check int "exit 0" 0 rc;
    check string "silent" "" (String.trim stdout);
    check int "no registration" 0 (count_regs ctx))

let test_malformed_invalid_and_unknown_inputs_exit_0 () =
  with_ctx (fun ctx ->
    List.iter
      (fun (name, pl) ->
        let rc, stdout, _ = run_hook ctx ~payload:pl in
        check int (name ^ ": exit 0") 0 rc;
        check string (name ^ ": silent") "" (String.trim stdout);
        check int (name ^ ": no registration") 0 (count_regs ctx))
      [ ("malformed", "not-json{")
      ; ("empty", "")
      ; ("invalid sid", payload ~session_id:"has spaces and CAPS!!" ())
      ; ( "unknown event"
        , payload ~event:"SubagentStart" ~session_id:"muse-e2e-unk-1" () )
      ])

(* kimi-#40 lesson: a SessionStart with no usable sid must still say so on
   stderr (muse records hook stderr in the session log) rather than exiting
   silently — a silent exit hid the managed-kimi gap for a live e2e. *)
let test_missing_session_id_logs_to_stderr () =
  with_ctx (fun ctx ->
    let rc, stdout, stderr = run_hook ctx ~payload:(payload ()) in
    check int "exit 0" 0 rc;
    check string "silent stdout" "" (String.trim stdout);
    check int "no registration" 0 (count_regs ctx);
    check bool "stderr names the missing session id" true
      (contains ~haystack:stderr ~needle:"no usable session id"))

let test_camel_case_spellings_accepted () =
  with_ctx (fun ctx ->
    let sid = "muse-e2e-camel-0001" in
    let rc, stdout, stderr =
      run_hook ctx ~payload:(payload ~session_id:sid ~camel:true ())
    in
    check int "exit 0" 0 rc;
    (match find_reg ctx sid with
     | None ->
         failf "camelCase SessionStart registered nothing (stderr: %S)" stderr
     | Some r ->
         check (option string) "registered_by" (Some "muse-hook") r.registered_by);
    (match parse_context stdout with
     | Some ("SessionStart", _) -> ()
     | _ -> failf "expected SessionStart output, got: %S" stdout))

(* --- vanilla broker-root correctness (no chdir) -------------------------

   B352 P4: muse hook cwd = workspace in every probe, so the hook resolves
   its broker root from the cwd with NO chdir (unlike agy #69). These cases
   deliberately do NOT set C2C_MCP_BROKER_ROOT and run the hook from a real
   git workspace, asserting the row lands in the workspace's broker. *)

let run_hook_vanilla ?(extra_env = []) ctx ~hook_cwd ~payload =
  let payload_path = ctx.dir // "payload.json" in
  let out_path = ctx.dir // "hook.out" in
  let err_path = ctx.dir // "hook.err" in
  write_file payload_path payload;
  let extra =
    String.concat " "
      (List.map
         (fun (k, v) -> Printf.sprintf "%s=%s" k (Filename.quote v))
         extra_env)
  in
  let cmd =
    Printf.sprintf "cd %s && env -i HOME=%s PATH=%s %s %s hook muse < %s > %s 2> %s"
      (Filename.quote hook_cwd)
      (Filename.quote ctx.home)
      (Filename.quote (Sys.getenv "PATH"))
      extra
      (Filename.quote c2c_binary)
      (Filename.quote payload_path)
      (Filename.quote out_path)
      (Filename.quote err_path)
  in
  let rc = Sys.command cmd in
  (rc, read_file out_path, read_file err_path)

let make_workspace ctx ~name =
  let ws = ctx.dir // name in
  mkdir_p ws;
  let quiet = " >/dev/null 2>&1" in
  ignore (Sys.command (Printf.sprintf "git -C %s init -q%s" (Filename.quote ws) quiet));
  ignore
    (Sys.command
       (Printf.sprintf "git -C %s remote add origin https://example.invalid/%s-%08x.git%s"
          (Filename.quote ws) name (Random.bits ()) quiet));
  ws

let repos_dir ctx = ctx.home // ".c2c" // "repos"

let rows_at broker_root =
  let path = broker_root // "registry.json" in
  if not (Sys.file_exists path) then []
  else
    match Yojson.Safe.from_string (read_file path) with
    | `List rows -> rows
    | `Assoc fields -> (
        match List.assoc_opt "registrations" fields with
        | Some (`List rows) -> rows
        | _ -> [])
    | _ -> []
    | exception _ -> []

let fingerprints_holding ctx ~session_id =
  let dir = repos_dir ctx in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir |> Array.to_list |> List.sort String.compare
    |> List.filter (fun fp ->
           List.exists
             (function
               | `Assoc row ->
                   List.assoc_opt "session_id" row = Some (`String session_id)
               | _ -> false)
             (rows_at (dir // fp // "broker")))

let test_vanilla_registers_into_workspace_broker () =
  with_ctx (fun ctx ->
    let ws = make_workspace ctx ~name:"muse-ws" in
    let sid = "muse-e2e-vanilla-broker" in
    let rc, stdout, stderr =
      run_hook_vanilla ctx ~hook_cwd:ws
        ~payload:(payload ~session_id:sid ~cwd:ws ())
    in
    check int "exit 0" 0 rc;
    (match parse_context stdout with
     | Some ("SessionStart", _) -> ()
     | _ -> failf "expected onboarding output, got: %S (stderr %S)" stdout stderr);
    let fps = fingerprints_holding ctx ~session_id:sid in
    check bool "row landed in exactly one broker" true (List.length fps = 1);
    check bool "row did NOT land in default" true (fps <> [ "default" ]))

let test_workspace_cwd_recorded_from_payload () =
  with_ctx (fun ctx ->
    let ws = make_workspace ctx ~name:"muse-ws-cwd" in
    let sid = "muse-e2e-vanilla-cwd" in
    let rc, _, stderr =
      run_hook_vanilla ctx ~hook_cwd:ws
        ~payload:(payload ~session_id:sid ~cwd:ws ())
    in
    check int "exit 0" 0 rc;
    match fingerprints_holding ctx ~session_id:sid with
    | [ fp ] -> (
        let rows = rows_at (repos_dir ctx // fp // "broker") in
        match
          List.find_opt
            (function
              | `Assoc row ->
                  List.assoc_opt "session_id" row = Some (`String sid)
              | _ -> false)
            rows
        with
        | Some (`Assoc row) ->
            check bool "registration cwd is the workspace" true
              (List.assoc_opt "cwd" row = Some (`String ws))
        | _ -> failf "row for %s missing fields (stderr: %S)" sid stderr)
    | fps ->
        failf "expected one broker holding %s, got [%s] (stderr: %S)" sid
          (String.concat ";" fps) stderr)

(* --- B361: managed-row adoption -----------------------------------------
   Muse scrubs hook env (B358 probe), so a managed SessionStart arrives with
   no C2C_* — the hook must adopt the launcher's row by cwd + live
   (pid, pid_start_time) instead of minting a competing native-sid row. *)

(* Mirrors what `c2c start muse` writes via
   [C2c_start.register_managed_muse_session]: session_id = instance name, a
   live (pid, pid_start_time) pair, the launch cwd, and NO registered_by
   (that marks hook rows). The pid is this test process's own — alive for
   the whole test — with its REAL start ticks, so only a correct
   generation comparison adopts it. *)
let my_pid_start_time () =
  C2c_mcp.Broker.capture_pid_start_time (Some (Unix.getpid ()))

let register_managed_muse ctx ~alias ~cwd =
  let b = broker ctx in
  C2c_mcp.Broker.register b ~session_id:alias ~alias
    ~pid:(Some (Unix.getpid ())) ~pid_start_time:(my_pid_start_time ())
    ~client_type:(Some "muse") ~cwd:(Some cwd) ~from_auto_gen:false ();
  b

(* Post-`c2c stop` shape: exact-generation cleanup stripped the liveness
   fields, wrote its durable receipt, and kept the sticky workspace-alias row. *)
let register_torn_down_managed_muse ctx ~alias ~cwd =
  let b = broker ctx in
  C2c_mcp.Broker.register b ~session_id:alias ~alias ~pid:None
    ~pid_start_time:None ~client_type:(Some "muse") ~cwd:(Some cwd)
    ~from_auto_gen:false ();
  let generation = Option.value (my_pid_start_time ()) ~default:1 in
  write_file
    (C2c_mcp_helpers.managed_teardown_evidence_path
       ~broker_root:ctx.broker_root ~session_id:alias)
    (Yojson.Safe.to_string
       (`Assoc
         [ ("session_id", `String alias)
         ; ("launcher_pid", `Int (Unix.getpid ()))
         ; ("launcher_generation", `Int generation)
         ; ("completed_at", `Float (Unix.gettimeofday ())) ]));
  b

let register_stale_pidless_managed_muse ctx ~alias ~cwd =
  let b = broker ctx in
  C2c_mcp.Broker.register b ~session_id:alias ~alias ~pid:None
    ~pid_start_time:None ~client_type:(Some "muse") ~cwd:(Some cwd)
    ~from_auto_gen:false ();
  b

let muse_mapping_path ctx = ctx.broker_root // "muse-sid-mapping.json"

let read_muse_mapping ctx =
  if not (Sys.file_exists (muse_mapping_path ctx)) then []
  else
    match Yojson.Safe.from_string (read_file (muse_mapping_path ctx)) with
    | `Assoc fields ->
        List.filter_map
          (function k, `String v -> Some (k, v) | _ -> None)
          fields
    | _ -> []
    | exception _ -> []

(* Native muse session ids are uuids (B358 probe shape). *)
let native_sid n = Printf.sprintf "01a0b361-0000-4000-8000-%012d" n

let test_b361_adopts_live_managed_row () =
  with_ctx (fun ctx ->
    let managed = "zz-b361-managed" in
    let cwd = "/tmp/b361-proj" in
    let b = register_managed_muse ctx ~alias:managed ~cwd in
    (* Backlog for the MANAGED alias: adoption must drain it (the B361
       drain gap), not a fresh payload row's empty inbox. *)
    C2c_mcp.Broker.register b ~session_id:"zz-b361-peer" ~alias:"zz-b361-peer"
      ~pid:None ~pid_start_time:None ~client_type:(Some "muse") ();
    C2c_mcp.Broker.enqueue_message b ~from_alias:"zz-b361-peer"
      ~to_alias:managed ~content:"hello managed muse" ();
    let payload_sid = native_sid 1 in
    let rc, stdout, stderr =
      run_hook ctx ~payload:(payload ~session_id:payload_sid ~cwd ())
    in
    check int "exit 0" 0 rc;
    check int "no competing row minted" 2 (count_regs ctx);
    check bool "managed row is the identity" true
      (find_reg ctx managed <> None);
    check bool "payload sid minted no row" true
      (find_reg ctx payload_sid = None);
    check bool "adoption is logged" true
      (contains ~haystack:stderr ~needle:"adopting managed session");
    check bool "mapping records payload -> managed" true
      (List.assoc_opt payload_sid (read_muse_mapping ctx) = Some managed);
    (match parse_context stdout with
     | Some (_, context) ->
         check bool "wake names the managed alias" true
           (contains ~haystack:context ~needle:managed);
         check bool "managed backlog drained into context" true
           (contains ~haystack:context ~needle:"hello managed muse");
         check bool "no second onboarding" false
           (contains ~haystack:context ~needle:"now registered")
     | None -> failf "expected wake output, got: %S" stdout);
    check int "managed inbox drained" 0
      (List.length (C2c_mcp.Broker.read_inbox b ~session_id:managed));
    (* kimi #40 F6: adoption writes no statefile — the launcher owns the
       managed identity. *)
    let statefile = read_file (ctx.broker_root // "default-session.json") in
    check bool "no statefile for the adopted payload sid" false
      (contains ~haystack:statefile ~needle:payload_sid))

let test_b361_bails_loudly_on_ambiguous_live_cwd () =
  with_ctx (fun ctx ->
    let cwd = "/tmp/b361-proj" in
    ignore (register_managed_muse ctx ~alias:"zz-b361-two-a" ~cwd);
    ignore (register_managed_muse ctx ~alias:"zz-b361-two-b" ~cwd);
    let rc, stdout, stderr =
      run_hook ctx ~payload:(payload ~session_id:(native_sid 2) ~cwd ())
    in
    check int "never fails the host turn" 0 rc;
    check string "silent stdout" "" (String.trim stdout);
    check int "no third identity minted" 2 (count_regs ctx);
    check bool "ambiguity is explained, not silent" true
      (contains ~haystack:stderr ~needle:"cannot tell which one");
    check bool "names the candidates" true
      (contains ~haystack:stderr ~needle:"zz-b361-two-a");
    check bool "no mapping written on bail" false
      (Sys.file_exists (muse_mapping_path ctx)))

let test_b361_dead_pid_row_is_not_adopted () =
  with_ctx (fun ctx ->
    let b = broker ctx in
    C2c_mcp.Broker.register b ~session_id:"zz-b361-dead" ~alias:"zz-b361-dead"
      ~pid:(Some 2147483646) ~pid_start_time:(Some 12345)
      ~client_type:(Some "muse") ~cwd:(Some "/tmp/b361-proj")
      ~from_auto_gen:false ();
    let payload_sid = native_sid 3 in
    let rc, _, stderr =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "exit 0" 0 rc;
    check bool "no adoption of a dead-pid row" false
      (contains ~haystack:stderr ~needle:"adopting managed session");
    check int "fresh session minted its own identity" 2 (count_regs ctx);
    check bool "the new row is this session" true
      (find_reg ctx payload_sid <> None))

(* #85 discriminator: a live pid with a WRONG start-time is PID reuse, not
   our instance. A bare /proc/<pid> existence check would wrongly adopt. *)
let test_b361_pid_reuse_row_is_not_adopted () =
  with_ctx (fun ctx ->
    let b = broker ctx in
    C2c_mcp.Broker.register b ~session_id:"zz-b361-reused"
      ~alias:"zz-b361-reused" ~pid:(Some (Unix.getpid ()))
      ~pid_start_time:(Some 1) (* never a real jiffy count *)
      ~client_type:(Some "muse") ~cwd:(Some "/tmp/b361-proj")
      ~from_auto_gen:false ();
    let payload_sid = native_sid 4 in
    let rc, _, stderr =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "exit 0" 0 rc;
    check bool "no adoption of a pid-reuse row" false
      (contains ~haystack:stderr ~needle:"adopting managed session");
    check int "session minted its own identity" 2 (count_regs ctx);
    check bool "the new row is this session" true
      (find_reg ctx payload_sid <> None))

(* Deliberate kimi divergence: kimi falls back to pid existence when
   pid_start_time is None (pre-#40 rows); launcher rows normally carry the
   pair, so muse fails closed instead of trusting a bare pid number. (A
   launcher row whose /proc read failed at register time is therefore
   permanently unadoptable — fail-closed dual identity; see the predicate
   comment.) *)
let test_b361_missing_start_time_fails_closed () =
  with_ctx (fun ctx ->
    let b = broker ctx in
    C2c_mcp.Broker.register b ~session_id:"zz-b361-nostart"
      ~alias:"zz-b361-nostart" ~pid:(Some (Unix.getpid ()))
      ~pid_start_time:None ~client_type:(Some "muse")
      ~cwd:(Some "/tmp/b361-proj") ~from_auto_gen:false ();
    let payload_sid = native_sid 5 in
    let rc, _, stderr =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "exit 0" 0 rc;
    check bool "no adoption without a recorded generation" false
      (contains ~haystack:stderr ~needle:"adopting managed session");
    check int "session minted its own identity" 2 (count_regs ctx))

let test_b361_torn_down_row_is_reclaimed () =
  with_ctx (fun ctx ->
    let managed = "zz-b361-torn" in
    ignore (register_torn_down_managed_muse ctx ~alias:managed ~cwd:"/tmp/b361-proj");
    let payload_sid = native_sid 6 in
    let rc, _, stderr =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "exit 0" 0 rc;
    check int "no competing alias minted" 1 (count_regs ctx);
    check bool "sticky managed alias preserved" true
      (find_reg ctx managed <> None);
    check bool "reclaim is logged, not silent" true
      (contains ~haystack:stderr ~needle:"reclaiming torn-down managed row");
    check bool "mapping records payload -> managed" true
      (List.assoc_opt payload_sid (read_muse_mapping ctx) = Some managed))

let test_b361_symlinked_teardown_evidence_is_not_reclaimed () =
  with_ctx (fun ctx ->
    let managed = "zz-b361-symlink-receipt" in
    ignore
      (register_torn_down_managed_muse ctx ~alias:managed
         ~cwd:"/tmp/b361-proj");
    let receipt =
      C2c_mcp_helpers.managed_teardown_evidence_path
        ~broker_root:ctx.broker_root ~session_id:managed
    in
    let target = receipt ^ ".target" in
    Unix.rename receipt target;
    Unix.symlink target receipt;
    let payload_sid = native_sid 20 in
    let rc, _, stderr =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "exit 0" 0 rc;
    check bool "symlinked receipt is not trusted" false
      (contains ~haystack:stderr ~needle:"reclaiming torn-down managed row");
    check int "fresh session gets its own identity" 2 (count_regs ctx);
    check bool "fresh payload row exists" true
      (find_reg ctx payload_sid <> None))

let test_b361_pidless_row_without_teardown_evidence_is_not_reclaimed () =
  with_ctx (fun ctx ->
    let managed = "zz-b361-stale-pidless" in
    ignore
      (register_stale_pidless_managed_muse ctx ~alias:managed
         ~cwd:"/tmp/b361-proj");
    let payload_sid = native_sid 13 in
    let rc, _, stderr =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "exit 0" 0 rc;
    check bool "stale pidless row is not adopted" false
      (contains ~haystack:stderr ~needle:"reclaiming torn-down managed row");
    check int "fresh session gets its own identity" 2 (count_regs ctx);
    check bool "fresh payload row exists" true (find_reg ctx payload_sid <> None))

let test_b361_bails_loudly_on_ambiguous_torn_down_cwd () =
  with_ctx (fun ctx ->
    let cwd = "/tmp/b361-proj" in
    ignore (register_torn_down_managed_muse ctx ~alias:"zz-b361-td-a" ~cwd);
    ignore (register_torn_down_managed_muse ctx ~alias:"zz-b361-td-b" ~cwd);
    let rc, stdout, stderr =
      run_hook ctx ~payload:(payload ~session_id:(native_sid 7) ~cwd ())
    in
    check int "never fails the host turn" 0 rc;
    check string "silent stdout" "" (String.trim stdout);
    check int "nothing minted" 2 (count_regs ctx);
    check bool "ambiguity is explained" true
      (contains ~haystack:stderr ~needle:"cannot tell which one"))

(* A dead-pid row asserts a liveness that is false — a stale claim, never a
   reclaim signal (#47 caveat). Only pid=None reclaims. *)
let test_b361_dead_pid_row_is_not_reclaimed () =
  with_ctx (fun ctx ->
    let b = broker ctx in
    C2c_mcp.Broker.register b ~session_id:"zz-b361-stale"
      ~alias:"zz-b361-stale" ~pid:(Some 2147483646)
      ~pid_start_time:(Some 12345) ~client_type:(Some "muse")
      ~cwd:(Some "/tmp/b361-proj") ~from_auto_gen:false ();
    let payload_sid = native_sid 8 in
    let rc, _, stderr =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "exit 0" 0 rc;
    check bool "no reclaim of a stale-claim row" false
      (contains ~haystack:stderr ~needle:"reclaiming torn-down managed row");
    check int "fresh session minted its own identity" 2 (count_regs ctx);
    check bool "the new row is this session" true
      (find_reg ctx payload_sid <> None))

(* The launcher writes a canonical cwd but the payload cwd is whatever muse
   passes: a trailing slash must not defeat the match. Uses a REAL directory
   so realpath (not just the strip fallback) is exercised. *)
let test_b361_adoption_normalizes_cwd () =
  with_ctx (fun ctx ->
    let ws = ctx.dir // "b361-ws" in
    mkdir_p ws;
    ignore (register_managed_muse ctx ~alias:"zz-b361-slash" ~cwd:ws);
    let rc, _, stderr =
      run_hook ctx
        ~payload:(payload ~session_id:(native_sid 9) ~cwd:(ws ^ "/") ())
    in
    check int "exit 0" 0 rc;
    check bool "trailing slash still matches the managed row" true
      (contains ~haystack:stderr ~needle:"adopting managed session");
    check int "no second identity minted" 1 (count_regs ctx))

(* Backdate the MANAGED row's anchor in place (raw JSON patch preserving
   pid/start/cwd), so the Stop touch-through has something to move. *)
let backdate_anchor ctx ~session_id ~age_s =
  let path = ctx.broker_root // "registry.json" in
  let before = Unix.gettimeofday () -. age_s in
  let rows =
    match Yojson.Safe.from_string (read_file path) with
    | `List rows -> rows
    | _ -> []
    | exception _ -> []
  in
  let rows =
    List.map
      (function
        | `Assoc row as r -> (
            match List.assoc_opt "session_id" row with
            | Some (`String s) when s = session_id ->
                `Assoc
                  (("last_activity_ts", `Float before)
                  :: List.remove_assoc "last_activity_ts" row)
            | _ -> r)
        | r -> r)
      rows
  in
  write_file path (Yojson.Safe.to_string (`List rows));
  before

let test_b361_stop_touches_through_to_managed_row () =
  with_ctx (fun ctx ->
    let managed = "zz-b361-touch" in
    ignore (register_managed_muse ctx ~alias:managed ~cwd:"/tmp/b361-proj");
    let payload_sid = native_sid 10 in
    let rc1, _, stderr1 =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "SessionStart exit 0" 0 rc1;
    check bool "adopted" true
      (contains ~haystack:stderr1 ~needle:"adopting managed session");
    let before = backdate_anchor ctx ~session_id:managed ~age_s:3600.0 in
    let rc, stdout, _ =
      run_hook ctx
        ~payload:(payload ~event:"Stop" ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "Stop exit 0" 0 rc;
    check string "Stop stdout silent" "" (String.trim stdout);
    check bool "payload sid still has no row" true
      (find_reg ctx payload_sid = None);
    check int "Stop mints no row" 1 (count_regs ctx);
    (match read_anchor ctx ~session_id:managed with
     | None -> fail "managed anchor missing after Stop"
     | Some after ->
         check bool
           (Printf.sprintf "Stop advances MANAGED anchor (before=%.3f after=%.3f)"
              before after)
           true (after > before +. 60.0)))

let test_b361_posttooluse_touches_through_to_managed_row () =
  with_ctx (fun ctx ->
    let managed = "zz-b361-ptu" in
    ignore (register_managed_muse ctx ~alias:managed ~cwd:"/tmp/b361-proj");
    let payload_sid = native_sid 11 in
    let rc1, _, stderr1 =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "SessionStart exit 0" 0 rc1;
    check bool "adopted" true
      (contains ~haystack:stderr1 ~needle:"adopting managed session");
    let before = backdate_anchor ctx ~session_id:managed ~age_s:3600.0 in
    let rc, stdout, _ =
      run_hook ctx
        ~payload:
          (payload ~event:"PostToolUse" ~session_id:payload_sid
             ~cwd:"/tmp/b361-proj" ())
    in
    check int "PostToolUse exit 0" 0 rc;
    check string "silent" "" (String.trim stdout);
    (match read_anchor ctx ~session_id:managed with
     | None -> fail "managed anchor missing after PostToolUse"
     | Some after ->
         check bool "PostToolUse advances MANAGED anchor" true
           (after > before +. 60.0)))

let test_b361_session_end_keeps_adopted_managed_row () =
  with_ctx (fun ctx ->
    let managed = "zz-b361-end" in
    ignore (register_managed_muse ctx ~alias:managed ~cwd:"/tmp/b361-proj");
    let payload_sid = native_sid 12 in
    let rc1, _, stderr1 =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "SessionStart exit 0" 0 rc1;
    check bool "adopted" true
      (contains ~haystack:stderr1 ~needle:"adopting managed session");
    check bool "mapping written" true
      (List.assoc_opt payload_sid (read_muse_mapping ctx) = Some managed);
    let rc, stdout, _ =
      run_hook ctx
        ~payload:(payload ~event:"SessionEnd" ~session_id:payload_sid ())
    in
    check int "SessionEnd exit 0" 0 rc;
    check string "SessionEnd silent" "" (String.trim stdout);
    check bool "adopted managed row survives SessionEnd" true
      (find_reg ctx managed <> None);
    check bool "mapping entry removed" true
      (List.assoc_opt payload_sid (read_muse_mapping ctx) = None))

(* Pre-B361 dual identity heals: a stale hook row for the payload sid plus a
   live managed row for the cwd — SessionStart adopts the managed row (no
   third row), and SessionEnd then retires the stale hook row while the
   managed row survives. *)
let test_b361_stale_hook_row_heals_to_managed () =
  with_ctx (fun ctx ->
    let managed = "zz-b361-heal" in
    let b = register_managed_muse ctx ~alias:managed ~cwd:"/tmp/b361-proj" in
    let payload_sid = native_sid 13 in
    C2c_mcp.Broker.register b ~session_id:payload_sid ~alias:"zz-b361-heal-hook"
      ~pid:None ~pid_start_time:None ~client_type:(Some "muse")
      ~cwd:(Some "/tmp/b361-proj") ~registered_by:(Some "muse-hook") ();
    let rc1, _, stderr1 =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "SessionStart exit 0" 0 rc1;
    check int "no third row" 2 (count_regs ctx);
    check bool "managed row adopted despite stale hook row" true
      (contains ~haystack:stderr1 ~needle:"adopting managed session");
    let rc2, _, _ =
      run_hook ctx
        ~payload:(payload ~event:"SessionEnd" ~session_id:payload_sid ())
    in
    check int "SessionEnd exit 0" 0 rc2;
    check bool "stale hook row retired" true
      (find_reg ctx payload_sid = None);
    check bool "managed row survives" true (find_reg ctx managed <> None);
    check int "one row left" 1 (count_regs ctx))

(* Adoption writes prune mapping entries whose managed sid is gone, so
   sessions that die without SessionEnd cannot grow the file unboundedly. *)
let test_b361_adoption_prunes_dead_mapping_entries () =
  with_ctx (fun ctx ->
    let managed = "zz-b361-prune" in
    ignore (register_managed_muse ctx ~alias:managed ~cwd:"/tmp/b361-proj");
    write_file (muse_mapping_path ctx)
      (Yojson.Safe.to_string
         (`Assoc [ ("dead-payload-0001", `String "gone-managed-0001") ]));
    let payload_sid = native_sid 14 in
    let rc, _, stderr =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "exit 0" 0 rc;
    check bool "adopted" true
      (contains ~haystack:stderr ~needle:"adopting managed session");
    let mapping = read_muse_mapping ctx in
    check bool "new entry written" true
      (List.assoc_opt payload_sid mapping = Some managed);
    check bool "dead entry pruned" true
      (List.assoc_opt "dead-payload-0001" mapping = None))

(* Step 0 runs ONLY when env_sid is absent: a hook that sees managed env
   keeps the env-first resolution and never adopts. *)
let test_b361_env_present_skips_adoption () =
  with_ctx (fun ctx ->
    ignore
      (register_managed_muse ctx ~alias:"zz-b361-env" ~cwd:"/tmp/b361-proj");
    let payload_sid = native_sid 15 in
    let rc, _, stderr =
      run_hook ctx
        ~extra_env:[ ("C2C_MCP_SESSION_ID", "muse-e2e-env-unregistered") ]
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "exit 0" 0 rc;
    check bool "no adoption when env is present" false
      (contains ~haystack:stderr ~needle:"adopting managed session");
    check bool "payload identity minted (step 3)" true
      (find_reg ctx payload_sid <> None))

(* Gate contract: a REGISTERED env sid wins over adoption (step 1 beats
   step 0) — the env-first claude/grok shape, no client-type guard. *)
let test_b361_registered_env_wins_over_adoption () =
  with_ctx (fun ctx ->
    ignore
      (register_managed_muse ctx ~alias:"zz-b361-envreg" ~cwd:"/tmp/b361-proj");
    let b = broker ctx in
    C2c_mcp.Broker.register b ~session_id:"muse-e2e-env-foreign"
      ~alias:"zz-b361-foreign" ~pid:None ~pid_start_time:None
      ~client_type:(Some "claude") ();
    let payload_sid = native_sid 16 in
    let rc, stdout, stderr =
      run_hook ctx
        ~extra_env:[ ("C2C_MCP_SESSION_ID", "muse-e2e-env-foreign") ]
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "exit 0" 0 rc;
    check bool "no adoption when env resolves" false
      (contains ~haystack:stderr ~needle:"adopting managed session");
    check int "nothing minted" 2 (count_regs ctx);
    check bool "payload sid minted no row" true
      (find_reg ctx payload_sid = None);
    (match parse_context stdout with
     | Some (_, context) ->
         check bool "wake names the env identity" true
           (contains ~haystack:context ~needle:"zz-b361-foreign")
     | None -> failf "expected wake output, got: %S" stdout))

(* Empty payload cwd falls back to the process cwd (B352 P4: the hook cwd
   IS the workspace) instead of skipping adoption. Hermetic: both sides
   read this test process's own cwd dynamically. *)
let test_b361_empty_payload_cwd_falls_back_to_getcwd () =
  with_ctx (fun ctx ->
    let here = Sys.getcwd () in
    ignore (register_managed_muse ctx ~alias:"zz-b361-getcwd" ~cwd:here);
    let rc, _, stderr =
      run_hook ctx ~payload:(payload ~session_id:(native_sid 17) ~cwd:"" ())
    in
    check int "exit 0" 0 rc;
    check bool "getcwd fallback still matches the managed row" true
      (contains ~haystack:stderr ~needle:"adopting managed session");
    check int "no second identity minted" 1 (count_regs ctx))

(* The cap is the real bound: 600 live entries (all pointing at the still-
   registered managed row, so prune keeps them) collapse to 512 newest-
   first on the next adoption write. *)
let test_b361_mapping_write_enforces_cap () =
  with_ctx (fun ctx ->
    let managed = "zz-b361-cap" in
    ignore (register_managed_muse ctx ~alias:managed ~cwd:"/tmp/b361-proj");
    let stale =
      List.init 600 (fun i ->
        (Printf.sprintf "stale-payload-%04d" i, `String managed))
    in
    write_file (muse_mapping_path ctx)
      (Yojson.Safe.to_string (`Assoc stale));
    let payload_sid = native_sid 18 in
    let rc, _, stderr =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "exit 0" 0 rc;
    check bool "adopted" true
      (contains ~haystack:stderr ~needle:"adopting managed session");
    let mapping = read_muse_mapping ctx in
    check int "capped at 512" 512 (List.length mapping);
    check bool "new entry written" true
      (List.assoc_opt payload_sid mapping = Some managed);
    check bool "newest-kept boundary holds" true
      (List.assoc_opt "stale-payload-0510" mapping = Some managed);
    check bool "oldest evicted" true
      (List.assoc_opt "stale-payload-0511" mapping = None))

(* A dropped mapping write degrades loudly, not silently: adoption still
   resolves (exit 0, no competing row) but stderr carries the warning.
   The uncreatable lock path (symlink into a missing dir) is the hermetic
   lock-failure fixture. *)
let test_b361_mapping_write_failure_warns_loudly () =
  with_ctx (fun ctx ->
    let managed = "zz-b361-lockfail" in
    ignore (register_managed_muse ctx ~alias:managed ~cwd:"/tmp/b361-proj");
    (try Unix.symlink "/nonexistent-b361-dir/x"
           (muse_mapping_path ctx ^ ".lock")
     with _ -> fail "could not plant lock-failure fixture");
    let payload_sid = native_sid 19 in
    let rc, _, stderr =
      run_hook ctx
        ~payload:(payload ~session_id:payload_sid ~cwd:"/tmp/b361-proj" ())
    in
    check int "still exits 0" 0 rc;
    check bool "adopted" true
      (contains ~haystack:stderr ~needle:"adopting managed session");
    check bool "mapping-write failure is loud" true
      (contains ~haystack:stderr ~needle:"adoption mapping write failed");
    check int "no competing row" 1 (count_regs ctx);
    check bool "no mapping recorded" true (read_muse_mapping ctx = []))

(* Vanilla SessionEnd takes no lock and leaves no siblings: neither the
   mapping file nor its .lock may appear for a session that never adopted. *)
let test_b361_vanilla_session_end_leaves_no_mapping_files () =
  with_ctx (fun ctx ->
    let sid = "muse-e2e-nolitter-0001" in
    let rc1, _, _ = run_hook ctx ~payload:(payload ~session_id:sid ()) in
    check int "SessionStart exit 0" 0 rc1;
    let rc2, _, _ =
      run_hook ctx ~payload:(payload ~event:"SessionEnd" ~session_id:sid ())
    in
    check int "SessionEnd exit 0" 0 rc2;
    check bool "no mapping file" false
      (Sys.file_exists (muse_mapping_path ctx));
    check bool "no lock sibling" false
      (Sys.file_exists (muse_mapping_path ctx ^ ".lock")))

let () =
  Random.self_init ();
  run "c2c_hook_muse"
    [ ( "hook_muse_session"
      , [ test_case "SessionStart registers + onboarding JSON" `Quick
            test_session_start_registers_with_onboarding
        ; test_case "second SessionStart is wake, no duplicate" `Quick
            test_second_session_start_is_wake_no_duplicate
        ; test_case "SessionStart drains backlog" `Quick
            test_session_start_drains_backlog
        ; test_case "SessionStart drains global backlog" `Quick
            test_session_start_drains_global_backlog
        ; test_case "SessionStart reuses sticky alias across repos" `Quick
            test_session_start_reuses_sticky_alias_across_repos
        ; test_case "env-first, no duplicate registration" `Quick
            test_env_first_no_duplicate_registration
        ; test_case "managed marker suppresses hook label" `Quick
            test_managed_marker_suppresses_hook_label
        ; test_case "camelCase spellings accepted" `Quick
            test_camel_case_spellings_accepted
        ] )
    ; ( "hook_muse_midsession"
      , [ test_case "Stop touches anchor, keeps row, silent" `Quick
            test_stop_touches_anchor_keeps_row_silent
        ; test_case "repeated Stops keep row (#61)" `Quick
            test_repeated_stops_keep_row
        ; test_case "PostToolUse unknown sid mints nothing (subagent-ignore)"
            `Quick test_posttooluse_unknown_sid_mints_nothing
        ; test_case "PostToolUse known sid touches silently" `Quick
            test_posttooluse_known_sid_touches_silently
        ; test_case "SessionEnd deregisters hook-owned only" `Quick
            test_session_end_deregisters_hook_owned_only
        ] )
    ; ( "hook_muse_guards"
      , [ test_case "B130 agent_id gate: no register, no drain" `Quick
            test_agent_id_gate_no_register_no_drain
        ; test_case "subagent-quiet is silent no-op" `Quick
            test_subagent_quiet_is_silent_noop
        ; test_case "malformed/invalid/unknown inputs exit 0" `Quick
            test_malformed_invalid_and_unknown_inputs_exit_0
        ; test_case "missing session id logs to stderr" `Quick
            test_missing_session_id_logs_to_stderr
        ] )
    ; ( "hook_muse_broker_root"
      , [ test_case "vanilla registers into workspace broker (no chdir)" `Quick
            test_vanilla_registers_into_workspace_broker
        ; test_case "workspace cwd recorded from payload" `Quick
            test_workspace_cwd_recorded_from_payload
        ] )
    ; ( "hook_muse_b361_adoption"
      , [ test_case "adopts live managed row + drains managed backlog" `Quick
            test_b361_adopts_live_managed_row
        ; test_case "bails loudly on ambiguous live cwd" `Quick
            test_b361_bails_loudly_on_ambiguous_live_cwd
        ; test_case "dead-pid row is not adopted" `Quick
            test_b361_dead_pid_row_is_not_adopted
        ; test_case "pid-reuse row is not adopted" `Quick
            test_b361_pid_reuse_row_is_not_adopted
        ; test_case "missing start-time fails closed" `Quick
            test_b361_missing_start_time_fails_closed
        ; test_case "torn-down row is reclaimed" `Quick
            test_b361_torn_down_row_is_reclaimed
        ; test_case "symlinked teardown evidence is not reclaimed" `Quick
            test_b361_symlinked_teardown_evidence_is_not_reclaimed
        ; test_case "pidless row without teardown evidence is not reclaimed"
            `Quick test_b361_pidless_row_without_teardown_evidence_is_not_reclaimed
        ; test_case "bails loudly on ambiguous torn-down cwd" `Quick
            test_b361_bails_loudly_on_ambiguous_torn_down_cwd
        ; test_case "dead-pid row is not reclaimed" `Quick
            test_b361_dead_pid_row_is_not_reclaimed
        ; test_case "adoption normalizes cwd" `Quick
            test_b361_adoption_normalizes_cwd
        ; test_case "Stop touches through to managed row" `Quick
            test_b361_stop_touches_through_to_managed_row
        ; test_case "PostToolUse touches through to managed row" `Quick
            test_b361_posttooluse_touches_through_to_managed_row
        ; test_case "SessionEnd keeps adopted managed row" `Quick
            test_b361_session_end_keeps_adopted_managed_row
        ; test_case "stale hook row heals to managed" `Quick
            test_b361_stale_hook_row_heals_to_managed
        ; test_case "adoption prunes dead mapping entries" `Quick
            test_b361_adoption_prunes_dead_mapping_entries
        ; test_case "env present skips adoption" `Quick
            test_b361_env_present_skips_adoption
        ; test_case "registered env wins over adoption" `Quick
            test_b361_registered_env_wins_over_adoption
        ; test_case "empty payload cwd falls back to getcwd" `Quick
            test_b361_empty_payload_cwd_falls_back_to_getcwd
        ; test_case "mapping write enforces cap" `Quick
            test_b361_mapping_write_enforces_cap
        ; test_case "mapping write failure warns loudly" `Quick
            test_b361_mapping_write_failure_warns_loudly
        ; test_case "vanilla SessionEnd leaves no mapping files" `Quick
            test_b361_vanilla_session_end_leaves_no_mapping_files
        ] )
    ]
