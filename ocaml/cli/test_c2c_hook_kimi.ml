(* test_c2c_hook_kimi — SessionStart/SessionEnd for Kimi Code.

   Kimi receives inbound messages via REST prompt injection. The hook
   auto-registers on SessionStart, writes a c2c-session identity skill with a
   receive-path nudge (B238), and deregisters on SessionEnd. Tests set
   C2C_KIMI_HOOK_SKIP_NOTIFIER=1 so we never fork a real notifier daemon. *)

open Alcotest

let ( // ) = Filename.concat

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec at i =
      i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1))
    in
    at 0

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else
    Sys.remove path

let mkdir_p path =
  let rec loop p =
    if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
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

let c2c_binary = Filename.dirname Sys.executable_name // "c2c.exe"

type env_ctx = { home : string; broker_root : string }

let with_ctx f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-hook-kimi-%08x" (Random.bits ()) in
  let home = dir // "home" in
  let broker_root = dir // "broker" in
  mkdir_p home;
  mkdir_p broker_root;
  Fun.protect
    ~finally:(fun () -> try remove_tree dir with _ -> ())
    (fun () -> f { home; broker_root })

let run_hook ?(extra_env = []) ctx ~payload =
  let dir = Filename.dirname ctx.home in
  let payload_path = dir // "payload.json" in
  let out_path = dir // "hook.out" in
  let err_path = dir // "hook.err" in
  write_file payload_path payload;
  (* Always skip real notifier fork in hermetic tests (B238). *)
  let extra_env =
    ("C2C_KIMI_HOOK_SKIP_NOTIFIER", "1") :: extra_env
  in
  let extra =
    String.concat " "
      (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (Filename.quote v))
         extra_env)
  in
  let cmd =
    Printf.sprintf
      "env -i HOME=%s PATH=%s C2C_MCP_BROKER_ROOT=%s %s %s hook kimi < %s > %s 2> %s"
      (Filename.quote ctx.home)
      (Filename.quote (Sys.getenv "PATH"))
      (Filename.quote ctx.broker_root)
      extra
      (Filename.quote c2c_binary)
      (Filename.quote payload_path)
      (Filename.quote out_path)
      (Filename.quote err_path)
  in
  let rc = Sys.command cmd in
  (rc, read_file out_path, read_file err_path)

let identity_skill_path ctx =
  ctx.home // ".kimi-code" // "skills" // "c2c-session" // "SKILL.md"

let session_id = "019f4fb9-3c7a-7720-96c2-5cacb719d951"

let session_start_payload =
  Printf.sprintf
    {|{"hook_event_name":"SessionStart","session_id":"%s","cwd":"/tmp/proj"}|}
    session_id

let session_end_payload =
  Printf.sprintf
    {|{"hook_event_name":"SessionEnd","session_id":"%s"}|}
    session_id

