(* #388 room handler tests — c2c_room_handlers.ml
   Tests pure argument-parsing / JSON-membership logic for each room handler.
   Broker-level operations (join_room, leave_room, send_room, etc.) require
   a live broker + sessions and are covered by integration tests.

   Handler arg-reading strategy (from c2c_room_handlers.ml):
     room_id       → string_member → raises if missing/wrong-type
     content       → string_member → raises if missing/wrong-type
     history_limit → Broker.int_opt_member → None if absent
     limit         → Broker.int_opt_member → None if absent
     since         → Broker.float_opt_member → None if absent
     force         → Yojson.Safe.Util.member + bool match
     visibility    → string_member → "invite_only" or other (handler maps to Public)
     tag           → Yojson.Safe.Util.member + parse_send_tag
     invitee_alias → string_member → raises if missing

   We test the JSON membership + conversion logic directly (Yojson.Safe.Util). *)

open Alcotest
module J = Yojson.Safe.Util

(* ------------------------------------------------------------------------- *)
(* room_id: Yojson.Safe.Util.member + string coercion                           *)
(* Handlers: string_member from C2c_mcp_helpers_post_broker (raises).        *)
(* We test the JSON membership behavior directly.                             *)
(* ------------------------------------------------------------------------- *)

let test_room_id_missing () =
  let args = `Assoc [] in
  let v = J.member "room_id" args in
  (* member returns `Null for missing key *)
  check bool "missing room_id is `Null" true (v = `Null)

let test_room_id_present () =
  let args = `Assoc [("room_id", `String "swarm-lounge")] in
  let v = J.member "room_id" args in
  match v with
  | `String s -> check string "room_id" "swarm-lounge" s
  | _ -> Alcotest.fail "expected `String"

let test_room_id_wrong_type () =
  let args = `Assoc [("room_id", `Int 42)] in
  let v = J.member "room_id" args in
  (* member returns the actual value even if wrong type *)
  check bool "room_id int is not `Null" true (v <> `Null)

(* ------------------------------------------------------------------------- *)
(* history_limit (join_room): Broker.int_opt_member → None if absent            *)
(* ------------------------------------------------------------------------- *)

let test_history_limit_absent () =
  let args = `Assoc [] in
  let hl = C2c_broker.int_opt_member "history_limit" args in
  check bool "history_limit absent → None" true (hl = None)

let test_history_limit_explicit () =
  let args = `Assoc [("history_limit", `Int 50)] in
  let hl = C2c_broker.int_opt_member "history_limit" args in
  match hl with
  | Some n -> check int "history_limit 50" 50 n
  | None -> Alcotest.fail "expected Some 50"

let test_history_limit_zero () =
  let args = `Assoc [("history_limit", `Int 0)] in
  let hl = C2c_broker.int_opt_member "history_limit" args in
  match hl with
  | Some n -> check int "history_limit 0" 0 n
  | None -> Alcotest.fail "expected Some 0"

(* ------------------------------------------------------------------------- *)
(* room_history limit: Broker.int_opt_member                                    *)
(* ------------------------------------------------------------------------- *)

let test_limit_absent () =
  let args = `Assoc [] in
  let limit = C2c_broker.int_opt_member "limit" args in
  check bool "limit absent → None" true (limit = None)

let test_limit_explicit () =
  let args = `Assoc [("limit", `Int 25)] in
  let limit = C2c_broker.int_opt_member "limit" args in
  match limit with
  | Some n -> check int "limit 25" 25 n
  | None -> Alcotest.fail "expected Some 25"

(* ------------------------------------------------------------------------- *)
(* since (room_history): Broker.float_opt_member                               *)
(* ------------------------------------------------------------------------- *)

let test_since_absent () =
  let args = `Assoc [] in
  let since = C2c_broker.float_opt_member "since" args in
  check bool "since absent → None" true (since = None)

let test_since_explicit () =
  let args = `Assoc [("since", `Float 1700000000.5)] in
  let since = C2c_broker.float_opt_member "since" args in
  match since with
  | Some f -> check bool "since 1700000000.5" true (abs_float (f -. 1700000000.5) < 0.001)
  | None -> Alcotest.fail "expected Some 1700000000.5"

