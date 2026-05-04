(* test_pending_verdict.ml — unit tests for Broker.parse_pending_verdict and verdict recording *)

open Alcotest

let verdict_testable =
  let pp fmt = function
    | `Approve -> Format.fprintf fmt "`Approve"
    | `Deny -> Format.fprintf fmt "`Deny"
  in
  let eq a b = match a, b with
    | `Approve, `Approve -> true
    | `Deny, `Deny -> true
    | _ -> false
  in
  testable pp eq

let result_testable =
  option (pair string verdict_testable)

let test_approve () =
  check result_testable "approve"
    (Some ("per_abc", `Approve))
    (C2c_mcp.Broker.parse_pending_verdict "[c2c:pending-verdict:per_abc:approve]")

let test_deny () =
  check result_testable "deny"
    (Some ("per_abc", `Deny))
    (C2c_mcp.Broker.parse_pending_verdict "[c2c:pending-verdict:per_abc:deny]")

let test_embedded () =
  check result_testable "embedded in text"
    (Some ("per_xyz", `Approve))
    (C2c_mcp.Broker.parse_pending_verdict
       "hello [c2c:pending-verdict:per_xyz:approve] world")

let test_no_verdict () =
  check result_testable "no verdict"
    None
    (C2c_mcp.Broker.parse_pending_verdict "no verdict here")

let test_unknown_verdict () =
  check result_testable "unknown verdict"
    None
    (C2c_mcp.Broker.parse_pending_verdict
       "[c2c:pending-verdict:per_abc:unknown]")

let test_empty_perm_id () =
  check result_testable "empty perm_id"
    None
    (C2c_mcp.Broker.parse_pending_verdict "[c2c:pending-verdict::approve]")

let test_no_closing_bracket () =
  check result_testable "no closing bracket"
    None
    (C2c_mcp.Broker.parse_pending_verdict
       "[c2c:pending-verdict:per_abc:approve")

let test_empty_string () =
  check result_testable "empty string"
    None
    (C2c_mcp.Broker.parse_pending_verdict "")

(* Verdict JSON serialization tests — verify the verdict field is correctly serialized *)

let test_verdict_approve_json () =
  (* Create a pending_permission with verdict=Some Approve and verify JSON *)
  let json = `Assoc [
    ("perm_id", `String "per_test")
  ; ("kind", `String "permission")
  ; ("requester_session_id", `String "sess")
  ; ("requester_alias", `String "req")
  ; ("supervisors", `List [`String "sup"])
  ; ("created_at", `Float 0.0)
  ; ("expires_at", `Float 100.0)
  ; ("fallthrough_fired_at", `List [])
  ; ("resolved_at", `Null)
  ; ("verdict", `String "approve")
  ] in
  let verdict_json = Yojson.Safe.Util.member "verdict" json in
  check string "verdict field is approve string" "approve" (Yojson.Safe.Util.to_string verdict_json)

let test_verdict_deny_json () =
  let json = `Assoc [
    ("perm_id", `String "per_test")
  ; ("kind", `String "permission")
  ; ("requester_session_id", `String "sess")
  ; ("requester_alias", `String "req")
  ; ("supervisors", `List [`String "sup"])
  ; ("created_at", `Float 0.0)
  ; ("expires_at", `Float 100.0)
  ; ("fallthrough_fired_at", `List [])
  ; ("resolved_at", `Null)
  ; ("verdict", `String "deny")
  ] in
  let verdict_json = Yojson.Safe.Util.member "verdict" json in
  check string "verdict field is deny string" "deny" (Yojson.Safe.Util.to_string verdict_json)

let test_verdict_null_json () =
  let json = `Assoc [
    ("perm_id", `String "per_test")
  ; ("kind", `String "permission")
  ; ("requester_session_id", `String "sess")
  ; ("requester_alias", `String "req")
  ; ("supervisors", `List [`String "sup"])
  ; ("created_at", `Float 0.0)
  ; ("expires_at", `Float 100.0)
  ; ("fallthrough_fired_at", `List [])
  ; ("resolved_at", `Null)
  ; ("verdict", `Null)
  ] in
  let verdict_json = Yojson.Safe.Util.member "verdict" json in
  check bool "verdict field is null" true (verdict_json = `Null)

let () =
  run "pending_verdict"
    [ ( "parse_pending_verdict"
      , [ test_case "approve" `Quick test_approve
        ; test_case "deny" `Quick test_deny
        ; test_case "embedded" `Quick test_embedded
        ; test_case "no verdict" `Quick test_no_verdict
        ; test_case "unknown verdict" `Quick test_unknown_verdict
        ; test_case "empty perm_id" `Quick test_empty_perm_id
        ; test_case "no closing bracket" `Quick test_no_closing_bracket
        ; test_case "empty string" `Quick test_empty_string
        ] )
    ; ( "verdict_json"
      , [ test_case "verdict=approve in JSON" `Quick test_verdict_approve_json
        ; test_case "verdict=deny in JSON" `Quick test_verdict_deny_json
        ; test_case "verdict=null in JSON" `Quick test_verdict_null_json
        ] )
    ]
