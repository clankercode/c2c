(* Focused tests for the Codex MCP identity resolver.  These stay separate from
   the lifecycle/session suite so the ownership parser and filesystem race
   contract can be reviewed and run in isolation. *)

module PB = C2c_mcp_helpers_post_broker
open Alcotest

let with_tmp_dir f =
  let path = Filename.temp_file "c2c-mcp-identity" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote path))))
    (fun () -> f path)

let write path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let write_json path json = write path (Yojson.Safe.to_string json ^ "\n")

let mapping_json ~session_id ~alias ~thread_id =
  `Assoc
    ([ ("session_id", `String session_id)
     ; ("alias", `String alias)
     ; ("created_at", `Float 1.)
     ; ("updated_at", `Float 2.) ]
     @ match thread_id with
       | None -> [ ("thread_id", `Null) ]
       | Some thread -> [ ("thread_id", `String thread) ])

let config_json ~name ~session_id ~alias ~thread_id ~broker_root =
  `Assoc
    [ ("name", `String name)
    ; ("client", `String "codex")
    ; ("session_id", `String session_id)
    ; ("resume_session_id", `String session_id)
    ; ("codex_resume_target", `String thread_id)
    ; ("alias", `String alias)
    ; ("broker_root", `String broker_root)
    ; ("extra_args", `List [])
    ; ("created_at", `Float 1.)
    ]

let with_resolver_env f =
  with_tmp_dir (fun root ->
      let instances = Filename.concat root "instances" in
      let broker = Filename.concat root "broker" in
      C2c_io.mkdir_p instances;
      C2c_io.mkdir_p broker;
      let previous = Sys.getenv_opt "C2C_INSTANCES_DIR" in
      Unix.putenv "C2C_INSTANCES_DIR" instances;
      Fun.protect
        ~finally:(fun () ->
          PB.set_codex_identity_test_hook (fun _ -> ());
          match previous with
          | Some value -> Unix.putenv "C2C_INSTANCES_DIR" value
          | None -> Unix.putenv "C2C_INSTANCES_DIR" "")
        (fun () -> f ~root ~instances ~broker))

let make_instance ~instances ~name ~session_id ~alias ~thread_id =
  let dir = Filename.concat instances name in
  C2c_io.mkdir_p dir;
  write_json (Filename.concat dir "codex-session.json")
    (mapping_json ~session_id ~alias ~thread_id);
  dir

let add_config ~dir ~name ~session_id ~alias ~thread_id ~broker_root =
  write_json (Filename.concat dir "config.json")
    (config_json ~name ~session_id ~alias ~thread_id ~broker_root)

let expect_resolution label expected actual =
  Alcotest.(check string) label expected
    (match actual with
     | PB.Codex_thread_resolved sid -> "resolved:" ^ sid
     | PB.Codex_thread_unmapped -> "unmapped"
     | PB.Codex_thread_uncertain -> "uncertain")

let test_mapping_alias_is_bound_to_instance_name () =
  with_resolver_env (fun ~root:_ ~instances ~broker ->
      ignore (make_instance ~instances ~name:"unit-a" ~session_id:"sid-a"
                ~alias:"unit-b" ~thread_id:(Some "thread-a"));
      expect_resolution "alias mismatch is uncertain"
        "uncertain"
        (PB.managed_session_id_from_codex_thread_resolution
           ~broker_root:broker ~thread_id:"thread-a"))

let test_mapping_only_legacy_fixture_still_resolves () =
  with_resolver_env (fun ~root:_ ~instances ~broker ->
      ignore (make_instance ~instances ~name:"unit-a" ~session_id:"sid-a"
                ~alias:"unit-a" ~thread_id:(Some "thread-a"));
      expect_resolution "missing config accepts legacy mapping"
        "resolved:sid-a"
        (PB.managed_session_id_from_codex_thread_resolution
           ~broker_root:broker ~thread_id:"thread-a"))

let test_config_owner_tuple_is_strict () =
  let cases =
    [ ("session mismatch", "other-session", "unit-a", "unit-a", None)
    ; ("name mismatch", "sid-a", "other-unit", "unit-a", None)
    ; ("alias mismatch", "sid-a", "unit-a", "other-alias", None)
    ; ("broker mismatch", "sid-a", "unit-a", "unit-a", Some "/other/broker")
    ]
  in
  List.iter (fun (label, session_id, name, alias, broker_override) ->
      with_resolver_env (fun ~root:_ ~instances ~broker ->
          let dir = make_instance ~instances ~name:"unit-a" ~session_id:"sid-a"
                      ~alias:"unit-a" ~thread_id:(Some "thread-a") in
          add_config ~dir ~name ~session_id ~alias ~thread_id:"thread-a"
            ~broker_root:(Option.value broker_override ~default:broker);
          expect_resolution label "unmapped"
            (PB.managed_session_id_from_codex_thread_resolution
               ~broker_root:broker ~thread_id:"thread-a")))
    cases

let test_malformed_config_fields_fail_closed () =
  with_resolver_env (fun ~root:_ ~instances ~broker ->
      let dir = make_instance ~instances ~name:"unit-a" ~session_id:"sid-a"
                  ~alias:"unit-a" ~thread_id:(Some "thread-a") in
      (* A malformed broker_root must not be treated like an omitted field. *)
      write (Filename.concat dir "config.json")
        {|{"name":"unit-a","client":"codex","session_id":"sid-a","resume_session_id":"sid-a","codex_resume_target":"thread-a","alias":"unit-a","broker_root":42}|};
      expect_resolution "malformed broker_root is uncertain" "uncertain"
        (PB.managed_session_id_from_codex_thread_resolution
           ~broker_root:broker ~thread_id:"thread-a");
      write (Filename.concat dir "config.json")
        {|{"name":"unit-a","client":"codex","session_id":"sid-a","resume_session_id":"sid-a","codex_resume_target":"thread-a","alias":"unit-a","broker_root":"/x","broker_root":"/y"}|};
      expect_resolution "duplicate ownership field is uncertain" "uncertain"
        (PB.managed_session_id_from_codex_thread_resolution
           ~broker_root:broker ~thread_id:"thread-a"))

let test_config_resume_owner_must_match_thread () =
  with_resolver_env (fun ~root:_ ~instances ~broker ->
      let dir = make_instance ~instances ~name:"unit-a" ~session_id:"sid-a"
                  ~alias:"unit-a" ~thread_id:(Some "thread-a") in
      (* With no codex_resume_target, a foreign resume_session_id cannot
         authorize the mapping. *)
      write_json (Filename.concat dir "config.json")
        (`Assoc [ ("name", `String "unit-a")
                ; ("client", `String "codex")
                ; ("session_id", `String "sid-a")
                ; ("resume_session_id", `String "foreign-thread")
                ; ("alias", `String "unit-a")
                ; ("broker_root", `String broker) ]);
      expect_resolution "foreign resume id is rejected" "unmapped"
        (PB.managed_session_id_from_codex_thread_resolution
           ~broker_root:broker ~thread_id:"thread-a"))

let registry_entry ~session_id ~alias ?dnd () =
  let base =
    [ ("session_id", `String session_id); ("alias", `String alias) ]
  in
  `Assoc (match dnd with None -> base | Some value -> base @ [ ("dnd", `Bool value) ])

