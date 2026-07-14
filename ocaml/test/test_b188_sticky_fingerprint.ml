(* B188: sticky alias across broker-fingerprint changes.
   When remote.origin.url appears (or a path-fingerprint broker switches to a
   remote-URL fingerprint), auto-register must reuse the prior session_id's
   alias instead of minting a second identity. *)

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
    base // Printf.sprintf "c2c-b188-%s-%08x" label (Random.bits ())
  in
  C2c_mcp.mkdir_p dir;
  dir

let mk_broker_under home ~fp =
  let root = home // ".c2c" // "repos" // fp // "broker" in
  C2c_mcp.mkdir_p root;
  let broker = C2c_mcp.Broker.create ~root in
  (* Touch registry so list_all_broker_roots discovers the path. *)
  ignore (C2c_mcp.Broker.list_registrations broker);
  (root, broker)

let write_key root ~alias content =
  let keys = root // "keys" in
  C2c_mcp.mkdir_p ~mode:0o700 keys;
  let path = keys // (alias ^ ".ed25519") in
  let oc = open_out_gen [ Open_wronly; Open_creat; Open_trunc ] 0o600 path in
  output_string oc content;
  close_out oc;
  path

let read_file path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let s = really_input_string ic len in
  close_in ic;
  s

(* Unit: lookup finds session on another fingerprint and prefers newest alive. *)
let test_find_prior_session_across_brokers () =
  with_restored_env (fun () ->
      let home = temp_dir "home" in
      Unix.putenv "HOME" home;
      Unix.putenv "XDG_STATE_HOME" (temp_dir "xdg-empty");
      Unix.putenv "C2C_STATE_HOME" "";
      Unix.putenv "C2C_BROKER_SCAN_DIRS" "";
      let sid = "fa3c5d7d-b987-41e6-ad0f-6b7bf9ffdb43" in
      let old_root, old_b = mk_broker_under home ~fp:"4cd37eaee8ca" in
      let _new_root, _new_b = mk_broker_under home ~fp:"f61c9ead06dc" in
      C2c_mcp.Broker.register old_b ~session_id:sid
        ~alias:"claude-wagon-chapel-l9nq" ~pid:(Some 77206)
        ~pid_start_time:None ~client_type:(Some "claude") ~from_auto_gen:true
        ();
      match
        C2c_mcp.find_prior_session_across_brokers ~session_id:sid
          ~exclude_root:_new_root ()
      with
      | None -> fail "expected prior session hit on path-fingerprint broker"
      | Some hit ->
          check string "alias" "claude-wagon-chapel-l9nq" hit.registration.alias;
          check string "fp" "4cd37eaee8ca" hit.fingerprint;
          check string "root" old_root hit.broker_root;
          check (option int) "pid" (Some 77206) hit.registration.pid)

(* Unit: exclude_root hides the target broker so we do not "find ourselves". *)
let test_exclude_root_skips_self () =
  with_restored_env (fun () ->
      let home = temp_dir "home-ex" in
      Unix.putenv "HOME" home;
      Unix.putenv "XDG_STATE_HOME" (temp_dir "xdg-empty2");
      Unix.putenv "C2C_STATE_HOME" "";
      Unix.putenv "C2C_BROKER_SCAN_DIRS" "";
      let sid = "sid-exclude-self" in
      let root, b = mk_broker_under home ~fp:"aabbccddeeff" in
      C2c_mcp.Broker.register b ~session_id:sid ~alias:"claude-self-only"
        ~pid:None ~pid_start_time:None ~from_auto_gen:true ();
      check (option string) "no prior when only self"
        None
        (match
           C2c_mcp.find_prior_session_across_brokers ~session_id:sid
             ~exclude_root:root ()
         with
         | None -> None
         | Some h -> Some h.registration.alias))

(* Unit: resolve_auto_register_alias reuses sticky instead of mint. *)
let test_resolve_reuses_sticky () =
  with_restored_env (fun () ->
      let home = temp_dir "home-res" in
      Unix.putenv "HOME" home;
      Unix.putenv "XDG_STATE_HOME" (temp_dir "xdg-empty3");
      Unix.putenv "C2C_STATE_HOME" "";
      Unix.putenv "C2C_BROKER_SCAN_DIRS" "";
      let sid = "sid-resolve-reuse" in
      let _old_root, old_b = mk_broker_under home ~fp:"111122223333" in
      let new_root, _new_b = mk_broker_under home ~fp:"444455556666" in
      C2c_mcp.Broker.register old_b ~session_id:sid
        ~alias:"claude-sticky-prior-zz01" ~pid:(Some 99) ~pid_start_time:None
        ~from_auto_gen:true ();
      let minted = ref false in
      let alias, _from_auto, prior =
        C2c_mcp.resolve_auto_register_alias ~session_id:sid
          ~broker_root:new_root
          ~mint:(fun () ->
            minted := true;
            ("claude-should-not-mint-xx99", true))
          ()
      in
      check string "reused alias" "claude-sticky-prior-zz01" alias;
      check bool "did not mint" false !minted;
      check bool "prior hit present" true (Option.is_some prior))