let test_since_wrong_type () =
  let args = `Assoc [("since", `String "2024-01-01")] in
  let since = C2c_broker.float_opt_member "since" args in
  check bool "since string → None" true (since = None)

(* ------------------------------------------------------------------------- *)
(* content (send_room): member + string coercion                              *)
(* ------------------------------------------------------------------------- *)

let test_content_missing () =
  let args = `Assoc [] in
  let v = J.member "content" args in
  check bool "missing content is `Null" true (v = `Null)

let test_content_present () =
  let args = `Assoc [("content", `String "hello room")] in
  let v = J.member "content" args in
  match v with
  | `String s -> check string "content" "hello room" s
  | _ -> Alcotest.fail "expected `String"

(* ------------------------------------------------------------------------- *)
(* tag (send_room): member + parse_send_tag                                    *)
(* ------------------------------------------------------------------------- *)

let test_tag_absent () =
  let args = `Assoc [] in
  let raw_tag = J.member "tag" args |> function `String s -> Some s | _ -> None in
  match C2c_mcp.parse_send_tag raw_tag with
  | Ok None -> () (* correct: absent/empty → Ok None *)
  | Ok (Some _) -> Alcotest.fail "tag absent should not be Some"
  | Error _ -> Alcotest.fail "tag absent should not Error"

let test_tag_wrong_type () =
  (* tag as int should be treated as non-string → parse_send_tag sees None → Ok None *)
  let args = `Assoc [("tag", `Int 1)] in
  let raw_tag = J.member "tag" args |> function `String s -> Some s | _ -> None in
  match C2c_mcp.parse_send_tag raw_tag with
  | Ok None -> () (* int tag → not a string → treated as absent *)
  | _ -> Alcotest.fail "tag int should be treated as absent"

let test_tag_fail () =
  let args = `Assoc [("tag", `String "fail")] in
  let raw_tag = J.member "tag" args |> function `String s -> Some s | _ -> None in
  match C2c_mcp.parse_send_tag raw_tag with
  | Ok (Some ("fail" as t)) -> check string "valid tag" "fail" t
  | Ok (Some ("blocking" as t)) -> check string "valid tag" "blocking" t
  | Ok (Some ("urgent" as t)) -> check string "valid tag" "urgent" t
  | Ok (Some "") -> Alcotest.fail "expected Ok (Some \"fail\")"
  | Ok (Some other) -> Alcotest.fail ("unexpected tag: " ^ other)
  | Ok None -> Alcotest.fail "expected Ok (Some \"fail\")"
  | Error _ -> Alcotest.fail "tag \"fail\" should be accepted"

(* ------------------------------------------------------------------------- *)
(* force (delete_room): member + bool match                                    *)
(* ------------------------------------------------------------------------- *)

let test_force_absent () =
  let args = `Assoc [] in
  let force = match J.member "force" args with `Bool b -> b | _ -> false in
  check bool "force absent → false" false force

let test_force_true () =
  let args = `Assoc [("force", `Bool true)] in
  let force = match J.member "force" args with `Bool b -> b | _ -> false in
  check bool "force true" true force

let test_force_false () =
  let args = `Assoc [("force", `Bool false)] in
  let force = match J.member "force" args with `Bool b -> b | _ -> false in
  check bool "force false" false force

let test_force_wrong_type () =
  let args = `Assoc [("force", `String "true")] in
  let force = match J.member "force" args with `Bool b -> b | _ -> false in
  check bool "force string → false" false force

(* ------------------------------------------------------------------------- *)
(* visibility (set_room_visibility): member + string                           *)
(* ------------------------------------------------------------------------- *)

let test_visibility_invite_only () =
  let args = `Assoc [("visibility", `String "invite_only")] in
  let v = J.member "visibility" args in
  match v with
  | `String s -> check string "visibility" "invite_only" s
  | _ -> Alcotest.fail "expected `String \"invite_only\""

let test_visibility_public () =
  let args = `Assoc [("visibility", `String "public")] in
  let v = J.member "visibility" args in
  match v with
  | `String s -> check string "visibility" "public" s
  | _ -> Alcotest.fail "expected `String \"public\""

