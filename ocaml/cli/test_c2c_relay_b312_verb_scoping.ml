(* test_c2c_relay_b312_verb_scoping — relay enable/disable/restart scoping.

   B312 names two verb-scoping defects, locked here end-to-end through the
   real binary (fixture systemctl, isolated HOME/state):

   (1) `c2c restart relay-connect` never considered relay.json /
       Relay_activation a URL candidate (bootstrap resolved [override; env],
       the managed-config arm ordered [saved; override; env]). Consequences:
       an enable-only non-systemd host failed to restart with "no relay URL
       known" even though `c2c start relay-connect` worked, and a saved
       managed-config URL WON over C2C_RELAY_URL — inverted vs B300 — so
       re-pointing via `relay enable --url` followed by restart relaunched
       on the stale URL. New order: override > env > activation > saved.

   (2) enable/disable write through Relay_activation.config_location, which
       honors C2C_RELAY_CONFIG / C2C_MCP_BROKER_ROOT: enable inside a
       broker-scoped session silently writes the repo-local relay.json while
       a later plain-shell disable flips the MACHINE file — one scope stays
       active while the operator believes the relay is off. Locked: both
       verbs warn loudly (naming the exact file) when the target is not the
       machine config, and plain-shell disable warns when a repo-local
       relay.json still resolves active. Warn-not-refuse: repo-scoped relay
       config is a legitimate deliberate configuration. *)

open Alcotest

let ( // ) = Filename.concat

let with_temp_dir f =
  let path = Filename.temp_file "c2c-b312-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote path)))
    (fun () -> f path)

let rec mkdir_p path =
  if path = "" || path = "/" || Sys.file_exists path then ()
  else (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let read_file path =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      really_input_string ic (in_channel_length ic))
  with Sys_error _ -> ""

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec loop i =
    i + nl <= hl && (String.sub haystack i nl = needle || loop (i + 1))
  in
  nl = 0 || loop 0

let c2c_exe =
  let e = Sys.executable_name in
  let abs = if Filename.is_relative e then Sys.getcwd () // e else e in
  Filename.dirname (Filename.dirname abs) // "cli" // "c2c.exe"

let env_with overrides =
  let keys = List.map fst overrides in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter (fun row ->
      not (List.exists (fun key -> String.starts_with ~prefix:(key ^ "=") row) keys))
  in
  Array.of_list (List.map (fun (k, v) -> k ^ "=" ^ v) overrides @ inherited)

let wait_status pid =
  let _, status = Unix.waitpid [] pid in
  match status with
  | Unix.WEXITED n -> n
  | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n

let spawn_to_log ~env args log =
  let fd = Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let pid =
    Unix.create_process_env c2c_exe (Array.of_list (c2c_exe :: args)) env
      Unix.stdin fd fd
  in
  Unix.close fd;
  let code = wait_status pid in
  read_file log, code

(* Run `c2c relay <args>` with cwd=<cwd> (for repo-fingerprint-dependent
   paths), output captured. *)
let run_relay_in ~cwd ~env ~args log =
  let cmd =
    Printf.sprintf "cd %s && exec \"$C2C_EXE\" relay %s"
      (Filename.quote cwd) args
  in
  let env = Array.append [| "C2C_EXE=" ^ c2c_exe |] env in
  let fd = Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let pid =
    Unix.create_process_env "/bin/sh" [| "/bin/sh"; "-c"; cmd |] env
      Unix.stdin fd fd
  in
  Unix.close fd;
  let code = wait_status pid in
  read_file log, code

let write_json path json =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    Yojson.Safe.pretty_to_string json |> output_string oc;
    output_char oc '\n')

let json_field path key =
  if not (Sys.file_exists path) then None
  else
    match Yojson.Safe.from_file path with
    | `Assoc a -> List.assoc_opt key a
    | _ -> None

let json_string_field path key =
  match json_field path key with
  | Some (`String u) -> Some u
  | _ -> None

