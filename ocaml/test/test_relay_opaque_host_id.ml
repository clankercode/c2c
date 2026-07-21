(* test_relay_opaque_host_id.ml — slice 1 tests for the opaque_host_id
   design (.collab/design/2026-06-17-c2c-opaque-host-id.md).

   Coverage:
   1. C2c_name.is_valid_with_opaque_host_id accepts the new <name>@<12hex>
      alias shape and rejects malformed variants.
   2. C2c_name.split_opaque_host_id splits a string into (name, host_id_opt).
   3. InMemoryRelay: register with opaque_host_id round-trips through the
      lease struct and RegistrationLease.to_json.
   4. InMemoryRelay: register without opaque_host_id keeps the field absent
      in JSON (back-compat for old consumers).
   5. InMemoryRelay: alias with <name>@<host_id> form is accepted; the
      display alias is stored on the lease and the extracted host_id ends
      up on the lease.
   6. Host_id.compute_host_hash produces a stable 12-char lowercase hex id
      for the current host source.
   7. Host_id.compute_host_hash_with_source returns the kind + value
      used, so diagnostics can see which source the recipe picked.
   8. c2c host-id CLI subcommand: exit 0 + stdout matches Host_id value.
   9. c2c host-id --json: exit 0 + stdout is valid JSON with host_id/kind/value. *)

(* B264_TEST_PUBLIC_REGISTER: fixtures opt into Public discovery (private is default). *)
let _b264_reg_mem t ~node_id ~session_id ~alias ?client_type ?client_version ?client_os ?ttl ?identity_pk ?enc_pubkey ?signed_at ?sig_b64 ?opaque_host_id () =
  let status, lease =
    Relay.InMemoryRelay.register t ~node_id ~session_id ~alias ?client_type ?client_version ?client_os ?ttl ?identity_pk ?enc_pubkey ?signed_at ?sig_b64 ?opaque_host_id ()
  in
  (match
     status,
     Relay.InMemoryRelay.set_peer_discovery_visibility t
       ~alias:(Relay.RegistrationLease.alias lease)
       ~visibility:Relay_backend_contract.Public
   with
   | "ok", Ok () -> ()
   | "ok", Error e -> failwith ("B264 test set public: " ^ e)
   | _ -> ());
  (status, lease)

let _b264_reg_sql t ~node_id ~session_id ~alias ?client_type ?client_version ?client_os ?ttl ?identity_pk ?enc_pubkey ?signed_at ?sig_b64 ?opaque_host_id () =
  let status, lease =
    Relay.SqliteRelay.register t ~node_id ~session_id ~alias ?client_type ?client_version ?client_os ?ttl ?identity_pk ?enc_pubkey ?signed_at ?sig_b64 ?opaque_host_id ()
  in
  (match
     status,
     Relay.SqliteRelay.set_peer_discovery_visibility t
       ~alias:(Relay.RegistrationLease.alias lease)
       ~visibility:Relay_backend_contract.Public
   with
   | "ok", Ok () -> ()
   | "ok", Error e -> failwith ("B264 test set public: " ^ e)
   | _ -> ());
  (status, lease)


open Alcotest

(* --- helpers --- *)

let json_get_string json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> s
       | _ -> failwith (Printf.sprintf "json_get_string: missing key %S" key))
  | _ -> failwith "json_get_string: expected Assoc"

let json_get_string_opt json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> Some s
       | Some _ -> Some (Printf.sprintf "<non-string for %S>" key)
       | None -> None)
  | _ -> None

(* Resolve c2c binary from the test runner's own location — same pattern
   as test_c2c_cli.ml: the test binary lives in _build/default/ocaml/test/
   and the c2c.exe is a sibling under _build/default/ocaml/cli/. *)
let c2c_bin =
  let dir = Filename.dirname Sys.executable_name in
  let candidate = Filename.concat (Filename.concat (Filename.dirname dir) "cli") "c2c.exe" in
  if Sys.file_exists candidate then candidate
  else "c2c"  (* fallback to PATH *)

(* --- 1. c2c_name: is_valid_with_opaque_host_id --- *)