(* Unit: migrate copies missing ed25519 keys, never overwrites. *)
let test_migrate_keys_copy_no_overwrite () =
  with_restored_env (fun () ->
      let home = temp_dir "home-keys" in
      let from_root = home // "from-broker" in
      let to_root = home // "to-broker" in
      C2c_mcp.mkdir_p from_root;
      C2c_mcp.mkdir_p to_root;
      let alias = "claude-key-migrate-aa11" in
      ignore (write_key from_root ~alias "SECRET-FROM");
      let n =
        C2c_mcp.migrate_alias_ed25519_keys ~from_root ~to_root ~alias
      in
      check int "copied once" 1 n;
      check string "content"
        "SECRET-FROM"
        (read_file (to_root // "keys" // (alias ^ ".ed25519")));
      (* Overwrite destination then ensure migrate leaves it alone. *)
      ignore (write_key to_root ~alias "SECRET-DST");
      let n2 =
        C2c_mcp.migrate_alias_ed25519_keys ~from_root ~to_root ~alias
      in
      check int "no overwrite" 0 n2;
      check string "dst preserved" "SECRET-DST"
        (read_file (to_root // "keys" // (alias ^ ".ed25519"))))

(* Unit: when target alias is occupied by a live different session, mint. *)
let test_occupied_alias_falls_back_to_mint () =
  with_restored_env (fun () ->
      let home = temp_dir "home-occ" in
      Unix.putenv "HOME" home;
      Unix.putenv "XDG_STATE_HOME" (temp_dir "xdg-empty4");
      Unix.putenv "C2C_STATE_HOME" "";
      Unix.putenv "C2C_BROKER_SCAN_DIRS" "";
      let sid = "sid-occupier-victim" in
      let _old_root, old_b = mk_broker_under home ~fp:"aaaa11112222" in
      let new_root, new_b = mk_broker_under home ~fp:"bbbb33334444" in
      C2c_mcp.Broker.register old_b ~session_id:sid
        ~alias:"claude-contested-name" ~pid:(Some 1) ~pid_start_time:None
        ~from_auto_gen:true ();
      (* Live holder of the same alias under a different session on the new broker. *)
      C2c_mcp.Broker.register new_b ~session_id:"other-session"
        ~alias:"claude-contested-name" ~pid:(Some (Unix.getpid ()))
        ~pid_start_time:None ~from_auto_gen:true ();
      let minted = ref false in
      let alias, _, prior =
        C2c_mcp.resolve_auto_register_alias ~session_id:sid
          ~broker_root:new_root
          ~mint:(fun () ->
            minted := true;
            ("claude-fresh-mint-bb22", true))
          ()
      in
      check bool "minted because occupied" true !minted;
      check string "fresh alias" "claude-fresh-mint-bb22" alias;
      check bool "no prior adopted" true (Option.is_none prior))

(* Integration-ish: auto_register_impl adopts cross-broker sticky over env. *)
let test_auto_register_impl_adopts_cross_broker () =
  with_restored_env (fun () ->
      let home = temp_dir "home-impl" in
      Unix.putenv "HOME" home;
      Unix.putenv "XDG_STATE_HOME" (temp_dir "xdg-empty5");
      Unix.putenv "C2C_STATE_HOME" "";
      Unix.putenv "C2C_BROKER_SCAN_DIRS" "";
      Unix.putenv "C2C_NO_AUTO_REGISTER" "";
      let sid = "sid-mcp-autoreg-cross" in
      let sticky = "claude-prior-sticky-cc33" in
      let env_alias = "claude-env-install-dd44" in
      let _old_root, old_b = mk_broker_under home ~fp:"cccc55556666" in
      let new_root, new_b = mk_broker_under home ~fp:"dddd77778888" in
      C2c_mcp.Broker.register old_b ~session_id:sid ~alias:sticky
        ~pid:(Some 42) ~pid_start_time:None ~client_type:(Some "claude")
        ~from_auto_gen:true ();
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" env_alias;
      Unix.putenv "C2C_MCP_SESSION_ID" sid;
      Unix.putenv "C2C_MCP_CLIENT_TYPE" "claude";
      Unix.putenv "C2C_MCP_CLIENT_PID" (string_of_int (Unix.getpid ()));
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_CLIENT_TYPE" "";
          Unix.putenv "C2C_MCP_CLIENT_PID" "")
        (fun () ->
          C2c_mcp.auto_register_impl ~broker_root:new_root ();
          let regs = C2c_mcp.Broker.list_registrations new_b in
          match
            List.find_opt
              (fun (r : C2c_mcp.registration) -> r.session_id = sid)
              regs
          with
          | None -> fail "expected registration on new broker"
          | Some reg ->
              check string "adopted sticky not env alias" sticky reg.alias))

let () =
  Random.self_init ();
  run "B188 sticky alias across fingerprint"
    [ ( "lookup"
      , [ test_case "find prior session across brokers" `Quick
            test_find_prior_session_across_brokers
        ; test_case "exclude_root skips self" `Quick test_exclude_root_skips_self
        ; test_case "resolve reuses sticky" `Quick test_resolve_reuses_sticky
        ; test_case "migrate keys copy no overwrite" `Quick
            test_migrate_keys_copy_no_overwrite
        ; test_case "occupied alias falls back to mint" `Quick
            test_occupied_alias_falls_back_to_mint
        ; test_case "auto_register_impl adopts cross-broker sticky" `Quick
            test_auto_register_impl_adopts_cross_broker
        ] )
    ]
