(* Tests for C2c_codex_session (P1.M1.E1.T006): deterministic session-ID-derived
   alias generation + collision extension, --yolo forwarding + non-persistence,
   `--` passthrough splitting, thread-conflict rejection, status terminology,
   identity-mapping round-trip, and the app-server lifecycle glue (alias
   published only after start; graceful fallback on a startup diagnostic). All
   scripted — no live codex process. *)

open C2c_codex_app_server
module S = C2c_codex_session
module PB = C2c_mcp_helpers_post_broker
module B = C2c_mcp.Broker

(* #31 (nit 2): the config.json repair inside persist_discovered_thread is a
   SIDE repair, not part of the binding verdict. If it raises (ENOSPC / EACCES /
   read-only fs) the binding is still correct, so the exception must NOT escape:
   the deliver loop's fail-closed latch would otherwise mark a correctly-bound
   unit degraded for its whole life. Forced here by making the instance dir
   read-only so open_out on config.json fails. *)
let test_i31_config_repair_failure_does_not_break_binding () =
  let name = Printf.sprintf "i31-repair-%d-%d" (Unix.getpid ()) (Random.bits ()) in
  let dir = C2c_start.instance_dir name in
  C2c_io.mkdir_p dir;
  Fun.protect
    ~finally:(fun () ->
      (try Unix.chmod dir 0o755 with _ -> ());
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      S.write_mapping ~instance_dir:dir
        { S.session_id = "sid"; alias = name; thread_id = Some "thread-exact";
          created_at = 1.; updated_at = 2. };
      C2c_start.write_config
        { C2c_start.name; client = "codex"; session_id = "sid";
          resume_session_id = "sid"; codex_resume_target = None; alias = name;
          extra_args = []; created_at = 1.; last_launch_at = None;
          last_exit_code = None; last_exit_reason = None; broker_root = "";
          auto_join_rooms = ""; binary_override = None; model_override = None;
          agent_name = None };
      (* Read+execute only: config.json can be READ (so the repair is attempted)
         but not rewritten. Skip if the fs does not enforce it (e.g. running as
         root) rather than asserting something untrue. *)
      Unix.chmod dir 0o500;
      let writable =
        try
          let oc = open_out (Filename.concat dir "probe.tmp") in
          close_out oc; true
        with _ -> false
      in
      if not writable then
        Alcotest.(check bool)
          "binding still reported bound despite a failing config repair" true
          (S.persist_discovered_thread ~instance_dir:dir ~name ~broker_root:""
             ~thread_id:"thread-exact"))

(* ------------------------------------------------------------------ *)
(* Deterministic session-ID-derived alias                              *)
(* ------------------------------------------------------------------ *)

let no_taken _ = false

let has_prefix prefix value =
  String.length value >= String.length prefix
  && String.sub value 0 (String.length prefix) = prefix

let is_lower_hex value =
  String.for_all
    (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
    value

let string_mem needle hay =
  let nl = String.length needle and hl = String.length hay in
  let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i+1)) in
  nl = 0 || go 0

let test_alias_deterministic () =
  (* Same fixed id + same taken predicate => identical alias every call. *)
  let a1 = S.derive_alias ~session_id:"fixed-session-A" ~taken:no_taken in
  let a2 = S.derive_alias ~session_id:"fixed-session-A" ~taken:no_taken in
  Alcotest.(check string) "stable across calls" a1 a2;
  Alcotest.(check string) "base == derived when free"
    (S.derive_alias_base "fixed-session-A") a1;
  Alcotest.(check bool) "codex prefix" true (has_prefix "codex-" a1);
  let suffix = String.sub a1 (String.length a1 - 4) 4 in
  Alcotest.(check bool) "four-character lowercase hex suffix" true
    (String.length suffix = 4 && is_lower_hex suffix)

let test_alias_distinct_for_distinct_ids () =
  let a = S.derive_alias ~session_id:"fixed-session-A" ~taken:no_taken in
  let b = S.derive_alias ~session_id:"fixed-session-B" ~taken:no_taken in
  Alcotest.(check bool) "two new threads => distinct aliases" false (a = b)

let test_alias_resume_stable () =
  (* Restart/resume re-derives the SAME alias from the SAME session id. *)
  let first = S.derive_alias ~session_id:"thread-xyz-123" ~taken:no_taken in
  let restart = S.derive_alias ~session_id:"thread-xyz-123" ~taken:no_taken in
  Alcotest.(check string) "resume retains alias" first restart

let test_alias_collision_extension_deterministic () =
  let sid = "collide-me" in
  let base = S.derive_alias_base sid in
  (* Predicate: only the base is taken -> must extend, NOT pick an unrelated
     random alias. The extension is derived from the same session id, so it is
     stable across calls. *)
  let taken a = a = base in
  let e1 = S.derive_alias ~session_id:sid ~taken in
  let e2 = S.derive_alias ~session_id:sid ~taken in
  Alcotest.(check bool) "extended != base" false (e1 = base);
  Alcotest.(check string) "extension deterministic" e1 e2;
  Alcotest.(check bool) "extension keeps base prefix" true
    (String.length e1 > String.length base
     && String.sub e1 0 (String.length base) = base)

let test_alias_collision_chain_deterministic () =
  (* When base AND the first extension are taken, the second extension is still
     deterministic and stable (no randomness anywhere in the chain). *)
  let sid = "chain-collide" in
  let base = S.derive_alias_base sid in
  let first_ext = S.derive_alias ~session_id:sid ~taken:(fun a -> a = base) in
  let taken a = a = base || a = first_ext in
  let c1 = S.derive_alias ~session_id:sid ~taken in
  let c2 = S.derive_alias ~session_id:sid ~taken in
  Alcotest.(check bool) "distinct from base" false (c1 = base);
  Alcotest.(check bool) "distinct from first ext" false (c1 = first_ext);
  Alcotest.(check string) "second extension deterministic" c1 c2

let test_app_server_log_vocabulary () =
  Alcotest.(check string) "plain startup banner"
    "c2c codex · ready · codex-oak-fern-a1b2 · ws://127.0.0.1:37305"
    (S.online_attached_log_body ~alias:"codex-oak-fern-a1b2"
       ~endpoint:"ws://127.0.0.1:37305");
  Alcotest.(check string) "coloured startup banner"
    "\027[1mc2c codex\027[0m\027[2m · \027[0m\027[32mready\027[0m\027[2m · \027[0m\027[1mcodex-oak-fern-a1b2\027[0m\027[2m · \027[0m\027[2mws://127.0.0.1:37305\027[0m"
    (S.startup_banner ~color:true ~alias:"codex-oak-fern-a1b2"
       ~endpoint:"ws://127.0.0.1:37305")

(* B176: local HH:MM:SS stamp + three distinguishable lifecycle phases. *)
let test_app_server_log_timestamp_format () =
  (* 2020-01-15 14:05:09 local — use a fixed epoch via localtime shape checks
     rather than a brittle absolute epoch (timezone-dependent). *)
  let fixed = fst (Unix.mktime {
      Unix.tm_sec = 9; tm_min = 5; tm_hour = 14;
      tm_mday = 15; tm_mon = 0; tm_year = 120; tm_wday = 0; tm_yday = 0;
      tm_isdst = false;
    }) in
  Alcotest.(check string) "HH:MM:SS local" "14:05:09" (S.app_server_log_hms fixed);
  Alcotest.(check string) "plain line shape"
    "[c2c codex app-server] [14:05:09] hello"
    (S.format_app_server_log ~color:false ~now:fixed "hello");
  Alcotest.(check string) "coloured label preserved"
    ("\027[1;33m[c2c codex app-server]\027[0m [14:05:09] hello")
    (S.format_app_server_log ~color:true ~now:fixed "hello");
  (* Label is a single unit; timestamp follows as [HH:MM:SS]. *)
  let line = S.format_app_server_log ~color:false ~now:fixed "x" in
  Alcotest.(check bool) "starts with label" true
    (has_prefix S.app_server_log_label line);
  Alcotest.(check bool) "contains bracketed timestamp" true
    (string_mem " [14:05:09] " line)

let test_app_server_lifecycle_phase_bodies () =
  let alias = "codex-oak-fern-a1b2" in
  let endpoint = "ws://127.0.0.1:37305" in
  let launch = S.lifecycle_launching_body ~alias in
  let ready = S.lifecycle_ready_body ~endpoint in
  let handoff = S.lifecycle_tui_handoff_body ~alias ~endpoint in
  Alcotest.(check string) "launching body"
    "launching app-server (c2c-alias=codex-oak-fern-a1b2)" launch;
  Alcotest.(check string) "ready body"
    "app-server ready (ws://127.0.0.1:37305)" ready;
  Alcotest.(check string) "handoff reuses polished banner"
    (S.online_attached_log_body ~alias ~endpoint) handoff;
  (* Three phases must be distinguishable in captured output. *)
  Alcotest.(check bool) "launch ≠ ready" false (launch = ready);
  Alcotest.(check bool) "ready ≠ handoff" false (ready = handoff);
  Alcotest.(check bool) "launch ≠ handoff" false (launch = handoff);
  Alcotest.(check bool) "launch mentions alias" true (string_mem alias launch);
  Alcotest.(check bool) "handoff mentions alias" true (string_mem alias handoff);
  Alcotest.(check bool) "ready mentions endpoint" true (string_mem endpoint ready);
  (* Full timestamped lines for each phase (what operators see). *)
  let now = 0. in
  let fmt body = S.format_app_server_log ~color:false ~now body in
  Alcotest.(check bool) "launch line has label+ts" true
    (has_prefix S.app_server_log_label (fmt launch)
     && string_mem (S.app_server_log_hms now) (fmt launch));
  Alcotest.(check bool) "ready line has label+ts" true
    (has_prefix S.app_server_log_label (fmt ready));
  Alcotest.(check bool) "handoff line has label+ts" true
    (has_prefix S.app_server_log_label (fmt handoff))

let test_app_server_frontend_identity_env () =
  let env =
    S.app_server_frontend_env ~session_id:"managed-codex-session"
      ~alias:"codex-stack-digit-ca73"
  in
  Alcotest.(check (list string)) "frontend gets stable managed identity"
    [ "C2C_MCP_SESSION_ID=managed-codex-session"
    ; "C2C_CODEX_APPSERVER_SESSION=managed-codex-session"
    ; "C2C_MCP_AUTO_REGISTER_ALIAS=codex-stack-digit-ca73"
    ; "C2C_CODEX_MANAGED=1" ] env

(* ------------------------------------------------------------------ *)
(* --yolo forwarding + non-persistence                                 *)
(* ------------------------------------------------------------------ *)

let test_yolo_forwards_bypass () =
  let args = S.frontend_extra_args ~yolo:true ~extra:[ "--model"; "m" ] in
  Alcotest.(check bool) "contains bypass flag" true
    (List.mem "--dangerously-bypass-approvals-and-sandbox" args);
  Alcotest.(check string) "exact flag" "--dangerously-bypass-approvals-and-sandbox"
    S.yolo_bypass_flag;
  Alcotest.(check bool) "bypass is first (before passthrough)" true
    (match args with f :: _ -> f = S.yolo_bypass_flag | [] -> false)

let test_yolo_absent_by_default () =
  let args = S.frontend_extra_args ~yolo:false ~extra:[ "--model"; "m" ] in
  Alcotest.(check bool) "no bypass without --yolo" false
    (List.mem "--dangerously-bypass-approvals-and-sandbox" args);
  Alcotest.(check (list string)) "passthrough preserved" [ "--model"; "m" ] args

(* ------------------------------------------------------------------ *)
(* `--` passthrough splitting                                          *)
(* ------------------------------------------------------------------ *)

let test_drop_sep () =
  Alcotest.(check (list string)) "drops leading --"
    [ "--model"; "x" ] (S.drop_sep [ "--"; "--model"; "x" ]);
  Alcotest.(check (list string)) "no-op when absent"
    [ "--model"; "x" ] (S.drop_sep [ "--model"; "x" ])