let json_bool_field path key =
  match json_field path key with
  | Some (`Bool b) -> Some b
  | _ -> None

let managed_config_url instances name =
  json_string_field (instances // name // "config.json") "relay_url"

(* Supervised relay-connect instance config, the shape parse_managed_config
   accepts (B212). *)
let managed_config_json ~relay_url =
  `Assoc [
    ("client", `String "relay-connect");
    ("scope", `String "machine");
    ("supervised", `Bool true);
    ("created_at", `Float 1234.0);
    ("relay_url", (match relay_url with Some u -> `String u | None -> `Null));
    ("interval", `Int 30);
  ]

let stop_connector env log =
  (* Exit 1 = "instance not found" (nothing to clean, e.g. the restart under
     test failed); anything else is a hygiene problem. *)
  let _, code = spawn_to_log ~env [ "stop"; "relay-connect" ] log in
  check bool "cleanup stop exits 0 (stopped) or 1 (nothing to stop)" true
    (code = 0 || code = 1)

(* Isolation rows shared by the restart cases. The empty-string rows clear
   ambient developer exports so only the fixture drives resolution. *)
let b312_env ~home ~instances ~state =
  env_with [
    "HOME", home;
    "C2C_INSTANCES_DIR", instances;
    "C2C_STATE_HOME", state;
    "XDG_STATE_HOME", state // "xdg";
    "C2C_SYSTEMCTL_FIXTURE", "1";
    "C2C_RELAY_URL", "";
    "C2C_RELAY_TOKEN", "";
    "C2C_RELAY_CONFIG", "";
    "C2C_MCP_BROKER_ROOT", "";
  ]

(* Dead-port URL: connection refused instantly, no DNS, no external traffic. *)
let dead_url = "http://127.0.0.1:1"

(* --- (1) restart URL resolution ------------------------------------------- *)

(* The resolution ORDER itself, pinned at the library seam (pure). The CLI
   passes an already-resolved override into C2c_relay_managed.restart
   (C2c_managed_cmd), which masks the ordering end-to-end for the bootstrap
   arm — the library must be correct on its own terms, not lean on its
   caller. Before B312 the managed arm ordered [saved; override; env]: the
   stale saved URL won, which no candidate order built by the caller could
   repair. *)
let test_restart_candidates_saved_url_is_last_resort () =
  let open C2c_relay_managed in
  check (option string) "env beats the stale saved managed URL"
    (Some "https://env.b312.example")
    (restart_url_candidates ~saved_url:(Some "https://saved.b312.example")
       ~relay_url_override:None ~env_url:(Some "https://env.b312.example")
       ~activation_url:None ());
  check (option string) "relay.json activation beats the stale saved URL"
    (Some "https://relayjson.b312.example")
    (restart_url_candidates ~saved_url:(Some "https://saved.b312.example")
       ~relay_url_override:None ~env_url:None
       ~activation_url:(Some "https://relayjson.b312.example") ());
  check (option string) "explicit override beats everything"
    (Some "https://override.b312.example")
    (restart_url_candidates ~saved_url:(Some "https://saved.b312.example")
       ~relay_url_override:(Some "https://override.b312.example")
       ~env_url:(Some "https://env.b312.example")
       ~activation_url:(Some "https://relayjson.b312.example") ());
  check (option string) "saved URL used only when nothing else resolves"
    (Some "https://saved.b312.example")
    (restart_url_candidates ~saved_url:(Some "https://saved.b312.example")
       ~relay_url_override:None ~env_url:None ~activation_url:None ());
  check (option string) "bootstrap: activation is a candidate without saved config"
    (Some "https://relayjson.b312.example")
    (restart_url_candidates ~saved_url:None ~relay_url_override:None
       ~env_url:None ~activation_url:(Some "https://relayjson.b312.example") ());
  check (option string) "nothing resolves -> None" None
    (restart_url_candidates ~saved_url:None ~relay_url_override:None
       ~env_url:None ~activation_url:None ())

let test_restart_bootstrap_uses_relay_json () =
  (* End-to-end pin of the ticket scenario: an enable-only host. `c2c relay
     enable` wrote the default machine relay.json; `c2c restart relay-connect`
     must bootstrap from it with no flag and no C2C_RELAY_CONFIG /
     C2C_RELAY_URL in the environment. *)
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let instances = root // "instances" in
  let state = root // "state" in
  let expected = "https://relayjson.b312.example" in
  mkdir_p home; mkdir_p instances;
  write_json (home // ".config" // "c2c" // "relay.json")
    (`Assoc [ ("url", `String expected) ]);
  let env = b312_env ~home ~instances ~state in
  let out, code =
    spawn_to_log ~env [ "restart"; "relay-connect" ] (root // "restart.log") in
  Fun.protect ~finally:(fun () -> stop_connector env (root // "stop.log"))
    (fun () ->
      check bool ("restart exits 0 on an enable-only host: " ^ out) true (code = 0);
      check (option string) "relay.json URL bootstrapped into managed config"
        (Some expected) (managed_config_url instances "relay-connect"))

let test_restart_env_url_beats_saved_managed_config () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let instances = root // "instances" in
  let state = root // "state" in
  let stale = "https://saved.b312.example" in
  let from_env = "https://env.b312.example" in
  mkdir_p (instances // "relay-connect");
  write_json (instances // "relay-connect" // "config.json")
    (managed_config_json ~relay_url:(Some stale));
  (* C2C_RELAY_CONFIG points at a missing file so no relay.json leaks in. *)
  let env =
    env_with [
      "HOME", home;
      "C2C_INSTANCES_DIR", instances;
      "C2C_STATE_HOME", state;
      "XDG_STATE_HOME", state // "xdg";
      "C2C_SYSTEMCTL_FIXTURE", "1";
      "C2C_RELAY_URL", from_env;
      "C2C_RELAY_TOKEN", "";
      "C2C_RELAY_CONFIG", root // "does-not-exist-relay.json";
      "C2C_MCP_BROKER_ROOT", "";
    ]
  in
  let out, code =
    spawn_to_log ~env [ "restart"; "relay-connect" ] (root // "restart.log") in
  Fun.protect ~finally:(fun () -> stop_connector env (root // "stop.log"))
    (fun () ->
      check bool ("restart exits 0: " ^ out) true (code = 0);
      check (option string) "env C2C_RELAY_URL wins over the stale saved URL"
        (Some from_env) (managed_config_url instances "relay-connect"))

let test_restart_relay_json_beats_saved_managed_config () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let instances = root // "instances" in
  let state = root // "state" in
  let stale = "https://saved.b312.example" in
  let from_relay_json = "https://relayjson.b312.example" in
  mkdir_p (instances // "relay-connect");
  write_json (instances // "relay-connect" // "config.json")
    (managed_config_json ~relay_url:(Some stale));
  let fixture = root // "relay.json" in
  write_json fixture (`Assoc [ ("url", `String from_relay_json) ]);
  let env =
    env_with [
      "HOME", home;
      "C2C_INSTANCES_DIR", instances;
      "C2C_STATE_HOME", state;
      "XDG_STATE_HOME", state // "xdg";
      "C2C_SYSTEMCTL_FIXTURE", "1";
      "C2C_RELAY_URL", "";
      "C2C_RELAY_TOKEN", "";
      "C2C_RELAY_CONFIG", fixture;
      "C2C_MCP_BROKER_ROOT", "";
    ]
  in
  let out, code =
    spawn_to_log ~env [ "restart"; "relay-connect" ] (root // "restart.log") in
  Fun.protect ~finally:(fun () -> stop_connector env (root // "stop.log"))
    (fun () ->
      check bool ("restart exits 0: " ^ out) true (code = 0);
      check (option string) "re-pointed relay.json wins over the stale saved URL"
        (Some from_relay_json) (managed_config_url instances "relay-connect"))

(* --- (2) enable/disable scoping warnings ---------------------------------- *)

let broker_scoped_env ~home ~broker ~state =
  env_with [
    "HOME", home;
    "C2C_STATE_HOME", state;
    "XDG_STATE_HOME", state // "xdg";
    "C2C_SYSTEMCTL_FIXTURE", "1";
    "C2C_MCP_BROKER_ROOT", broker;
    "C2C_RELAY_URL", "";
    "C2C_RELAY_TOKEN", "";
    "C2C_RELAY_CONFIG", "";
  ]

let repo_local_relay_json broker = broker // "relay.json"

let test_enable_broker_scoped_warns_names_file () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let broker = root // "broker" in
  let state = root // "state" in
  let env = broker_scoped_env ~home ~broker ~state in
  let out, code =
    spawn_to_log ~env
      [ "relay"; "enable"; "--url"; dead_url ]
      (root // "enable.log")
  in
  check bool ("enable exits 0: " ^ out) true (code = 0);
  check bool "enable warns about the non-machine target" true
    (contains ~haystack:out ~needle:"warning");
  check bool "warning names the exact repo-local file" true
    (contains ~haystack:out ~needle:(repo_local_relay_json broker));
  check bool "warning names the split-brain risk" true
    (contains ~haystack:out ~needle:"split-brain");
  check bool "repo-local file still written (warn-not-refuse)" true
    (json_string_field (repo_local_relay_json broker) "url" <> None)

let test_disable_broker_scoped_warns_names_file () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let broker = root // "broker" in
  let state = root // "state" in
  let env = broker_scoped_env ~home ~broker ~state in
  let _, code1 =
    spawn_to_log ~env
      [ "relay"; "enable"; "--url"; dead_url ] (root // "enable.log")
  in
  check bool "enable exits 0" true (code1 = 0);
  let out, code2 =
    spawn_to_log ~env [ "relay"; "disable" ] (root // "disable.log")
  in
  check bool ("disable exits 0: " ^ out) true (code2 = 0);
  check bool "disable warns about the non-machine target" true
    (contains ~haystack:out ~needle:"warning");
  check bool "warning names the exact repo-local file" true
    (contains ~haystack:out ~needle:(repo_local_relay_json broker));
  check bool "repo-local scope now disabled" true
    (json_bool_field (repo_local_relay_json broker) "enabled" = Some false)

(* The canonical repo broker root for a repo whose remote.origin.url is
   [remote], under C2C_STATE_HOME: <state>/c2c/repos/<fp12>/broker — the
   documented fingerprint is SHA-256 of remote.origin.url, first 12 hex. *)
let canonical_repo_broker ~state remote =
  let hex = Digestif.SHA256.to_hex (Digestif.SHA256.digest_string remote) in
  state // "c2c" // "repos" // String.sub hex 0 12 // "broker"

let init_git_repo dir remote =
  mkdir_p dir;
  Sys.command
    (Printf.sprintf "cd %s && git init -q && git config remote.origin.url %s"
       (Filename.quote dir) (Filename.quote remote)) = 0

let test_disable_machine_scope_warns_repo_local_still_active () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let state = root // "state" in
  let repo = root // "repo" in
  let remote = "https://b312.example/repo.git" in
  check bool "git init ok" true (init_git_repo repo remote);
  let broker = canonical_repo_broker ~state remote in
  write_json (broker // "relay.json")
    (`Assoc [ ("url", `String dead_url) ]);
  let env = b312_env ~home ~instances:(root // "instances") ~state in
  let out, code =
    run_relay_in ~cwd:repo ~env ~args:"disable" (root // "disable.log")
  in
  check bool ("disable exits 0: " ^ out) true (code = 0);
  check bool "machine config disabled" true
    (json_bool_field (home // ".config" // "c2c" // "relay.json") "enabled"
     = Some false);
  check bool "disable warns a repo-local scope is still active" true
    (contains ~haystack:out ~needle:"still ACTIVE");
  check bool "warning names the repo-local file" true
    (contains ~haystack:out ~needle:(broker // "relay.json"));
  check bool "warning says how to disable that scope" true
    (contains ~haystack:out ~needle:"C2C_RELAY_CONFIG")

let test_disable_machine_scope_silent_without_repo_local_config () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let state = root // "state" in
  let repo = root // "repo" in
  let remote = "https://b312.example/quiet.git" in
  check bool "git init ok" true (init_git_repo repo remote);
  (* No repo-local relay.json anywhere: the canonical repo broker must not
     even exist. *)
  let env = b312_env ~home ~instances:(root // "instances") ~state in
  let out, code =
    run_relay_in ~cwd:repo ~env ~args:"disable" (root // "disable.log")
  in
  check bool ("disable exits 0: " ^ out) true (code = 0);
  check bool "no still-active warning" true
    (not (contains ~haystack:out ~needle:"still ACTIVE"))

let () =
  run "c2c relay b312 verb scoping" [
    "B312 restart URL resolution", [
      test_case "candidates: saved URL is last resort (order)" `Quick
        test_restart_candidates_saved_url_is_last_resort;
      test_case "bootstrap uses relay.json (enable-only host)" `Quick
        test_restart_bootstrap_uses_relay_json;
      test_case "env C2C_RELAY_URL beats saved managed config" `Quick
        test_restart_env_url_beats_saved_managed_config;
      test_case "relay.json beats saved managed config" `Quick
        test_restart_relay_json_beats_saved_managed_config;
    ];
    "B312 enable/disable scoping warnings", [
      test_case "broker-scoped enable warns, names the file" `Quick
        test_enable_broker_scoped_warns_names_file;
      test_case "broker-scoped disable warns, names the file" `Quick
        test_disable_broker_scoped_warns_names_file;
      test_case "machine disable warns when repo-local still active" `Quick
        test_disable_machine_scope_warns_repo_local_still_active;
      test_case "machine disable silent without repo-local config" `Quick
        test_disable_machine_scope_silent_without_repo_local_config;
    ];
  ]
