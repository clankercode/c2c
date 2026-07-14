(* c2c_init_cmd — onboarding/setup command island extracted from c2c.ml. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax
open C2c_mcp
open C2c_types
open C2c_utils

(* --- repo config helpers (also used by init_cmd + repo subcommand) ------- *)

let repo_config_path () =
  Filename.concat (Sys.getcwd ()) ".c2c" // "repo.json"

let load_repo_config () =
  let path = repo_config_path () in
  if not (Sys.file_exists path) then `Assoc []
  else
    (try Yojson.Safe.from_file path
     with _ -> `Assoc [])

let save_repo_config json =
  let path = repo_config_path () in
  let dir = Filename.dirname path in
  C2c_utils.mkdir_p dir;
  C2c_setup.json_write_file path json

let valid_strategies = [ "first-alive"; "round-robin"; "broadcast" ]

(* --- subcommand: init ---------------------------------------------------- *)

(* Shared with MCP inference (B134): keep init + inferred_client_type_from_env
   in lockstep so GROK_SESSION_ID / Cursor markers are not silently dropped. *)
let native_client_type_from_env () = C2c_mcp.inferred_client_type_from_env ()

(* PATH uniqueness candidates (B102/B134). Include grok; do NOT include Cursor
   (no reliable PATH binary — Cursor uses env markers only). When more than one
   of these is present, fail closed (None) rather than silently picking Codex. *)
let path_detectable_binaries = [ "opencode"; "claude"; "codex"; "kimi"; "grok" ]

