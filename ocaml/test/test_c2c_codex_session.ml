(* Tests for C2c_codex_session (P1.M1.E1.T006): deterministic session-ID-derived
   alias generation + collision extension, --yolo forwarding + non-persistence,
   `--` passthrough splitting, thread-conflict rejection, status terminology,
   identity-mapping round-trip, and the app-server lifecycle glue (alias
   published only after start; graceful fallback on a startup diagnostic). All
   scripted — no live codex process. *)

open C2c_codex_app_server
module S = C2c_codex_session

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
  Alcotest.(check string) "colored label content"
    "[c2c codex app-server]" S.app_server_log_label;
  Alcotest.(check string) "online-attached fields"
    "online-attached: c2c-alias=codex-oak-fern-a1b2 endpoint=ws://127.0.0.1:37305"
    (S.online_attached_log_body ~alias:"codex-oak-fern-a1b2"
       ~endpoint:"ws://127.0.0.1:37305");
  Alcotest.(check bool) "legacy generic alias field absent" false
    (string_mem " alias="
       (S.online_attached_log_body ~alias:"codex-oak-fern-a1b2"
          ~endpoint:"ws://127.0.0.1:37305"))

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
      S.persist_discovered_thread ~instance_dir:dir ~name
        ~thread_id:"thread-exact";
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
        None (S.delivery_degraded_of_instance ~instance_dir:dir ~unit_id:uid);
      (* Degraded at loop start. *)
      S.write_delivery_degraded ~instance_dir:dir ~unit_id:uid true;
      Alcotest.(check (option bool)) "persisted degraded=true (matching unit)"
        (Some true) (S.delivery_degraded_of_instance ~instance_dir:dir ~unit_id:uid);
      (* Flip to healthy once a thread loads — later write wins. *)
      S.write_delivery_degraded ~instance_dir:dir ~unit_id:uid false;
      Alcotest.(check (option bool)) "flip to healthy persists degraded=false"
        (Some false) (S.delivery_degraded_of_instance ~instance_dir:dir ~unit_id:uid);
      (* A DIFFERENT unit_id must NOT trust the record — stale prior-run value. *)
      Alcotest.(check (option bool)) "mismatched unit_id reads as None (stale)"
        None (S.delivery_degraded_of_instance ~instance_dir:dir ~unit_id:"u-2");
      (* File name is the documented path so doctor/health read the same place. *)
      Alcotest.(check bool) "status file exists at the documented path" true
        (Sys.file_exists (S.delivery_status_path ~instance_dir:dir)))

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
        (S.online_attached_delivery_degraded ~instance_dir:dir));
  (* matching degraded=true → degraded *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-A";
      S.write_delivery_degraded ~instance_dir:dir ~unit_id:"u-A" true;
      Alcotest.(check bool) "matching degraded=true → degraded" true
        (S.online_attached_delivery_degraded ~instance_dir:dir));
  (* matching degraded=false (thread loaded) → healthy (NOT weakened) *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-A";
      S.write_delivery_degraded ~instance_dir:dir ~unit_id:"u-A" false;
      Alcotest.(check bool) "matching degraded=false → healthy" false
        (S.online_attached_delivery_degraded ~instance_dir:dir));
  (* stale record from a prior run (healthy=false but WRONG unit) → fail-closed
     degraded, so a reused dir never masks a new no-thread session *)
  with_tmp_dir (fun dir ->
      write_persisted_unit ~dir ~unit_id:"u-NEW";
      S.write_delivery_degraded ~instance_dir:dir ~unit_id:"u-OLD" false;
      Alcotest.(check bool) "stale healthy record (wrong unit) → fail-closed degraded"
        true (S.online_attached_delivery_degraded ~instance_dir:dir));
  (* no persisted app-server record at all → fail-closed degraded *)
  with_tmp_dir (fun dir ->
      Alcotest.(check bool) "no persisted record → fail-closed degraded" true
        (S.online_attached_delivery_degraded ~instance_dir:dir))

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

let test_force_hooks_env_uses_fallback () =
  (* The hidden C2C_CODEX_FORCE_HOOKS=1 escape (operator testing only) skips the
     app-server path entirely and runs the hook fallback; --yolo still forwards
     the bypass flag through the effective extra_args. *)
  let seen = ref [] in
  Unix.putenv "C2C_CODEX_FORCE_HOOKS" "1";
  let rc =
    Fun.protect ~finally:(fun () -> Unix.putenv "C2C_CODEX_FORCE_HOOKS" "0")
      (fun () ->
        S.run ~mode:S.Start ~yolo:true ~extra_args:[ "--model"; "x" ]
          ~fallback:(fun ~extra_args () -> seen := extra_args; 0) ())
  in
  Alcotest.(check int) "fallback rc" 0 rc;
  Alcotest.(check bool) "yolo bypass forwarded to hook path" true
    (List.mem "--dangerously-bypass-approvals-and-sandbox" !seen);
  Alcotest.(check bool) "passthrough preserved" true (List.mem "--model" !seen)

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
        ; test_case "app-server log vocabulary" `Quick test_app_server_log_vocabulary ] )
    ; ( "yolo",
        [ test_case "forwards bypass" `Quick test_yolo_forwards_bypass
        ; test_case "absent by default" `Quick test_yolo_absent_by_default ] )
    ; ( "passthrough",
        [ test_case "drop_sep" `Quick test_drop_sep
        ; test_case "split_client" `Quick test_split_client_passthrough
        ; test_case "split_client_alias" `Quick test_split_client_alias_passthrough ] )
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
        ; test_case "online-attached decision fail-closed (true/false/absent/stale)" `Quick test_online_attached_degraded_fail_closed ] )
    ; ( "lifecycle-glue",
        [ test_case "default (no flag) engages app-server, publishes after start"
            `Quick test_glue_happy_publishes_after_start
        ; test_case "new codex (default, no flag) engages app-server"
            `Quick test_glue_new_mode_default_engages_app_server
        ; test_case "unsupported codex auto-falls-back, no publish" `Quick test_glue_diagnostic_falls_back_no_publish
        ; test_case "force-hooks env uses fallback" `Quick test_force_hooks_env_uses_fallback ] )
    ]