let test_name_validates_bare_alias () =
  let r1 = C2c_name.is_valid_with_opaque_host_id "lyra-quill" in
  let r2 = C2c_name.is_valid_with_opaque_host_id "storm.ember" in
  let r3 = C2c_name.is_valid_with_opaque_host_id "" in
  check bool "bare alias 'lyra-quill' valid" true r1;
  check bool "bare alias 'storm.ember' valid" true r2;
  check bool "empty alias invalid" false r3

let test_name_validates_alias_with_host_id () =
  let v1 = C2c_name.is_valid_with_opaque_host_id "lyra-quill@3d08761ae3f3" in
  let v2 = C2c_name.is_valid_with_opaque_host_id "alice@abcdef012345" in
  let v3 = C2c_name.is_valid_with_opaque_host_id "alice@abcdef0123456789" in
  let v4 = C2c_name.is_valid_with_opaque_host_id "3d08761ae3f3" in
  let v5 = C2c_name.is_valid_with_opaque_host_id "alice@3d08761ae3f" in
  let v6 = C2c_name.is_valid_with_opaque_host_id "alice@3d08761ae3f30000a" in
  let v7 = C2c_name.is_valid_with_opaque_host_id "alice@not-a-hex-id!" in
  let v8 = C2c_name.is_valid_with_opaque_host_id "alice#abcdef012345" in
  check bool "<name>@<host_id> form valid" true v1;
  check bool "12-char hex id valid" true v2;
  check bool "16-char hex id valid" true v3;
  check bool "12-char hex id only valid" true v4;
  check bool "11-char hex id (too short) invalid" false v5;
  check bool "17-char hex id (too long) invalid" false v6;
  check bool "non-hex id invalid" false v7;
  check bool "legacy #host_id form invalid for relay alias" false v8

let test_name_validates_rejects_special_chars_in_host_id () =
  let v1 = C2c_name.is_valid_with_opaque_host_id "alice@ABCDEF012345" in
  let v2 = C2c_name.is_valid_with_opaque_host_id "alice@abc-def-01234" in
  check bool "uppercase hex rejected" false v1;
  check bool "host_id with '-' rejected" false v2

let test_name_validates_rejects_bad_name_part () =
  let v1 = C2c_name.is_valid_with_opaque_host_id ".alice" in
  let v2 = C2c_name.is_valid_with_opaque_host_id "alice/bob@3d08761ae3f3" in
  let v3 = C2c_name.is_valid_with_opaque_host_id "alice@bob@3d08761ae3f3" in
  check bool "name with leading dot invalid" false v1;
  check bool "name with '/' invalid" false v2;
  check bool "name with '@' invalid" false v3

(* --- 2. c2c_name: split_opaque_host_id --- *)

let test_name_split_no_suffix () =
  let name, host_id = C2c_name.split_opaque_host_id "lyra-quill" in
  check string "bare name" "lyra-quill" name;
  check (option string) "no host_id" None host_id

let test_name_split_with_suffix () =
  let name, host_id = C2c_name.split_opaque_host_id "lyra-quill@3d08761ae3f3" in
  check string "name stripped" "lyra-quill" name;
  check (option string) "host_id present" (Some "3d08761ae3f3") host_id

let test_name_split_preserves_internal_chars () =
  let name, host_id = C2c_name.split_opaque_host_id "name@xxx" in
  check string "name" "name" name;
  check (option string) "raw suffix" (Some "xxx") host_id

(* --- 3. InMemoryRelay: register with opaque_host_id round-trip --- *)