let test_registry_rejects_malformed_optional_and_duplicate_identity () =
  with_tmp_dir (fun broker ->
      write_json (Filename.concat broker "registry.json")
        (`List [registry_entry ~session_id:"sid-a" ~alias:"unit-a" ()
               |> fun (`Assoc fields) -> `Assoc (fields @ [("dnd", `String "yes")])]);
      Alcotest.(check bool) "malformed optional field" true
        (match PB.strict_registry ~broker_root:broker with Error () -> true | Ok _ -> false);
      write_json (Filename.concat broker "registry.json")
        (`List [ registry_entry ~session_id:"sid-a" ~alias:"unit-a" ()
               ; registry_entry ~session_id:"sid-a" ~alias:"unit-b" () ]);
      Alcotest.(check bool) "duplicate session identity" true
        (match PB.strict_registry ~broker_root:broker with Error () -> true | Ok _ -> false);
      write_json (Filename.concat broker "registry.json")
        (`List [ registry_entry ~session_id:"sid-a" ~alias:"unit-a" ()
               ; registry_entry ~session_id:"sid-b" ~alias:"UNIT-A" () ]);
      Alcotest.(check bool) "duplicate case-folded alias identity" true
        (match PB.strict_registry ~broker_root:broker with Error () -> true | Ok _ -> false))