let test_split_client_passthrough () =
  (* c2c new codex -- --model gpt-5.3-codex-spark *)
  let (client, extra) =
    S.split_client [ "codex"; "--"; "--model"; "gpt-5.3-codex-spark" ] in
  Alcotest.(check (option string)) "client" (Some "codex") client;
  Alcotest.(check (list string)) "verbatim passthrough"
    [ "--model"; "gpt-5.3-codex-spark" ] extra;
  (* Without an explicit `--` (cmdliner already stripped it): still verbatim. *)
  let (c2, e2) = S.split_client [ "codex"; "--model"; "x" ] in
  Alcotest.(check (option string)) "client2" (Some "codex") c2;
  Alcotest.(check (list string)) "passthrough2" [ "--model"; "x" ] e2;
  let (c3, e3) = S.split_client [ "codex" ] in
  Alcotest.(check (option string)) "client only" (Some "codex") c3;
  Alcotest.(check (list string)) "no passthrough" [] e3

let test_split_client_alias_passthrough () =
  (* c2c resume codex myalias -- --model x *)
  let (client, alias, extra) =
    S.split_client_alias [ "codex"; "myalias"; "--"; "--model"; "x" ] in
  Alcotest.(check (option string)) "client" (Some "codex") client;
  Alcotest.(check (option string)) "alias" (Some "myalias") alias;
  Alcotest.(check (list string)) "passthrough" [ "--model"; "x" ] extra;
  (* alias must NOT be captured from a `--`-prefixed token. *)
  let (_, alias2, extra2) = S.split_client_alias [ "codex"; "a"; "--model" ] in
  Alcotest.(check (option string)) "alias2" (Some "a") alias2;
  Alcotest.(check (list string)) "passthrough2" [ "--model" ] extra2

let test_namespaced_name_for_new_alias_wrapper_b221 () =
  (* alias cx='c2c new codex --'; cx --model gpt-5.6-sol --c2c:name mine *)
  let client, extra =
    S.split_client
      [ "codex"; "--"; "--model"; "gpt-5.6-sol";
        "--c2c:name"; "mine-codex" ]
  in
  Alcotest.(check (option string)) "client" (Some "codex") client;
  match S.resolve_namespaced_passthrough ~allow_name:true ~existing_name:None extra with
  | Error msg -> Alcotest.fail msg
  | Ok (name, frontend_args) ->
      Alcotest.(check (option string)) "managed name extracted"
        (Some "mine-codex") name;
      Alcotest.(check (list string)) "codex args preserved"
        [ "--model"; "gpt-5.6-sol" ] frontend_args

let test_namespaced_name_codex_conflict_and_resume_rejected_b221 () =
  Alcotest.(check bool) "pre-separator alias conflict rejected" true
    (match
       S.resolve_namespaced_passthrough ~allow_name:true
         ~existing_name:(Some "before") [ "--c2c:name"; "after" ]
     with Error _ -> true | Ok _ -> false);
  Alcotest.(check bool) "resume positional alias remains authoritative" true
    (match
       S.resolve_namespaced_passthrough ~allow_name:false ~existing_name:None
         [ "--model"; "x"; "--c2c:name"; "other" ]
     with Error _ -> true | Ok _ -> false)

(* ------------------------------------------------------------------ *)
(* thread-id conflict rejection                                        *)
(* ------------------------------------------------------------------ *)

let test_reconcile_thread () =
  let ok = function Ok v -> v | Error e -> Alcotest.failf "unexpected Error: %s" e in
  Alcotest.(check (option string)) "none/none" None
    (ok (S.reconcile_thread ~requested:None ~saved:None));
  Alcotest.(check (option string)) "saved wins when no request" (Some "T1")
    (ok (S.reconcile_thread ~requested:None ~saved:(Some "T1")));
  Alcotest.(check (option string)) "request when no saved" (Some "T2")
    (ok (S.reconcile_thread ~requested:(Some "T2") ~saved:None));
  Alcotest.(check (option string)) "matching request+saved" (Some "T3")
    (ok (S.reconcile_thread ~requested:(Some "T3") ~saved:(Some "T3")));
  (match S.reconcile_thread ~requested:(Some "Treq") ~saved:(Some "Tsaved") with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "conflicting thread ids must be rejected, not guessed")

(* ------------------------------------------------------------------ *)
(* status terminology                                                  *)
(* ------------------------------------------------------------------ *)

let test_status_mapping () =
  let eq name exp st =
    Alcotest.(check string) name exp (S.status_to_string (S.status_of_app_server_state st))
  in
  eq "allocating" "starting" Allocating;
  eq "starting_server" "starting" Starting_server;
  eq "waiting_ready" "starting" Waiting_ready;
  eq "starting_frontend" "starting" Starting_frontend;
  eq "running" "online-attached" Running;
  eq "frontend_exited" "offline" Frontend_exited;
  eq "stopping_server" "offline" Stopping_server;
  eq "offline" "offline" Offline;
  eq "failed" "failed-startup" Failed;
  eq "cleaning_up" "failed-startup" Cleaning_up

(* ------------------------------------------------------------------ *)
(* mapping round-trip                                                  *)
(* ------------------------------------------------------------------ *)

let with_tmp_dir f =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-codex-sess-%d-%d" (Unix.getpid ()) (Random.bits ())) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let test_mapping_roundtrip () =
  with_tmp_dir (fun dir ->
      let m = { S.session_id = "sid-123"; alias = "quokka-lantern";
                thread_id = Some "thr-abc"; created_at = 100.0; updated_at = 200.0 } in
      S.write_mapping ~instance_dir:dir m;
      match S.load_mapping ~instance_dir:dir with
      | None -> Alcotest.fail "mapping should round-trip"
      | Some m2 ->
          Alcotest.(check string) "session_id" m.session_id m2.session_id;
          Alcotest.(check string) "alias" m.alias m2.alias;
          Alcotest.(check (option string)) "thread_id" m.thread_id m2.thread_id)