let detect_client () =
  (* A shell commonly has several agent CLIs on PATH.  Picking the first one
     makes the result depend on an arbitrary list order (B102: a Claude Code
     session was labelled opencode merely because both binaries were present).
     Prefer the client process's explicit/native environment; only use a
     managed c2c session-id prefix next, and regard PATH as evidence when it
     identifies exactly one possible client. *)
  match native_client_type_from_env () with
  | Some _ as client -> client
  | None ->
      (match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
       | Some sid ->
           List.find_opt (fun c ->
             let cl = String.length c in
             String.length sid >= cl && String.sub sid 0 cl = c)
             C2c_setup.detect_client_prefixes
       | None -> None)
      |> (function
          | Some _ as client -> client
          | None ->
              let has_bin name =
                let path = try Sys.getenv "PATH" with Not_found -> "" in
                List.exists (fun d -> Sys.file_exists (d // name))
                  (String.split_on_char ':' path)
              in
              match List.filter has_bin path_detectable_binaries with
              | [ client ] -> Some client
              | _ -> None)

let init_cmd =
  let open Cmdliner in
  let client_opt =
    Arg.(value & opt (some string) None & info ["client"; "c"] ~docv:"CLIENT"
           ~doc:(Printf.sprintf "Client to configure: %s. Auto-detected when omitted." C2c_setup.init_configurable_client_list))
  in
  let alias_opt_arg =
    Arg.(value & opt (some string) None & info ["alias"; "a"] ~docv:"ALIAS"
           ~doc:"Alias to register under. Auto-generated when omitted.")
  in
  let no_nonce_flag =
    Arg.(value & flag & info ["no-nonce"]
           ~doc:"Deprecated no-op: default auto-generated aliases always keep the 4-character nonce suffix.")
  in
  let room_arg =
    Arg.(value & opt string "swarm-lounge" & info ["room"; "r"] ~docv:"ROOM"
           ~doc:"Room to join on init (default: swarm-lounge). Pass empty string to skip.")
  in
  let no_setup =
    Arg.(value & flag & info ["no-setup"]
           ~doc:"Skip client MCP setup; only register and join room.")
  in
  let supervisor_arg =
    Arg.(value & opt (some string) None & info ["supervisor"; "S"] ~docv:"ALIAS[,ALIAS2,...]"
           ~doc:"Permission supervisor alias(es). Written to .c2c/repo.json. Equivalent to c2c repo set supervisor.")
  in
  let supervisor_strategy_arg =
    Arg.(value & opt (some string) None & info ["supervisor-strategy"] ~docv:"STRATEGY"
           ~doc:"Supervisor dispatch strategy: first-alive (default), round-robin, broadcast.")
  in
  let relay_url_arg =
    Arg.(value & opt (some string) None & info ["relay"]
           ~docv:"URL" ~doc:"Configure and register with a relay at this URL. Prints connector start command as next step.")
  in
  let easy_pool_flag =
    Arg.(value & flag & info ["easy-pool"]
           ~doc:"Generate alias from the easy-pool word subset (52 nature-themed English-readable words) instead of the full alias pool (~1,450 words).")
  in
  let require_easy_flag =
    Arg.(value & flag & info ["require-easy"]
           ~doc:"Fail if the auto-generated alias is not from the easy pool. Implies --easy-pool. Use when the agent must have a human-readable alias.")
  in
  let with_mcp_flag =
    Arg.(value & flag & info ["with-mcp"]
           ~doc:"Install MCP server config (.mcp.json) for the detected client. Off by default — CLI is the primary usage path.")
  in
  let hooks_flag =
    Arg.(value & flag & info ["hooks"]
           ~doc:"Install client hooks (e.g. Claude PostToolUse nudge). Implies --with-mcp. Off by default.")
  in
  let+ json = json_flag
  and+ client_opt = client_opt
  and+ alias_opt = alias_opt_arg
  and+ room = room_arg
  and+ no_setup = no_setup
  and+ supervisor_opt = supervisor_arg
  and+ supervisor_strategy_opt = supervisor_strategy_arg
  and+ relay_url = relay_url_arg
  and+ easy_pool = easy_pool_flag
  and+ require_easy = require_easy_flag
  and+ no_nonce = no_nonce_flag
  and+ with_mcp = with_mcp_flag
  and+ hooks = hooks_flag in
  let output_mode = if json then Json else Human in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in

  let client_resolved =
    match client_opt with
    | Some c -> Some c
    | None -> detect_client ()
  in

  (* B046: Resolve session_id BEFORE alias so we can look up existing
     registrations and reuse the alias when --alias is not given.
     Resolution order (#10): env (C2C_MCP_SESSION_ID or a client-native key
     such as CLAUDE_CODE_SESSION_ID) > persisted init-fallback statefile
     (validated against the registry) > synthesize a fresh id. When the id
     was NOT env-derived it is persisted to <broker_root>/default-session.json
     after registration so later env-less `c2c` invocations in the same
     context resolve the same identity. *)
  let env_derived_session_id = C2c_mcp.session_id_from_env () in
  let session_id =
    match env_derived_session_id with
    | Some s -> s
    | None ->
        (match session_id_from_statefile () with
         | Some s -> s
         | None -> C2c_setup.generate_session_id ())
  in

  (* Resolve alias ONCE before do_install_client so both the .mcp.json env
     (C2C_MCP_AUTO_REGISTER_ALIAS) and Broker.register use the same alias.
     B046: when --alias is not given, check for an existing registration
     with the same session_id and reuse its alias for stable re-runs. *)
  let alias =
    match alias_opt with
    | Some a -> a
    | None ->
        (* B046: check if session_id already has a registration; reuse alias.
           B188: also look across other broker fingerprints under
           ~/.c2c/repos/*/broker so path→remote.origin.url switches keep
           the sticky alias instead of minting a second identity. *)
        let existing_alias_opt =
          try
            let regs = C2c_mcp.Broker.list_registrations broker in
            match List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = session_id) regs with
            | Some reg -> Some (reg.alias, None)
            | None ->
                (match
                   C2c_mcp.find_prior_session_across_brokers ~session_id
                     ~exclude_root:root ()
                 with
                 | Some hit -> Some (hit.registration.alias, Some hit)
                 | None -> None)
          with _ -> None
        in
        match existing_alias_opt with
        | Some (existing_alias, prior_hit) ->
            (match prior_hit with
             | Some hit ->
                 ignore
                   (C2c_mcp.migrate_alias_ed25519_keys ~from_root:hit.broker_root
                      ~to_root:root ~alias:existing_alias);
                 Printf.eprintf
                   "[c2c register] reusing sticky alias=%s for session_id=%s \
                    (from broker fingerprint %s)\n%!"
                   existing_alias session_id hit.fingerprint
             | None ->
                 Printf.eprintf
                   "[c2c register] reusing existing alias=%s for session_id=%s\n%!"
                   existing_alias session_id);
            existing_alias
        | None ->
            let use_easy = easy_pool || require_easy in
            (* Generate a BARE candidate first; the nonce is appended AFTER
               the require-easy pool check to avoid an infinite loop
               (#B-require-easy blocker). *)
            let prefix =
              match client_resolved with
              | Some c -> C2c_setup.default_alias_prefix c
              | None -> "agent"
            in
            let base_gen_fn =
              if use_easy then C2c_setup.generate_alias_easy ~no_nonce:true
              else C2c_setup.generate_alias ~no_nonce:true
            in
            let rec loop () =
              let bare = base_gen_fn () in
              if require_easy then
                let w1, w2 = match String.split_on_char '-' bare with [w1; w2] -> (w1, w2) | _ -> ("", "") in
                let easy = C2c_alias_words.easy_pool in
                let is_easy w = Array.exists (fun e -> e = w) easy in
                if is_easy w1 && is_easy w2 then C2c_nonce.append_nonce (prefix ^ "-" ^ bare) else loop ()
              else
                C2c_nonce.append_nonce (prefix ^ "-" ^ bare)
            in
            let a = loop () in
            Printf.eprintf "[c2c register] no --alias given; auto-picked alias=%s. Pass --alias NAME to override.\n%!" a;
            a
  in

  (* B135: alias is sticky per session_id — refuse explicit --alias rename. *)
  (match alias_opt with
   | Some requested ->
       (match
          C2c_mcp.Broker.sticky_alias_conflict broker ~session_id
            ~requested_alias:requested
        with
        | Some existing_alias ->
            let msg =
              C2c_mcp.Broker.sticky_alias_error ~session_id ~existing_alias
                ~requested_alias:requested
            in
            (match output_mode with
             | Json ->
                 print_json (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
             | Human ->
                 Printf.eprintf "error: %s\n%!" msg);
            exit 1
        | None -> ())
   | None -> ());

  let alias_for_install = Some alias in
  let do_mcp_setup = with_mcp || hooks in
  let setup_result =
    if no_setup then `Skipped
    else if not do_mcp_setup then `Cli_only
    else match client_resolved with
      | None ->
          (match output_mode with
           | Human ->
               Printf.printf "No client detected. Specify one with --client:\n";
               Printf.printf "  c2c init --client claude\n";
               Printf.printf "  c2c init --client codex\n";
               Printf.printf "  c2c init --client opencode\n";
               Printf.printf "  c2c init --client kimi\n"
           | Json -> ());
          `No_client
      | Some client ->
          (try
             C2c_setup.do_install_client ~output_mode ~dry_run:false ~client ~alias_opt:alias_for_install ~no_nonce ~broker_root_opt:(Some root) ~target_dir_opt:None ~force:false ~skip_summary:true ~skip_hooks:(not hooks) ();
             `Ok (C2c_setup.canonical_install_client client)
           with e -> `Error (Printexc.to_string e))
  in
  (* B186: no install/init-time wake.toml seed (dead for raw clients; redundant
     with managed builtin heartbeat). B033: still write the /c2c skill on the
     CLI-only path when the client is claude — the skill is a static
     CLI+Monitor reference with no MCP dep, so plain `c2c init` (default,
     --with-mcp/--hooks off) must still install it. *)
  (match setup_result with
   | `Cli_only ->
       (match client_resolved with
        | Some c when C2c_setup.canonical_install_client c = "claude" ->
            ignore (C2c_setup.write_claude_skill ~output_mode ~dry_run:false ())
        | _ -> ())
   | _ -> ());
  (* Ensure Ed25519 identity exists — idempotent, safe to run always. *)
  (* Identity init is a pure side-effect from init's perspective: init only
     consumes the exit code and emits its own consolidated output (Human or
     Json). Mute BOTH streams of the child — on a fresh host the child prints
     "identity written to ..." to STDOUT, which would otherwise corrupt the
     single-JSON-document guarantee of `c2c init --json` (B025). *)
  let identity_init_rc =
    Sys.command (Printf.sprintf "%s relay identity init >/dev/null 2>&1"
      (Filename.quote (current_c2c_command ())))
  in
  if identity_init_rc <> 0 then
    Printf.eprintf "  warning: relay identity init failed (rc=%d). Relay features may not work.\n  hint: run 'c2c relay identity init' manually to diagnose.\n%!" identity_init_rc;

  let alias_from_auto_gen = (alias_opt = None) in
  (* B071: same pid chain as `c2c register` — env override → stable agent
     ancestor → None (unknown liveness, routable). *)
  let reg_pid = resolve_registration_pid ~session_id () in
  let reg_pid_start = C2c_mcp.Broker.capture_pid_start_time reg_pid in
  (try
     (* Prefer detect_client / --client resolution over bare C2C_MCP_CLIENT_TYPE
        so Grok/Cursor native markers persist into registration + statefile (B134). *)
     C2c_mcp.Broker.register broker ~session_id ~alias ~pid:reg_pid ~pid_start_time:reg_pid_start
       ~client_type:client_resolved ~from_auto_gen:alias_from_auto_gen ()
   with Invalid_argument msg ->
     (if json then
        print_json (`Assoc [("ok", `Bool false); ("error", `String msg)])
      else
        Printf.eprintf "error: %s\n%!" msg);
     exit 1);

  (* Write default-alias config so bare `c2c monitor` can resolve alias
     without env vars or --alias flag. *)
  (try
     let config_dir = (try Sys.getenv "HOME" with Not_found -> "/tmp") // ".config" // "c2c" in
     C2c_mcp.mkdir_p config_dir;
     ignore (C2c_io.write_file_atomic (config_dir // "default-alias") (alias ^ "\n"))
   with _ -> ());  (* best-effort, non-fatal *)

  (* #10: persist the session id when it was NOT derived from the environment,
     so the very next `c2c whoami`/`c2c send` in the same env-less context
     resolves the identity we just registered. Env-derived ids are never
     persisted — the env remains the source of truth for them. *)
  if env_derived_session_id = None then
    write_session_statefile ~broker_root:root ~session_id ~alias
      ~client:client_resolved;

  let room_result =
    if String.trim room = "" then `Skipped
    else
      (try
         let (_ : C2c_mcp.room_member list) =
           C2c_mcp.Broker.join_room broker ~session_id ~alias ~room_id:room
         in
         `Joined room
       with Invalid_argument msg -> `Error msg)
  in

  let supervisor_result =
    match supervisor_opt with
    | None -> `Skipped
    | Some sup_str ->
        let aliases = List.filter (fun s -> s <> "") (String.split_on_char ',' sup_str) in
        if aliases = [] then `Error "empty supervisor list"
        else begin
          (match supervisor_strategy_opt with
           | Some s when not (List.mem s valid_strategies) ->
               Printf.eprintf "error: unknown strategy '%s'. Use: %s\n%!"
                 s (String.concat ", " valid_strategies);
               exit 1
           | _ -> ());
          let config = load_repo_config () in
          let fields = match config with `Assoc f -> f | _ -> [] in
          let supervisor_val = `List (List.map (fun a -> `String a) aliases) in
          let fields' = ref
            (("supervisors", supervisor_val)
             :: List.filter (fun (k, _) -> k <> "supervisors" && k <> "permission_supervisors"
                                           && k <> "supervisor_strategy") fields)
          in
          (match supervisor_strategy_opt with
           | Some s -> fields' := ("supervisor_strategy", `String s) :: !fields'
           | None -> ());
          save_repo_config (`Assoc !fields');
          `Set (aliases, supervisor_strategy_opt)
        end
  in

  (* Relay attachment: setup + register when --relay URL is given. *)
  let relay_result = match relay_url with
    | None -> `Skipped
    | Some rurl ->
        (try
           (* Save relay config: same path resolution as relay_setup_cmd. *)
           let config_path =
             match Sys.getenv_opt "C2C_RELAY_CONFIG" with
             | Some p when p <> "" -> p
             | _ ->
                 (match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
                  | Some d when String.trim d <> "" -> Filename.concat (String.trim d) "relay.json"
                  | _ ->
                      let home = try Sys.getenv "HOME" with Not_found -> "." in
                      Filename.concat home ".config/c2c/relay.json")
           in
           let existing = try
             let ic = open_in config_path in
             Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
               Yojson.Safe.from_channel ic)
           with _ -> `Assoc [] in
           let set_field fields key v =
             (key, `String v) :: List.filter (fun (k, _) -> k <> key) fields
           in
           let merged = match existing with
             | `Assoc l -> set_field l "url" rurl
             | _ -> [("url", `String rurl)]
           in
           let oc = open_out config_path in
           Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
             output_string oc (Yojson.Safe.pretty_to_string (`Assoc merged)));
           (match output_mode with Human -> Printf.printf "  relay:     saved config\n" | Json -> Printf.eprintf "  relay:     saved config\n%!");
           (* Register with relay. *)
           (match Relay_identity.load () with
            | Ok id ->
                let client = Relay.Relay_client.make rurl in
                let node_id = Printf.sprintf "cli-%s" alias in
                let session_id = node_id in
                let p = Relay_signed_ops.sign_register id ~alias ~relay_url:rurl in
                let result = Lwt_main.run (Relay.Relay_client.register_signed client
                  ~node_id ~session_id ~alias ~client_type:"cli"
                  ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
                  ~sig_b64:p.Relay_signed_ops.sig_b64
                  ~nonce:p.Relay_signed_ops.nonce
                  ~ts:p.Relay_signed_ops.ts ()) in
                (match result with
                 | `Assoc fields ->
                     (match List.assoc_opt "ok" fields with
                      | Some (`Bool true) -> Printf.eprintf "  relay:     registered %s\n%!" alias
                      | _ -> Printf.eprintf "  relay:     registration returned non-ok\n%!")
                 | _ -> Printf.eprintf "  relay:     unexpected response\n%!")
            | Error _ ->
                (* Unauthenticated registration. *)
                let client = Relay.Relay_client.make rurl in
                let node_id = Printf.sprintf "cli-%s" alias in
                let session_id = node_id in
                let result = Lwt_main.run (Relay.Relay_client.register client
                  ~node_id ~session_id ~alias ~client_type:"cli" ~identity_pk:"" ()) in
                (match result with
                 | `Assoc fields ->
                     (match List.assoc_opt "ok" fields with
                      | Some (`Bool true) -> Printf.eprintf "  relay:     registered %s (unauthenticated)\n%!" alias
                      | _ -> Printf.eprintf "  relay:     registration returned non-ok\n%!")
                 | _ -> Printf.eprintf "  relay:     unexpected response\n%!"));
           `Ok rurl
         with e -> `Error (Printexc.to_string e))
  in

  (match output_mode with
   | Json ->
       let setup_json = match setup_result with
         | `Ok c -> `String (Printf.sprintf "configured %s" c)
         | `Skipped -> `String "skipped"
         | `Cli_only -> `String "cli-only (no MCP)"
         | `No_client -> `String "no client detected"
         | `Error e -> `String (Printf.sprintf "error: %s" e)
       in
       let room_json = match room_result with
         | `Joined r -> `String r
         | `Skipped -> `Null
         | `Error e -> `String (Printf.sprintf "error: %s" e)
       in
        let supervisor_json = match supervisor_result with
          | `Set (aliases, strat) ->
              `Assoc ([ ("ok", `Bool true); ("aliases", `List (List.map (fun a -> `String a) aliases)) ]
                      @ (match strat with Some s -> [("strategy", `String s)] | None -> []))
          | `Skipped -> `Null
          | `Error e -> `Assoc [("ok", `Bool false); ("error", `String e)]
        in
        let relay_json = match relay_result with
          | `Ok url -> `Assoc [("ok", `Bool true); ("relay_url", `String url)]
          | `Skipped -> `Null
          | `Error e -> `Assoc [("ok", `Bool false); ("error", `String e)]
        in
        let room_id_str = match room_result with `Joined r -> r | _ -> room in
        let onboarding_lines =
          let is_claude = match client_resolved with Some "claude" -> true | _ -> false in
          [ Printf.sprintf "Start receiving: run c2c monitor (shows incoming DMs; add --drain to also clear the inbox)"
          ; Printf.sprintf "Send:    c2c send <alias> <msg>    (e.g. c2c send %s \"hello\")" alias
          ; "Check:   c2c poll-inbox"
          ; Printf.sprintf "Room:    c2c rooms send %s <msg>" room_id_str
          ] @
          (if is_claude then
            [ "Monitor: add to Claude Code Monitor tool for auto-delivery" ]
          else []) @
          (if not do_mcp_setup then
            [ "MCP is optional; the CLI + Monitor work immediately with zero reload. Pass --with-mcp to enable MCP tools."
            ]
          else [])
        in
        let onboarding_json = `Assoc
          [ ("alias", `String alias)
          ; ("room", `String room_id_str)
          ; ("cli_first", `Bool (not do_mcp_setup))
          ; ("lines", `List (List.map (fun s -> `String s) onboarding_lines))
          ]
        in
        print_json (`Assoc
          [ ("ok", `Bool true)
          ; ("session_id", `String session_id)
          ; ("alias", `String alias)
          ; ("broker_root", `String root)
          ; ("setup", setup_json)
          ; ("room", room_json)
          ; ("supervisor", supervisor_json)
          ; ("relay", relay_json)
          ; ("onboarding", onboarding_json)
         ])
   | Human ->
       Printf.printf "\nc2c init complete!\n";
       Printf.printf "  session:  %s\n" session_id;
       Printf.printf "  alias:    %s\n" alias;
       Printf.printf "  broker:   %s\n" root;
       (match setup_result with
        | `Ok c -> Printf.printf "  setup:    %s configured\n" c
        | `Skipped -> ()
        | `Cli_only -> Printf.printf "  setup:    CLI-only (no MCP wiring)\n"
        | `No_client -> Printf.printf "  setup:    skipped (no client detected)\n"
        | `Error e -> Printf.printf "  setup:    error — %s\n" e);
       (match room_result with
        | `Joined r -> Printf.printf "  room:     joined #%s\n" r
        | `Skipped -> ()
        | `Error e -> Printf.printf "  room:     error joining — %s\n" e);
       (match supervisor_result with
        | `Set (aliases, strat) ->
            Printf.printf "  supervisor: %s%s\n" (String.concat ", " aliases)
              (match strat with Some s -> Printf.sprintf " (strategy: %s)" s | None -> "")
        | `Skipped -> ()
        | `Error e -> Printf.printf "  supervisor: error — %s\n" e);
       (match relay_result with
        | `Ok rurl ->
            Printf.printf "\nRelay attached. Start the connector with:\n";
            Printf.printf "  c2c relay connect --relay-url %s\n" rurl
        | `Skipped -> ()
        | `Error e -> Printf.printf "  relay:     error — %s\n" e);
       Printf.printf "\n";
       Printf.printf "  AGENT ONBOARDING\n";
       Printf.printf "  ----------------\n";
       Printf.printf "  Start receiving: run c2c monitor\n";
       Printf.printf "  Send:    c2c send <alias> <msg>    (e.g. c2c send %s \"hello\")\n" alias;
       Printf.printf "  Check:   c2c poll-inbox\n";
       Printf.printf "  Room:    c2c rooms send %s <msg>\n" room;
       Printf.printf "  c2c monitor           — watch incoming messages (auto-resolves alias; watches your live inbox, peeks by default)\n";
       Printf.printf "  c2c monitor --drain   — same, but the monitor consumes (drains) your inbox\n";
       (match client_resolved with
        | Some "claude" ->
            Printf.printf "  Monitor: add to Claude Code Monitor tool for auto-delivery\n"
        | _ -> ());
       if not do_mcp_setup then
         Printf.printf "  MCP is optional; the CLI + Monitor work immediately with zero reload.\n  Pass --with-mcp to enable MCP tools.\n"
)

let completion_cmd =
  let shell_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "shell" ] ~docv:"SHELL"
      ~doc:"Shell to generate completions for: bash, zsh, or pwsh. Detects from \\$SHELL if omitted.")
  in
  let detect_shell () =
    try
      let shell = Sys.getenv "SHELL" in
      if Filename.check_suffix shell "bash" then Some "bash"
      else if Filename.check_suffix shell "zsh" then Some "zsh"
      else if Filename.check_suffix shell "pwsh" || Filename.check_suffix shell "powershell" then Some "pwsh"
      else None
    with Not_found -> None
  in
  let cmdliner_bin () =
    try
      let opam_prefix = Sys.getenv "OPAM_SWITCH_PREFIX" in
      Filename.concat opam_prefix "bin" // "cmdliner"
    with Not_found ->
      let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
      Filename.concat home ".opam/c2c/bin/cmdliner"
  in
  let term =
    let+ shell = shell_arg in
    let shell = match shell with
      | Some s -> Some (String.lowercase_ascii (String.trim s))
      | None -> detect_shell ()
    in
    match shell with
    | Some s when List.mem s ["bash"; "zsh"; "pwsh"] ->
        let cmd = Printf.sprintf "%s tool-completion --standalone-completion %s c2c"
          (cmdliner_bin ()) s
        in
        let run_and_check cmd =
          let ic = Unix.open_process_in cmd in
          let rec copy_all () =
            try print_endline (input_line ic); copy_all ()
            with End_of_file -> ()
          in
          copy_all ();
          match Unix.close_process_in ic with
          | Unix.WEXITED 0 -> ()
          | Unix.WEXITED n ->
              Printf.eprintf "error: cmdliner exited with code %d\n%!" n;
              exit 1
          | _ ->
              Printf.eprintf "error: cmdliner terminated unexpectedly\n%!";
              exit 1
        in
        run_and_check cmd
    | Some s ->
        Printf.eprintf "error: unknown shell '%s'. Supported: bash, zsh, pwsh\n%!" s;
        exit 1
    | None ->
        Printf.eprintf "error: could not detect shell. Please specify --shell explicitly\n%!";
        exit 1
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "completion"
       ~doc:"Generate shell completion scripts for bash, zsh, and pwsh.")
    term

let init =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "init"
       ~doc:"One-command project onboarding: configure client MCP, register, join swarm-lounge."
       ~man:[ `S "DESCRIPTION"
            ; `P "$(b,c2c init) configures the current AI client for c2c messaging, registers \
                  the session, and joins swarm-lounge. Run once per project."
            ; `P "Auto-detects the client from explicit/native client environment, then $(b,C2C_MCP_SESSION_ID), or a single installed client binary. \
                  Override with $(b,--client)."
            ; `S "SESSION IDENTITY"
            ; `P "The session id is resolved from the environment first \
                  ($(b,C2C_MCP_SESSION_ID), then client-native keys such as \
                  $(b,CLAUDE_SESSION_ID)/$(b,CLAUDE_CODE_SESSION_ID) or \
                  $(b,CODEX_THREAD_ID)). When none is present, init synthesizes \
                  one and persists it to $(i,<broker-root>/default-session.json) \
                  so later env-less $(b,c2c) commands (whoami, send, ...) resolve \
                  the same identity."
            ; `P "LIMITATION: the persisted fallback holds a $(i,single) identity \
                  per repo — it is intended for CLI-only single-session usage. Two \
                  env-less agents running $(b,c2c init) in the same repo will \
                  collide (last init wins). Env-derived session ids always take \
                  precedence over the fallback, and a stale fallback (session no \
                  longer registered) is ignored."
            ; `S "EXAMPLES"
            ; `P "$(b,c2c init)  — auto-detect client, configure, register, join swarm-lounge"
            ; `P "$(b,c2c init --client opencode --alias my-bot)  — explicit client and alias"
            ; `P "$(b,c2c init --no-setup --room project-room)  — skip MCP setup, join custom room"
            ; `P "$(b,c2c init --supervisor coordinator1)  — set permission supervisor"
            ; `P "$(b,c2c init --supervisor coordinator1,planner1 --supervisor-strategy round-robin)  — multi-supervisor"
            ])
    init_cmd

let self_update_cmd =
  let check_only =
    Cmdliner.Arg.(
      value & flag & info [ "check" ]
        ~doc:"Report latest available vs current version without modifying anything.")
  in
  let pinned_version =
    Cmdliner.Arg.(
      value & opt (some string) None
        & info [ "target" ] ~docv:"VERSION"
            ~doc:"Pin to a specific release tag (e.g. 0.8.8 or v0.8.8).")
  in
  let json_output =
    Cmdliner.Arg.(
      value & flag & info [ "json" ]
        ~doc:"Output a single valid JSON document on stdout; diagnostics to stderr.")
  in
  let verify_sig =
    Cmdliner.Arg.(
      value & flag & info [ "verify-sig" ]
        ~doc:"Verify release signature if available. (TODO: not yet implemented — prints a note.)")
  in
  let open Cmdliner.Term in
  let+ check_only = check_only
  and+ pinned_version = pinned_version
  and+ json_output = json_output
  and+ verify_sig = verify_sig in
  let result = C2c_self_update.run_self_update ~check_only ~pinned_version ~json_output ~verify_sig in
  match result with
  | C2c_self_update.Updated _ -> ()
  | Already_latest -> ()
  | Check_only _ -> ()
  | Update_error _ -> exit 1

let self_update =
  let info = Cmdliner.Cmd.info "self-update"
    ~doc:"Update c2c to the latest (or pinned) release."
    ~man:
      [ `S "DESCRIPTION"
      ; `P "$(b,c2c self-update) updates the running c2c in a way that preserves how it \
            was installed. It first detects the install method, then behaves honestly:"
      ; `P "$(b,standalone) — downloads the latest (or pinned) release from GitHub, \
            verifies the SHA-256 checksum, and atomically replaces the running binary in place."
      ; `P "$(b,npm / pnpm / bun) — delegates to the owning package manager (e.g. \
            $(b,npm install -g @clanker-code/c2c@latest)) instead of overwriting the binary \
            inside $(b,node_modules) or a content-addressed store. Pass $(b,--target <ver>) \
            to select a specific package version."
      ; `P "Asset naming convention for standalone installs (shared with install.sh): \
            $(b,c2c-<version>-<os>-<arch>.tar.gz) where os ∈ {linux, darwin}, arch ∈ {x64, arm64}."
      ; `S "PROVENANCE & REFUSALS"
      ; `P "The updater refuses rather than acting dishonestly when: the running binary is \
            $(b,shadowed) on PATH (a different c2c runs when you type $(b,c2c), so updating \
            the running one would not help); the install provenance is $(b,unknown/ambiguous) \
            (a package store this updater does not recognise); or the owning package manager \
            is $(b,not installed). Each case exits non-zero with an actionable message and \
            never silently drops a standalone copy elsewhere."
      ; `P "Still refuses to touch system paths (/usr, /usr/local, /bin) for standalone \
            installs. Advises the curl bootstrap at https://c2c.im/install.sh."
      ; `P "Exit codes: 0 = updated or check-only OK; 1 = error; the JSON output \
            distinguishes $(b,already_latest) vs $(b,updated) vs $(b,error), and for \
            package-managed installs reports $(b,install_method) plus the \
            $(b,delegate_command) that runs."
      ; `S "SECURITY"
      ; `P "SHA-256 checksum verification is always performed against the published \
            SHA256SUMS file. Signature verification (cosign/sigstore) is a TODO — \
            when $(b,--verify-sig) is passed, a note is printed."
      ; `S "EXAMPLES"
      ; `P "$(b,c2c self-update)  — update to latest release"
      ; `P "$(b,c2c self-update --check)  — report latest vs current without modifying"
      ; `P "$(b,c2c self-update --check --json)  — machine-readable check"
      ; `P "$(b,c2c self-update --target 0.8.5)  — pin to a specific version"
      ; `P "$(b,c2c self-update --json)  — update with JSON output"
      ]
  in
  Cmdliner.Cmd.v info self_update_cmd

(* Aliases for self-update *)
let update_alias =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "update"
       ~doc:"Alias for self-update.")
    self_update_cmd

let upgrade_alias =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "upgrade"
       ~doc:"Alias for self-update.")
    self_update_cmd

let install =
  let info = Cmdliner.Cmd.info "install"
    ~doc:"Install c2c — binary by default; client MCP is explicit opt-in."
    ~man:
      [ `S "DESCRIPTION"
      ; `P "With no subcommand, $(b,c2c install) runs an interactive TUI. \
            Defaults are $(b,binary-only): install the c2c CLI if missing. \
            Client MCP/hooks are never selected by default (B122). Press \
            $(b,Enter) for binary-only, $(b,c) to customize (client prompts \
            default to no), or $(b,n) to abort."
      ; `P
          ("Scriptable installs: $(b,c2c install self) installs only the binary \
            (add $(b,--mcp-server) to also install $(b,c2c-mcp-server)); \
            $(b,c2c install " ^ C2c_setup.install_client_pipe_list ^ ") configures \
            one client deliberately; $(b,c2c install all) installs the binary only \
            unless $(b,--with-clients) is passed. Prefer naming a single client. \
            Claude $(b,--global) (writes $(b,~/.claude.json)) is advanced and never \
            implied.")
      ]
  in
  Cmdliner.Cmd.group ~default:C2c_setup.install_default_term info
    ([ C2c_setup.install_self_subcmd
     ; C2c_setup.install_all_subcmd
     ; C2c_setup.install_git_hook_subcmd
     ]
     @ List.map C2c_setup.install_client_subcmd C2c_setup.install_subcommand_clients)
