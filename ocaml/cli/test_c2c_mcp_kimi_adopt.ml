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

(* (a) A live managed kimi row owning cwd suppresses the MCP mint/rebind. *)
let test_adopts_live_managed_row () =
  with_ctx (fun ~home ~broker_root ~workdir ->
    Unix.chdir workdir;
    let cwd = Sys.getcwd () in
    (* Seed the AUTHORITATIVE launcher row: managed (registered_by=None),
       kimi, owning cwd, live (self pid + matching start time). *)
    let self = Unix.getpid () in
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    C2c_mcp.Broker.register broker
      ~session_id:"managed-kimi-instance"
      ~alias:"kimi-managed-anchor"
      ~pid:(Some self)
      ~pid_start_time:(C2c_mcp.Broker.capture_pid_start_time (Some self))
      ~client_type:(Some "kimi")
      ~cwd:(Some cwd)
      ~registered_by:None
      ~from_auto_gen:true  (* managed kimi aliases come from the auto-gen pool *)
      ();
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

let () =
  run "c2c_mcp_kimi_adopt"
    [ ( "auto_register vs managed kimi row (#48)",
        [ test_case "adopts live managed row (no competing alias)" `Quick
            test_adopts_live_managed_row
        ; test_case "vanilla kimi still registers install alias" `Quick
            test_vanilla_still_registers_install_alias
        ] )
    ]
