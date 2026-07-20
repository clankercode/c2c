(* test_c2c_mcp_kimi_adopt — #48 regression.

   The global ~/.kimi-code/mcp.json bakes ONE install-time
   C2C_MCP_AUTO_REGISTER_ALIAS with deliberately no C2C_MCP_SESSION_ID (one
   file serves every kimi session). Before #48 the in-session MCP server's
   startup auto-register ([C2c_mcp.auto_register_startup]) minted/rebound that
   sticky alias under its own (session-index-derived) session id even when a
   managed `c2c start kimi` row already owned this cwd — creating a SECOND,
   competing identity that tripped #40's "2 live managed kimi instances share
   cwd" ambiguity guard on relaunch.

   These tests exercise [auto_register_startup] in-process against a temp
   broker root and pin BOTH directions:
     (a) a LIVE managed kimi row owns cwd  → auto-register RESOLVES to it,
         mints NO competing alias (registry keeps exactly the managed row);
     (b) no managed row for cwd            → the install-time alias is still
         registered (vanilla kimi is not regressed). *)

open Alcotest

let ( // ) = Filename.concat

let rec remove_tree path =
  if not (Sys.file_exists path) then ()
  else if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    (try Unix.rmdir path with _ -> ())
  end else (try Sys.remove path with _ -> ())

let mkdir_p path =
  let rec loop p =
    if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  if path <> "" && path <> Filename.dirname path then loop path

(* Clean, deterministic env for the auto-register path. Empty string is
   treated as unset by every reader consulted here (they all check
   [String.trim <> ""]). *)
let set_env pairs = List.iter (fun (k, v) -> Unix.putenv k v) pairs

let base_env ~home ~alias ~session_id =
  [ ("HOME", home)
  ; ("C2C_STATE_HOME", "")           (* → HOME-based locks/keys *)
  ; ("C2C_NO_AUTO_REGISTER", "")     (* not a subagent opt-out *)
  ; ("C2C_MCP_CLIENT_PID", "")       (* fall back to getppid *)
  ; ("KIMI_SESSION_ID", "")          (* C2C_MCP_SESSION_ID wins anyway *)
  ; ("C2C_MCP_AUTO_JOIN_ROOMS", "")
  ; ("C2C_MCP_CLIENT_TYPE", "kimi")
  ; ("C2C_MCP_AUTO_REGISTER_ALIAS", alias)
  (* The install/managed alias is drawn from the auto-gen pool (kimi-
     prefixed), so the reserved-prefix blocklist is skipped; mirror that. *)
  ; ("C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN", "1")
  ; ("C2C_MCP_SESSION_ID", session_id)
  ]

let with_ctx f =
  let orig_cwd = try Some (Sys.getcwd ()) with _ -> None in
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-mcp-kimi-adopt-%08x" (Random.bits ()) in
  let home = dir // "home" in
  let broker_root = dir // "broker" in
  let workdir = dir // "workspace" in
  mkdir_p home;
  mkdir_p broker_root;
  mkdir_p workdir;
  Fun.protect
    ~finally:(fun () ->
      (match orig_cwd with Some c -> (try Unix.chdir c with _ -> ()) | None -> ());
      (try remove_tree dir with _ -> ()))
    (fun () -> f ~home ~broker_root ~workdir)

let regs_of broker_root =
  C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:broker_root)

let aliases regs =
  List.map (fun (r : C2c_mcp.registration) -> r.alias) regs

let session_ids regs =
  List.map (fun (r : C2c_mcp.registration) -> r.session_id) regs

(* Seed an AUTHORITATIVE managed launcher row: managed (registered_by=None),
   kimi, owning [cwd], live (self pid + matching start time). *)