let test_restart_request_roundtrip () =
  with_tmp_dir (fun dir ->
      let request_id = S.request_restart ~instance_dir:dir ~force:true in
      match C2c_io.read_json_opt (S.restart_request_path ~instance_dir:dir) with
      | Some (`Assoc fields) ->
          Alcotest.(check (option string)) "request id persisted" (Some request_id)
            (match List.assoc_opt "request_id" fields with
             | Some (`String s) -> Some s | _ -> None);
          Alcotest.(check (option bool)) "force persisted" (Some true)
            (match List.assoc_opt "force" fields with
             | Some (`Bool b) -> Some b | _ -> None)
      | _ -> Alcotest.fail "restart request should be valid JSON")

let test_restart_result_ack () =
  with_tmp_dir (fun dir ->
      let request_id = S.request_restart ~instance_dir:dir ~force:false in
      let result_path = S.restart_result_path ~instance_dir:dir ~request_id in
      let oc = open_out result_path in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
          Printf.fprintf oc "{\"request_id\":%S,\"result\":\"skipped-active\"}\n"
            request_id);
      Alcotest.(check (option string)) "explicit skip observed"
        (Some "skipped-active")
        (S.await_restart_result ~instance_dir:dir ~request_id ~timeout_s:0.1);
      Alcotest.(check bool) "result consumed" false (Sys.file_exists result_path))

let make_executable path =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc "#!/bin/sh\nexit 0\n");
  Unix.chmod path 0o755

let test_restart_executable_resolves_bare_path_launch () =
  with_tmp_dir (fun dir ->
      let installed = Filename.concat dir "c2c" in
      make_executable installed;
      Alcotest.(check (option string)) "PATH c2c selected over bare argv0"
        (Some (Unix.realpath installed))
        (S.resolve_restart_executable ~path:(Some dir) ~self:"c2c" ()))

let test_restart_executable_fails_before_stop_when_unavailable () =
  with_tmp_dir (fun dir ->
      Alcotest.(check (option string)) "no executable means no restart target"
        None
        (S.resolve_restart_executable ~path:(Some dir)
           ~self:"definitely-missing-c2c" ()))

let test_thread_persistence_repairs_config_independently () =
  let name = Printf.sprintf "b153-persist-%d-%d" (Unix.getpid ()) (Random.bits ()) in
  let dir = C2c_start.instance_dir name in
  C2c_io.mkdir_p dir;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      S.write_mapping ~instance_dir:dir
        { S.session_id = "sid"; alias = name; thread_id = Some "thread-exact";
          created_at = 1.; updated_at = 2. };
      C2c_start.write_config
        { C2c_start.name; client = "codex"; session_id = "sid";
          resume_session_id = "sid"; codex_resume_target = None; alias = name;
          extra_args = []; created_at = 1.; last_launch_at = None;
          last_exit_code = None; last_exit_reason = None; broker_root = "";
          auto_join_rooms = ""; binary_override = None; model_override = None;
          agent_name = None };
      Alcotest.(check bool) "already-ours persist reports bound" true
        (S.persist_discovered_thread ~instance_dir:dir ~name ~broker_root:""
           ~thread_id:"thread-exact");
      match C2c_start.load_config_opt name with
      | Some cfg ->
          Alcotest.(check (option string)) "config repaired despite fresh mapping"
            (Some "thread-exact") cfg.codex_resume_target;
          Alcotest.(check string) "resume id repaired" "thread-exact"
            cfg.resume_session_id
      | None -> Alcotest.fail "config missing")

(* ------------------------------------------------------------------ *)
(* Deliver-loop degraded signal persistence (B138)                     *)
(* ------------------------------------------------------------------ *)

let test_delivery_degraded_roundtrip () =
  with_tmp_dir (fun dir ->
      let uid = "u-1" in
      (* No signal file yet → None. *)
      Alcotest.(check (option bool)) "absent signal reads as None"
        None (S.delivery_degraded_of_instance ~instance_dir:dir ~unit_id:uid ());
      (* Degraded at loop start. *)
      S.write_delivery_degraded ~instance_dir:dir ~unit_id:uid true;
      Alcotest.(check (option bool)) "persisted degraded=true (matching unit)"
        (Some true) (S.delivery_degraded_of_instance ~instance_dir:dir ~unit_id:uid ());
      (* Flip to healthy once a thread loads — later write wins. *)
      S.write_delivery_degraded ~instance_dir:dir ~unit_id:uid false;
      Alcotest.(check (option bool)) "flip to healthy persists degraded=false"
        (Some false) (S.delivery_degraded_of_instance ~instance_dir:dir ~unit_id:uid ());
      (* A DIFFERENT unit_id must NOT trust the record — stale prior-run value. *)
      Alcotest.(check (option bool)) "mismatched unit_id reads as None (stale)"
        None (S.delivery_degraded_of_instance ~instance_dir:dir ~unit_id:"u-2" ());
      (* File name is the documented path so doctor/health read the same place. *)
      Alcotest.(check bool) "status file exists at the documented path" true
        (Sys.file_exists (S.delivery_status_path ~instance_dir:dir)))

(* ------------------------------------------------------------------ *)
(* #24 Codex thread split-brain: liveness-aware read resolver +        *)
(* write-side duplicate guard. Fully hermetic — no live Codex, uses    *)
(* this process's own pid for "alive" and a >pid_max pid for "dead".   *)
(* ------------------------------------------------------------------ *)

(* A pid guaranteed to have no /proc entry (exceeds Linux pid_max). *)
let dead_pid = 1_073_741_824

(* Run [f] with C2C_INSTANCES_DIR pointed at a fresh instances root and a
   fresh isolated broker root (no collision with any live peer). *)
let with_split_brain_env f =
  with_tmp_dir (fun root ->
      let inst = Filename.concat root "instances" in
      let broker_root = Filename.concat root "broker" in
      C2c_io.mkdir_p inst;
      C2c_io.mkdir_p broker_root;
      let prev = Sys.getenv_opt "C2C_INSTANCES_DIR" in
      Unix.putenv "C2C_INSTANCES_DIR" inst;
      Fun.protect
        ~finally:(fun () ->
          match prev with
          | Some v -> Unix.putenv "C2C_INSTANCES_DIR" v
          | None -> Unix.putenv "C2C_INSTANCES_DIR" "")
        (fun () -> f ~inst ~broker_root))

let write_codex_mapping ~dir ~session_id ~thread_id =
  C2c_io.mkdir_p dir;
  S.write_mapping ~instance_dir:dir
    { S.session_id; alias = Filename.basename dir; thread_id;
      created_at = 1.; updated_at = 2. }

let register_alive broker ~session_id ~alias =
  let pid = Unix.getpid () in
  B.register broker ~session_id ~alias ~pid:(Some pid)
    ~pid_start_time:(B.read_pid_start_time pid) ()

let register_dead broker ~session_id ~alias =
  B.register broker ~session_id ~alias ~pid:(Some dead_pid)
    ~pid_start_time:None ()

(* A: the resolver must follow the LIVE identity, not the first readdir hit.
   Asserted with the two instance dirs created in both orders. *)
let test_resolver_prefers_alive_regardless_of_order () =
  let run ~stale_first =
    with_split_brain_env (fun ~inst ~broker_root ->
        let broker = B.create ~root:broker_root in
        let thread = "thread-split-24" in
        let stale = (Filename.concat inst "unit-stale", "sid-stale") in
        let live = (Filename.concat inst "unit-live", "sid-live") in
        let make (dir, sid) =
          write_codex_mapping ~dir ~session_id:sid ~thread_id:(Some thread)
        in
        (* Creation order is the only thing [stale_first] changes; the resolver
           ranks by liveness, so the result must be identical either way. *)
        if stale_first then (make stale; make live)
        else (make live; make stale);
        register_dead broker ~session_id:"sid-stale" ~alias:"unit-stale";
        register_alive broker ~session_id:"sid-live" ~alias:"unit-live";
        Alcotest.(check (option string))
          (Printf.sprintf "alive session wins (stale_first=%b)" stale_first)
          (Some "sid-live")
          (PB.managed_session_id_from_codex_thread ~broker_root
             ~thread_id:thread))
  in
  run ~stale_first:true;
  run ~stale_first:false

(* A: none live → deterministic pick = newest registered_at. [sid-a-older] is
   registered FIRST (older) and sorts lexicographically BEFORE [sid-z-newer],
   so a correct newest-registered_at pick returns "sid-z-newer" and proves
   registered_at dominates the lexicographic final tiebreak. *)
let test_resolver_none_live_picks_newest () =
  with_split_brain_env (fun ~inst ~broker_root ->
      let broker = B.create ~root:broker_root in
      let thread = "thread-both-dead-24" in
      write_codex_mapping ~dir:(Filename.concat inst "unit-a")
        ~session_id:"sid-a-older" ~thread_id:(Some thread);
      write_codex_mapping ~dir:(Filename.concat inst "unit-z")
        ~session_id:"sid-z-newer" ~thread_id:(Some thread);
      register_dead broker ~session_id:"sid-a-older" ~alias:"unit-a";
      register_dead broker ~session_id:"sid-z-newer" ~alias:"unit-z";
      Alcotest.(check (option string))
        "none live -> newest registered_at wins (not lexicographic)"
        (Some "sid-z-newer")
        (PB.managed_session_id_from_codex_thread ~broker_root ~thread_id:thread))

(* A: a single (unique) mapping keeps working even when offline — no broker
   liveness required, so whoami/send for a legitimately-idle unit still resolve. *)
let test_resolver_single_offline_mapping_resolves () =
  with_split_brain_env (fun ~inst ~broker_root ->
      let thread = "thread-solo-24" in
      write_codex_mapping ~dir:(Filename.concat inst "unit-solo")
        ~session_id:"sid-solo" ~thread_id:(Some thread);
      (* No broker registration at all. *)
      Alcotest.(check (option string)) "sole mapping resolves offline"
        (Some "sid-solo")
        (PB.managed_session_id_from_codex_thread ~broker_root ~thread_id:thread))

(* B: write-side guard refuses to mint a second binding when a LIVE managed
   sibling already owns the thread. *)
let test_write_guard_refuses_on_live_sibling () =
  with_split_brain_env (fun ~inst ~broker_root ->
      let broker = B.create ~root:broker_root in
      let thread = "thread-guard-24" in
      let self_dir = Filename.concat inst "self" in
      let sib_dir = Filename.concat inst "sib" in
      write_codex_mapping ~dir:self_dir ~session_id:"sid-self" ~thread_id:None;
      write_codex_mapping ~dir:sib_dir ~session_id:"sid-sib"
        ~thread_id:(Some thread);
      register_alive broker ~session_id:"sid-sib" ~alias:"sib";
      Alcotest.(check bool) "refused: live sibling owns thread" false
        (S.persist_discovered_thread ~instance_dir:self_dir ~name:"self"
           ~broker_root ~thread_id:thread);
      match S.load_mapping ~instance_dir:self_dir with
      | Some m ->
          Alcotest.(check (option string)) "no second binding written" None
            m.thread_id
      | None -> Alcotest.fail "self mapping vanished")

(* B: a DEAD prior owner is freely reclaimed — the binding is written. *)
let test_write_guard_reclaims_dead_sibling () =
  with_split_brain_env (fun ~inst ~broker_root ->
      let broker = B.create ~root:broker_root in
      let thread = "thread-reclaim-24" in
      let self_dir = Filename.concat inst "self" in
      let sib_dir = Filename.concat inst "sib" in
      write_codex_mapping ~dir:self_dir ~session_id:"sid-self" ~thread_id:None;
      write_codex_mapping ~dir:sib_dir ~session_id:"sid-sib"
        ~thread_id:(Some thread);
      register_dead broker ~session_id:"sid-sib" ~alias:"sib";
      Alcotest.(check bool) "dead prior owner freely reclaimed" true
        (S.persist_discovered_thread ~instance_dir:self_dir ~name:"self"
           ~broker_root ~thread_id:thread);
      match S.load_mapping ~instance_dir:self_dir with
      | Some m ->
          Alcotest.(check (option string)) "binding written on reclaim"
            (Some thread) m.thread_id
      | None -> Alcotest.fail "self mapping vanished")

(* Build a minimal Running app-server persisted record for the given unit_id so
   online_attached_delivery_degraded can resolve the live unit. *)
let write_persisted_unit ~dir ~unit_id =
  let p : persisted =
    { unit_id; instance_name = "tst"; alias = Some "x";
      codex_version = "codex-cli 0.144.1";
      endpoint = { transport = "ws"; host = "127.0.0.1"; port = 40123 };
      token_env_var = "C2C_CODEX_REMOTE_TOKEN_TST";
      token_sha256 = String.make 64 'a';
      server_pid = Some (Unix.getpid ()); frontend_pid = None;
      thread_id = None; state = Running; created_at = 1.0; updated_at = 2.0 }
  in
  match write_persisted ~instance_dir:dir p with
  | Ok () -> () | Error e -> Alcotest.failf "write_persisted: %s" e

let test_online_attached_degraded_fail_closed () =
  (* The decision helper shared by `c2c doctor` + `c2c health`. Covers finding 2:
     true, false, absent, and stale/mismatched-generation. *)
  (* absent delivery record → fail-closed degraded (write-failure / mid-startup) *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-A";
      Alcotest.(check bool) "no delivery record → fail-closed degraded" true
        (S.online_attached_delivery_degraded ~instance_dir:dir ()));
  (* matching degraded=true → degraded *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-A";
      S.write_delivery_degraded ~instance_dir:dir ~unit_id:"u-A" true;
      Alcotest.(check bool) "matching degraded=true → degraded" true
        (S.online_attached_delivery_degraded ~instance_dir:dir ()));
  (* matching degraded=false (thread loaded) → healthy (NOT weakened) *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-A";
      S.write_delivery_degraded ~instance_dir:dir ~unit_id:"u-A" false;
      Alcotest.(check bool) "matching degraded=false → healthy" false
        (S.online_attached_delivery_degraded ~instance_dir:dir ()));
  (* stale record from a prior run (healthy=false but WRONG unit) → fail-closed
     degraded, so a reused dir never masks a new no-thread session *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-NEW";
      S.write_delivery_degraded ~instance_dir:dir ~unit_id:"u-OLD" false;
      Alcotest.(check bool) "stale healthy record (wrong unit) → fail-closed degraded"
        true (S.online_attached_delivery_degraded ~instance_dir:dir ()));
  (* no persisted app-server record at all → fail-closed degraded *)
  with_tmp_dir (fun dir ->
      Alcotest.(check bool) "no persisted record → fail-closed degraded" true
        (S.online_attached_delivery_degraded ~instance_dir:dir ()))

let test_i31_degraded_reason_roundtrip () =
  (* #31: the persisted record carries WHY it is degraded, so doctor/health can
     pick the followable remediation. *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-A";
      (* refused binding: degraded, reason=binding-refused, and thread_loaded
         stays TRUE (a thread IS loaded; only the binding was refused). *)
      S.write_delivery_degraded ~reason:S.Dr_binding_refused ~instance_dir:dir
        ~unit_id:"u-A" true;
      Alcotest.(check bool) "still degraded" true
        (S.online_attached_delivery_degraded ~instance_dir:dir ());
      Alcotest.(check bool) "reason surfaces as binding-refused" true
        (S.online_attached_delivery_binding_refused ~instance_dir:dir ());
      (match C2c_io.read_json_opt (S.delivery_status_path ~instance_dir:dir) with
       | Some (`Assoc a) ->
           Alcotest.(check (option bool)) "thread_loaded decoupled from degraded"
             (Some true)
             (match List.assoc_opt "thread_loaded" a with
              | Some (`Bool b) -> Some b | _ -> None)
       | _ -> Alcotest.fail "delivery-status record unreadable");
      (* no-thread: same degraded verdict, but NOT attributed to a refusal. *)
      S.write_delivery_degraded ~reason:S.Dr_no_thread ~instance_dir:dir
        ~unit_id:"u-A" true;
      Alcotest.(check bool) "no-thread is not reported as a refused binding" false
        (S.online_attached_delivery_binding_refused ~instance_dir:dir ());
      (* healthy: no reason at all. *)
      S.write_delivery_degraded ~instance_dir:dir ~unit_id:"u-A" false;
      Alcotest.(check bool) "healthy record has no refusal reason" false
        (S.online_attached_delivery_binding_refused ~instance_dir:dir ());
      Alcotest.(check (option (module struct
          type t = S.degraded_reason
          let equal = ( = )
          let pp fmt r = Format.pp_print_string fmt (S.degraded_reason_to_string r)
        end : Alcotest.TESTABLE with type t = S.degraded_reason)))
        "healthy record reports no reason" None
        (S.delivery_degraded_reason_of_instance ~instance_dir:dir ~unit_id:"u-A" ()));
  (* A record stamped for a DIFFERENT unit is never trusted for its reason
     either — no specific-but-wrong remediation from a stale record. *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-NEW";
      S.write_delivery_degraded ~reason:S.Dr_binding_refused ~instance_dir:dir
        ~unit_id:"u-OLD" true;
      Alcotest.(check bool) "stale-unit refusal reason is not trusted" false
        (S.online_attached_delivery_binding_refused ~instance_dir:dir ()));
  (* Backward compatibility: a degraded record written by a pre-#31 binary has
     no [reason] field and must read as the historical no-thread meaning. *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-A";
      let path = S.delivery_status_path ~instance_dir:dir in
      let oc = open_out path in
      output_string oc
        {|{"unit_id":"u-A","degraded":true,"thread_loaded":false,"updated_at":1.0}|};
      close_out oc;
      Alcotest.(check bool) "legacy degraded record is not a refusal" false
        (S.online_attached_delivery_binding_refused ~instance_dir:dir ()))

(* #27: a persisted degraded=false record whose HEARTBEAT [updated_at] is stale
   (the deliver loop was SIGKILLed while the frontend TUI child survived) must be
   downgraded to degraded so the silently-deaf session becomes visible. A FRESH
   heartbeat still reads healthy. Uses the [?now]/[?stale_window_s] test seams so
   the assertion is hermetic (no real clock). *)
let test_online_attached_degraded_stale_heartbeat () =
  let window = 120.0 in
  (* Stamp a healthy record at t=1000 with a matching unit. *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-A";
      S.write_delivery_degraded ~now:1000.0 ~instance_dir:dir ~unit_id:"u-A" false;
      (* Fresh heartbeat (now just past the stamp, within the window) → healthy. *)
      Alcotest.(check bool) "fresh heartbeat (degraded=false) → healthy" false
        (S.online_attached_delivery_degraded ~now:1005.0 ~stale_window_s:window
           ~instance_dir:dir ());
      (* Stale heartbeat (now far past the stamp, beyond the window) → the loop
         is presumed dead, so degraded=false is DOWNGRADED to degraded. *)
      Alcotest.(check bool) "stale heartbeat (degraded=false) → degraded" true
        (S.online_attached_delivery_degraded ~now:(1000.0 +. window +. 30.0)
           ~stale_window_s:window ~instance_dir:dir ());
      (* Same, at the raw read layer (matching unit, degraded=false, stale). *)
      Alcotest.(check (option bool)) "raw read: stale healthy → Some true"
        (Some true)
        (S.delivery_degraded_of_instance ~now:(1000.0 +. window +. 30.0)
           ~stale_window_s:window ~instance_dir:dir ~unit_id:"u-A" ()));
  (* A DEGRADED record with a stale heartbeat stays degraded (never upgraded). *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-A";
      S.write_delivery_degraded ~now:1000.0 ~instance_dir:dir ~unit_id:"u-A" true;
      Alcotest.(check bool) "stale + already degraded → still degraded" true
        (S.online_attached_delivery_degraded ~now:(1000.0 +. window +. 30.0)
           ~stale_window_s:window ~instance_dir:dir ()))

(* ------------------------------------------------------------------ *)
(* Lifecycle glue: alias published only after start succeeds; graceful *)
(* fallback on a startup diagnostic.                                   *)
(* ------------------------------------------------------------------ *)

type fake = { mutable status : child_status }

let mk_fake ?(id = 4242) (f : fake) : child =
  { child_id = id;
    poll_fn = (fun () -> f.status);
    signal_fn = (fun _ -> ());
    reap_fn = (fun _ -> (match f.status with Running_ -> f.status <- Exited 0 | _ -> ()); f.status) }

let scripted ~clock ?(codex_version = Ok "codex-cli 0.144.1") ?(capabilities = Ok ())
    ?(spawn_server = fun ~argv:_ ~env:_ ~log_path:_ -> Error "unset")
    ?(spawn_frontend = fun ~argv:_ ~env:_ -> Error "unset") () : backend =
  { now = (fun () -> !clock); sleep = (fun d -> clock := !clock +. d);
    gen_token = (fun () -> "RAWT0KEN_do_not_leak");
    alloc_port = (fun () -> Ok 40123);
    codex_version = (fun _ -> codex_version); capabilities = (fun _ -> capabilities);
    spawn_server; spawn_frontend;
    probe_ready = (fun _ ~token:_ -> Ok ());
    verify_owner = (fun _ ~server_pid:_ -> true) }

(* A stable, unique session id => a deterministic derived alias => a known
   instance dir we can inspect and clean. *)
let unique_sid () = Printf.sprintf "t006-glue-%d-%d" (Unix.getpid ()) (Random.bits ())

let cleanup_alias alias =
  ignore (Sys.command (Printf.sprintf "rm -rf %s"
    (Filename.quote (C2c_start.instance_dir alias))))

let test_glue_happy_publishes_after_start () =
  let sid = unique_sid () in
  let alias = S.derive_alias ~session_id:sid ~taken:(fun _ -> false) in
  Fun.protect ~finally:(fun () -> cleanup_alias alias) (fun () ->
      let clock = ref 0.0 in
      let server = { status = Running_ } in
      (* Frontend already exited => supervise_until_exit returns immediately. *)
      let frontend = { status = Exited 0 } in
      let bk = scripted ~clock
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> Ok (mk_fake ~id:111 server))
          ~spawn_frontend:(fun ~argv:_ ~env:_ -> Ok (mk_fake ~id:222 frontend)) () in
      let fallback_called = ref false in
      (* No --app-server flag: the app-server transport is now the default+only
         managed path for a supported codex. A supported scripted codex must NOT
         fall back to hooks. *)
      let rc = S.run ~mode:S.Start ~yolo:false
          ~extra_args:[] ~thread_id:sid ~backend:bk
          ~fallback:(fun ~extra_args:_ () -> fallback_called := true; 99) () in
      Alcotest.(check bool) "fallback NOT used on happy path" false !fallback_called;
      Alcotest.(check int) "clean exit" 0 rc;
      Alcotest.(check bool) "managed config persisted" true
        (Sys.file_exists (C2c_start.config_path alias));
      Alcotest.(check bool) "launcher pid persisted" true
        (Sys.file_exists (C2c_start.outer_pid_path alias));
      (* B167: the app-server loop must register under the exact managed
         session id supplied to the remote frontend in C2C_MCP_SESSION_ID,
         rather than under the display/instance name.  Otherwise the first
         SessionStart hook cannot adopt this alias and mints a second identity;
         mail to that user-visible alias then bypasses the arrival loop. *)
      let broker = C2c_mcp.Broker.create
          ~root:(Sys.getenv "C2C_MCP_BROKER_ROOT") in
      (match List.find_opt
               (fun (r : C2c_mcp.registration) -> r.session_id = sid)
               (C2c_mcp.Broker.list_registrations broker)
       with
       | Some r -> Alcotest.(check string) "broker row uses frontend session id"
                     alias r.alias
       | None -> Alcotest.fail "managed frontend session id was never registered");
      (match C2c_start.load_config_opt alias with
       | Some cfg ->
           Alcotest.(check string) "managed client is codex" "codex" cfg.client;
           Alcotest.(check string) "exact resume target persisted" sid
             (Option.value cfg.codex_resume_target ~default:"")
       | None -> Alcotest.fail "managed config must load");
      (* The routable mapping is published only after start returned Ok. *)
      match S.load_mapping ~instance_dir:(C2c_start.instance_dir alias) with
      | None -> Alcotest.fail "mapping should be published after Running"
      | Some m ->
          Alcotest.(check string) "published alias" alias m.alias;
          Alcotest.(check string) "seed persisted" sid m.session_id)

let test_generic_start_namespaced_name_reaches_app_server_alias_b221 () =
  (* Wiring regression: generic [c2c start codex] parses the reserved control,
     converts it to the app-server's [alias_override], and the normal
     app-server lifecycle exports that exact routable identity to the remote
     frontend.  Testing only the fallback [C2c_start.cmd_start] path would miss
     this because that path derives its alias from the instance name. *)
  let alias =
    Printf.sprintf "cx-custom-%d-%d" (Unix.getpid ()) (Random.bits ())
  in
  let sid = unique_sid () in
  let parsed =
    match C2c_start.parse_namespaced_passthrough
            [ "--model"; "gpt-5.6-sol"; "--c2c:name"; alias ] with
    | Ok parsed -> parsed
    | Error msg -> Alcotest.fail msg
  in
  let alias_override =
    C2c_start.codex_alias_override_for_managed_start ~alias_opt:None
      ~requested_name:parsed.C2c_start.c2c_name
  in
  Fun.protect ~finally:(fun () -> cleanup_alias alias) (fun () ->
      let clock = ref 0.0 in
      let server = { status = Running_ } in
      let frontend = { status = Exited 0 } in
      let frontend_env = ref [||] in
      let bk = scripted ~clock
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ ->
            Ok (mk_fake ~id:311 server))
          ~spawn_frontend:(fun ~argv:_ ~env ->
            frontend_env := env;
            Ok (mk_fake ~id:322 frontend)) () in
      let rc = S.run ~mode:S.Start ?alias_override ~yolo:false
          ~extra_args:parsed.C2c_start.client_args ~thread_id:sid ~backend:bk
          ~fallback:(fun ~extra_args:_ () -> 99) () in
      Alcotest.(check int) "normal app-server path succeeds" 0 rc;
      Alcotest.(check bool) "frontend receives requested broker alias" true
        (Array.exists (( = ) ("C2C_MCP_AUTO_REGISTER_ALIAS=" ^ alias))
           !frontend_env);
      match S.load_mapping ~instance_dir:(C2c_start.instance_dir alias) with
      | None -> Alcotest.fail "namespaced alias mapping should be published"
      | Some mapping ->
          Alcotest.(check string) "published namespaced alias" alias mapping.alias)

(* #34 review, fix 1. [resolve_identity] guards only saved codex mappings and
   managed-instance configs, so it is blind to a PLAIN broker registry row — a
   vanilla Claude Code / hook-codex / relay peer, i.e. the common case. Before
   this fix `c2c start codex -n <live-peer-alias>` sailed all the way through:
   [C2c_mcp.Broker.register] did refuse (no hijack, delivery integrity was never
   at risk), but only AFTER write_config, the outer pidfile, the app-server and
   the TUI spawn — and uncaught, so the launcher died leaving an orphaned codex
   frontend with no broker row, no delivery loop, and a poisoned instance dir.

   Asserted here through a fork because the refusal is a hard [exit 1]: the child
   must exit nonzero having spawned NOTHING and written NOTHING. *)
let test_i34r_live_registry_alias_refused_before_launch () =
  let alias = Printf.sprintf "i34r-live-%d-%d" (Unix.getpid ()) (Random.bits ()) in
  let tmp = Filename.temp_file "c2c-i34r-broker" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o700;
  let spawn_marker = Filename.concat tmp "server-was-spawned" in
  Fun.protect
    ~finally:(fun () ->
      cleanup_alias alias;
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmp))))
    (fun () ->
      (* A live plain peer already owns [alias]: this test process, which is
         alive and signalable but is NOT the forked child's pid (self-owned rows
         are deliberately not conflicts, so the holder must be someone else). *)
      let holder_pid = Unix.getpid () in
      Yojson.Safe.to_file (Filename.concat tmp "registry.json")
        (`List
           [ `Assoc
               [ ("session_id", `String "some-other-session")
               ; ("alias", `String alias)
               ; ("pid", `Int holder_pid) ] ]);
      flush stdout;
      flush stderr;
      match Unix.fork () with
      | 0 ->
          (* Child: the launcher. Any spawn is a failure, recorded on disk so
             the parent can see it even though the child exits. *)
          Unix.putenv "C2C_MCP_BROKER_ROOT" tmp;
          let clock = ref 0.0 in
          let bk =
            scripted ~clock
              ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ ->
                close_out (open_out spawn_marker);
                Error "must not be reached")
              ~spawn_frontend:(fun ~argv:_ ~env:_ -> Error "must not be reached")
              ()
          in
          let rc =
            try
              S.run ~mode:S.Start ~alias_override:alias ~yolo:false
                ~extra_args:[] ~thread_id:(unique_sid ()) ~backend:bk
                ~fallback:(fun ~extra_args:_ () -> 99) ()
            with _ -> 98
          in
          (* Reached only if the guard did NOT refuse. *)
          Stdlib.exit (if rc = 0 then 0 else rc)
      | child ->
          let _, status = Unix.waitpid [] child in
          (match status with
           | Unix.WEXITED 0 ->
               Alcotest.fail
                 "launcher accepted an alias held by a LIVE plain registry peer"
           | Unix.WEXITED 1 -> ()
           | Unix.WEXITED n ->
               Alcotest.failf "expected exit 1 from the pre-launch guard, got %d" n
           | _ -> Alcotest.fail "launcher child died abnormally");
          Alcotest.(check bool) "app-server was never spawned" false
            (Sys.file_exists spawn_marker);
          Alcotest.(check bool) "no managed instance config was written" false
            (Sys.file_exists (C2c_start.config_path alias));
          Alcotest.(check bool) "no outer pidfile was written" false
            (Sys.file_exists (C2c_start.outer_pid_path alias)))

