(* #388 tests for c2c_inbox_handlers.ml — 8 test cases *)

open Alcotest

(* ------------------------------------------------------------------------- *)
(* Helpers                                                                    *)
(* ------------------------------------------------------------------------- *)

let yojson_of_string s = Yojson.Safe.from_string s

(* Extract a string field from a JSON object, failing on absence *)
let get_string_exn name json =
  let open Yojson.Safe.Util in
  member name json |> to_string

(* Extract a list field from a JSON object *)
let get_list name json =
  let open Yojson.Safe.Util in
  member name json |> to_list

(* ------------------------------------------------------------------------- *)
(* server_info: pure — returns static JSON from C2c_mcp_helpers.server_info *)
(* ------------------------------------------------------------------------- *)

let test_server_info_returns_valid_json () =
  let json = C2c_mcp_helpers.server_info () in
  check string "name is c2c" "c2c" (get_string_exn "name" json)

let test_server_info_has_version_field () =
  let json = C2c_mcp_helpers.server_info () in
  let v = get_string_exn "version" json in
  (* version format: N.N.N or N.N.N-commit *)
  check bool "version is non-empty" true (String.length v > 0)

let test_server_info_has_git_hash_field () =
  let json = C2c_mcp_helpers.server_info () in
  let h = get_string_exn "git_hash" json in
  check bool "git_hash is non-empty" true (String.length h > 0)

let test_server_info_features_is_list () =
  let json = C2c_mcp_helpers.server_info () in
  let features = get_list "features" json in
  (* features should be a list of strings *)
  List.iter (fun f ->
    let open Yojson.Safe.Util in
    ignore (to_string f : string)
  ) features

let test_server_info_runtime_identity_fields () =
  let json = C2c_mcp_helpers.server_info () in
  let open Yojson.Safe.Util in
  let ri = member "runtime_identity" json in
  (* runtime_identity has: schema, pid, started_at, executable, executable_mtime,
     executable_sha256. No alias field — registration is separate. *)
  let schema = member "schema" ri in
  let pid   = member "pid" ri in
  let started = member "started_at" ri in
  let exe = member "executable" ri in
  check bool "runtime_identity.schema present"  true (schema  <> `Null);
  check bool "runtime_identity.pid present"    true (pid    <> `Null);
  check bool "runtime_identity.started_at present" true (started <> `Null);
  check bool "runtime_identity.executable present" true (exe <> `Null);
  (* pid should be a positive int *)
  let pid_int = to_int pid in
  check bool "runtime_identity.pid > 0" true (pid_int > 0);
  (* started_at should be a positive float *)
  let started_float = to_float started in
  check bool "runtime_identity.started_at > 0" true (started_float > 0.0)

(* ------------------------------------------------------------------------- *)
(* history limit argument parsing                                            *)
(* The handler uses Broker.int_opt_member to read "limit". Defaults to 50.  *)
(* ------------------------------------------------------------------------- *)

let test_history_default_limit () =
  let args = `Assoc [] in
  let limit = C2c_broker.int_opt_member "limit" args in
  check bool "no limit arg → None" true (limit = None)

let test_history_explicit_limit () =
  let args = `Assoc [("limit", `Int 20)] in
  let limit = C2c_broker.int_opt_member "limit" args in
  match limit with
  | Some n -> check int "explicit limit 20" 20 n
  | None -> Alcotest.fail "expected Some 20, got None"

(* ------------------------------------------------------------------------- *)
(* tail_log limit argument parsing                                           *)
(* tail_log uses Broker.int_opt_member but enforces 1..500 range.           *)
(* ------------------------------------------------------------------------- *)

let test_tail_log_default_limit () =
  let args = `Assoc [] in
  let limit = C2c_broker.int_opt_member "limit" args in
  check bool "no limit arg → None" true (limit = None)

let test_tail_log_explicit_limit () =
  let args = `Assoc [("limit", `Int 10)] in
  let limit = C2c_broker.int_opt_member "limit" args in
  match limit with
  | Some n -> check int "explicit limit 10" 10 n
  | None -> Alcotest.fail "expected Some 10, got None"

(* ------------------------------------------------------------------------- *)
(* Test suite                                                               *)
(* ------------------------------------------------------------------------- *)

let () =
  run "c2c_inbox_handlers" [
    "server_info", [
      test_case "returns valid json with name=c2c"    `Quick test_server_info_returns_valid_json;
      test_case "has non-empty version field"         `Quick test_server_info_has_version_field;
      test_case "has non-empty git_hash field"        `Quick test_server_info_has_git_hash_field;
      test_case "features is a list of strings"      `Quick test_server_info_features_is_list;
      test_case "runtime_identity has required fields"`Quick test_server_info_runtime_identity_fields;
    ];
    "history_limit_parsing", [
      test_case "default limit is None when absent"   `Quick test_history_default_limit;
      test_case "explicit limit 20 parsed correctly"  `Quick test_history_explicit_limit;
    ];
    "tail_log_limit_parsing", [
      test_case "default limit is None when absent"   `Quick test_tail_log_default_limit;
      test_case "explicit limit 10 parsed correctly" `Quick test_tail_log_explicit_limit;
    ];
  ]