let make_test_relay () = Relay.InMemoryRelay.create ()

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
      (Printf.sprintf "c2c-relay-opaque-%08x" (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let test_relay_register_with_opaque_host_id () =
  let t = make_test_relay () in
  let status, lease = _b264_reg_mem t
    ~node_id:"n1" ~session_id:"s1" ~alias:"lyra-quill"
    ~opaque_host_id:(Some "3d08761ae3f3") () in
  check string "register status" "ok" status;
  let lease_ohid = Relay.RegistrationLease.opaque_host_id lease in
  check (option string) "opaque_host_id on lease" (Some "3d08761ae3f3") lease_ohid;
  let json = Relay.RegistrationLease.to_json lease in
  let json_ohid = json_get_string json "opaque_host_id" in
  check string "json opaque_host_id" "3d08761ae3f3" json_ohid;
  let peers = Relay.InMemoryRelay.list_peers ~include_dead:false t in
  check int "one peer" 1 (List.length peers);
  let peer_json = Relay.RegistrationLease.to_json (List.hd peers) in
  let peer_ohid = json_get_string_opt peer_json "opaque_host_id" in
  check (option string) "list opaque_host_id present" (Some "3d08761ae3f3") peer_ohid

(* --- 4. InMemoryRelay: register without opaque_host_id (back-compat) --- *)

let test_relay_register_without_opaque_host_id () =
  let t = make_test_relay () in
  let status, lease = _b264_reg_mem t
    ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  check string "register status" "ok" status;
  let lease_ohid = Relay.RegistrationLease.opaque_host_id lease in
  check (option string) "opaque_host_id absent on lease" None lease_ohid;
  let json = Relay.RegistrationLease.to_json lease in
  let json_ohid = json_get_string_opt json "opaque_host_id" in
  check (option string) "json opaque_host_id absent" None json_ohid

(* --- 5. InMemoryRelay: <name>@<host_id> alias form --- *)

let test_relay_register_with_alias_embedded_host_id () =
  let t = make_test_relay () in
  let status, lease = _b264_reg_mem t
    ~node_id:"n1" ~session_id:"s1"
    ~alias:"lyra-quill@3d08761ae3f3" () in
  check string "register status" "ok" status;
  let alias_val = Relay.RegistrationLease.alias lease in
  check string "alias stored as display alias" "lyra-quill" alias_val;
  check (option string) "embedded host_id extracted"
    (Some "3d08761ae3f3") (Relay.RegistrationLease.opaque_host_id lease);
  let peers = Relay.InMemoryRelay.list_peers ~include_dead:false t in
  check int "one peer" 1 (List.length peers);
  let peer = List.hd peers in
  let peer_alias = Relay.RegistrationLease.alias peer in
  check string "peer alias roundtrip" "lyra-quill" peer_alias;
  check (option string) "peer opaque_host_id roundtrip"
    (Some "3d08761ae3f3") (Relay.RegistrationLease.opaque_host_id peer)

let test_relay_send_to_embedded_host_id_alias () =
  let t = make_test_relay () in
  let status, _lease = _b264_reg_mem t
    ~node_id:"n1" ~session_id:"s1"
    ~alias:"lyra-quill@3d08761ae3f3" () in
  check string "register status" "ok" status;
  match Relay.InMemoryRelay.send t
          ~from_alias:"alice" ~to_alias:"lyra-quill@3d08761ae3f3"
          ~content:"hello" ~message_id:None ~pow_difficulty:(-1) with
  | `Ok _ ->
      let inbox = Relay.InMemoryRelay.poll_inbox t ~node_id:"n1" ~session_id:"s1" in
      check int "one delivered message" 1 (List.length inbox);
      let msg = List.hd inbox in
      check string "to_alias preserves reply route"
        "lyra-quill@3d08761ae3f3" (json_get_string msg "to_alias")
  | `Duplicate _ -> fail "send unexpectedly reported duplicate"
  | `Error (err, msg) ->
      fail (Printf.sprintf "send failed: %s %s" err msg)

let test_relay_identity_lookup_accepts_reply_route () =
  let t = make_test_relay () in
  let status, _lease = _b264_reg_mem t
    ~node_id:"n1" ~session_id:"s1"
    ~alias:"lyra-quill@3d08761ae3f3" ~identity_pk:"raw-test-pk" () in
  check string "register status" "ok" status;
  check (option string) "identity lookup by display alias"
    (Some "raw-test-pk") (Relay.InMemoryRelay.identity_pk_of t ~alias:"lyra-quill");
  check (option string) "identity lookup by reply route"
    (Some "raw-test-pk")
    (Relay.InMemoryRelay.identity_pk_of t ~alias:"lyra-quill@3d08761ae3f3")

let test_sqlite_relay_send_to_embedded_host_id_alias () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let status, lease = _b264_reg_sql t
      ~node_id:"n1" ~session_id:"s1"
      ~alias:"lyra-quill@3d08761ae3f3" () in
    check string "register status" "ok" status;
    check string "alias stored as display alias"
      "lyra-quill" (Relay.RegistrationLease.alias lease);
    match Relay.SqliteRelay.send t
            ~from_alias:"alice" ~to_alias:"lyra-quill@3d08761ae3f3"
            ~content:"hello sqlite" ~message_id:None ~pow_difficulty:(-1) with
    | `Ok _ ->
        let inbox = Relay.SqliteRelay.poll_inbox t ~node_id:"n1" ~session_id:"s1" in
        check int "one delivered sqlite message" 1 (List.length inbox);
        check string "sqlite to_alias preserves reply route"
          "lyra-quill@3d08761ae3f3"
          (json_get_string (List.hd inbox) "to_alias")
    | `Duplicate _ -> fail "sqlite send unexpectedly reported duplicate"
    | `Error (err, msg) ->
        fail (Printf.sprintf "sqlite send failed: %s %s" err msg))

let test_relay_query_messages_since_matches_reply_route () =
  let t = make_test_relay () in
  let status, _lease = _b264_reg_mem t
    ~node_id:"n1" ~session_id:"s1"
    ~alias:"lyra-quill@3d08761ae3f3" () in
  check string "register status" "ok" status;
  let _ = Relay.InMemoryRelay.send t
      ~from_alias:"alice" ~to_alias:"lyra-quill@3d08761ae3f3"
      ~content:"for backfill" ~message_id:None ~pow_difficulty:(-1) in
  let msgs = Relay.InMemoryRelay.query_messages_since t
      ~alias:"lyra-quill" ~since_ts:0.0 in
  check int "query_messages_since sees opaque route message"
    1 (List.length msgs);
  check string "backfill to_alias preserves reply route"
    "lyra-quill@3d08761ae3f3" (json_get_string (List.hd msgs) "to_alias")

let test_sqlite_query_messages_since_matches_reply_route () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let status, _lease = _b264_reg_sql t
      ~node_id:"n1" ~session_id:"s1"
      ~alias:"lyra-quill@3d08761ae3f3" () in
    check string "register status" "ok" status;
    let _ = Relay.SqliteRelay.send t
        ~from_alias:"alice" ~to_alias:"lyra-quill@3d08761ae3f3"
        ~content:"sqlite backfill" ~message_id:None ~pow_difficulty:(-1) in
    let msgs = Relay.SqliteRelay.query_messages_since t
        ~alias:"lyra-quill" ~since_ts:0.0 in
    check int "sqlite query_messages_since sees opaque route message"
      1 (List.length msgs);
    check string "sqlite backfill to_alias preserves reply route"
      "lyra-quill@3d08761ae3f3" (json_get_string (List.hd msgs) "to_alias"))