(* The managed-peer case was ALREADY clean via [config_exists] and must stay
   that way: it errors out of resolve_identity with its own message, before the
   registry guard and before any launch side effect. *)
let test_i34r_managed_peer_path_not_regressed () =
  let alias = Printf.sprintf "i34r-managed-%d-%d" (Unix.getpid ()) (Random.bits ()) in
  match
    S.resolve_identity ~mode:S.Start ~alias_override:(Some alias)
      ~thread_id:None
      ~lookup:(fun _ -> None)
      ~config_exists:(fun a -> a = alias)
  with
  | Ok _ ->
      Alcotest.fail "a managed-instance-owned alias must still be refused"
  | Error msg ->
      Alcotest.(check bool) "still the non-app-server managed-instance message"
        true
        (string_mem "non-app-server managed instance" msg)

let test_glue_new_mode_default_engages_app_server () =
  (* AC (B131): plain `c2c new codex` (mode=New, NO --app-server flag) must select
     the app-server path on a supported codex — never the hook fallback. Mirrors
     the Start-mode happy path but exercises the New launch mode the `c2c new
     codex` command uses. *)
  let sid = unique_sid () in
  let alias = S.derive_alias ~session_id:sid ~taken:(fun _ -> false) in
  Fun.protect ~finally:(fun () -> cleanup_alias alias) (fun () ->
      let clock = ref 0.0 in
      let server = { status = Running_ } in
      let frontend = { status = Exited 0 } in
      let bk = scripted ~clock
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> Ok (mk_fake ~id:111 server))
          ~spawn_frontend:(fun ~argv:_ ~env:_ -> Ok (mk_fake ~id:222 frontend)) () in
      let fallback_called = ref false in
      let rc = S.run ~mode:S.New ~yolo:false
          ~extra_args:[ "--model"; "gpt-5.3-codex-spark" ] ~thread_id:sid ~backend:bk
          ~fallback:(fun ~extra_args:_ () -> fallback_called := true; 99) () in
      Alcotest.(check bool) "new codex on supported codex does NOT fall back to hooks"
        false !fallback_called;
      Alcotest.(check int) "clean exit" 0 rc;
      match S.load_mapping ~instance_dir:(C2c_start.instance_dir alias) with
      | None -> Alcotest.fail "new codex should publish the mapping after Running"
      | Some m -> Alcotest.(check string) "published alias" alias m.alias)

