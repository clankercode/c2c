(* test_c2c_find.ml — integration tests for `c2c find` and `c2c list`.

   Verifies:
   (a) `c2c find` exit codes: 0 on ≥1 match, 1 on none;
   (b) case-insensitive alias substring + exact session-id matching;
   (c) default search covers BOTH the per-repo broker and the cross-repo
       sessions broker (peer registered only on the sessions broker is found);
   (d) --json output shape (alias/session_id/alive/state/client_type/broker)
       and alive-first ordering;
   (e) `c2c list` hides confirmed-dead sessions by default and `--all`
       explicitly reveals them;
   (f) `c2c list --alive` is the strict subset which excludes unknown state;
   (g) `c2c list --global` keeps visible peers grouped by repository.

   Brokers are seeded in-process via C2c_mcp.Broker into temp roots; the
   binary is pointed at them with C2C_MCP_BROKER_ROOT /
   C2C_SESSIONS_BROKER_ROOT. Alive = this test process's pid + start time;
   dead = a pid that cannot exist in /proc. *)

open Alcotest

let ( // ) = Filename.concat

let c2c_binary =
  let dir = Filename.dirname Sys.executable_name in
  let candidate = dir // "c2c.exe" in
  if Sys.file_exists candidate then candidate else "c2c"

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-find-test-%d-%08x" (Unix.getpid ()) (Random.bits ()) in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

(* Run the c2c binary; capture (rc, stdout, stderr). Neutralises inherited
   session env, then layers the caller's env on top. *)
let run_c2c ?(env = []) args =
  let tmp = Filename.get_temp_dir_name () in
  let tag = Printf.sprintf "%d-%06x" (Unix.getpid ()) (Random.bits ()) in
  let out_file = tmp // ("c2c-find-out-" ^ tag) in
  let err_file = tmp // ("c2c-find-err-" ^ tag) in
  let base_env =
    [ "C2C_CLI_FORCE=1"
    ; "C2C_MCP_SESSION_ID="
    ; "CLAUDE_SESSION_ID="
    ; "C2C_MCP_AUTO_REGISTER_ALIAS="
    ; "C2C_INSTANCE_NAME="
    ]
  in
  let home = match List.assoc_opt "HOME" env with Some h -> h | None ->
    (try Sys.getenv "HOME" with Not_found -> "/tmp")
  in
  let env = List.filter (fun (k, _) -> k <> "HOME") env in
  let env_list =
    base_env
    @ List.map (fun (k, v) -> k ^ "=" ^ v) env
    @ [ "PATH=" ^ Sys.getenv "PATH"; "HOME=" ^ home ]
  in
  let env_str = String.concat " " env_list in
  let args_str = String.concat " " (List.map Filename.quote args) in
  let cmd =
    Printf.sprintf "{ env %s %s %s; echo exit:$?; } >%s 2>%s" env_str
      (Filename.quote c2c_binary) args_str (Filename.quote out_file)
      (Filename.quote err_file)
  in
  let _ = Sys.command cmd in
  let raw = try read_file out_file with _ -> "" in
  let err = try read_file err_file with _ -> "" in
  (try Sys.remove out_file with _ -> ());
  (try Sys.remove err_file with _ -> ());
  (* Split off the trailing "exit:N" marker line. *)
  let rc, stdout =
    let marker = "exit:" in
    let mlen = String.length marker in
    let n = String.length raw in
    let idx = ref (-1) in
    for i = 0 to n - mlen do
      if String.sub raw i mlen = marker then idx := i
    done;
    if !idx >= 0 then
      let after = String.trim (String.sub raw (!idx + mlen) (n - !idx - mlen)) in
      let rc = try int_of_string after with _ -> -1 in
      let cut = if !idx > 0 && raw.[!idx - 1] = '\n' then !idx - 1 else !idx in
      (rc, String.sub raw 0 cut)
    else (-1, raw)
  in
  (rc, stdout, err)

(* --- broker seeding ------------------------------------------------------ *)

let dead_pid = 999999999 (* > kernel pid_max: /proc/<pid> can never exist *)

let register_alive broker ~session_id ~alias ~client_type =
  let pid = Unix.getpid () in
  let st = C2c_mcp.Broker.read_pid_start_time pid in
  C2c_mcp.Broker.register broker ~session_id ~alias ~pid:(Some pid)
    ~pid_start_time:st ~client_type:(Some client_type) ()

let register_dead broker ~session_id ~alias ~client_type =
  C2c_mcp.Broker.register broker ~session_id ~alias ~pid:(Some dead_pid)
    ~pid_start_time:(Some 1) ~client_type:(Some client_type) ()

(* A live PID without a captured start time is deliberately [Unknown], not
   [Dead]. This models a registration that cannot be verified against PID
   reuse; it must remain discoverable until an operator asks for --alive. *)
let register_unknown broker ~session_id ~alias ~client_type =
  C2c_mcp.Broker.register broker ~session_id ~alias ~pid:(Some (Unix.getpid ()))
    ~pid_start_time:None ~client_type:(Some client_type) ()

(* Vanilla Codex hook registrations have no durable process PID. A fresh
   hook-activity lease is the available delivery signal and must appear as
   alive in both discovery commands. *)
let register_fresh_codex_hook broker ~session_id ~alias =
  C2c_mcp.Broker.register broker ~session_id ~alias ~pid:None
    ~pid_start_time:None ~client_type:(Some "codex")
    ~registered_by:(Some "codex-hook") ()

(* Seed a standard fixture: repo broker with one alive + one dead peer,
   sessions broker with one alive peer. Returns env bindings for run_c2c. *)
let seed_std dir =
  let repo_root = dir // "repo" in
  let sessions_root = dir // "sessions" in
  Unix.mkdir repo_root 0o755;
  Unix.mkdir sessions_root 0o755;
  let rb = C2c_mcp.Broker.create ~root:repo_root in
  register_alive rb ~session_id:"sid-alive-1" ~alias:"zzqfind-alpha-live" ~client_type:"claude";
  register_dead rb ~session_id:"sid-dead-1" ~alias:"zzqfind-alpha-dead" ~client_type:"codex";
  let sb = C2c_mcp.Broker.create ~root:sessions_root in
  register_alive sb ~session_id:"sid-sess-1" ~alias:"zzqfind-beta-sess" ~client_type:"opencode";
  [ ("C2C_MCP_BROKER_ROOT", repo_root)
  ; ("C2C_SESSIONS_BROKER_ROOT", sessions_root)
  ]

(* JSON helpers *)
let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let str_member name json =
  match member name json with Some (`String s) -> s | _ -> "<missing>"

(* --- c2c find ------------------------------------------------------------ *)

let test_find_match_exit_zero () =
  with_temp_dir @@ fun dir ->
  let env = seed_std dir in
  let rc, out, _ = run_c2c ~env [ "find"; "alpha" ] in
  check int "find with matches exits 0" 0 rc;
  check bool "output names the live peer" true (string_contains out "zzqfind-alpha-live");
  check bool "output names the dead peer" true (string_contains out "zzqfind-alpha-dead");
  check bool "output shows alive state" true (string_contains out "alive");
  check bool "output shows dead state" true (string_contains out "dead");
  check bool "output shows session id" true (string_contains out "sid-alive-1");
  check bool "output shows client type" true (string_contains out "claude");
  check bool "output shows broker label" true (string_contains out "[repo]")

let test_find_no_match_exit_one () =
  with_temp_dir @@ fun dir ->
  let env = seed_std dir in
  let rc, out, _ = run_c2c ~env [ "find"; "snorkelwomp" ] in
  check int "find with no matches exits 1" 1 rc;
  check bool "no-match message printed" true (string_contains out "No peers matching")

let test_find_case_insensitive () =
  with_temp_dir @@ fun dir ->
  let env = seed_std dir in
  let rc, out, _ = run_c2c ~env [ "find"; "ALPHA-LIVE" ] in
  check int "uppercase pattern matches lowercase alias" 0 rc;
  check bool "matched alias printed" true (string_contains out "zzqfind-alpha-live")

let test_find_session_id_exact () =
  with_temp_dir @@ fun dir ->
  let env = seed_std dir in
  let rc, out, _ = run_c2c ~env [ "find"; "sid-dead-1" ] in
  check int "exact session id matches" 0 rc;
  check bool "session-id match resolves alias" true (string_contains out "zzqfind-alpha-dead");
  (* a session-id substring must NOT match (exact only) *)
  let rc2, _, _ = run_c2c ~env [ "find"; "sid-dead" ] in
  check int "session-id substring does not match" 1 rc2

let test_find_covers_sessions_broker_by_default () =
  with_temp_dir @@ fun dir ->
  let env = seed_std dir in
  let rc, out, _ = run_c2c ~env [ "find"; "beta" ] in
  check int "peer only on sessions broker is found" 0 rc;
  check bool "sessions-broker peer printed" true (string_contains out "zzqfind-beta-sess");
  check bool "sessions broker label shown" true (string_contains out "[sessions]")

let test_find_json_shape_and_alive_first () =
  with_temp_dir @@ fun dir ->
  let env = seed_std dir in
  let rc, out, _ = run_c2c ~env [ "find"; "zzqfind"; "--json" ] in
  check int "find --json exits 0" 0 rc;
  let json = Yojson.Safe.from_string out in
  match json with
  | `List entries ->
      check int "three matches" 3 (List.length entries);
      let first = List.hd entries in
      check bool "first entry is alive" true (member "alive" first = Some (`Bool true));
      let last = List.nth entries 2 in
      check bool "last entry is dead" true (member "alive" last = Some (`Bool false));
      check string "dead entry alias" "zzqfind-alpha-dead" (str_member "alias" last);
      check string "dead entry state" "dead" (str_member "state" last);
      check string "dead entry client_type" "codex" (str_member "client_type" last);
      check string "dead entry broker" "repo" (str_member "broker" last);
      check bool "session_id present" true (str_member "session_id" last = "sid-dead-1");
      check bool "broker_root present" true (str_member "broker_root" last <> "<missing>")
  | _ -> fail "find --json did not produce a JSON list"

let test_find_json_no_match () =
  with_temp_dir @@ fun dir ->
  let env = seed_std dir in
  let rc, out, _ = run_c2c ~env [ "find"; "snorkelwomp"; "--json" ] in
  check int "find --json no-match exits 1" 1 rc;
  let json = Yojson.Safe.from_string out in
  check bool "empty JSON list" true (json = `List [])

let test_find_and_list_report_fresh_codex_hook_alive () =
  with_temp_dir @@ fun dir ->
  let repo_root = dir // "repo" in
  Unix.mkdir repo_root 0o755;
  let broker = C2c_mcp.Broker.create ~root:repo_root in
  register_fresh_codex_hook broker ~session_id:"sid-codex-hook-fresh"
    ~alias:"zzqfind-codex-hook-fresh";
  let env = [ ("C2C_MCP_BROKER_ROOT", repo_root) ] in
  let rc_find, out_find, _ =
    run_c2c ~env [ "find"; "codex-hook-fresh"; "--json" ]
  in
  check int "find fresh Codex hook exits 0" 0 rc_find;
  let find_entry =
    match Yojson.Safe.from_string out_find with
    | `List [ entry ] -> entry
    | _ -> fail "find did not return exactly one fresh Codex hook"
  in
  check bool "find reports hook peer alive" true
    (member "alive" find_entry = Some (`Bool true));
  check string "find reports alive state" "alive" (str_member "state" find_entry);
  let rc_list, out_list, _ =
    run_c2c ~env [ "list"; "--match"; "codex-hook-fresh"; "--json" ]
  in
  check int "list fresh Codex hook exits 0" 0 rc_list;
  match Yojson.Safe.from_string out_list with
  | `List [ entry ] ->
      check bool "list reports hook peer alive" true
        (member "alive" entry = Some (`Bool true));
      check string "list reports explicit alive state" "alive"
        (str_member "state" entry)
  | _ -> fail "list did not return exactly one fresh Codex hook"

(* --- c2c list filters ---------------------------------------------------- *)

let test_list_alive_filter () =
  with_temp_dir @@ fun dir ->
  let env = seed_std dir in
  let rc, out, _ = run_c2c ~env [ "list"; "--alive" ] in
  check int "list --alive exits 0" 0 rc;
  check bool "alive peer listed" true (string_contains out "zzqfind-alpha-live");
  check bool "dead peer suppressed" false (string_contains out "zzqfind-alpha-dead")

let test_list_hides_dead_by_default_and_all_reveals () =
  with_temp_dir @@ fun dir ->
  let env = seed_std dir in
  let rc, out, _ = run_c2c ~env [ "list" ] in
  check int "default list exits 0" 0 rc;
  check bool "alive peer listed" true (string_contains out "zzqfind-alpha-live");
  check bool "dead peer hidden" false (string_contains out "zzqfind-alpha-dead");
  let rc_json, out_json, _ = run_c2c ~env [ "list"; "--json" ] in
  check int "default JSON list exits 0" 0 rc_json;
  (match Yojson.Safe.from_string out_json with
   | `List [ entry ] ->
       check string "default JSON keeps only the live peer" "zzqfind-alpha-live"
         (str_member "alias" entry)
   | `List entries ->
       fail (Printf.sprintf "expected one visible JSON peer, got %d" (List.length entries))
   | _ -> fail "default list --json did not produce a JSON list");
  let rc_all, out_all, _ = run_c2c ~env [ "list"; "--all" ] in
  check int "list --all exits 0" 0 rc_all;
  check bool "dead peer revealed by --all" true (string_contains out_all "zzqfind-alpha-dead")

let test_list_keeps_unknown_by_default_but_alive_excludes_it () =
  with_temp_dir @@ fun dir ->
  let repo_root = dir // "repo-unknown" in
  Unix.mkdir repo_root 0o755;
  let broker = C2c_mcp.Broker.create ~root:repo_root in
  register_unknown broker ~session_id:"sid-unknown-1" ~alias:"zzqfind-unknown"
    ~client_type:"codex";
  let env = [ ("C2C_MCP_BROKER_ROOT", repo_root) ] in
  let rc, out, _ = run_c2c ~env [ "list" ] in
  check int "default list exits 0" 0 rc;
  check bool "unknown peer remains visible" true (string_contains out "zzqfind-unknown");
  check bool "human output labels unknown state" true (string_contains out "unknown");
  let rc_json, out_json, _ = run_c2c ~env [ "list"; "--json" ] in
  check int "default JSON list exits 0" 0 rc_json;
  (match Yojson.Safe.from_string out_json with
   | `List [ entry ] ->
       check string "unknown JSON alias" "zzqfind-unknown" (str_member "alias" entry);
       check bool "unknown JSON alive is null" true (member "alive" entry = Some `Null);
       check string "unknown JSON state" "unknown" (str_member "state" entry)
   | _ -> fail "expected one unknown peer in default JSON list");
  let rc_alive, out_alive, _ = run_c2c ~env [ "list"; "--alive" ] in
  check int "strict alive list exits 0" 0 rc_alive;
  check bool "unknown peer excluded by --alive" false (string_contains out_alive "zzqfind-unknown")

let test_list_match_composes_with_json () =
  with_temp_dir @@ fun dir ->
  let env = seed_std dir in
  let rc, out, _ = run_c2c ~env [ "list"; "--match"; "alpha"; "--alive"; "--json" ] in
  check int "list --match --alive --json exits 0" 0 rc;
  match Yojson.Safe.from_string out with
  | `List [ entry ] ->
      check string "single filtered entry" "zzqfind-alpha-live" (str_member "alias" entry);
      check bool "alive field true" true (member "alive" entry = Some (`Bool true))
  | `List l -> fail (Printf.sprintf "expected 1 entry, got %d" (List.length l))
  | _ -> fail "list --json did not produce a JSON list"

(* --- dead filtering + global repository groups -------------------------- *)

let seed_noisy dir =
  let repo_root = dir // "repo-noisy" in
  Unix.mkdir repo_root 0o755;
  let rb = C2c_mcp.Broker.create ~root:repo_root in
  for i = 1 to 25 do
    register_dead rb
      ~session_id:(Printf.sprintf "sid-noise-%d" i)
      ~alias:(Printf.sprintf "zzqnoise-dead-%d" i)
      ~client_type:"claude"
  done;
  register_alive rb ~session_id:"sid-noise-live" ~alias:"zzqnoise-live" ~client_type:"claude";
  [ ("C2C_MCP_BROKER_ROOT", repo_root) ]

let test_no_dead_noise_by_default () =
  with_temp_dir @@ fun dir ->
  let env = seed_noisy dir in
  let rc, out, err = run_c2c ~env [ "list" ] in
  check int "noisy list exits 0" 0 rc;
  check bool "dead sessions hidden from stdout" false (string_contains out "zzqnoise-dead-");
  check bool "live session remains visible" true (string_contains out "zzqnoise-live");
  check string "no stale-session warning needed" "" err

let test_all_reveals_dead_noisy_rows () =
  with_temp_dir @@ fun dir ->
  let env = seed_noisy dir in
  let rc, out, _ = run_c2c ~env [ "list"; "--all" ] in
  check int "list --all exits 0" 0 rc;
  check bool "dead sessions are available for forensics" true
    (string_contains out "zzqnoise-dead-")

let test_global_list_hides_dead_and_keeps_repository_groups () =
  with_temp_dir @@ fun dir ->
  let home = dir // "home" in
  let c2c_dir = home // ".c2c" in
  let repos_dir = c2c_dir // "repos" in
  let alpha_dir = repos_dir // "repo-alpha" in
  let beta_dir = repos_dir // "repo-beta" in
  List.iter (fun path -> Unix.mkdir path 0o755)
    [ home; c2c_dir; repos_dir; alpha_dir; beta_dir ];
  let alpha = C2c_mcp.Broker.create ~root:(alpha_dir // "broker") in
  let beta = C2c_mcp.Broker.create ~root:(beta_dir // "broker") in
  register_alive alpha ~session_id:"sid-global-alpha" ~alias:"zzqglobal-alpha-live"
    ~client_type:"claude";
  register_dead beta ~session_id:"sid-global-beta" ~alias:"zzqglobal-beta-dead"
    ~client_type:"codex";
  let env = [ ("HOME", home); ("XDG_STATE_HOME", dir // "xdg-empty") ] in
  let rc, out, _ = run_c2c ~env [ "list"; "--global" ] in
  check int "global list exits 0" 0 rc;
  check bool "live repository group rendered" true (string_contains out "repo: repo-alpha");
  check bool "live peer rendered" true (string_contains out "zzqglobal-alpha-live");
  check bool "dead repository group hidden" false (string_contains out "repo: repo-beta");
  let rc_all, out_all, _ = run_c2c ~env [ "list"; "--global"; "--all" ] in
  check int "global --all exits 0" 0 rc_all;
  check bool "dead repository group restored" true (string_contains out_all "repo: repo-beta");
  check bool "dead peer restored" true (string_contains out_all "zzqglobal-beta-dead")

(* ---------------------------------------------------------------- *)

let () =
  Random.self_init ();
  run "c2c_find"
    [ ( "find",
        [ test_case "match → exit 0 + fields" `Quick test_find_match_exit_zero
        ; test_case "no match → exit 1" `Quick test_find_no_match_exit_one
        ; test_case "case-insensitive substring" `Quick test_find_case_insensitive
        ; test_case "exact session-id match only" `Quick test_find_session_id_exact
        ; test_case "sessions broker searched by default" `Quick test_find_covers_sessions_broker_by_default
        ; test_case "--json shape + alive-first sort" `Quick test_find_json_shape_and_alive_first
        ; test_case "--json no match → [] + exit 1" `Quick test_find_json_no_match
        ; test_case "fresh Codex hook is alive in find and list" `Quick test_find_and_list_report_fresh_codex_hook_alive
        ] )
    ; ( "list_filters",
        [ test_case "--alive suppresses dead" `Quick test_list_alive_filter
        ; test_case "default hides dead and --all reveals them" `Quick test_list_hides_dead_by_default_and_all_reveals
        ; test_case "default keeps unknown while --alive excludes it" `Quick
            test_list_keeps_unknown_by_default_but_alive_excludes_it
        ; test_case "--match composes with --alive --json" `Quick test_list_match_composes_with_json
        ] )
    ; ( "global_list",
        [ test_case "hides dead by default" `Quick test_no_dead_noise_by_default
        ; test_case "--all reveals dead rows" `Quick test_all_reveals_dead_noisy_rows
        ; test_case "hides dead and groups by repository" `Quick
            test_global_list_hides_dead_and_keeps_repository_groups
        ] )
    ]