let test_legitimate_non_codex_config_is_ignored () =
  with_resolver_env (fun ~root:_ ~instances ~broker ->
      let dir = make_instance ~instances ~name:"unit-a" ~session_id:"sid-a"
                  ~alias:"unit-a" ~thread_id:(Some "thread-a") in
      write_json (Filename.concat dir "config.json")
        (`Assoc [ ("client", `String "relay"); ("broker_root", `String broker) ]);
      expect_resolution "non-Codex config does not poison scan" "unmapped"
        (PB.managed_session_id_from_codex_thread_resolution
           ~broker_root:broker ~thread_id:"thread-a"))

let test_parent_replacement_is_detected () =
  with_resolver_env (fun ~root ~instances ~broker ->
      ignore (make_instance ~instances ~name:"unit-a" ~session_id:"sid-a"
                ~alias:"unit-a" ~thread_id:(Some "thread-a"));
      let old_instances = Filename.concat root "instances-old" in
      PB.set_codex_identity_test_hook (fun label ->
          if label = "after-snapshots" then begin
            Unix.rename instances old_instances;
            Unix.mkdir instances 0o700
          end);
      expect_resolution "parent replacement is uncertain" "uncertain"
        (PB.managed_session_id_from_codex_thread_resolution
           ~broker_root:broker ~thread_id:"thread-a");
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote instances)));
      Unix.rename old_instances instances)

let test_sibling_replacement_is_detected () =
  with_resolver_env (fun ~root:_ ~instances ~broker ->
      let dir = make_instance ~instances ~name:"unit-a" ~session_id:"sid-a"
                  ~alias:"unit-a" ~thread_id:(Some "thread-a") in
      let old_dir = Filename.concat instances "unit-a-old" in
      PB.set_codex_identity_test_hook (fun label ->
          if label = "before-sibling-read:unit-a" then begin
            Unix.rename dir old_dir;
            Unix.mkdir dir 0o700
          end);
      expect_resolution "sibling replacement is uncertain" "uncertain"
        (PB.managed_session_id_from_codex_thread_resolution
           ~broker_root:broker ~thread_id:"thread-a");
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
      Unix.rename old_dir dir)

let () =
  Alcotest.run "c2c_mcp_helpers_post_broker_identity"
    [ ("resolver",
       [ test_case "mapping alias matches instance" `Quick
           test_mapping_alias_is_bound_to_instance_name
       ; test_case "mapping-only legacy fixture" `Quick
           test_mapping_only_legacy_fixture_still_resolves
       ; test_case "strict config owner tuple" `Quick
           test_config_owner_tuple_is_strict
       ; test_case "malformed config fields" `Quick
           test_malformed_config_fields_fail_closed
       ; test_case "config resume owner matches thread" `Quick
           test_config_resume_owner_must_match_thread
       ; test_case "non-Codex config" `Quick
           test_legitimate_non_codex_config_is_ignored
       ; test_case "parent replacement" `Quick
           test_parent_replacement_is_detected
       ; test_case "sibling replacement" `Quick
           test_sibling_replacement_is_detected ])
    ; ("registry",
       [ test_case "strict optional fields and duplicate identities" `Quick
           test_registry_rejects_malformed_optional_and_duplicate_identity ]) ]
