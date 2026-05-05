(* Integration tests for S5 role heartbeat persistence.
   Tests that resolve_managed_heartbeats_and_persist_role correctly:
   - Splits role heartbeats from config/per-agent heartbeats
   - Writes correct TOML to .c2c/schedules/<alias>/
   - Produces round-trip-safe TOML (parse_schedule inverts render_schedule_entry)

   Run: cd ocaml && opam exec -- dune test test_c2c_schedule_persist *)

open Alcotest

(* ---------------------------------------------------------------------------
 * Helpers
 * --------------------------------------------------------------------------- *)

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base (Printf.sprintf "c2c-sched-persist-%08x" (Random.bits ()))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    Unix.mkdir dir 0o755);
  Fun.protect
    ~finally:(fun () -> Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

(* ---------------------------------------------------------------------------
 * Test 1: schedule_entry round-trip
   managed_heartbeat -> schedule_entry -> TOML -> parse_schedule -> schedule_entry
   The parsed schedule_entry should equal the original (modulo timestamps).
 * --------------------------------------------------------------------------- *)

let test_schedule_entry_roundtrip_interval () =
  let open C2c_mcp in
  let hb =
    { C2c_start.heartbeat_name = "wake"
    ; schedule = C2c_start.Interval 300.0
    ; interval_s = 300.0
    ; message = "wake — poll inbox"
    ; command = None
    ; command_timeout_s = 30.0
    ; clients = []
    ; role_classes = []
    ; enabled = true
    ; idle_only = true
    ; idle_threshold_s = 300.0
    }
  in
  let entry = C2c_start.schedule_entry_of_managed_heartbeat hb in
  check string "name preserved" "wake" entry.s_name;
  check bool "enabled preserved" true entry.s_enabled;
  check bool "idle_only preserved" true entry.s_only_when_idle;
  check string "align empty for Interval" "" entry.s_align;
  check string "message preserved" "wake — poll inbox" entry.s_message;
  check bool "interval_s preserved"
    (abs_float (300.0 -. entry.s_interval_s) < 1e-6) true;
  check bool "idle_threshold_s preserved"
    (abs_float (300.0 -. entry.s_idle_threshold_s) < 1e-6) true

let test_schedule_entry_roundtrip_aligned () =
  let open C2c_mcp in
  let hb =
    { C2c_start.heartbeat_name = "sitrep"
    ; schedule = C2c_start.Aligned_interval { interval_s = 3600.0; offset_s = 420.0 }
    ; interval_s = 3600.0
    ; message = "sitrep tick"
    ; command = None
    ; command_timeout_s = 30.0
    ; clients = []
    ; role_classes = []
    ; enabled = true
    ; idle_only = false
    ; idle_threshold_s = 3600.0
    }
  in
  let entry = C2c_start.schedule_entry_of_managed_heartbeat hb in
  check string "name preserved" "sitrep" entry.s_name;
  check string "align serialized as @interval+offset"
    "@3600s+420s" entry.s_align;
  check bool "idle_only preserved" false entry.s_only_when_idle

(* ---------------------------------------------------------------------------
 * Test 2: TOML render + parse round-trip
   render_schedule_entry -> parse_schedule should give back the same entry
   (modulo created_at — we don't preserve it through the TOML round-trip).
 * --------------------------------------------------------------------------- *)

let test_render_and_parse_roundtrip () =
  let open C2c_mcp in
  let original : schedule_entry =
    { s_name = "wake"
    ; s_interval_s = 246.0
    ; s_align = ""
    ; s_message = "wake — poll inbox, advance work"
    ; s_only_when_idle = true
    ; s_idle_threshold_s = 246.0
    ; s_enabled = true
    ; s_created_at = "2026-05-05T00:00:00Z"
    ; s_updated_at = "2026-05-05T00:00:00Z"
    }
  in
  let toml_str = C2c_start.render_schedule_entry original in
  let parsed = C2c_mcp.parse_schedule toml_str in
  check string "name round-trips" original.s_name parsed.s_name;
  check string "message round-trips" original.s_message parsed.s_message;
  check bool "only_when_idle round-trips"
    original.s_only_when_idle parsed.s_only_when_idle;
  check bool "enabled round-trips" original.s_enabled parsed.s_enabled;
  check string "align round-trips" original.s_align parsed.s_align;
  (* interval_s may lose trailing zeros from float formatting; check within epsilon *)
  check bool "interval_s round-trips (within 1e-6)"
    (abs_float (original.s_interval_s -. parsed.s_interval_s) < 1e-6)
    true

(* ---------------------------------------------------------------------------
 * Test 3: persist_role_heartbeats_to_schedule_dir writes files
   Create a role with heartbeat entries, call persist, verify .toml files exist.
 * --------------------------------------------------------------------------- *)

let test_persist_writes_toml_files () =
  with_temp_dir (fun dir ->
    Unix.putenv "C2C_SCHEDULE_ROOT_OVERRIDE" dir;
    Fun.protect ~finally:(fun () -> Unix.putenv "C2C_SCHEDULE_ROOT_OVERRIDE" "") (fun () ->
      let role =
        C2c_role.parse_string
          "---\n\
           description: Test role\n\
           role: primary\n\
           c2c:\n\
           \  heartbeat:\n\
           \    message: \"Role default tick\"\n\
           \    interval: 5m\n\
           \  heartbeats:\n\
           \    sitrep:\n\
           \      interval: 1h\n\
           \      message: \"Write sitrep\"\n\
           ---\n\
           body\n"
      in
      (* Build the managed_heartbeat list as resolve_managed_heartbeats would *)
      let builtin = C2c_start.builtin_managed_heartbeat in
      let role_default =
        { builtin with
          C2c_start.heartbeat_name = "default";
          C2c_start.schedule = C2c_start.Interval 300.0;
          C2c_start.interval_s = 300.0;
          C2c_start.message = "Role default tick";
          C2c_start.enabled = true;
        }
      in
      let role_sitrep =
        { builtin with
          C2c_start.heartbeat_name = "sitrep";
          C2c_start.schedule = C2c_start.Interval 3600.0;
          C2c_start.interval_s = 3600.0;
          C2c_start.message = "Write sitrep";
          C2c_start.enabled = true;
        }
      in
      let role_hbs = [ role_default; role_sitrep ] in
      C2c_start.persist_role_heartbeats_to_schedule_dir
        ~alias:"test-agent" role_hbs;
      (* Verify files exist *)
      let base_dir = C2c_mcp.schedule_base_dir "test-agent" in
      let expected_default = Filename.concat base_dir "default.toml" in
      let expected_sitrep = Filename.concat base_dir "sitrep.toml" in
      check bool "default.toml exists"
        true (Sys.file_exists expected_default);
      check bool "sitrep.toml exists"
        true (Sys.file_exists expected_sitrep);
      (* Verify content parses correctly *)
      let default_content = C2c_io.read_file_opt expected_default in
      check bool "default.toml non-empty"
        true (default_content <> "");
      let parsed_default = C2c_mcp.parse_schedule default_content in
      check string "default name in file" "default" parsed_default.s_name;
      check string "default message in file" "Role default tick" parsed_default.s_message;
      let sitrep_content = C2c_io.read_file_opt expected_sitrep in
      let parsed_sitrep = C2c_mcp.parse_schedule sitrep_content in
      check string "sitrep name in file" "sitrep" parsed_sitrep.s_name;
      check string "sitrep message in file" "Write sitrep" parsed_sitrep.s_message
    )
  )

(* ---------------------------------------------------------------------------
 * Test 4: resolve_managed_heartbeats_and_persist_role splits correctly
   Role heartbeats -> second list (to persist); config/per-agent -> first list.
 * --------------------------------------------------------------------------- *)

let test_resolve_splits_role_vs_config () =
  let open C2c_mcp in
  with_temp_dir (fun dir ->
    Unix.putenv "C2C_SCHEDULE_ROOT_OVERRIDE" dir;
    Fun.protect ~finally:(fun () -> Unix.putenv "C2C_SCHEDULE_ROOT_OVERRIDE" "") (fun () ->
      let role =
        C2c_role.parse_string
          "---\n\
           description: Coordinator role\n\
           role: primary\n\
           role_class: coordinator\n\
           c2c:\n\
           \  heartbeat:\n\
           \    message: \"Coordinator tick\"\n\
           \    interval: 4m\n\
           \  heartbeats:\n\
           \    sitrep:\n\
           \      interval: 1h\n\
           \      message: \"Write sitrep\"\n\
           ---\n\
           body\n"
      in
      (* Builtin + config heartbeat *)
      let config_specs =
        [ { C2c_start.builtin_managed_heartbeat with
            C2c_start.heartbeat_name = "builtin-wake";
            C2c_start.schedule = C2c_start.Interval 246.0;
            C2c_start.interval_s = 246.0;
            C2c_start.message = "builtin tick";
            C2c_start.enabled = true;
          }
        ]
      in
      (* No per-agent specs *)
      let per_agent_specs = [] in
      let non_role, role_specs =
        C2c_start.resolve_managed_heartbeats_and_persist_role
          ~client:"claude"
          ~deliver_started:false
          ~role:(Some role)
          ~per_agent_specs
          config_specs
      in
      (* Config/builtin heartbeat should be in non_role list *)
      check bool "builtin-wake in non_role list"
        true
        (List.exists (fun hb -> hb.C2c_start.heartbeat_name = "builtin-wake") non_role);
      (* Role-defined heartbeats (default + sitrep) should be in role_specs list *)
      check bool "role default (from c2c.heartbeat) in role_specs"
        true
        (List.exists (fun hb -> hb.C2c_start.heartbeat_name = "default") role_specs);
      check bool "role sitrep (from c2c.heartbeats.sitrep) in role_specs"
        true
        (List.exists (fun hb -> hb.C2c_start.heartbeat_name = "sitrep") role_specs);
      (* role_specs should NOT contain the builtin *)
      check bool "builtin NOT in role_specs"
        false
        (List.exists (fun hb -> hb.C2c_start.heartbeat_name = "builtin-wake") role_specs);
      (* non_role should NOT contain role heartbeats *)
      check bool "role default NOT in non_role"
        false
        (List.exists (fun hb -> hb.C2c_start.heartbeat_name = "default") non_role);
      (* Persist role heartbeats and verify files written *)
      C2c_start.persist_role_heartbeats_to_schedule_dir
        ~alias:"coordinator-test" role_specs;
      let base_dir = C2c_mcp.schedule_base_dir "coordinator-test" in
      check bool "default.toml written from role"
        true (Sys.file_exists (Filename.concat base_dir "default.toml"));
      check bool "sitrep.toml written from role"
        true (Sys.file_exists (Filename.concat base_dir "sitrep.toml"))
    )
  )

(* ---------------------------------------------------------------------------
 * Test 5: role = None returns all heartbeats in non_role, empty role_specs
 * --------------------------------------------------------------------------- *)

let test_no_role_returns_empty_role_specs () =
  let open C2c_mcp in
  with_temp_dir (fun dir ->
    Unix.putenv "C2C_SCHEDULE_ROOT_OVERRIDE" dir;
    Fun.protect ~finally:(fun () -> Unix.putenv "C2C_SCHEDULE_ROOT_OVERRIDE" "") (fun () ->
      let config_specs =
        [ { C2c_start.builtin_managed_heartbeat with
            C2c_start.heartbeat_name = "config-wake";
            C2c_start.schedule = C2c_start.Interval 300.0;
            C2c_start.interval_s = 300.0;
            C2c_start.message = "config tick";
            C2c_start.enabled = true;
          }
        ]
      in
      let per_agent_specs = [] in
      let non_role, role_specs =
        C2c_start.resolve_managed_heartbeats_and_persist_role
          ~client:"claude"
          ~deliver_started:false
          ~role:None
          ~per_agent_specs
          config_specs
      in
      check bool "config heartbeat in non_role when no role"
        true
        (List.exists (fun hb -> hb.C2c_start.heartbeat_name = "config-wake") non_role);
      check int "role_specs empty when no role"
        0 (List.length role_specs)
    )
  )

(* ---------------------------------------------------------------------------
 * Test 6: Align format round-trips through parse_heartbeat_schedule
   The @interval+offset format must parse back to Aligned_interval correctly.
 * --------------------------------------------------------------------------- *)

let test_aligned_interval_parse_roundtrip () =
  let open C2c_start in
  (* Serialize a 1h+7m aligned schedule *)
  let align_str = "@3600s+420s" in
  let parsed = parse_heartbeat_schedule align_str in
  (match parsed with
   | Ok (Aligned_interval { interval_s; offset_s }) ->
       check bool "interval_s parsed correctly" true (interval_s = 3600.0);
       check bool "offset_s parsed correctly" true (offset_s = 420.0)
   | Ok (Interval _) ->
       Alcotest.fail "Expected Aligned_interval but got Interval"
   | Error msg ->
       Alcotest.fail (Printf.sprintf "parse_heartbeat_schedule failed: %s" msg));

  (* Also test @interval+0s (zero offset — serialize always uses +0s for
     zero-offset Aligned_interval so this is the canonical round-trip form) *)
  let align_str2 = "@1800s+0s" in
  match parse_heartbeat_schedule align_str2 with
  | Ok (Aligned_interval { interval_s; offset_s }) ->
      check bool "interval_s without offset" true (interval_s = 1800.0);
      check bool "offset_s defaults to 0" true (offset_s = 0.0)
  | Ok (Interval _) ->
      Alcotest.fail "Expected Aligned_interval but got Interval"
  | Error msg ->
      Alcotest.fail (Printf.sprintf "parse_heartbeat_schedule failed: %s" msg)

(* ---------------------------------------------------------------------------
 * Test 7: idle_only=false survives the round-trip
 * --------------------------------------------------------------------------- *)

let test_idle_only_false_roundtrips () =
  let open C2c_mcp in
  let hb =
    { C2c_start.heartbeat_name = "busy-tick"
    ; schedule = C2c_start.Interval 120.0
    ; interval_s = 120.0
    ; message = "Check build"
    ; command = None
    ; command_timeout_s = 30.0
    ; clients = []
    ; role_classes = []
    ; enabled = true
    ; idle_only = false
    ; idle_threshold_s = 120.0
    }
  in
  let entry = C2c_start.schedule_entry_of_managed_heartbeat hb in
  let toml_str = C2c_start.render_schedule_entry entry in
  let parsed = C2c_mcp.parse_schedule toml_str in
  check bool "only_when_idle=false round-trips" false parsed.s_only_when_idle

(* ---------------------------------------------------------------------------
 * Test 8: messages with special characters survive TOML escape/unescape
 * --------------------------------------------------------------------------- *)

let test_message_special_chars () =
  let open C2c_mcp in
  let msg = "wake — poll inbox, advance work (don't forget!)" in
  let hb =
    { C2c_start.heartbeat_name = "wake"
    ; schedule = C2c_start.Interval 300.0
    ; interval_s = 300.0
    ; message = msg
    ; command = None
    ; command_timeout_s = 30.0
    ; clients = []
    ; role_classes = []
    ; enabled = true
    ; idle_only = true
    ; idle_threshold_s = 300.0
    }
  in
  let entry = C2c_start.schedule_entry_of_managed_heartbeat hb in
  let toml_str = C2c_start.render_schedule_entry entry in
  let parsed = C2c_mcp.parse_schedule toml_str in
  check string "message with quotes and parens" msg parsed.s_message

(* ---------------------------------------------------------------------------
 * Run all tests
 * --------------------------------------------------------------------------- *)

let () =
  run "C2c_schedule_persist"
    [ ( "schedule_entry_roundtrip"
      , [ test_case "Interval" `Quick test_schedule_entry_roundtrip_interval
        ; test_case "Aligned_interval" `Quick test_schedule_entry_roundtrip_aligned
        ] )
    ; ( "render_parse_roundtrip"
      , [ test_case "full roundtrip" `Quick test_render_and_parse_roundtrip
        ] )
    ; ( "persist_writes_files"
      , [ test_case "writes default.toml and sitrep.toml" `Quick
            test_persist_writes_toml_files
        ] )
    ; ( "resolve_splits"
      , [ test_case "role vs config split" `Quick
            test_resolve_splits_role_vs_config
        ; test_case "no role => empty role_specs" `Quick
            test_no_role_returns_empty_role_specs
        ] )
    ; ( "aligned_interval"
      , [ test_case "align format parse roundtrip" `Quick
            test_aligned_interval_parse_roundtrip
        ] )
    ; ( "idle_only_false"
      , [ test_case "idle_only=false survives roundtrip" `Quick
            test_idle_only_false_roundtrips
        ] )
    ; ( "message_special_chars"
      , [ test_case "special chars in message" `Quick
            test_message_special_chars
        ] )
    ]