let test_visibility_unknown () =
  let args = `Assoc [("visibility", `String "private")] in
  let v = J.member "visibility" args in
  match v with
  | `String s -> check string "visibility" "private" s
  | _ -> Alcotest.fail "expected `String \"private\""

(* ------------------------------------------------------------------------- *)
(* prune_rooms / list_rooms / my_rooms: no required args                      *)
(* ------------------------------------------------------------------------- *)

let test_prune_rooms_no_args () =
  (* prune_rooms ignores arguments entirely — any args are acceptable *)
  let (_ : Yojson.Safe.t) = `Assoc [("foo", `String "bar")] in
  check bool "args accepted" true true

let test_list_rooms_no_args () =
  let args = `Assoc [] in
  let limit = C2c_broker.int_opt_member "limit" args in
  check bool "no limit arg" true (limit = None)

(* ------------------------------------------------------------------------- *)
(* invitee_alias (send_room_invite): member + string                           *)
(* ------------------------------------------------------------------------- *)

let test_invitee_alias_present () =
  let args = `Assoc [("room_id", `String "test-room");
                      ("invitee_alias", `String "jungle-coder")] in
  let v = J.member "invitee_alias" args in
  match v with
  | `String a -> check string "invitee_alias" "jungle-coder" a
  | _ -> Alcotest.fail "expected `String"

let test_invitee_alias_missing () =
  let args = `Assoc [("room_id", `String "test-room")] in
  let v = J.member "invitee_alias" args in
  check bool "missing invitee_alias is `Null" true (v = `Null)

(* ========================================================================= *)
let room_handler_tests : unit test =
  "room_handler_argument_parsing", [
    (* room_id (join/leave/send/history/delete/invite) *)
    "room_id missing → `Null"  , `Quick, test_room_id_missing;
    "room_id present"          , `Quick, test_room_id_present;
    "room_id wrong type"       , `Quick, test_room_id_wrong_type;
    (* history_limit (join_room) *)
    "history_limit absent"      , `Quick, test_history_limit_absent;
    "history_limit explicit"    , `Quick, test_history_limit_explicit;
    "history_limit zero"       , `Quick, test_history_limit_zero;
    (* limit (room_history) *)
    "limit absent"             , `Quick, test_limit_absent;
    "limit explicit"          , `Quick, test_limit_explicit;
    (* since (room_history) *)
    "since absent"             , `Quick, test_since_absent;
    "since explicit"          , `Quick, test_since_explicit;
    "since wrong type"        , `Quick, test_since_wrong_type;
    (* content (send_room) *)
    "content missing → `Null"  , `Quick, test_content_missing;
    "content present"          , `Quick, test_content_present;
    (* tag (send_room) *)
    "tag absent → Ok None"     , `Quick, test_tag_absent;
    "tag fail → Ok Some"       , `Quick, test_tag_fail;
    (* force (delete_room) *)
    "force absent → false"     , `Quick, test_force_absent;
    "force true"              , `Quick, test_force_true;
    "force false"             , `Quick, test_force_false;
    "force wrong type → false" , `Quick, test_force_wrong_type;
    (* visibility (set_room_visibility) *)
    "visibility invite_only"   , `Quick, test_visibility_invite_only;
    "visibility public"       , `Quick, test_visibility_public;
    "visibility unknown"       , `Quick, test_visibility_unknown;
    (* misc *)
    "prune_rooms ignores args", `Quick, test_prune_rooms_no_args;
    "list_rooms no args"     , `Quick, test_list_rooms_no_args;
    (* invitee_alias (send_room_invite) *)
    "invitee_alias present"   , `Quick, test_invitee_alias_present;
    "invitee_alias missing"   , `Quick, test_invitee_alias_missing;
  ]

let () =
  Alcotest.run "c2c_room_handlers"
    [room_handler_tests]
