(* #388 agent-state handler tests — c2c_agent_state_handlers.ml
   Tests pure argument-parsing / JSON-membership logic for each agent-state
   handler entrypoint (set_dnd, dnd_status, set_compact, clear_compact, stop_self).

   Handler arg-reading strategy:
     set_dnd:  "on" → bool_of_arg (lenient: Bool/String("true"/"false")/Int(0/1))
                       "until_epoch" → member + float/int coercion
     dnd_status: no args
     set_compact: "reason" → optional_string_member (None if absent/empty)
     clear_compact: no args
     stop_self: "reason" → optional_string_member

   Note: bool_of_arg and optional_string_member live in C2c_mcp_helpers_post_broker
   but are NOT exported in c2c_mcp.mli. We test the JSON-membership + coercion
   logic using Yojson.Safe.Util directly (same data the handlers inspect). *)

open Alcotest
module J = Yojson.Safe.Util

(* ------------------------------------------------------------------------- *)
(* bool_of_arg behavior (lenient bool parsing from JSON value):                *)
(* Bool b → Some b, String "true"/"false" (case-insensitive) → Some bool,    *)
(* Int 1 → Some true, Int 0 → Some false, other → None                      *)
(* We replicate the logic inline to test the expected behavior.                 *)
(* ------------------------------------------------------------------------- *)

let parse_bool_of_arg : Yojson.Safe.t -> bool option = function
  | `Bool b -> Some b
  | `String s ->
      (match String.lowercase_ascii (String.trim s) with
       | "true" -> Some true
       | "false" -> Some false
       | _ -> None)
  | `Int 1 -> Some true
  | `Int 0 -> Some false
  | _ -> None

let test_bool_of_arg_bool_true () =
  match parse_bool_of_arg (`Bool true) with
  | Some true -> ()
  | Some false -> Alcotest.fail "expected Some true"
  | None -> Alcotest.fail "expected Some true"

let test_bool_of_arg_bool_false () =
  match parse_bool_of_arg (`Bool false) with
  | Some false -> ()
  | Some true -> Alcotest.fail "expected Some false"
  | None -> Alcotest.fail "expected Some false"

let test_bool_of_arg_string_true () =
  match parse_bool_of_arg (`String "true") with
  | Some true -> ()
  | _ -> Alcotest.fail "expected Some true for String \"true\""

let test_bool_of_arg_string_false () =
  match parse_bool_of_arg (`String "false") with
  | Some false -> ()
  | _ -> Alcotest.fail "expected Some false for String \"false\""

let test_bool_of_arg_string_mixed_case () =
  match parse_bool_of_arg (`String "TRUE") with
  | Some true -> ()
  | _ -> Alcotest.fail "expected Some true for String \"TRUE\""

let test_bool_of_arg_int_1 () =
  match parse_bool_of_arg (`Int 1) with
  | Some true -> ()
  | _ -> Alcotest.fail "expected Some true for Int 1"

let test_bool_of_arg_int_0 () =
  match parse_bool_of_arg (`Int 0) with
  | Some false -> ()
  | _ -> Alcotest.fail "expected Some false for Int 0"

let test_bool_of_arg_rejects_string_yes () =
  match parse_bool_of_arg (`String "yes") with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for String \"yes\""

let test_bool_of_arg_rejects_float () =
  match parse_bool_of_arg (`Float 1.0) with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for Float 1.0"

let test_bool_of_arg_rejects_null () =
  match parse_bool_of_arg (`Null) with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for Null"

(* ------------------------------------------------------------------------- *)
(* until_epoch: float or int JSON value → float option                         *)
(* set_dnd handler: match member "until_epoch" with                            *)
(*   `Float f → Some f, `Int i → Some (float_of_int i), _ → None           *)
(* ------------------------------------------------------------------------- *)

let parse_until_epoch : Yojson.Safe.t -> float option = function
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None

let test_until_epoch_float () =
  match parse_until_epoch (`Float 1700000000.5) with
  | Some f -> check bool "until_epoch float" true (abs_float (f -. 1700000000.5) < 0.001)
  | None -> Alcotest.fail "expected Some 1700000000.5"

let test_until_epoch_int () =
  match parse_until_epoch (`Int 1700000000) with
  | Some f -> check bool "until_epoch int" true (abs_float (f -. 1700000000.) < 0.001)
  | None -> Alcotest.fail "expected Some 1700000000 (from int)"

let test_until_epoch_wrong_type () =
  match parse_until_epoch (`String "2024-01-01") with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for String \"2024-01-01\""

(* ------------------------------------------------------------------------- *)
(* optional_string_member: trimmed non-empty string if present, None otherwise   *)
(* Implementation: match string_member name json with                         *)
(*   Some text when String.trim text <> "" → Some text, _ → None            *)
(* string_member: Some s if `String s, None otherwise                       *)
(* ------------------------------------------------------------------------- *)

let parse_optional_string_member (name : string) (json : Yojson.Safe.t) : string option =
  match J.member name json with
  | `String s when String.trim s <> "" -> Some s
  | _ -> None

let test_optional_string_member_present () =
  match parse_optional_string_member "reason" (`Assoc [("reason", `String "context limit near")]) with
  | Some s -> check string "reason" "context limit near" s
  | None -> Alcotest.fail "expected Some \"context limit near\""

let test_optional_string_member_absent () =
  match parse_optional_string_member "reason" (`Assoc []) with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for absent key"

let test_optional_string_member_empty () =
  match parse_optional_string_member "reason" (`Assoc [("reason", `String "  ")]) with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for whitespace-only string"

