(* B191: global per-session registration lock.
   One session id invoking c2c from two different git roots at the same time
   must not mint two aliases. The B188 sticky scan handles the sequential
   case; these tests cover the lock that makes the [scan -> mint -> register]
   sequence atomic across brokers, closing the concurrent race. *)

open Alcotest

let ( // ) = Filename.concat

let saved_home = try Sys.getenv "HOME" with Not_found -> "/tmp"
let saved_xdg = try Sys.getenv "XDG_STATE_HOME" with Not_found -> ""
let saved_c2c_state = try Sys.getenv "C2C_STATE_HOME" with Not_found -> ""
let saved_scan = try Sys.getenv "C2C_BROKER_SCAN_DIRS" with Not_found -> ""

let restore_env () =
  Unix.putenv "HOME" saved_home;
  Unix.putenv "XDG_STATE_HOME" saved_xdg;
  Unix.putenv "C2C_STATE_HOME" saved_c2c_state;
  Unix.putenv "C2C_BROKER_SCAN_DIRS" saved_scan

let with_restored_env f = Fun.protect ~finally:restore_env f

let temp_dir label =
  let base = Filename.get_temp_dir_name () in
  let dir =
    base // Printf.sprintf "c2c-b191-%s-%08x" label (Random.bits ())
  in
  C2c_mcp.mkdir_p dir;
  dir

let fresh_isolated_home label =
  let home = temp_dir label in
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" (temp_dir (label ^ "-xdg"));
  Unix.putenv "C2C_STATE_HOME" "";
  Unix.putenv "C2C_BROKER_SCAN_DIRS" "";
  home

let mk_broker_under home ~fp =
  let root = home // ".c2c" // "repos" // fp // "broker" in
  C2c_mcp.mkdir_p root;
  let broker = C2c_mcp.Broker.create ~root in
  (* Touch registry so list_all_broker_roots discovers the path. *)
  ignore (C2c_mcp.Broker.list_registrations broker);
  (root, broker)

(* Unit: lock path is deterministic per session id, distinct across ids,
   under $HOME/.c2c/locks. *)
let test_lock_path_stable () =
  with_restored_env (fun () ->
      let home = fresh_isolated_home "path" in
      let p1 =
        C2c_mcp.session_registration_lock_path ~session_id:"zq-sid-one"
      in
      let p1' =
        C2c_mcp.session_registration_lock_path ~session_id:"zq-sid-one"
      in
      let p2 =
        C2c_mcp.session_registration_lock_path ~session_id:"zq-sid-two"
      in
      check string "stable per sid" p1 p1';
      check bool "distinct across sids" true (p1 <> p2);
      let expected_dir = home // ".c2c" // "locks" in
      check string "under HOME/.c2c/locks" expected_dir (Filename.dirname p1))

(* Cross-process mutual exclusion: child holds the lock and writes a marker
   file just before releasing; the parent's acquisition must block until the
   marker exists. Synchronization: child signals lock-held over a pipe. *)
let test_mutual_exclusion_across_processes () =
  with_restored_env (fun () ->
      let home = fresh_isolated_home "mutex" in
      let sid = "zq-b191-mutex-sid" in
      let marker = home // "child-done.marker" in
      let r, w = Unix.pipe () in
      match Unix.fork () with
      | 0 ->
          (* child *)
          Unix.close r;
          let lock =
            C2c_mcp.acquire_session_registration_lock ~session_id:sid ()
          in
          if lock = None then Unix._exit 3;
          ignore (Unix.write w (Bytes.of_string "L") 0 1);
          Unix.close w;
          Unix.sleepf 0.4;
          let oc = open_out marker in
          close_out oc;
          C2c_mcp.release_session_registration_lock lock;
          Unix._exit 0
      | child_pid ->
          Unix.close w;
          let buf = Bytes.create 1 in
          let n = Unix.read r buf 0 1 in
          Unix.close r;
          check int "child signalled lock held" 1 n;
          (* This must block until the child released the lock. *)
          C2c_mcp.with_session_registration_lock ~session_id:sid (fun () ->
              check bool "parent entered only after child released" true
                (Sys.file_exists marker));
          let _, status = Unix.waitpid [] child_pid in
          check bool "child exited cleanly" true (status = Unix.WEXITED 0))

(* The B191 race regression: while a child process holds the lock and
   registers the session in broker X, a concurrent
   [locked_sticky_auto_register] against broker Y must block, then adopt the
   child's alias instead of minting a second one. Without the lock the
   parent's scan runs before the child's register and mints. *)
let test_concurrent_cross_repo_register_single_alias () =
  with_restored_env (fun () ->
      let home = fresh_isolated_home "race" in
      let sid = "zq-b191-race-sid" in
      let child_alias = "claude-zqchild-vheq-aa11" in
      let x_root, _x_b = mk_broker_under home ~fp:"b191aaaa1111" in
      let y_root, y_b = mk_broker_under home ~fp:"b191bbbb2222" in
      let r, w = Unix.pipe () in
      match Unix.fork () with
      | 0 ->
          (* child: register in broker X while holding the lock. *)
          Unix.close r;
          (try
             C2c_mcp.with_session_registration_lock ~session_id:sid (fun () ->
                 ignore (Unix.write w (Bytes.of_string "L") 0 1);
                 Unix.close w;
                 (* Keep the lock held long enough for the parent to reach
                    its own (blocking) acquisition. *)
                 Unix.sleepf 0.4;
                 let broker = C2c_mcp.Broker.create ~root:x_root in
                 C2c_mcp.Broker.register broker ~session_id:sid
                   ~alias:child_alias ~pid:(Some (Unix.getpid ()))
                   ~pid_start_time:None ~client_type:(Some "claude")
                   ~from_auto_gen:true ());
             Unix._exit 0
           with _ -> Unix._exit 3)
      | child_pid ->
          Unix.close w;
          let buf = Bytes.create 1 in
          let n = Unix.read r buf 0 1 in
          Unix.close r;
          check int "child signalled lock held" 1 n;
          let minted = ref false in
          let alias, _from_auto_gen, prior =
            C2c_mcp.locked_sticky_auto_register ~session_id:sid
              ~broker_root:y_root
              ~mint:(fun () ->
                minted := true;
                ("claude-zqparent-vheq-bb22", true))
              ~register:(fun ~alias ~from_auto_gen ->
                C2c_mcp.Broker.register y_b ~session_id:sid ~alias
                  ~pid:(Some (Unix.getpid ())) ~pid_start_time:None
                  ~client_type:(Some "claude") ~from_auto_gen ())
              ()
          in
          let _, status = Unix.waitpid [] child_pid in
          check bool "child exited cleanly" true (status = Unix.WEXITED 0);
          check string "parent adopted child's alias" child_alias alias;
          check bool "parent did not mint" false !minted;
          check bool "prior hit found" true (Option.is_some prior);
          (* Both brokers now hold the SAME alias for the session. *)
          let alias_in root =
            let b = C2c_mcp.Broker.create ~root in
            List.find_map
              (fun (r : C2c_mcp.registration) ->
                if r.session_id = sid then Some r.alias else None)
              (C2c_mcp.Broker.list_registrations b)
          in
          check (option string) "broker X alias" (Some child_alias)
            (alias_in x_root);
          check (option string) "broker Y alias" (Some child_alias)
            (alias_in y_root))

(* Same race through the MCP-server surface: auto_register_impl must adopt
   the alias a concurrent locked registrant committed in another broker,
   not the static env alias. *)
let test_auto_register_impl_concurrent_adopts () =
  with_restored_env (fun () ->
      let home = fresh_isolated_home "impl" in
      let sid = "zq-b191-impl-sid" in
      let child_alias = "claude-zqhold-vheq-cc33" in
      let env_alias = "claude-zqenv-vheq-dd44" in
      let x_root, _x_b = mk_broker_under home ~fp:"b191cccc3333" in
      let y_root, y_b = mk_broker_under home ~fp:"b191dddd4444" in
      let r, w = Unix.pipe () in
      match Unix.fork () with
      | 0 ->
          Unix.close r;
          (try
             C2c_mcp.with_session_registration_lock ~session_id:sid (fun () ->
                 ignore (Unix.write w (Bytes.of_string "L") 0 1);
                 Unix.close w;
                 Unix.sleepf 0.4;
                 let broker = C2c_mcp.Broker.create ~root:x_root in
                 C2c_mcp.Broker.register broker ~session_id:sid
                   ~alias:child_alias ~pid:(Some (Unix.getpid ()))
                   ~pid_start_time:None ~client_type:(Some "claude")
                   ~from_auto_gen:true ());
             Unix._exit 0
           with _ -> Unix._exit 3)
      | child_pid ->
          Unix.close w;
          let buf = Bytes.create 1 in
          let n = Unix.read r buf 0 1 in
          Unix.close r;
          check int "child signalled lock held" 1 n;
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" env_alias;
          Unix.putenv "C2C_MCP_SESSION_ID" sid;
          Unix.putenv "C2C_MCP_CLIENT_TYPE" "claude";
          Unix.putenv "C2C_MCP_CLIENT_PID" (string_of_int (Unix.getpid ()));
          Unix.putenv "C2C_NO_AUTO_REGISTER" "";
          Fun.protect
            ~finally:(fun () ->
              Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
              Unix.putenv "C2C_MCP_SESSION_ID" "";
              Unix.putenv "C2C_MCP_CLIENT_TYPE" "";
              Unix.putenv "C2C_MCP_CLIENT_PID" "")
            (fun () ->
              (* Blocks on the lock until the child commits, then must adopt
                 the child's alias over the env alias. *)
              C2c_mcp.auto_register_impl ~broker_root:y_root ();
              let _, status = Unix.waitpid [] child_pid in
              check bool "child exited cleanly" true
                (status = Unix.WEXITED 0);
              match
                List.find_opt
                  (fun (reg : C2c_mcp.registration) -> reg.session_id = sid)
                  (C2c_mcp.Broker.list_registrations y_b)
              with
              | None -> fail "expected registration on broker Y"
              | Some reg ->
                  check string "adopted concurrent sticky alias" child_alias
                    reg.alias))

let () =
  Random.self_init ();
  run "B191 per-session registration lock"
    [ ( "lock"
      , [ test_case "lock path stable per sid" `Quick test_lock_path_stable
        ; test_case "mutual exclusion across processes" `Quick
            test_mutual_exclusion_across_processes
        ] )
    ; ( "race"
      , [ test_case "concurrent cross-repo register converges on one alias"
            `Quick test_concurrent_cross_repo_register_single_alias
        ; test_case "auto_register_impl adopts concurrent registrant" `Quick
            test_auto_register_impl_concurrent_adopts
        ] )
    ]