let seed_managed_kimi_row ?(session_id = "managed-kimi-instance") broker ~cwd ~alias =
  let self = Unix.getpid () in
  C2c_mcp.Broker.register broker
    ~session_id
    ~alias
    ~pid:(Some self)
    ~pid_start_time:(C2c_mcp.Broker.capture_pid_start_time (Some self))
    ~client_type:(Some "kimi")
    ~cwd:(Some cwd)
    ~registered_by:None
    ~from_auto_gen:true
    ()

(* A recipient peer so a [send] fully resolves. Offline (dead pid) forces the
   durable-queue path — no notifier side effects. *)
let seed_offline_peer broker ~alias =
  C2c_mcp.Broker.register broker
    ~session_id:"peer-session"
    ~alias
    ~pid:(Some 999999999) (* > pid_max: /proc entry can never exist *)
    ~pid_start_time:(Some 1)
    ~client_type:(Some "claude")
    ()

(* A LIVE third-party peer (distinct session, live self pid) whose alias a
   caller might try to send AS. *)
let seed_live_third_party broker ~alias =
  let self = Unix.getpid () in
  C2c_mcp.Broker.register broker
    ~session_id:"third-party-session"
    ~alias
    ~pid:(Some self)
    ~pid_start_time:(C2c_mcp.Broker.capture_pid_start_time (Some self))
    ~client_type:(Some "claude")
    ()

let contains ~needle haystack =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec at i = i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1)) in
    at 0

(* Drive a real tool handler end-to-end and return (text, is_error). *)
let run_tool ~broker ~tool_name ~arguments =
  let result =
    Lwt_main.run
      (C2c_mcp.handle_tool_call ~broker ~session_id_override:None ~tool_name
         ~arguments)
  in
  let open Yojson.Safe.Util in
  let text =
    match member "content" result with
    | `List (first :: _) -> (match member "text" first with `String s -> s | _ -> "")
    | _ -> ""
  in
  let is_error = match member "isError" result with `Bool b -> b | _ -> false in
  (text, is_error)

(* (a) A live managed kimi row owning cwd suppresses the MCP mint/rebind. *)
let test_adopts_live_managed_row () =
  with_ctx (fun ~home ~broker_root ~workdir ->
    Unix.chdir workdir;
    let cwd = Sys.getcwd () in
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    seed_managed_kimi_row broker ~cwd ~alias:"kimi-managed-anchor";
    set_env
      (base_env ~home ~alias:"kimi-install-sticky"
         ~session_id:"kimi-uuid-distinct-9f4fb9");
    C2c_mcp.auto_register_startup ~broker_root;
    let regs = regs_of broker_root in
    (* No second identity: the install alias never registered, and no row was
       created under the MCP server's (distinct) session id. *)
    check bool "install-time alias NOT registered" false
      (List.mem "kimi-install-sticky" (aliases regs));
    check bool "no row under the MCP-derived session id" false
      (List.mem "kimi-uuid-distinct-9f4fb9" (session_ids regs));
    check int "exactly the managed row remains" 1 (List.length regs);
    check bool "managed anchor preserved" true
      (List.mem "kimi-managed-anchor" (aliases regs)))

(* (b) With no managed row for cwd, vanilla behaviour is unchanged: the
   install-time alias is still auto-registered. *)
let test_vanilla_still_registers_install_alias () =
  with_ctx (fun ~home ~broker_root ~workdir ->
    Unix.chdir workdir;
    set_env
      (base_env ~home ~alias:"kimi-install-sticky-b"
         ~session_id:"kimi-uuid-vanilla-b");
    C2c_mcp.auto_register_startup ~broker_root;
    let regs = regs_of broker_root in
    check bool "install-time alias IS registered" true
      (List.mem "kimi-install-sticky-b" (aliases regs));
    check bool "registered under the session id" true
      (List.mem "kimi-uuid-vanilla-b" (session_ids regs)))

(* Common setup for the send/whoami identity tests: a live managed launcher row
   owns cwd, plus a recipient peer, and this process presents as an UNREGISTERED
   in-session kimi MCP server (client_type=kimi, session id = a uuid with no
   row). [f] receives the live broker handle. *)
let with_managed_kimi_mcp_session ~home ~broker_root ~workdir ?(client_type = "kimi") f =
  Unix.chdir workdir;
  let cwd = Sys.getcwd () in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  seed_managed_kimi_row broker ~cwd ~alias:"kimi-managed-anchor";
  seed_offline_peer broker ~alias:"peer-target";
  set_env
    (base_env ~home ~alias:"kimi-install-sticky"
       ~session_id:"kimi-uuid-mcp-session");
  Unix.putenv "C2C_MCP_CLIENT_TYPE" client_type;
  f broker

(* whoami: an unregistered managed-kimi MCP session reports the LAUNCHER
   alias (resolved by cwd), not "" and not the install alias. *)
let test_whoami_reports_managed_alias () =
  with_ctx (fun ~home ~broker_root ~workdir ->
    with_managed_kimi_mcp_session ~home ~broker_root ~workdir (fun broker ->
      let text, is_error = run_tool ~broker ~tool_name:"whoami" ~arguments:(`Assoc []) in
      check bool "whoami not an error" false is_error;
      (* whoami reports the managed alias (bare, or as {alias,canonical_alias}
         JSON when the row carries a canonical alias) — never "" and never the
         install alias. *)
      check bool "whoami names the managed alias" true
        (contains ~needle:"kimi-managed-anchor" text);
      check bool "whoami does NOT report the install alias" false
        (contains ~needle:"kimi-install-sticky" text)))