let test_glue_diagnostic_falls_back_no_publish () =
  let sid = unique_sid () in
  let alias = S.derive_alias ~session_id:sid ~taken:(fun _ -> false) in
  Fun.protect ~finally:(fun () -> cleanup_alias alias) (fun () ->
      let clock = ref 0.0 in
      (* Too-old codex => start returns a version diagnostic BEFORE any spawn,
         so no routable alias is ever published. *)
      let bk = scripted ~clock ~codex_version:(Ok "codex-cli 0.100.0") () in
      let fallback_called = ref false in
      (* Unsupported codex (0.100.0) => the app-server start returns a version
         diagnostic and run AUTOMATICALLY falls back to the hook path (no flag). *)
      let rc = S.run ~mode:S.Start ~yolo:false
          ~extra_args:[ "--model"; "x" ] ~thread_id:sid ~backend:bk
          ~fallback:(fun ~extra_args () ->
              fallback_called := true;
              (* passthrough forwarded to the hook fallback *)
              Alcotest.(check bool) "passthrough reaches fallback" true
                (List.mem "--model" extra_args);
              77) () in
      Alcotest.(check bool) "fallback used on diagnostic" true !fallback_called;
      Alcotest.(check int) "fallback exit code propagated" 77 rc;
      Alcotest.(check (option string)) "no alias published on failure" None
        (Option.map (fun (m : S.mapping) -> m.alias)
           (S.load_mapping ~instance_dir:(C2c_start.instance_dir alias))))

(* B175: upgrade guidance only for version/capability gaps; readiness timeout
   / process exit on a supported Codex must NOT tell the operator to upgrade. *)
let test_diagnostic_followup_upgrade_only_when_version_issue () =
  let min = "0.144.0" in
  let version_diag : diagnostic =
    { code = Codex_version_unsupported;
      message = "codex too old";
      codex_version = Some "codex-cli 0.100.0";
      min_codex_version = Some min }
  in
  let timeout_diag : diagnostic =
    { code = Readiness_timeout;
      message = "app-server did not become ready within 90.0s";
      codex_version = Some "codex-cli 0.144.1";
      min_codex_version = Some min }
  in
  let died_diag : diagnostic =
    { code = Server_died_before_ready;
      message = "app-server exited before becoming ready (exited:1)";
      codex_version = Some "codex-cli 0.144.1";
      min_codex_version = Some min }
  in
  let v = S.diagnostic_followup version_diag in
  let t = S.diagnostic_followup timeout_diag in
  let d = S.diagnostic_followup died_diag in
  Alcotest.(check bool) "version failure mentions upgrade" true
    (string_mem "upgrade codex" v);
  Alcotest.(check bool) "timeout does NOT say upgrade" false
    (string_mem "upgrade codex" t);
  Alcotest.(check bool) "timeout mentions readiness" true
    (string_mem "readiness timeout" t);
  Alcotest.(check bool) "died does NOT say upgrade" false
    (string_mem "upgrade codex" d);
  Alcotest.(check bool) "died mentions process exit" true
    (string_mem "exited before it was" d);
  Alcotest.(check bool) "timeout still falls back to hooks" true
    (string_mem "hook-backed" t)

let test_force_hooks_env_uses_fallback () =
  (* The hidden C2C_CODEX_FORCE_HOOKS=1 escape (operator testing only) skips the
     app-server path entirely and runs the hook fallback; --yolo still forwards
     the bypass flag through the effective extra_args. *)
  let seen = ref [] in
  Unix.putenv "C2C_CODEX_FORCE_HOOKS" "1";
  (* B224: this is a backend=None launch, so the MCP preflight would otherwise
     read the host's real ~/.codex/config.toml and could short-circuit to exit 78
     on a machine with a stale c2c block. Bypass it — this test is about the
     force-hooks escape, not the preflight (which has its own hermetic tests). *)
  let saved_skip = Sys.getenv_opt "C2C_CODEX_SKIP_MCP_PREFLIGHT" in
  Unix.putenv "C2C_CODEX_SKIP_MCP_PREFLIGHT" "1";
  let rc =
    Fun.protect
      ~finally:(fun () ->
        Unix.putenv "C2C_CODEX_FORCE_HOOKS" "0";
        Unix.putenv "C2C_CODEX_SKIP_MCP_PREFLIGHT"
          (match saved_skip with Some v -> v | None -> ""))
      (fun () ->
        S.run ~mode:S.Start ~yolo:true ~extra_args:[ "--model"; "x" ]
          ~fallback:(fun ~extra_args () -> seen := extra_args; 0) ())
  in
  Alcotest.(check int) "fallback rc" 0 rc;
  Alcotest.(check bool) "yolo bypass forwarded to hook path" true
    (List.mem "--dangerously-bypass-approvals-and-sandbox" !seen);
  Alcotest.(check bool) "passthrough preserved" true (List.mem "--model" !seen)

(* ------------------------------------------------------------------ *)
(* B224: stale codex MCP-block preflight                               *)
(* ------------------------------------------------------------------ *)

(* The block `c2c install codex` writes when it finds a real `c2c-mcp-server`. *)
let mcp_block_bare ~server =
  Printf.sprintf
    "\n[mcp_servers.c2c]\ncommand = \"%s\"\nargs = []\n\n\
     [mcp_servers.c2c.env]\nC2C_MCP_CLIENT_TYPE = \"codex\"\n\n\
     [mcp_servers.c2c.tools.send]\napproval_mode = \"auto\"\n"
    server

(* The block written for a dev build: `opam exec -- <server_path>` — the shape
   whose <server_path> going stale (removed _build/tmp path) is B224. *)
let mcp_block_opam ~server_path =
  Printf.sprintf
    "\n[mcp_servers.c2c]\ncommand = \"opam\"\nargs = [\"exec\", \"--\", \"%s\"]\n\n\
     [mcp_servers.c2c.env]\nC2C_MCP_CLIENT_TYPE = \"codex\"\n"
    server_path

let test_preflight_parse_bare () =
  match S.parse_codex_mcp_command (mcp_block_bare ~server:"c2c-mcp-server") with
  | Some (Some cmd, args) ->
      Alcotest.(check string) "command" "c2c-mcp-server" cmd;
      Alcotest.(check (list string)) "no args" [] args
  | _ -> Alcotest.fail "expected a parsed command"

let test_preflight_parse_opam () =
  match S.parse_codex_mcp_command (mcp_block_opam ~server_path:"/tmp/x/c2c-mcp-server") with
  | Some (Some cmd, args) ->
      Alcotest.(check string) "command" "opam" cmd;
      (* the nested [.env] header stops the scan: only exec/--/<path> captured *)
      Alcotest.(check (list string)) "opam exec args"
        [ "exec"; "--"; "/tmp/x/c2c-mcp-server" ] args
  | _ -> Alcotest.fail "expected a parsed command"

let test_preflight_parse_absent () =
  Alcotest.(check bool) "no c2c section => None" true
    (S.parse_codex_mcp_command "[mcp_servers.other]\ncommand = \"x\"\n" = None)

(* Classifier (pure) — the core of the regression. A stale opam server_path or a
   bare command that no longer resolves must be flagged; a resolvable one must
   not; an absent block reads as Missing (not the failure mode). *)
let never_resolves _ = false
let always_resolves _ = true

let test_preflight_stale_opam_path () =
  (* `c2c new codex` with the reported stale block: opam exec -- <gone path>. *)
  let content = Some (mcp_block_opam ~server_path:"/tmp/gone/c2c-mcp-server") in
  match S.classify_codex_mcp_block ~content ~resolves:never_resolves with
  | S.Mcp_stale reason ->
      Alcotest.(check bool) "reason names the unresolvable target" true
        (string_mem "/tmp/gone/c2c-mcp-server" reason)
  | _ -> Alcotest.fail "a removed opam server_path must classify as stale"

let test_preflight_ok_opam_path () =
  let content = Some (mcp_block_opam ~server_path:"/opt/c2c/c2c-mcp-server") in
  Alcotest.(check bool) "resolvable opam server_path is ok" true
    (S.classify_codex_mcp_block ~content ~resolves:always_resolves = S.Mcp_ok)

let test_preflight_stale_bare_off_path () =
  let content = Some (mcp_block_bare ~server:"c2c-mcp-server") in
  match S.classify_codex_mcp_block ~content ~resolves:never_resolves with
  | S.Mcp_stale reason ->
      Alcotest.(check bool) "reason names the command" true
        (string_mem "c2c-mcp-server" reason)
  | _ -> Alcotest.fail "a c2c-mcp-server off PATH must classify as stale"

let test_preflight_ok_bare_on_path () =
  let content = Some (mcp_block_bare ~server:"c2c-mcp-server") in
  Alcotest.(check bool) "c2c-mcp-server on PATH is ok" true
    (S.classify_codex_mcp_block ~content ~resolves:always_resolves = S.Mcp_ok)

let test_preflight_missing_block () =
  Alcotest.(check bool) "no block => missing (proceed, not the failure mode)" true
    (S.classify_codex_mcp_block
       ~content:(Some "[mcp_servers.other]\ncommand = \"x\"\n")
       ~resolves:always_resolves = S.Mcp_missing);
  Alcotest.(check bool) "absent file => missing" true
    (S.classify_codex_mcp_block ~content:None ~resolves:always_resolves = S.Mcp_missing)

(* Impure preflight over a real config file with an injected resolver: exercises
   the file read + C2C_CODEX_CONFIG_PATH-style override that `c2c new codex`
   drives (via the default ~/.codex/config.toml path). *)
let test_preflight_reads_config_file () =
  with_tmp_dir (fun dir ->
      let cfg = Filename.concat dir "config.toml" in
      let oc = open_out cfg in
      output_string oc (mcp_block_opam ~server_path:"/tmp/gone/c2c-mcp-server");
      close_out oc;
      (match S.preflight_codex_mcp_block ~config_path:cfg ~resolves:never_resolves () with
       | S.Mcp_stale _ -> ()
       | _ -> Alcotest.fail "stale on-disk block should classify as stale");
      Alcotest.(check bool) "same block resolves => ok" true
        (S.preflight_codex_mcp_block ~config_path:cfg ~resolves:always_resolves ()
         = S.Mcp_ok);
      (* absent file => missing *)
      Alcotest.(check bool) "absent config file => missing" true
        (S.preflight_codex_mcp_block
           ~config_path:(Filename.concat dir "nope.toml")
           ~resolves:always_resolves () = S.Mcp_missing))