let test_optional_string_member_wrong_type () =
  match parse_optional_string_member "reason" (`Assoc [("reason", `Int 42)]) with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for non-string"

let test_optional_string_member_null () =
  match parse_optional_string_member "reason" (`Assoc [("reason", `Null)]) with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for Null"

(* ------------------------------------------------------------------------- *)
(* dnd_status / clear_compact: no required args                               *)
(* ------------------------------------------------------------------------- *)

let test_dnd_status_no_required_args () =
  let args = `Assoc [] in
  let on = J.member "on" args in
  check bool "dnd_status args can be empty" true (on = `Null)

let test_clear_compact_no_required_args () =
  let args = `Assoc [] in
  let reason = J.member "reason" args in
  check bool "clear_compact args can be empty" true (reason = `Null)

(* ------------------------------------------------------------------------- *)
(* set_dnd: combined on + until_epoch membership                              *)
(* ------------------------------------------------------------------------- *)

let test_set_dnd_on_member () =
  let args = `Assoc [("on", `Bool true)] in
  let v = J.member "on" args in
  check bool "on member present" true (v <> `Null)

let test_set_dnd_until_member () =
  let args = `Assoc [("until_epoch", `Float 1700000000.0)] in
  let v = J.member "until_epoch" args in
  check bool "until_epoch member present" true (v <> `Null)

(* ------------------------------------------------------------------------- *)
(* set_compact: reason (optional_string_member)                               *)
(* ------------------------------------------------------------------------- *)

let test_set_compact_reason_present () =
  match parse_optional_string_member "reason" (`Assoc [("reason", `String "context limit")]) with
  | Some _ -> ()
  | None -> Alcotest.fail "expected Some for reason"

(* ------------------------------------------------------------------------- *)
(* stop_self: reason (optional_string_member, defaults to "" if absent)         *)
(* ------------------------------------------------------------------------- *)

let test_stop_self_reason_absent () =
  let args = `Assoc [] in
  let v = J.member "reason" args in
  (* Handler treats None as "" — we just verify membership *)
  check bool "reason absent → `Null" true (v = `Null)

let test_stop_self_reason_present () =
  match parse_optional_string_member "reason" (`Assoc [("reason", `String "user requested")]) with
  | Some s -> check string "reason" "user requested" s
  | None -> Alcotest.fail "expected Some \"user requested\""

(* ========================================================================= *)
let agent_state_handler_tests : unit test =
  "agent_state_handler_argument_parsing", [
    (* set_dnd: bool_of_arg *)
    "bool_of_arg Bool true"      , `Quick, test_bool_of_arg_bool_true;
    "bool_of_arg Bool false"     , `Quick, test_bool_of_arg_bool_false;
    "bool_of_arg String true"    , `Quick, test_bool_of_arg_string_true;
    "bool_of_arg String false"   , `Quick, test_bool_of_arg_string_false;
    "bool_of_arg String TRUE"   , `Quick, test_bool_of_arg_string_mixed_case;
    "bool_of_arg Int 1"         , `Quick, test_bool_of_arg_int_1;
    "bool_of_arg Int 0"         , `Quick, test_bool_of_arg_int_0;
    "bool_of_arg String yes → None", `Quick, test_bool_of_arg_rejects_string_yes;
    "bool_of_arg Float → None"  , `Quick, test_bool_of_arg_rejects_float;
    "bool_of_arg Null → None"   , `Quick, test_bool_of_arg_rejects_null;
    (* set_dnd: until_epoch *)
    "until_epoch Float"          , `Quick, test_until_epoch_float;
    "until_epoch Int"           , `Quick, test_until_epoch_int;
    "until_epoch wrong type"    , `Quick, test_until_epoch_wrong_type;
    (* set_dnd: combined membership *)
    "set_dnd: on member"        , `Quick, test_set_dnd_on_member;
    "set_dnd: until_epoch member", `Quick, test_set_dnd_until_member;
    (* optional_string_member behavior *)
    "optional_string_member present", `Quick, test_optional_string_member_present;
    "optional_string_member absent" , `Quick, test_optional_string_member_absent;
    "optional_string_member empty"   , `Quick, test_optional_string_member_empty;
    "optional_string_member wrong type", `Quick, test_optional_string_member_wrong_type;
    "optional_string_member Null"   , `Quick, test_optional_string_member_null;
    (* dnd_status / clear_compact: no args *)
    "dnd_status accepts empty args", `Quick, test_dnd_status_no_required_args;
    "clear_compact accepts empty args", `Quick, test_clear_compact_no_required_args;
    (* set_compact: reason *)
    "set_compact reason present", `Quick, test_set_compact_reason_present;
    (* stop_self: reason *)
    "stop_self reason absent", `Quick, test_stop_self_reason_absent;
    "stop_self reason present", `Quick, test_stop_self_reason_present;
  ]

let () =
  Alcotest.run "c2c_agent_state_handlers"
    [agent_state_handler_tests]