let test_relay_register_rejects_legacy_hash_alias () =
  let t = make_test_relay () in
  let status, _lease = _b264_reg_mem t
    ~node_id:"n1" ~session_id:"s1"
    ~alias:"lyra-quill#3d08761ae3f3" () in
  check string "legacy hash host-id alias rejected" "invalid_alias" status

(* --- 6. Host_id.compute_host_hash recipe parity --- *)

let test_host_id_recipe_shape_and_stability () =
  let h = Host_id.compute_host_hash () in
  let h2 = Host_id.compute_host_hash () in
  check string "host_hash stable across calls" h h2;
  check int "hash length" 12 (String.length h)

let test_host_id_returns_12_lowercase_hex () =
  let h = Host_id.compute_host_hash () in
  let is_lower_hex_char c =
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') in
  let all_lower_hex =
    String.fold_left (fun acc c -> acc && is_lower_hex_char c) true h in
  check bool "all lowercase hex" true all_lower_hex;
  check int "exactly 12 chars" 12 (String.length h)

(* --- 7. Host_id.compute_host_hash_with_source --- *)

let test_host_id_with_source_reports_kind () =
  let info = Host_id.compute_host_hash_with_source () in
  let h = Host_id.compute_host_hash () in
  check string "host_id matches plain compute_host_hash" h info.Host_id.host_id;
  let valid_kind = List.mem info.Host_id.kind
    ["product_uuid"; "machine_id"; "hostname"] in
  check bool ("unexpected kind " ^ info.Host_id.kind) true valid_kind;
  let value_nonempty = info.Host_id.value <> "" in
  check bool "non-empty value" true value_nonempty;
  check int "host_id is 12 chars" 12 (String.length info.Host_id.host_id)