let test_preflight_diagnostic_is_actionable () =
  let d = S.codex_mcp_preflight_diagnostic "the c2c MCP command `x` is not runnable" in
  Alcotest.(check bool) "names the repair command" true (string_mem "c2c install codex" d);
  Alcotest.(check bool) "names the skip escape" true
    (string_mem "C2C_CODEX_SKIP_MCP_PREFLIGHT" d)

(* End-to-end gate: `c2c new codex` (mode=New) aborts BEFORE any launch when the
   preflight (over a C2C_CODEX_CONFIG_PATH-pointed stale block) trips. No backend
   is injected — this is the real launch path — but the stale block short-circuits
   run before it ever reaches the app-server/hook dispatch, so the fallback is
   never called and the distinguished exit code is returned. *)
let test_new_codex_aborts_on_stale_block () =
  with_tmp_dir (fun dir ->
      let cfg = Filename.concat dir "config.toml" in
      let oc = open_out cfg in
      output_string oc (mcp_block_opam ~server_path:"/tmp/definitely-gone/c2c-mcp-server");
      close_out oc;
      let saved = Sys.getenv_opt "C2C_CODEX_CONFIG_PATH" in
      Unix.putenv "C2C_CODEX_CONFIG_PATH" cfg;
      Fun.protect
        ~finally:(fun () ->
          match saved with
          | Some v -> Unix.putenv "C2C_CODEX_CONFIG_PATH" v
          | None -> Unix.putenv "C2C_CODEX_CONFIG_PATH" "")
        (fun () ->
          let fallback_called = ref false in
          let rc =
            S.run ~mode:S.New ~yolo:false ~extra_args:[]
              ~fallback:(fun ~extra_args:_ () -> fallback_called := true; 0) ()
          in
          Alcotest.(check bool) "stale block => launch aborted, fallback NOT called"
            false !fallback_called;
          Alcotest.(check int) "distinguished preflight exit code"
            S.codex_mcp_preflight_exit_code rc))

(* The C2C_CODEX_SKIP_MCP_PREFLIGHT=1 escape lets a launch through even with a
   stale block (operator override). With no backend and force-hooks on, the
   fallback runs instead of aborting. *)
let test_skip_env_bypasses_preflight () =
  with_tmp_dir (fun dir ->
      let cfg = Filename.concat dir "config.toml" in
      let oc = open_out cfg in
      output_string oc (mcp_block_opam ~server_path:"/tmp/definitely-gone/c2c-mcp-server");
      close_out oc;
      let saved_cfg = Sys.getenv_opt "C2C_CODEX_CONFIG_PATH" in
      let saved_skip = Sys.getenv_opt "C2C_CODEX_SKIP_MCP_PREFLIGHT" in
      let saved_hooks = Sys.getenv_opt "C2C_CODEX_FORCE_HOOKS" in
      Unix.putenv "C2C_CODEX_CONFIG_PATH" cfg;
      Unix.putenv "C2C_CODEX_SKIP_MCP_PREFLIGHT" "1";
      Unix.putenv "C2C_CODEX_FORCE_HOOKS" "1";
      let restore key = function Some v -> Unix.putenv key v | None -> Unix.putenv key "" in
      Fun.protect
        ~finally:(fun () ->
          restore "C2C_CODEX_CONFIG_PATH" saved_cfg;
          restore "C2C_CODEX_SKIP_MCP_PREFLIGHT" saved_skip;
          restore "C2C_CODEX_FORCE_HOOKS" saved_hooks)
        (fun () ->
          let fallback_called = ref false in
          let rc =
            S.run ~mode:S.New ~yolo:false ~extra_args:[]
              ~fallback:(fun ~extra_args:_ () -> fallback_called := true; 0) ()
          in
          Alcotest.(check bool) "skip env => preflight bypassed, fallback runs"
            true !fallback_called;
          Alcotest.(check int) "fallback rc propagated" 0 rc))

(* ------------------------------------------------------------------ *)
(* B227: resume-thread persistence preflight                           *)
(* ------------------------------------------------------------------ *)

let persistence_str = function
  | S.Thread_persisted -> "persisted"
  | S.Thread_unpersisted -> "unpersisted"
  | S.Thread_unknown -> "unknown"

let with_b227_env bindings f =
  let saved =
    List.map (fun (key, _) -> (key, Sys.getenv_opt key)) bindings in
  List.iter (fun (key, value) -> Unix.putenv key value) bindings;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (key, value) -> Unix.putenv key (Option.value value ~default:""))
        saved)
    f

(* Codex rollout layout: sessions/YYYY/MM/DD/rollout-<ts>-<thread-id>.jsonl *)
let write_rollout ~sessions_dir ~thread_id =
  let day =
    List.fold_left Filename.concat sessions_dir [ "2026"; "07"; "17" ] in
  C2c_io.mkdir_p day;
  let path =
    Filename.concat day
      (Printf.sprintf "rollout-2026-07-17T20-36-06-%s.jsonl" thread_id) in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc "{}\n"; path)

let test_rollout_scan_states () =
  with_tmp_dir (fun dir ->
      let sessions = Filename.concat dir "sessions" in
      (* missing sessions dir → Unknown (never treat as absence) *)
      Alcotest.(check string) "missing dir → unknown" "unknown"
        (persistence_str
           (S.thread_rollout_exists ~sessions_dir:sessions ~thread_id:"t-1"));
      C2c_io.mkdir_p sessions;
      (* dir exists, no rollout → Unpersisted (the B227 zero-turn case) *)
      Alcotest.(check string) "no rollout → unpersisted" "unpersisted"
        (persistence_str
           (S.thread_rollout_exists ~sessions_dir:sessions ~thread_id:"t-1"));
      (* An unrelated jsonl is not a Codex rollout and must not vouch for a
         thread that Codex never persisted. *)
      let decoy = Filename.concat sessions "not-a-rollout-t-1.jsonl" in
      let decoy_oc = open_out decoy in
      output_string decoy_oc "{}\n";
      close_out decoy_oc;
      Alcotest.(check string) "non-rollout jsonl → unpersisted" "unpersisted"
        (persistence_str
           (S.thread_rollout_exists ~sessions_dir:sessions ~thread_id:"t-1"));
      Sys.remove decoy;
      ignore (write_rollout ~sessions_dir:sessions ~thread_id:"t-1");
      Alcotest.(check string) "date-partitioned rollout → persisted" "persisted"
        (persistence_str
           (S.thread_rollout_exists ~sessions_dir:sessions ~thread_id:"t-1"));
      (* a DIFFERENT thread's rollout does not vouch for this one *)
      Alcotest.(check string) "other thread's rollout → unpersisted" "unpersisted"
        (persistence_str
           (S.thread_rollout_exists ~sessions_dir:sessions ~thread_id:"t-2"));
      (* blank id → Unknown *)
      Alcotest.(check string) "blank id → unknown" "unknown"
        (persistence_str
           (S.thread_rollout_exists ~sessions_dir:sessions ~thread_id:"  ")))

let test_rollout_scan_uncertainty () =
  with_tmp_dir (fun dir ->
      (* The ROOT is resolved through symlinks before classifying: profile-share
         setups symlink ~/.codex and ~/.codex/sessions (the B227 incident
         machine's layout), and treating that as uncertainty would leave the
         preflight inert exactly where the bug happens. The resolved tree then
         answers authoritatively. *)
      let real_sessions = Filename.concat dir "real-sessions" in
      let sessions_link = Filename.concat dir "sessions-link" in
      C2c_io.mkdir_p real_sessions;
      Unix.symlink real_sessions sessions_link;
      Alcotest.(check string) "symlinked empty root resolves → unpersisted"
        "unpersisted"
        (persistence_str
           (S.thread_rollout_exists ~sessions_dir:sessions_link ~thread_id:"t-1"));
      write_rollout ~sessions_dir:real_sessions ~thread_id:"t-1";
      Alcotest.(check string) "symlinked root resolves → persisted" "persisted"
        (persistence_str
           (S.thread_rollout_exists ~sessions_dir:sessions_link ~thread_id:"t-1"));
      let dangling = Filename.concat dir "dangling-link" in
      Unix.symlink (Filename.concat dir "no-such-target") dangling;
      Alcotest.(check string) "dangling root symlink → unknown" "unknown"
        (persistence_str
           (S.thread_rollout_exists ~sessions_dir:dangling ~thread_id:"t-1")));
  with_tmp_dir (fun dir ->
      let sessions = Filename.concat dir "sessions" in
      C2c_io.mkdir_p sessions;
      (* Never follow a directory symlink: this is a bounded answer for cycles
         and preserves the resume target rather than claiming an absence. *)
      Unix.symlink sessions (Filename.concat sessions "cycle");
      Alcotest.(check string) "symlink cycle → unknown" "unknown"
        (persistence_str
           (S.thread_rollout_exists ~sessions_dir:sessions ~thread_id:"t-1")));
  with_tmp_dir (fun dir ->
      let sessions = Filename.concat dir "sessions" in
      let unreadable = Filename.concat sessions "2026" in
      C2c_io.mkdir_p unreadable;
      Unix.chmod unreadable 0o000;
      Fun.protect
        ~finally:(fun () -> Unix.chmod unreadable 0o755)
        (fun () ->
          Alcotest.(check string) "unreadable nested dir → unknown" "unknown"
            (persistence_str
               (S.thread_rollout_exists ~sessions_dir:sessions ~thread_id:"t-1"))))

let test_thread_preflight_gate_decision () =
  with_b227_env
    [ ("C2C_CODEX_SESSIONS_DIR", "");
      ("C2C_CODEX_SKIP_THREAD_PREFLIGHT", "") ]
    (fun () ->
      Alcotest.(check bool) "real launch scans by default" true
        (S.should_preflight_resume_thread ~backend_is_injected:false);
      Alcotest.(check bool) "scripted backend skips without seam" false
        (S.should_preflight_resume_thread ~backend_is_injected:true);
      with_tmp_dir (fun dir ->
          with_b227_env [ ("C2C_CODEX_SESSIONS_DIR", dir) ] (fun () ->
              Alcotest.(check bool) "scripted backend scans with seam" true
                (S.should_preflight_resume_thread ~backend_is_injected:true);
              with_b227_env [ ("C2C_CODEX_SKIP_THREAD_PREFLIGHT", "1") ]
                (fun () ->
                  Alcotest.(check bool) "skip forces real resume" false
                    (S.should_preflight_resume_thread ~backend_is_injected:false);
                  Alcotest.(check bool) "skip forces scripted resume" false
                    (S.should_preflight_resume_thread ~backend_is_injected:true)))))

let test_effective_resume_thread_decision () =
  let const v _ = v in
  (* persisted → thread kept, no log *)
  Alcotest.(check (pair (option string) (option string)))
    "persisted kept" (Some "T", None)
    (S.effective_resume_thread ~persistence:(const S.Thread_persisted) (Some "T"));
  (* unknown → thread kept (scanner uncertainty must not discard context) *)
  Alcotest.(check (pair (option string) (option string)))
    "unknown kept" (Some "T", None)
    (S.effective_resume_thread ~persistence:(const S.Thread_unknown) (Some "T"));
  (* unpersisted → dropped, operator log names the thread + the escape *)
  (match S.effective_resume_thread
           ~persistence:(const S.Thread_unpersisted) (Some "T-dead") with
   | None, Some body ->
       Alcotest.(check bool) "log names the thread" true
         (string_mem "T-dead" body);
       Alcotest.(check bool) "log names the escape env" true
         (string_mem "C2C_CODEX_SKIP_THREAD_PREFLIGHT" body)
   | eff, _ ->
       Alcotest.failf "unpersisted thread must be dropped with a log (got %s)"
         (Option.value eff ~default:"<none>"));
  (* no thread → nothing to decide, and the persistence seam is never called *)
  Alcotest.(check (pair (option string) (option string)))
    "no thread untouched" (None, None)
    (S.effective_resume_thread
       ~persistence:(fun _ -> Alcotest.fail "persistence must not be probed")
       None)

(* End-to-end through S.run with a scripted backend: the C2C_CODEX_SESSIONS_DIR
   seam opts the hermetic test into the preflight. [rollout] controls whether
   the requested thread has a persisted rollout; returns the frontend argv and
   the persisted codex_resume_target. *)
let run_with_thread_preflight ~skip_thread_preflight ~rollout =
  let sid = unique_sid () in
  let alias = S.derive_alias ~session_id:sid ~taken:(fun _ -> false) in
  Fun.protect ~finally:(fun () -> cleanup_alias alias) (fun () ->
      with_tmp_dir (fun dir ->
          let sessions = Filename.concat dir "sessions" in
          C2c_io.mkdir_p sessions;
          if rollout then ignore (write_rollout ~sessions_dir:sessions ~thread_id:sid);
          let saved = Sys.getenv_opt "C2C_CODEX_SESSIONS_DIR" in
          let saved_skip = Sys.getenv_opt "C2C_CODEX_SKIP_THREAD_PREFLIGHT" in
          Unix.putenv "C2C_CODEX_SESSIONS_DIR" sessions;
          Unix.putenv "C2C_CODEX_SKIP_THREAD_PREFLIGHT"
            (if skip_thread_preflight then "1" else "");
          Fun.protect
            ~finally:(fun () ->
              Unix.putenv "C2C_CODEX_SESSIONS_DIR"
                (Option.value saved ~default:"");
              Unix.putenv "C2C_CODEX_SKIP_THREAD_PREFLIGHT"
                (Option.value saved_skip ~default:""))
            (fun () ->
              let clock = ref 0.0 in
              let server = { status = Running_ } in
              let frontend = { status = Exited 0 } in
              let frontend_argv = ref [||] in
              let bk = scripted ~clock
                  ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ ->
                    Ok (mk_fake ~id:111 server))
                  ~spawn_frontend:(fun ~argv ~env:_ ->
                    frontend_argv := argv; Ok (mk_fake ~id:222 frontend)) () in
              let rc = S.run ~mode:S.Start ~yolo:false ~extra_args:[]
                  ~thread_id:sid ~backend:bk
                  ~fallback:(fun ~extra_args:_ () -> 99) () in
              Alcotest.(check int) "clean exit" 0 rc;
              let target =
                match C2c_start.load_config_opt alias with
                | Some cfg -> cfg.C2c_start.codex_resume_target
                | None -> Alcotest.fail "managed config must load"
              in
              (!frontend_argv, target, sid))))

let test_run_drops_unpersisted_thread_b227 () =
  let argv, target, _sid =
    run_with_thread_preflight ~skip_thread_preflight:false ~rollout:false in
  Alcotest.(check bool) "frontend launched FRESH (no `codex resume`)" false
    (Array.exists (fun a -> a = "resume") argv);
  Alcotest.(check (option string)) "dead thread not re-persisted" None target

let test_run_keeps_persisted_thread_b227 () =
  let argv, target, sid =
    run_with_thread_preflight ~skip_thread_preflight:false ~rollout:true in
  Alcotest.(check bool) "frontend resumes the persisted thread" true
    (Array.exists (fun a -> a = "resume") argv
     && Array.exists (fun a -> a = sid) argv);
  Alcotest.(check (option string)) "resume target persisted" (Some sid) target

let test_skip_thread_preflight_forces_resume_b227 () =
  let argv, target, sid =
    run_with_thread_preflight ~skip_thread_preflight:true ~rollout:false in
  Alcotest.(check bool) "skip launches `codex resume`" true
    (Array.exists (fun a -> a = "resume") argv
     && Array.exists (fun a -> a = sid) argv);
  Alcotest.(check (option string)) "skip preserves resume target" (Some sid) target

let test_unpersisted_thread_cleared_before_hook_fallback_b227 () =
  let session_id = unique_sid () in
  let thread_id = "thread-" ^ session_id in
  let alias = S.derive_alias ~session_id ~taken:(fun _ -> false) in
  Fun.protect ~finally:(fun () -> cleanup_alias alias) (fun () ->
      with_tmp_dir (fun dir ->
          let instance_dir = C2c_start.instance_dir alias in
          C2c_io.mkdir_p instance_dir;
          S.write_mapping ~instance_dir
            { S.session_id; alias; thread_id = Some thread_id;
              created_at = 0.; updated_at = 0. };
          let sessions = Filename.concat dir "sessions" in
          C2c_io.mkdir_p sessions;
          let rollout = write_rollout ~sessions_dir:sessions ~thread_id in
          with_b227_env
            [ ("C2C_CODEX_SESSIONS_DIR", sessions);
              ("C2C_CODEX_SKIP_THREAD_PREFLIGHT", "") ]
            (fun () ->
              let clock = ref 0.0 in
              let server = { status = Running_ } in
              let frontend = { status = Exited 0 } in
              let good_backend = scripted ~clock
                  ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ ->
                    Ok (mk_fake ~id:111 server))
                  ~spawn_frontend:(fun ~argv:_ ~env:_ ->
                    Ok (mk_fake ~id:222 frontend)) () in
              let first_rc = S.run ~mode:(S.Resume alias) ~yolo:false ~extra_args:[]
                  ~backend:good_backend
                  ~fallback:(fun ~extra_args:_ () -> 99) () in
              Alcotest.(check int) "persisted setup launch" 0 first_rc;
              Sys.remove rollout;
              let failed_backend =
                scripted ~clock ~codex_version:(Error "forced app-server failure") () in
              let fallback_called = ref false in
              let rc = S.run ~mode:(S.Resume alias) ~yolo:false ~extra_args:[]
                  ~backend:failed_backend
                  ~fallback:(fun ~extra_args:_ () ->
                    fallback_called := true;
                    (match C2c_start.load_config_opt alias with
                     | Some cfg ->
                         Alcotest.(check (option string))
                           "fallback config has no dead resume target" None
                           cfg.C2c_start.codex_resume_target;
                         Alcotest.(check string)
                           "fallback config restores launcher session id" session_id
                           cfg.C2c_start.resume_session_id
                     | None -> Alcotest.fail "fallback config must remain available");
                    (match S.load_mapping ~instance_dir:(C2c_start.instance_dir alias) with
                     | Some mapping ->
                         Alcotest.(check (option string))
                           "fallback mapping has no dead thread" None mapping.thread_id
                     | None -> Alcotest.fail "fallback mapping must remain available");
                    0) () in
              Alcotest.(check bool) "hook fallback ran after app-server failure" true
                !fallback_called;
              Alcotest.(check int) "fallback rc" 0 rc)))

