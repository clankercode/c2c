(* test_c2c_relay_subscribe_daemon — pure IPC/list helpers for B278.
 *
 * Covers:
 * - list parse: default per-client; all/scope/list_all → global
 * - alias_state_string / summarize_alias_infos
 * - response_to_json always emits summary+aliases on list responses
 *   (including empty), so operators never confuse missing fields with idle
 *)

open Alcotest
open C2c_relay_subscribe_daemon

let yojson = testable Yojson.Safe.pp Yojson.Safe.equal

let parse_cmd s =
  parse_request (Yojson.Safe.from_string s)

let test_parse_list_default_per_client () =
  match parse_cmd {|{"cmd":"list"}|} with
  | Some (List { all = false }) -> ()
  | other ->
    failf "expected List {all=false}, got %s"
      (match other with None -> "None" | Some _ -> "Some other")

let assert_list_all expected msg json =
  match parse_cmd json with
  | Some (List { all }) when all = expected -> ()
  | Some (List { all }) ->
    failf "%s: expected all=%b got %b" msg expected all
  | Some _ -> failf "%s: expected List" msg
  | None -> failf "%s: parse failed" msg

let test_parse_list_all_bool () =
  assert_list_all true "all:true" {|{"cmd":"list","all":true}|};
  assert_list_all false "all:false" {|{"cmd":"list","all":false}|}

let test_parse_list_scope_and_list_all_cmd () =
  assert_list_all true "scope:all" {|{"cmd":"list","scope":"all"}|};
  assert_list_all true "scope:global" {|{"cmd":"list","scope":"global"}|};
  assert_list_all true "cmd list_all" {|{"cmd":"list_all"}|}

let test_parse_list_all_string_forms () =
  assert_list_all true "all:\"true\"" {|{"cmd":"list","all":"true"}|};
  assert_list_all true "all:1" {|{"cmd":"list","all":1}|}
let test_alias_state_string () =
  check string "connected" "connected"
    (alias_state_string ~stop_requested:false ~session_alive:true);
  check string "connecting" "connecting"
    (alias_state_string ~stop_requested:false ~session_alive:false);
  check string "stopped wins" "stopped"
    (alias_state_string ~stop_requested:true ~session_alive:true);
  check string "stopped over connecting" "stopped"
    (alias_state_string ~stop_requested:true ~session_alive:false)

let test_summarize_alias_infos () =
  let aliases = [
    { info_alias = "a"; info_state = "connected"; info_started_at = 1.0 };
    { info_alias = "b"; info_state = "connecting"; info_started_at = 0.0 };
    { info_alias = "c"; info_state = "connected"; info_started_at = 2.0 };
    { info_alias = "d"; info_state = "stopped"; info_started_at = 3.0 };
  ] in
  let s = summarize_alias_infos ~clients:2 aliases in
  check int "clients" 2 s.sum_clients;
  check int "aliases" 4 s.sum_aliases;
  check int "connected" 2 s.sum_connected;
  check int "connecting" 1 s.sum_connecting;
  check int "stopped" 1 s.sum_stopped

let test_summarize_empty () =
  let s = summarize_alias_infos ~clients:0 [] in
  check int "clients" 0 s.sum_clients;
  check int "aliases" 0 s.sum_aliases;
  check int "connected" 0 s.sum_connected;
  check int "connecting" 0 s.sum_connecting;
  check int "stopped" 0 s.sum_stopped

let test_response_json_list_with_summary_empty () =
  let summary = summarize_alias_infos ~clients:0 [] in
  let resp = {
    resp_ok = true; resp_id = ""; resp_alias = "";
    resp_error = None; resp_aliases = [];
    resp_summary = Some summary;
  } in
  let j = response_to_json resp in
  match j with
  | `Assoc fields ->
    check bool "has aliases key even when empty" true
      (List.mem_assoc "aliases" fields);
    check bool "has summary key" true (List.mem_assoc "summary" fields);
    (match List.assoc "aliases" fields with
     | `List [] -> ()
     | _ -> fail "aliases should be empty list");
    (match List.assoc "summary" fields with
     | `Assoc sfields ->
       check yojson "clients 0" (`Int 0) (List.assoc "clients" sfields);
       check yojson "aliases 0" (`Int 0) (List.assoc "aliases" sfields)
     | _ -> fail "summary not object")
  | _ -> fail "response not object"

let test_response_json_list_with_aliases () =
  let aliases = [
    { info_alias = "storm"; info_state = "connected"; info_started_at = 10.5 };
  ] in
  let summary = summarize_alias_infos ~clients:1 aliases in
  let resp = {
    resp_ok = true; resp_id = ""; resp_alias = "";
    resp_error = None; resp_aliases = aliases;
    resp_summary = Some summary;
  } in
  let j = response_to_json resp in
  match j with
  | `Assoc fields ->
    (match List.assoc "summary" fields with
     | `Assoc sfields ->
       check yojson "connected 1" (`Int 1) (List.assoc "connected" sfields);
       check yojson "aliases 1" (`Int 1) (List.assoc "aliases" sfields)
     | _ -> fail "summary");
    (match List.assoc "aliases" fields with
     | `List [`Assoc a] ->
       check yojson "alias name" (`String "storm") (List.assoc "alias" a);
       check yojson "state" (`String "connected") (List.assoc "state" a)
     | _ -> fail "aliases shape")
  | _ -> fail "not object"

let test_non_list_response_omits_summary () =
  let resp = empty_response ~id:"reg-1" ~alias:"x" () in
  let j = response_to_json resp in
  match j with
  | `Assoc fields ->
    check bool "no summary on register ack" false (List.mem_assoc "summary" fields);
    check bool "no aliases when empty and no summary" false
      (List.mem_assoc "aliases" fields)
  | _ -> fail "not object"

let () =
  run "c2c_relay_subscribe_daemon B278"
    [ "parse",
      [ test_case "list default is per-client" `Quick test_parse_list_default_per_client
      ; test_case "list all bool" `Quick test_parse_list_all_bool
      ; test_case "list scope and list_all cmd" `Quick test_parse_list_scope_and_list_all_cmd
      ; test_case "list all string/int forms" `Quick test_parse_list_all_string_forms
      ]
    ; "summary",
      [ test_case "alias_state_string" `Quick test_alias_state_string
      ; test_case "summarize counts" `Quick test_summarize_alias_infos
      ; test_case "summarize empty" `Quick test_summarize_empty
      ]
    ; "response_json",
      [ test_case "empty global list includes aliases+summary" `Quick
          test_response_json_list_with_summary_empty
      ; test_case "list with aliases" `Quick test_response_json_list_with_aliases
      ; test_case "non-list omits summary" `Quick test_non_list_response_omits_summary
      ]
    ]