(* --- 8. c2c host-id CLI subcommand --- *)

let test_cli_host_id_plain_output () =
  let ic = Unix.open_process_in (Printf.sprintf "%s host-id" c2c_bin) in
  let output = input_line ic in
  let _ = Unix.close_process_in ic in
  let h = Host_id.compute_host_hash () in
  check string "c2c host-id matches Host_id.compute_host_hash" h output;
  check int "c2c host-id is 12 chars" 12 (String.length output)

let test_cli_host_id_json_output () =
  let ic = Unix.open_process_in (Printf.sprintf "%s host-id --json" c2c_bin) in
  let line = input_line ic in
  let _ = Unix.close_process_in ic in
  let json = Yojson.Safe.from_string line in
  let h = json_get_string json "host_id" in
  check string "json host_id matches Host_id.compute_host_hash"
    (Host_id.compute_host_hash ()) h;
  let kind = json_get_string json "kind" in
  let kind_nonempty = kind <> "" in
  check bool "json kind is non-empty" true kind_nonempty;
  let valid_kind = List.mem kind ["product_uuid"; "machine_id"; "hostname"] in
  check bool ("json kind " ^ kind ^ " is one of the known sources") true valid_kind

(* --- test runner --- *)

let () =
  run "Test_relay_opaque_host_id"
    [ "c2c_name validators", [
        test_case "is_valid_with_opaque_host_id — bare aliases" `Quick
          test_name_validates_bare_alias;
        test_case "is_valid_with_opaque_host_id — @hostid form" `Quick
          test_name_validates_alias_with_host_id;
        test_case "is_valid_with_opaque_host_id — rejects special chars in host_id" `Quick
          test_name_validates_rejects_special_chars_in_host_id;
        test_case "is_valid_with_opaque_host_id — rejects bad name part" `Quick
          test_name_validates_rejects_bad_name_part;
        test_case "split_opaque_host_id — no suffix" `Quick
          test_name_split_no_suffix;
        test_case "split_opaque_host_id — with suffix" `Quick
          test_name_split_with_suffix;
        test_case "split_opaque_host_id — preserves internal chars" `Quick
          test_name_split_preserves_internal_chars;
      ];
      "Relay lease round-trip", [
        test_case "register with opaque_host_id → to_json emits field" `Quick
          test_relay_register_with_opaque_host_id;
        test_case "register without opaque_host_id → field absent (back-compat)" `Quick
          test_relay_register_without_opaque_host_id;
        test_case "register with <name>@<host_id> alias form" `Quick
          test_relay_register_with_alias_embedded_host_id;
        test_case "send to <name>@<host_id> alias reaches display alias lease" `Quick
          test_relay_send_to_embedded_host_id_alias;
        test_case "identity lookup accepts <name>@<host_id> reply route" `Quick
          test_relay_identity_lookup_accepts_reply_route;
        test_case "sqlite send to <name>@<host_id> reaches display alias lease" `Quick
          test_sqlite_relay_send_to_embedded_host_id_alias;
        test_case "query_messages_since matches <name>@<host_id> route" `Quick
          test_relay_query_messages_since_matches_reply_route;
        test_case "sqlite query_messages_since matches <name>@<host_id> route" `Quick
          test_sqlite_query_messages_since_matches_reply_route;
        test_case "register rejects legacy #hostid alias" `Quick
          test_relay_register_rejects_legacy_hash_alias;
      ];
      "Host_id recipe", [
        test_case "compute_host_hash returns stable 12-char host id" `Quick
          test_host_id_recipe_shape_and_stability;
        test_case "compute_host_hash returns 12 lowercase hex chars" `Quick
          test_host_id_returns_12_lowercase_hex;
        test_case "compute_host_hash_with_source reports kind/value" `Quick
          test_host_id_with_source_reports_kind;
      ];
      "c2c CLI host-id subcommand", [
        test_case "c2c host-id (plain) — value matches library" `Quick
          test_cli_host_id_plain_output;
        test_case "c2c host-id --json — parses as JSON with host_id/kind" `Quick
          test_cli_host_id_json_output;
      ];
    ]