let test_force_hooks_preflights_existing_alias_b227 () =
  let session_id = unique_sid () in
  let thread_id = "thread-" ^ session_id in
  let alias = S.derive_alias ~session_id ~taken:(fun _ -> false) in
  Fun.protect ~finally:(fun () -> cleanup_alias alias) (fun () ->
      with_tmp_dir (fun dir ->
          let instance_dir = C2c_start.instance_dir alias in
          C2c_io.mkdir_p instance_dir;
          S.write_mapping ~instance_dir
            { S.session_id; alias; thread_id = Some thread_id;
              created_at = 0.; updated_at = 0. };
          let sessions = Filename.concat dir "sessions" in
          C2c_io.mkdir_p sessions;
          let rollout = write_rollout ~sessions_dir:sessions ~thread_id in
          with_b227_env
            [ ("C2C_CODEX_SESSIONS_DIR", sessions);
              ("C2C_CODEX_SKIP_THREAD_PREFLIGHT", "");
              ("C2C_CODEX_FORCE_HOOKS", "");
              ("C2C_CODEX_SKIP_MCP_PREFLIGHT", "1") ]
            (fun () ->
              let clock = ref 0.0 in
              let server = { status = Running_ } in
              let frontend = { status = Exited 0 } in
              let backend = scripted ~clock
                  ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ ->
                    Ok (mk_fake ~id:111 server))
                  ~spawn_frontend:(fun ~argv:_ ~env:_ ->
                    Ok (mk_fake ~id:222 frontend)) () in
              let first_rc = S.run ~mode:(S.Resume alias) ~yolo:false ~extra_args:[]
                  ~backend ~fallback:(fun ~extra_args:_ () -> 99) () in
              Alcotest.(check int) "persisted setup launch" 0 first_rc;
              Sys.remove rollout;
              Unix.putenv "C2C_CODEX_FORCE_HOOKS" "1";
              let fallback_called = ref false in
              let rc = S.run ~mode:(S.Resume alias) ~yolo:false ~extra_args:[]
                  ~fallback:(fun ~extra_args:_ () ->
                    fallback_called := true;
                    (match C2c_start.load_config_opt alias with
                     | Some cfg -> Alcotest.(check (option string))
                         "forced hook config has no dead resume target" None
                         cfg.C2c_start.codex_resume_target
                     | None -> Alcotest.fail "forced hook config must remain available");
                    (match S.load_mapping ~instance_dir with
                     | Some mapping -> Alcotest.(check (option string))
                         "forced hook mapping has no dead thread" None mapping.thread_id
                     | None -> Alcotest.fail "forced hook mapping must remain available");
                    0) () in
              Alcotest.(check bool) "forced hook fallback ran" true !fallback_called;
              Alcotest.(check int) "forced hook rc" 0 rc)))

(* ------------------------------------------------------------------ *)
(* Identity resolution: ambiguous client/alias/thread combos rejected  *)
(* ------------------------------------------------------------------ *)

let mk_mapping ?(thread=None) ~sid ~alias () : S.mapping =
  { S.session_id = sid; alias; thread_id = thread; created_at = 0.; updated_at = 0. }

let no_lookup (_ : string) : S.mapping option = None
let no_config (_ : string) = false

let is_error = function Error _ -> true | Ok _ -> false

let test_resolve_resume_unknown_rejected () =
  Alcotest.(check bool) "resume of unknown alias is rejected" true
    (is_error (S.resolve_identity ~mode:(S.Resume "nope") ~alias_override:None
                 ~thread_id:None ~lookup:no_lookup ~config_exists:no_config))

let test_resolve_resume_ok () =
  let m = mk_mapping ~sid:"S1" ~alias:"quiet-harbor" ~thread:(Some "T1") () in
  let lookup a = if a = "quiet-harbor" then Some m else None in
  match S.resolve_identity ~mode:(S.Resume "quiet-harbor") ~alias_override:None
          ~thread_id:None ~lookup ~config_exists:no_config with
  | Ok r ->
      Alcotest.(check string) "alias retained" "quiet-harbor" r.S.r_alias;
      Alcotest.(check string) "seed retained" "S1" r.S.r_session_id;
      Alcotest.(check (option string)) "thread retained" (Some "T1") r.S.r_thread_id
  | Error e -> Alcotest.failf "resume should succeed: %s" e

let test_resolve_alias_conflict_rejected () =
  (* `new --alias X` where X is owned by a DIFFERENT session ⇒ reject (never
     silently reuse). *)
  let other = mk_mapping ~sid:"OTHER" ~alias:"taken-alias" () in
  let lookup a = if a = "taken-alias" then Some other else None in
  Alcotest.(check bool) "new --alias owned by other rejected" true
    (is_error (S.resolve_identity ~mode:S.New ~alias_override:(Some "taken-alias")
                 ~thread_id:(Some "sidX") ~lookup ~config_exists:no_config));
  (* By contrast, `start --alias X` naming an existing mapping RESUMES it
     (adopt-by-alias), adopting its seed — not a conflict. *)
  (match S.resolve_identity ~mode:S.Start ~alias_override:(Some "taken-alias")
           ~thread_id:None ~lookup ~config_exists:no_config with
   | Ok r -> Alcotest.(check string) "start --alias resumes seed" "OTHER" r.S.r_session_id
   | Error e -> Alcotest.failf "start --alias on existing mapping should resume: %s" e)