(* send with NO from_alias: sender resolves to the managed alias by cwd, so it
   is neither missing-sender nor impersonation-rejected. *)
let test_send_resolves_to_managed_alias () =
  with_ctx (fun ~home ~broker_root ~workdir ->
    with_managed_kimi_mcp_session ~home ~broker_root ~workdir (fun broker ->
      let text, is_error =
        run_tool ~broker ~tool_name:"send"
          ~arguments:(`Assoc [ ("to_alias", `String "peer-target"); ("content", `String "hi") ])
      in
      check bool "send did NOT fail on sender resolution" false
        (contains ~needle:"missing sender alias" text
         || contains ~needle:"cannot send as another agent" text);
      check bool "send succeeded (queued to offline peer)" false is_error))

(* send WITH from_alias = the managed alias: the impersonation guard treats the
   launcher row as SELF (carve-out), so it is allowed. *)
let test_send_with_managed_from_alias_allowed () =
  with_ctx (fun ~home ~broker_root ~workdir ->
    with_managed_kimi_mcp_session ~home ~broker_root ~workdir (fun broker ->
      let text, is_error =
        run_tool ~broker ~tool_name:"send"
          ~arguments:
            (`Assoc
               [ ("to_alias", `String "peer-target")
               ; ("content", `String "hi")
               ; ("from_alias", `String "kimi-managed-anchor")
               ])
      in
      check bool "explicit managed from_alias not rejected as impersonation" false
        (contains ~needle:"cannot send as another agent" text);
      check bool "send succeeded" false is_error))

(* Narrowness: a NON-kimi session sharing the cwd must NOT be able to send as
   the managed kimi alias — the carve-out is inert and the impersonation guard
   still fires. *)
let test_non_kimi_cannot_impersonate_managed_alias () =
  with_ctx (fun ~home ~broker_root ~workdir ->
    with_managed_kimi_mcp_session ~home ~broker_root ~workdir ~client_type:"claude"
      (fun broker ->
        let text, is_error =
          run_tool ~broker ~tool_name:"send"
            ~arguments:
              (`Assoc
                 [ ("to_alias", `String "peer-target")
                 ; ("content", `String "hi")
                 ; ("from_alias", `String "kimi-managed-anchor")
                 ])
        in
        check bool "non-kimi impersonation rejected" true is_error;
        check bool "rejection is the impersonation message" true
          (contains ~needle:"cannot send as another agent" text)))

(* Alias-SPECIFIC: the carve-out binds to the launcher alias only. A from_alias
   argument naming a DIFFERENT (live third-party) alias cannot override it —
   [current_registered_alias] resolves self FIRST, so the message is attributed
   to the managed anchor, never the requested third party. *)
let test_from_alias_arg_cannot_override_self () =
  with_ctx (fun ~home ~broker_root ~workdir ->
    with_managed_kimi_mcp_session ~home ~broker_root ~workdir (fun broker ->
      seed_live_third_party broker ~alias:"peer-live";
      let text, is_error =
        run_tool ~broker ~tool_name:"send"
          ~arguments:
            (`Assoc
               [ ("to_alias", `String "peer-target")
               ; ("content", `String "hi")
               ; ("from_alias", `String "peer-live")
               ])
      in
      check bool "send not an error" false is_error;
      check bool "attributed to the managed anchor (self)" true
        (contains ~needle:"\"from_alias\":\"kimi-managed-anchor\"" text);
      check bool "NOT attributed to the requested third-party alias" false
        (contains ~needle:"peer-live" text)))

(* #40 ambiguity fail-closed: TWO live managed kimi rows share the cwd, so
   [self_managed_kimi_row] returns None (cannot tell which launcher is self).
   whoami reports unregistered and send fails closed with missing-sender. *)
let test_two_managed_rows_fail_closed () =
  with_ctx (fun ~home ~broker_root ~workdir ->
    Unix.chdir workdir;
    let cwd = Sys.getcwd () in
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    seed_managed_kimi_row broker ~cwd ~alias:"kimi-managed-anchor"
      ~session_id:"managed-kimi-instance-1";
    seed_managed_kimi_row broker ~cwd ~alias:"kimi-managed-other"
      ~session_id:"managed-kimi-instance-2";
    seed_offline_peer broker ~alias:"peer-target";
    set_env
      (base_env ~home ~alias:"kimi-install-sticky"
         ~session_id:"kimi-uuid-mcp-session");
    Unix.putenv "C2C_MCP_CLIENT_TYPE" "kimi";
    let whoami_text, whoami_err =
      run_tool ~broker ~tool_name:"whoami" ~arguments:(`Assoc [])
    in
    check bool "whoami not an error" false whoami_err;
    check string "whoami reports unregistered (empty)" "" whoami_text;
    let send_text, send_err =
      run_tool ~broker ~tool_name:"send"
        ~arguments:(`Assoc [ ("to_alias", `String "peer-target"); ("content", `String "hi") ])
    in
    check bool "send fails closed" true send_err;
    check bool "send reports missing sender alias" true
      (contains ~needle:"missing sender alias" send_text))

let () =
  run "c2c_mcp_kimi_adopt"
    [ ( "auto_register vs managed kimi row (#48)",
        [ test_case "adopts live managed row (no competing alias)" `Quick
            test_adopts_live_managed_row
        ; test_case "vanilla kimi still registers install alias" `Quick
            test_vanilla_still_registers_install_alias
        ] )
    ; ( "managed kimi MCP identity: whoami + send (#48)",
        [ test_case "whoami reports the launcher alias" `Quick
            test_whoami_reports_managed_alias
        ; test_case "send resolves to the managed alias" `Quick
            test_send_resolves_to_managed_alias
        ; test_case "send with explicit managed from_alias allowed" `Quick
            test_send_with_managed_from_alias_allowed
        ; test_case "non-kimi cannot impersonate the managed alias" `Quick
            test_non_kimi_cannot_impersonate_managed_alias
        ; test_case "from_alias arg cannot override self (alias-specific)" `Quick
            test_from_alias_arg_cannot_override_self
        ; test_case "two managed rows: fail closed (whoami + send)" `Quick
            test_two_managed_rows_fail_closed
        ] )
    ]