let list_aliases broker_root =
  let registry = broker_root // "registry.json" in
  if not (Sys.file_exists registry) then []
  else
    let extract_regs = function
      | `List regs -> regs
      | `Assoc fields ->
          (match List.assoc_opt "registrations" fields with
           | Some (`List regs) -> regs
           | _ -> [])
      | _ -> []
    in
    extract_regs (Yojson.Safe.from_string (read_file registry))
    |> List.filter_map (function
         | `Assoc r ->
             (match List.assoc_opt "alias" r with
              | Some (`String a) -> Some a
              | _ -> None)
         | _ -> None)

let list_registrations broker_root =
  let registry = broker_root // "registry.json" in
  if not (Sys.file_exists registry) then []
  else
    let extract_regs = function
      | `List regs -> regs
      | `Assoc fields ->
          (match List.assoc_opt "registrations" fields with
           | Some (`List regs) -> regs
           | _ -> [])
      | _ -> []
    in
    extract_regs (Yojson.Safe.from_string (read_file registry))
    |> List.filter_map (function
         | `Assoc r ->
             (match List.assoc_opt "session_id" r, List.assoc_opt "alias" r with
              | Some (`String sid), Some (`String a) -> Some (sid, a)
              | _ -> None)
         | _ -> None)

let test_session_start_auto_registers_from_env_alias () =
  with_ctx (fun ctx ->
    let rc, stdout, stderr =
      run_hook ctx ~payload:session_start_payload
        ~extra_env:
          [ ("C2C_MCP_SESSION_ID", session_id)
          ; ("C2C_MCP_AUTO_REGISTER_ALIAS", "kimi-env-alias")
          ; ("C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN", "1")
          ]
    in
    check int "exit 0" 0 rc;
    check string "empty stdout" "" (String.trim stdout);
    let regs = list_registrations ctx.broker_root in
    check bool "registered exactly one alias" true (List.length regs = 1);
    let sid, alias = List.hd regs in
    check string "session id matches" session_id sid;
    check string "alias from env" "kimi-env-alias" alias;
    if String.trim stderr <> "" && contains ~haystack:stderr ~needle:"failed"
    then failf "unexpected stderr: %s" stderr;
    (* B238: identity skill with receive-path nudge.

       #83 inverted the identity assertion. This file lives at a path shared by
       every Kimi session on the host, and Kimi snapshots its skill catalogue
       into the system prompt BEFORE `c2c hook kimi` runs — so the catalogue
       captures whatever the previous session left behind. Measured across 95
       recorded sessions, 57 of the 67 carrying this skill (85%) were told they
       were a different agent. Naming an alias here is therefore not a feature
       to preserve; it is the bug. The body points at `c2c whoami` instead. *)
    let skill = read_file (identity_skill_path ctx) in
    check bool "identity skill written" true (String.length skill > 0);
    check bool "skill does NOT name an alias" false
      (contains ~haystack:skill ~needle:"kimi-env-alias");
    check bool "skill points at c2c whoami instead" true
      (contains ~haystack:skill ~needle:"c2c whoami");
    check bool "skill mentions receive path" true
      (contains ~haystack:skill ~needle:"Monitor"
       || contains ~haystack:skill ~needle:"poll-inbox"
       || contains ~haystack:skill ~needle:"notifier"))

let test_session_start_auto_registers_with_auto_gen_alias () =
  with_ctx (fun ctx ->
    let rc, stdout, _ =
      run_hook ctx ~payload:session_start_payload
        ~extra_env:[ ("C2C_MCP_SESSION_ID", session_id) ]
    in
    check int "exit 0" 0 rc;
    check string "empty stdout" "" (String.trim stdout);
    let aliases = list_aliases ctx.broker_root in
    check bool "registered exactly one alias" true (List.length aliases = 1);
    let alias = List.hd aliases in
    check bool ("alias starts with kimi-: " ^ alias) true
      (String.starts_with ~prefix:"kimi-" alias))

let test_session_end_deregisters () =
  with_ctx (fun ctx ->
    let rc1, _, _ =
      run_hook ctx ~payload:session_start_payload
        ~extra_env:
          [ ("C2C_MCP_SESSION_ID", session_id)
          ; ("C2C_MCP_AUTO_REGISTER_ALIAS", "kimi-end-test")
          ; ("C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN", "1")
          ]
    in
    check int "start exit 0" 0 rc1;
    check bool "registered before end" true
      (List.mem "kimi-end-test" (list_aliases ctx.broker_root));
    check bool "identity skill present before end" true
      (Sys.file_exists (identity_skill_path ctx));
    let rc2, _, _ =
      run_hook ctx ~payload:session_end_payload
        ~extra_env:[ ("C2C_MCP_SESSION_ID", session_id) ]
    in
    check int "end exit 0" 0 rc2;
    check bool "deregistered after end" false
      (List.mem "kimi-end-test" (list_aliases ctx.broker_root));
    (* #83: the skill SURVIVES SessionEnd. Its body is identity-agnostic, so a
       file outliving its session names nothing stale — and the path is shared,
       so deleting it here yanked it out from under concurrent sessions.
       Removal belongs to `c2c uninstall kimi`, which now lists it. *)
    check bool "identity skill survives session end" true
      (Sys.file_exists (identity_skill_path ctx)))

let test_malformed_payload_exits_0 () =
  with_ctx (fun ctx ->
    let rc, stdout, _ = run_hook ctx ~payload:"not-json{" in
    check int "exit 0" 0 rc;
    check string "empty stdout" "" (String.trim stdout))

(* Pre-register a session directly on the broker so we can seed its inbox
   before SessionStart fires (models pre-startup backlog). Returns the broker
   handle for enqueueing. *)
let register_session ctx ~session_id ~alias =
  let b = C2c_mcp.Broker.create ~root:ctx.broker_root in
  C2c_mcp.Broker.register b ~session_id ~alias ~pid:None ~pid_start_time:None
    ~client_type:(Some "kimi") ~registered_by:(Some "kimi-hook")
    ~from_auto_gen:true ();
  b

(* #12 asked SessionStart to surface pre-startup backlog in the identity skill,
   so a fresh Kimi session sees mail that arrived before it started.

   #83 keeps the GOAL and drops the mechanism. A live count cannot work from
   this file: Kimi snapshots the skill catalogue before `c2c hook kimi` runs,
   and the path is shared by every Kimi session on the host, so any number
   written here is read by somebody else, one session late. It was not a stale
   number, it was another agent's number.

   The body now tells every session to run `c2c poll-inbox` unconditionally,
   which drains the same backlog without asserting a count that cannot be
   right. These two tests pin that: the instruction is always present, and no
   per-session count is claimed either way. *)
let test_session_start_surfaces_queued_backlog () =
  with_ctx (fun ctx ->
    let b = register_session ctx ~session_id ~alias:"zz-kimi-backlog-sess" in
    ignore (register_session ctx ~session_id:"zz-kimi-peer-sid"
              ~alias:"zz-kimi-peer");
    C2c_mcp.Broker.enqueue_message b ~from_alias:"zz-kimi-peer"
      ~to_alias:"zz-kimi-backlog-sess" ~content:"backlog one" ();
    C2c_mcp.Broker.enqueue_message b ~from_alias:"zz-kimi-peer"
      ~to_alias:"zz-kimi-backlog-sess" ~content:"backlog two" ();
    let rc, _, _ =
      run_hook ctx ~payload:session_start_payload
        ~extra_env:[ ("C2C_MCP_SESSION_ID", session_id) ]
    in
    check int "exit 0" 0 rc;
    let skill = read_file (identity_skill_path ctx) in
    check bool "identity skill written" true (String.length skill > 0);
    check bool "skill does NOT name the session alias" false
      (contains ~haystack:skill ~needle:"zz-kimi-backlog-sess");
    check bool "skill does NOT claim a queued count" false
      (contains ~haystack:skill ~needle:"2 c2c message");
    (* The goal #12 was after, kept: drain the backlog at session start. *)
    check bool "skill tells the agent to drain the inbox" true
      (contains ~haystack:skill ~needle:"c2c poll-inbox");
    check bool "and says why (mail may predate the session)" true
      (contains ~haystack:skill ~needle:"queued before this"))

(* The drain instruction is unconditional, so an empty inbox must still not
   produce a count-shaped claim. Same assertion as the backlog case, from the
   other side: the body says the same thing either way, which is what makes it
   safe to share between sessions. *)
let test_session_start_no_backlog_no_false_nudge () =
  with_ctx (fun ctx ->
    ignore (register_session ctx ~session_id ~alias:"zz-kimi-empty-sess");
    let rc, _, _ =
      run_hook ctx ~payload:session_start_payload
        ~extra_env:[ ("C2C_MCP_SESSION_ID", session_id) ]
    in
    check int "exit 0" 0 rc;
    let skill = read_file (identity_skill_path ctx) in
    check bool "identity skill written" true (String.length skill > 0);
    check bool "no false queued nudge" false
      (contains ~haystack:skill ~needle:"already queued"))

(* ---------------------------------------------------------------------------
 * #40 — the hook and managed sessions
 *
 * Kimi Code >= 0.27 spawns hooks from the shared `kimi server` daemon, so the
 * hook cannot see a managed session's C2C_MCP_SESSION_ID /
 * C2C_MCP_AUTO_REGISTER_ALIAS. It must therefore recognise the launcher's
 * registration by cwd + live pid and adopt it, rather than minting a second,
 * competing identity for the same live session.
 * --------------------------------------------------------------------------- *)

(* Mirrors what `c2c start kimi` writes via
   [C2c_start.register_managed_kimi_session]: session_id = instance name, a
   live pid, the launch cwd, and NO registered_by (that marks hook rows). *)
let register_managed_session ctx ~alias ~cwd =
  let b = C2c_mcp.Broker.create ~root:ctx.broker_root in
  C2c_mcp.Broker.register b ~session_id:alias ~alias
    ~pid:(Some (Unix.getpid ())) ~pid_start_time:None
    ~client_type:(Some "kimi") ~cwd:(Some cwd) ~from_auto_gen:false ();
  b

let test_i40_hook_adopts_managed_session_instead_of_minting () =
  with_ctx (fun ctx ->
    ignore (register_managed_session ctx ~alias:"zz-i40-managed" ~cwd:"/tmp/proj");
    (* The daemon-spawned hook: real kimi session id in the payload, and NO
       managed identity env — exactly the #40 reproduction. *)
    let rc, _, stderr =
      run_hook ctx
        ~payload:
          {|{"hook_event_name":"SessionStart","session_id":"session_5f3a2591-0289-4bd3-b214-12c4d6939412","cwd":"/tmp/proj"}|}
    in
    check int "exit 0" 0 rc;
    let regs = list_registrations ctx.broker_root in
    check int "no second identity minted" 1 (List.length regs);
    let sid, alias = List.hd regs in
    check string "managed alias preserved" "zz-i40-managed" alias;
    check string "managed session_id preserved" "zz-i40-managed" sid;
    check bool "adoption is logged" true
      (contains ~haystack:stderr ~needle:"adopting managed session");
    (* The adoption is established above by the registry rows and the log line.
       Since #83 the skill names no alias — it cannot, correctly, because Kimi
       reads it before the hook writes it and the path is shared across
       sessions. The agent gets its addressable alias from `c2c whoami`. *)
    let skill = read_file (identity_skill_path ctx) in
    check bool "identity skill written" true (String.length skill > 0);
    check bool "and names no alias" false
      (contains ~haystack:skill ~needle:"zz-i40-managed");
    check bool "points at c2c whoami for the addressable alias" true
      (contains ~haystack:skill ~needle:"c2c whoami"))

let test_i40_hook_bails_loudly_on_ambiguous_managed_cwd () =
  with_ctx (fun ctx ->
    ignore (register_managed_session ctx ~alias:"zz-i40-two-a" ~cwd:"/tmp/proj");
    ignore (register_managed_session ctx ~alias:"zz-i40-two-b" ~cwd:"/tmp/proj");
    let rc, _, stderr =
      run_hook ctx
        ~payload:
          {|{"hook_event_name":"SessionStart","session_id":"session_0baa88d1-3c1f-4121-bfb6-676117f52203","cwd":"/tmp/proj"}|}
    in
    check int "never fails the host turn" 0 rc;
    check int "no third identity minted" 2
      (List.length (list_registrations ctx.broker_root));
    check bool "ambiguity is explained, not silent" true
      (contains ~haystack:stderr ~needle:"cannot tell which one");
    check bool "names the candidates" true
      (contains ~haystack:stderr ~needle:"zz-i40-two-a"))

(* A dead managed pid means the instance is gone: its row must not be adopted,
   so a genuinely new vanilla session still gets its own alias. *)
let test_i40_hook_ignores_dead_managed_registration () =
  with_ctx (fun ctx ->
    let b = C2c_mcp.Broker.create ~root:ctx.broker_root in
    C2c_mcp.Broker.register b ~session_id:"zz-i40-dead" ~alias:"zz-i40-dead"
      ~pid:(Some 2147483646) ~pid_start_time:None ~client_type:(Some "kimi")
      ~cwd:(Some "/tmp/proj") ~from_auto_gen:false ();
    let rc, _, _ = run_hook ctx ~payload:session_start_payload in
    check int "exit 0" 0 rc;
    let regs = list_registrations ctx.broker_root in
    check int "fresh session minted its own identity" 2 (List.length regs);
    check bool "the new row is not the dead managed one" true
      (List.exists (fun (sid, _) -> sid = session_id) regs))

(* #40 F4: a row whose recorded pid_start_time no longer matches the live
   process is a PID-REUSE hit, not our instance — it must not be adopted.
   Uses a live pid (our own) with a deliberately wrong start-time, so a bare
   `/proc/<pid>` existence check would wrongly match. *)
let test_i40_hook_rejects_pid_reuse_row () =
  with_ctx (fun ctx ->
    let b = C2c_mcp.Broker.create ~root:ctx.broker_root in
    C2c_mcp.Broker.register b ~session_id:"zz-i40-reused" ~alias:"zz-i40-reused"
      ~pid:(Some (Unix.getpid ())) ~pid_start_time:(Some 1) (* never a real jiffy count *)
      ~client_type:(Some "kimi") ~cwd:(Some "/tmp/proj") ~from_auto_gen:false ();
    let rc, _, stderr = run_hook ctx ~payload:session_start_payload in
    check int "exit 0" 0 rc;
    check bool "no adoption of a pid-reuse row" false
      (contains ~haystack:stderr ~needle:"adopting managed session");
    let regs = list_registrations ctx.broker_root in
    check int "session minted its own identity" 2 (List.length regs);
    check bool "the new row is this session" true
      (List.exists (fun (sid, _) -> sid = session_id) regs))

(* #40 F7: the launcher writes a canonical cwd but kimi's payload cwd is
   whatever the client passes. A trailing slash must not defeat the match and
   resurrect the competing-alias bug. *)
let test_i40_hook_adoption_normalizes_cwd () =
  with_ctx (fun ctx ->
    ignore (register_managed_session ctx ~alias:"zz-i40-slash" ~cwd:"/tmp/proj");
    let rc, _, stderr =
      run_hook ctx
        ~payload:
          {|{"hook_event_name":"SessionStart","session_id":"session_5f3a2591-0289-4bd3-b214-12c4d6939412","cwd":"/tmp/proj/"}|}
    in
    check int "exit 0" 0 rc;
    check bool "trailing slash still matches the managed row" true
      (contains ~haystack:stderr ~needle:"adopting managed session");
    check int "no second identity minted" 1
      (List.length (list_registrations ctx.broker_root)))

(* The bare `exit 0` on an unresolvable session id is what made #40 invisible.
   It must stay exit 0 (never fail the host turn) but say why. *)
let test_i40_unresolvable_session_id_logs_reason_and_exits_0 () =
  with_ctx (fun ctx ->
    let rc, _, stderr =
      run_hook ctx ~payload:{|{"hook_event_name":"SessionStart","cwd":"/tmp/proj"}|}
    in
    check int "still exits 0" 0 rc;
    check bool "logs a reason" true
      (contains ~haystack:stderr ~needle:"no usable session id");
    check bool "names the env var it looked for" true
      (contains ~haystack:stderr ~needle:"C2C_MCP_SESSION_ID");
    check bool "says what the consequence is" true
      (contains ~haystack:stderr ~needle:"unreachable by peers");
    check int "nothing registered" 0
      (List.length (list_registrations ctx.broker_root)))


(* ---------------------------------------------------------------------------
 * #47 — a torn-down managed row must not let #40 resurface
 *
 * [C2c_start.clear_registration_pid] runs on managed teardown and strips
 * [pid] + [pid_start_time] so a later PID reuse cannot make the dead row read
 * as ghost-alive. The row itself survives deliberately: it is the workspace's
 * sticky alias. But #40's adoption predicate requires [Some pid], so the row
 * became UNADOPTABLE and the next SessionStart minted a competing alias —
 * #40, verbatim, after any managed exit.
 * --------------------------------------------------------------------------- *)

(* Mirrors the post-teardown row observed live (#47):
     alias=i40test session_id=i40test cwd=<worktree>   # pid, pid_start_time absent
   i.e. what [register_managed_kimi_session] wrote, after
   [clear_registration_pid] stripped its liveness fields. *)
let register_torn_down_managed_session ctx ~alias ~cwd =
  let b = C2c_mcp.Broker.create ~root:ctx.broker_root in
  C2c_mcp.Broker.register b ~session_id:alias ~alias ~pid:None
    ~pid_start_time:None ~client_type:(Some "kimi") ~cwd:(Some cwd)
    ~from_auto_gen:false ();
  b

(* THE #47 RED TEST. Against master this mints a second alias — #40 returning. *)
let test_i47_torn_down_managed_row_is_reclaimed_not_shadowed () =
  with_ctx (fun ctx ->
    ignore (register_torn_down_managed_session ctx ~alias:"zz-i47-torn" ~cwd:"/tmp/proj");
    let rc, _, stderr =
      run_hook ctx
        ~payload:
          {|{"hook_event_name":"SessionStart","session_id":"session_0baa88d1-3c1f-4121-bfb6-676117f52203","cwd":"/tmp/proj"}|}
    in
    check int "exit 0" 0 rc;
    let regs = list_registrations ctx.broker_root in
    check int "no competing alias minted (#40 does not resurface)" 1
      (List.length regs);
    let sid, alias = List.hd regs in
    check string "sticky managed alias preserved" "zz-i47-torn" alias;
    check string "sticky managed session_id preserved" "zz-i47-torn" sid;
    check bool "reclaim is logged, not silent" true
      (contains ~haystack:stderr ~needle:"reclaiming torn-down managed row");
    (* The reclaim itself is established above by the registry rows and the log
       line. Since #83 the skill names no alias at all, so it can no longer
       corroborate WHICH alias was reclaimed — only that one was written. *)
    let skill = read_file (identity_skill_path ctx) in
    check bool "identity skill written" true (String.length skill > 0);
    check bool "and names no alias" false
      (contains ~haystack:skill ~needle:"zz-i47-torn"))

(* A LIVE managed row must still win over a torn-down one — reclaim is the
   fallback, never a competing candidate. *)
let test_i47_live_row_wins_over_torn_down_row () =
  with_ctx (fun ctx ->
    ignore (register_torn_down_managed_session ctx ~alias:"zz-i47-dead-row" ~cwd:"/tmp/proj");
    ignore (register_managed_session ctx ~alias:"zz-i47-live-row" ~cwd:"/tmp/proj");
    let rc, _, stderr = run_hook ctx ~payload:session_start_payload in
    check int "exit 0" 0 rc;
    check bool "adopted the live instance" true
      (contains ~haystack:stderr ~needle:"'zz-i47-live-row'");
    check bool "did not reclaim the torn-down row" false
      (contains ~haystack:stderr ~needle:"reclaiming torn-down managed row");
    check int "nothing minted" 2
      (List.length (list_registrations ctx.broker_root)))

(* Two torn-down managed rows for one cwd are as unresolvable as two live ones:
   bail loudly rather than hijack an arbitrary identity. *)
let test_i47_ambiguous_torn_down_rows_bail_loudly () =
  with_ctx (fun ctx ->
    ignore (register_torn_down_managed_session ctx ~alias:"zz-i47-torn-a" ~cwd:"/tmp/proj");
    ignore (register_torn_down_managed_session ctx ~alias:"zz-i47-torn-b" ~cwd:"/tmp/proj");
    let rc, _, stderr = run_hook ctx ~payload:session_start_payload in
    check int "never fails the host turn" 0 rc;
    check int "nothing minted" 2
      (List.length (list_registrations ctx.broker_root));
    check bool "ambiguity is explained" true
      (contains ~haystack:stderr ~needle:"cannot tell which one");
    check bool "names the candidates" true
      (contains ~haystack:stderr ~needle:"zz-i47-torn-a"))

(* Don't over-correct: reclaim applies to MANAGED rows only. A pid-less
   HOOK-registered row belongs to some other vanilla session and must never be
   adopted as this session's identity. *)
let test_i47_pidless_hook_row_is_not_reclaimable () =
  with_ctx (fun ctx ->
    ignore (register_session ctx ~session_id:"zz-i47-other-sid" ~alias:"zz-i47-other");
    let rc, _, stderr =
      run_hook ctx
        ~payload:
          {|{"hook_event_name":"SessionStart","session_id":"session_0baa88d1-3c1f-4121-bfb6-676117f52203","cwd":"/tmp/proj"}|}
    in
    check int "exit 0" 0 rc;
    check bool "no reclaim of a foreign hook row" false
      (contains ~haystack:stderr ~needle:"reclaiming");
    check int "this session minted its own identity" 2
      (List.length (list_registrations ctx.broker_root)))

let () =
  Random.self_init ();
  run "c2c_hook_kimi"
    [ ( "hook_kimi"
      , [ test_case "SessionStart registers from env alias" `Quick
            test_session_start_auto_registers_from_env_alias
        ; test_case "SessionStart auto-generates kimi- alias" `Quick
            test_session_start_auto_registers_with_auto_gen_alias
        ; test_case "SessionEnd deregisters" `Quick
            test_session_end_deregisters
        ; test_case "malformed payload exit 0" `Quick
            test_malformed_payload_exits_0
        ; test_case "SessionStart surfaces queued backlog (#12)" `Quick
            test_session_start_surfaces_queued_backlog
        ; test_case "SessionStart no backlog no false nudge (#12)" `Quick
            test_session_start_no_backlog_no_false_nudge
        ] )
    ; ( "hook_kimi_managed_40"
      , [ test_case "adopts managed session instead of minting" `Quick
            test_i40_hook_adopts_managed_session_instead_of_minting
        ; test_case "ambiguous managed cwd bails loudly" `Quick
            test_i40_hook_bails_loudly_on_ambiguous_managed_cwd
        ; test_case "dead managed registration is ignored" `Quick
            test_i40_hook_ignores_dead_managed_registration
        ; test_case "pid-reuse row is rejected (F4)" `Quick
            test_i40_hook_rejects_pid_reuse_row
        ; test_case "adoption normalizes cwd (F7)" `Quick
            test_i40_hook_adoption_normalizes_cwd
        ; test_case "unresolvable session id logs reason, exits 0" `Quick
            test_i40_unresolvable_session_id_logs_reason_and_exits_0
        ] )
    ; ( "hook_kimi_torn_down_47"
      , [ test_case "torn-down managed row is reclaimed, not shadowed" `Quick
            test_i47_torn_down_managed_row_is_reclaimed_not_shadowed
        ; test_case "live row wins over torn-down row" `Quick
            test_i47_live_row_wins_over_torn_down_row
        ; test_case "ambiguous torn-down rows bail loudly" `Quick
            test_i47_ambiguous_torn_down_rows_bail_loudly
        ; test_case "pid-less hook row is not reclaimable" `Quick
            test_i47_pidless_hook_row_is_not_reclaimable
        ] )
    ]