let test_resolve_thread_conflict_rejected () =
  let m = mk_mapping ~sid:"S1" ~alias:"a-b" ~thread:(Some "SAVED") () in
  let lookup a = if a = "a-b" then Some m else None in
  Alcotest.(check bool) "resume with conflicting --thread-id rejected" true
    (is_error (S.resolve_identity ~mode:(S.Resume "a-b") ~alias_override:None
                 ~thread_id:(Some "DIFFERENT") ~lookup ~config_exists:no_config))

let test_resolve_config_owned_rejected () =
  (* Start --alias where a non-app-server managed instance owns that name. *)
  Alcotest.(check bool) "start --alias owned by non-app-server instance rejected" true
    (is_error (S.resolve_identity ~mode:S.Start ~alias_override:(Some "legacy")
                 ~thread_id:None ~lookup:no_lookup
                 ~config_exists:(fun a -> a = "legacy")))

let test_resolve_new_derives_deterministic () =
  (* No --alias ⇒ derived from the thread_id seed, deterministic + distinct. *)
  let r1 = S.resolve_identity ~mode:S.New ~alias_override:None ~thread_id:(Some "seedA")
             ~lookup:no_lookup ~config_exists:no_config in
  let r2 = S.resolve_identity ~mode:S.New ~alias_override:None ~thread_id:(Some "seedA")
             ~lookup:no_lookup ~config_exists:no_config in
  (match r1, r2 with
   | Ok a, Ok b ->
       Alcotest.(check string) "deterministic derived alias" a.S.r_alias b.S.r_alias;
       Alcotest.(check string) "alias derived from seed"
         (S.derive_alias ~session_id:"seedA" ~taken:(fun _ -> false)) a.S.r_alias;
       Alcotest.(check string) "name == alias" a.S.r_alias a.S.r_name
   | _ -> Alcotest.fail "derivation should succeed")

let test_resolve_start_alias_resumes_mapping () =
  (* Start with --alias naming an existing mapping resumes it (same seed). *)
  let m = mk_mapping ~sid:"SEED9" ~alias:"my-agent" ~thread:(Some "TT") () in
  let lookup a = if a = "my-agent" then Some m else None in
  match S.resolve_identity ~mode:S.Start ~alias_override:(Some "my-agent")
          ~thread_id:None ~lookup ~config_exists:no_config with
  | Ok r ->
      Alcotest.(check string) "resumes same seed" "SEED9" r.S.r_session_id;
      Alcotest.(check (option string)) "resumes saved thread" (Some "TT") r.S.r_thread_id
  | Error e -> Alcotest.failf "start --alias on existing mapping should resume: %s" e

(* ------------------------------------------------------------------ *)
(* --yolo is NEVER persisted into the identity mapping                 *)
(* ------------------------------------------------------------------ *)

let test_yolo_not_persisted () =
  let sid = unique_sid () in
  let alias = S.derive_alias ~session_id:sid ~taken:(fun _ -> false) in
  Fun.protect ~finally:(fun () -> cleanup_alias alias) (fun () ->
      let clock = ref 0.0 in
      let server = { status = Running_ } in
      let frontend = { status = Exited 0 } in
      let bk = scripted ~clock
          ~spawn_server:(fun ~argv:_ ~env:_ ~log_path:_ -> Ok (mk_fake ~id:111 server))
          ~spawn_frontend:(fun ~argv:_ ~env:_ -> Ok (mk_fake ~id:222 frontend)) () in
      (* Launch WITH --yolo. *)
      let _ = S.run ~mode:S.Start ~yolo:true ~extra_args:[]
          ~thread_id:sid ~backend:bk ~fallback:(fun ~extra_args:_ () -> 0) () in
      (* The persisted mapping file must contain NO bypass flag and NO yolo marker. *)
      let raw =
        let ic = open_in (S.mapping_path ~instance_dir:(C2c_start.instance_dir alias)) in
        Fun.protect ~finally:(fun () -> close_in ic)
          (fun () -> really_input_string ic (in_channel_length ic)) in
      Alcotest.(check bool) "no bypass flag in mapping" false
        (string_mem "dangerously-bypass" raw);
      Alcotest.(check bool) "no yolo marker in mapping" false
        (string_mem "yolo" raw))

let () =
  (* B131: the app-server lifecycle glue now registers a routable broker alias
     via the delivery loop. Isolate that side-effect to a throwaway broker root
     so these identity/lifecycle tests never touch the real machine broker. *)
  (let tmp = Filename.temp_file "c2c-codex-session-test" "" in
   Sys.remove tmp;
   (try Unix.mkdir tmp 0o755 with _ -> ());
   Unix.putenv "C2C_MCP_BROKER_ROOT" tmp);
  let open Alcotest in
  run "c2c_codex_session"
    [ ( "deterministic-alias",
        [ test_case "stable" `Quick test_alias_deterministic
        ; test_case "distinct ids" `Quick test_alias_distinct_for_distinct_ids
        ; test_case "resume stable" `Quick test_alias_resume_stable
        ; test_case "collision extension" `Quick test_alias_collision_extension_deterministic
        ; test_case "collision chain" `Quick test_alias_collision_chain_deterministic
        ; test_case "app-server log vocabulary" `Quick test_app_server_log_vocabulary
        ; test_case "app-server log timestamp format (B176)" `Quick
            test_app_server_log_timestamp_format
        ; test_case "app-server lifecycle phase bodies (B176)" `Quick
            test_app_server_lifecycle_phase_bodies
        ; test_case "app-server frontend inherits managed identity" `Quick
            test_app_server_frontend_identity_env ] )
    ; ( "yolo",
        [ test_case "forwards bypass" `Quick test_yolo_forwards_bypass
        ; test_case "absent by default" `Quick test_yolo_absent_by_default ] )
    ; ( "passthrough",
        [ test_case "drop_sep" `Quick test_drop_sep
        ; test_case "split_client" `Quick test_split_client_passthrough
        ; test_case "split_client_alias" `Quick test_split_client_alias_passthrough
        ; test_case "namespaced name for new alias wrapper (B221)" `Quick
            test_namespaced_name_for_new_alias_wrapper_b221
        ; test_case "namespaced conflict + resume rejection (B221)" `Quick
            test_namespaced_name_codex_conflict_and_resume_rejected_b221 ] )
    ; ( "thread-conflict",
        [ test_case "reconcile" `Quick test_reconcile_thread ] )
    ; ( "restart-control",
        [ test_case "request is atomic JSON" `Quick test_restart_request_roundtrip
        ; test_case "result acknowledgement observed" `Quick test_restart_result_ack
        ; test_case "bare argv0 resolves PATH upgrade target" `Quick test_restart_executable_resolves_bare_path_launch
        ; test_case "missing target fails before stop" `Quick test_restart_executable_fails_before_stop_when_unavailable
        ; test_case "thread repairs config independently" `Quick test_thread_persistence_repairs_config_independently ] )
    ; ( "identity-resolve",
        [ test_case "resume unknown rejected" `Quick test_resolve_resume_unknown_rejected
        ; test_case "resume ok" `Quick test_resolve_resume_ok
        ; test_case "alias conflict rejected" `Quick test_resolve_alias_conflict_rejected
        ; test_case "thread conflict rejected" `Quick test_resolve_thread_conflict_rejected
        ; test_case "config-owned alias rejected" `Quick test_resolve_config_owned_rejected
        ; test_case "new derives deterministic" `Quick test_resolve_new_derives_deterministic
        ; test_case "start --alias resumes mapping" `Quick test_resolve_start_alias_resumes_mapping ] )
    ; ( "yolo-persistence",
        [ test_case "yolo not persisted" `Quick test_yolo_not_persisted ] )
    ; ( "status",
        [ test_case "mapping" `Quick test_status_mapping ] )
    ; ( "mapping",
        [ test_case "roundtrip" `Quick test_mapping_roundtrip ] )
    ; ( "delivery-degraded",
        [ test_case "persist + read + flip + stale roundtrip" `Quick test_delivery_degraded_roundtrip
        ; test_case "online-attached decision fail-closed (true/false/absent/stale)" `Quick test_online_attached_degraded_fail_closed
        ; test_case "online-attached stale heartbeat downgrades to degraded (#27)" `Quick test_online_attached_degraded_stale_heartbeat
        ; test_case "degraded reason roundtrip: binding-refused vs no-thread (#31)" `Quick test_i31_degraded_reason_roundtrip
        ; test_case "failing config repair does not break the binding verdict (#31)" `Quick test_i31_config_repair_failure_does_not_break_binding ] )
    ; ( "codex-thread-split-brain-24",
        [ test_case "resolver prefers alive regardless of readdir order" `Quick
            test_resolver_prefers_alive_regardless_of_order
        ; test_case "resolver none-live picks newest registered_at" `Quick
            test_resolver_none_live_picks_newest
        ; test_case "resolver single offline mapping still resolves" `Quick
            test_resolver_single_offline_mapping_resolves
        ; test_case "write-guard refuses on live sibling" `Quick
            test_write_guard_refuses_on_live_sibling
        ; test_case "write-guard reclaims dead sibling" `Quick
            test_write_guard_reclaims_dead_sibling ] )
    ; ( "lifecycle-glue",
        [ test_case "default (no flag) engages app-server, publishes after start"
            `Quick test_glue_happy_publishes_after_start
        ; test_case "generic start namespaced name reaches app-server alias (B221)"
            `Quick test_generic_start_namespaced_name_reaches_app_server_alias_b221
        ; test_case "new codex (default, no flag) engages app-server"
            `Quick test_glue_new_mode_default_engages_app_server
        ; test_case "unsupported codex auto-falls-back, no publish" `Quick test_glue_diagnostic_falls_back_no_publish
        ; test_case "force-hooks env uses fallback" `Quick test_force_hooks_env_uses_fallback
        ; test_case "diagnostic followup upgrade only for version issues (B175)"
            `Quick test_diagnostic_followup_upgrade_only_when_version_issue
        ; test_case "#34r live plain registry alias refused before any launch"
            `Quick test_i34r_live_registry_alias_refused_before_launch
        ; test_case "#34r managed-peer refusal path not regressed"
            `Quick test_i34r_managed_peer_path_not_regressed ] )
    ; ( "mcp-preflight-B224",
        [ test_case "parse bare command" `Quick test_preflight_parse_bare
        ; test_case "parse opam exec args, stop at sub-table" `Quick test_preflight_parse_opam
        ; test_case "absent section parses to None" `Quick test_preflight_parse_absent
        ; test_case "stale opam server_path => stale" `Quick test_preflight_stale_opam_path
        ; test_case "resolvable opam server_path => ok" `Quick test_preflight_ok_opam_path
        ; test_case "c2c-mcp-server off PATH => stale" `Quick test_preflight_stale_bare_off_path
        ; test_case "c2c-mcp-server on PATH => ok" `Quick test_preflight_ok_bare_on_path
        ; test_case "no block => missing" `Quick test_preflight_missing_block
        ; test_case "reads config file + override" `Quick test_preflight_reads_config_file
        ; test_case "diagnostic is actionable" `Quick test_preflight_diagnostic_is_actionable
        ; test_case "new codex aborts before launch on stale block" `Quick
            test_new_codex_aborts_on_stale_block
        ; test_case "skip env bypasses preflight" `Quick test_skip_env_bypasses_preflight ] )
    ; ( "thread-preflight-B227",
        [ test_case "rollout scan states" `Quick test_rollout_scan_states
        ; test_case "rollout scan uncertainty is fail-closed" `Quick
            test_rollout_scan_uncertainty
        ; test_case "run gate decision table" `Quick test_thread_preflight_gate_decision
        ; test_case "fallback decision table" `Quick test_effective_resume_thread_decision
        ; test_case "run drops unpersisted resume thread (fresh thread, same alias)"
            `Quick test_run_drops_unpersisted_thread_b227
        ; test_case "run keeps persisted resume thread" `Quick
            test_run_keeps_persisted_thread_b227
        ; test_case "skip escape forces resume" `Quick
            test_skip_thread_preflight_forces_resume_b227
        ; test_case "fallback clears stale resume persistence" `Quick
            test_unpersisted_thread_cleared_before_hook_fallback_b227
        ; test_case "forced hook fallback preflights existing alias" `Quick
            test_force_hooks_preflights_existing_alias_b227 ] )
    ]
