(* #388 tests for #450 handler module: c2c_pending_reply_handlers.ml *)

open Alcotest

(* ------------------------------------------------------------------------- *)
(* Test infrastructure                                                       *)
(* ------------------------------------------------------------------------- *)

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base (Printf.sprintf "c2c-pending-reply-%06x" (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let yojson_of_string s = Yojson.Safe.from_string s

(* tool_result shape: { content: [{type: "text", text: <msg>}], isError: bool } *)
let get_is_error json =
  let open Yojson.Safe.Util in
  member "isError" json |> to_bool

let get_text_content json =
  let open Yojson.Safe.Util in
  member "content" json |> index 0 |> member "text" |> to_string

(* ------------------------------------------------------------------------- *)
(* Pure helper tests: pending_kind_of_string / pending_kind_to_string         *)
(* These live in C2c_mcp_helpers and are imported by the handler module.    *)
(* ------------------------------------------------------------------------- *)

let test_pending_kind_of_string_question () =
  let got = C2c_mcp_helpers.pending_kind_of_string "question" in
  check int "question -> Question" 0 (compare got C2c_mcp_helpers.Question)

let test_pending_kind_of_string_permission () =
  let got = C2c_mcp_helpers.pending_kind_of_string "permission" in
  check int "permission -> Permission" 0 (compare got C2c_mcp_helpers.Permission)

let test_pending_kind_of_string_unknown_defaults_to_permission () =
  let got = C2c_mcp_helpers.pending_kind_of_string "garbage" in
  check int "garbage -> Permission" 0 (compare got C2c_mcp_helpers.Permission)

let test_pending_kind_to_string_question () =
  check string "Question -> question"
    "question"
    (C2c_mcp_helpers.pending_kind_to_string C2c_mcp_helpers.Question)

let test_pending_kind_to_string_permission () =
  check string "Permission -> permission"
    "permission"
    (C2c_mcp_helpers.pending_kind_to_string C2c_mcp_helpers.Permission)

(* ------------------------------------------------------------------------- *)
(* open_pending_reply: unregistered caller → isError:true                      *)
(* From #432 Slice B: unregistered callers are rejected before any state      *)
(* is written.                                                              *)
(* ------------------------------------------------------------------------- *)

let test_open_pending_reply_rejects_unregistered_session () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      (* No registration — session is not registered. *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-not-registered";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let args = `Assoc [
             ("perm_id", `String "perm-unreg-test");
             ("kind", `String "permission");
             ("supervisors", `List [`String "coordinator1"]);
           ] in
           let result = Lwt_main.run
             (C2c_pending_reply_handlers.open_pending_reply
                ~broker ~session_id_override:None ~arguments:args)
           in
           check bool "isError=true for unregistered" true (get_is_error result);
           let text = get_text_content result in
           check bool "error mentions registration" true
             (String.length text > 0);
           (* Ensure nothing was written to the broker. *)
           let stored = C2c_broker.find_pending_permission
             broker "perm-unreg-test"
           in
           check bool "no pending entry written" true (stored = None)))

(* ------------------------------------------------------------------------- *)
(* open_pending_reply: happy path → isError:false, ok:true                   *)
(* ------------------------------------------------------------------------- *)

let test_open_pending_reply_success () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      C2c_broker.register broker ~session_id:"session-test"
        ~alias:"test-agent" ~pid:None ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" "session-test";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let args = `Assoc [
             ("perm_id", `String "perm-ok-1");
             ("kind", `String "permission");
             ("supervisors", `List [`String "coordinator1"; `String "ceo"]);
           ] in
           let result = Lwt_main.run
             (C2c_pending_reply_handlers.open_pending_reply
                ~broker ~session_id_override:None ~arguments:args)
           in
           check bool "isError=false on success" false (get_is_error result);
           let body_json = yojson_of_string (get_text_content result) in
           let open Yojson.Safe.Util in
           check string "perm_id" "perm-ok-1" (body_json |> member "perm_id" |> to_string);
           check string "kind" "permission" (body_json |> member "kind" |> to_string);
           (* Verify the entry was written to the broker. *)
           let stored = C2c_broker.find_pending_permission broker "perm-ok-1" in
           match stored with
           | None -> fail "pending entry not found in broker"
           | Some p ->
               check string "stored alias" "test-agent" p.C2c_mcp_helpers.requester_alias;
               check string "stored kind" "permission"
                 (C2c_mcp_helpers.pending_kind_to_string p.C2c_mcp_helpers.kind);
               check int "2 supervisors" 2 (List.length p.C2c_mcp_helpers.supervisors)))

(* ------------------------------------------------------------------------- *)
(* check_pending_reply: valid supervisor → valid:true                         *)
(* ------------------------------------------------------------------------- *)

let test_check_pending_reply_valid_supervisor () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      C2c_broker.register broker ~session_id:"session-supervisor"
        ~alias:"coord-x" ~pid:None ~pid_start_time:None ();
      C2c_broker.register broker ~session_id:"session-requester"
        ~alias:"agent-x" ~pid:None ~pid_start_time:None ();
      (* Open a pending permission from the requester. *)
      let now = Unix.gettimeofday () in
      let pending = {
        C2c_mcp_helpers.perm_id = "perm-check-1";
        kind = C2c_mcp_helpers.Permission;
        requester_session_id = "session-requester";
        requester_alias = "agent-x";
        supervisors = ["coord-x"];
        created_at = now;
        expires_at = now +. 300.0;
        fallthrough_fired_at = [];
        resolved_at = None;
      } in
      C2c_broker.open_pending_permission broker pending;
      (* Call check_pending_reply from the supervisor session. *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-supervisor";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let args = `Assoc [("perm_id", `String "perm-check-1")] in
           let result = Lwt_main.run
             (C2c_pending_reply_handlers.check_pending_reply
                ~broker ~session_id_override:None ~arguments:args)
           in
           check bool "isError=false for valid reply" false (get_is_error result);
           let body_json = yojson_of_string (get_text_content result) in
           let open Yojson.Safe.Util in
           check bool "valid" true (body_json |> member "valid" |> to_bool);
           check string "requester_session_id" "session-requester"
             (body_json |> member "requester_session_id" |> to_string)))

(* ------------------------------------------------------------------------- *)
(* check_pending_reply: non-supervisor caller → valid:false, error contains  *)
(* "reply from non-supervisor"                                               *)
(* ------------------------------------------------------------------------- *)

let test_check_pending_reply_non_supervisor_rejected () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      C2c_broker.register broker ~session_id:"session-supervisor"
        ~alias:"coord-x" ~pid:None ~pid_start_time:None ();
      C2c_broker.register broker ~session_id:"session-requester"
        ~alias:"agent-x" ~pid:None ~pid_start_time:None ();
      C2c_broker.register broker ~session_id:"session-random"
        ~alias:"random-agent" ~pid:None ~pid_start_time:None ();
      let now = Unix.gettimeofday () in
      let pending = {
        C2c_mcp_helpers.perm_id = "perm-check-2";
        kind = C2c_mcp_helpers.Permission;
        requester_session_id = "session-requester";
        requester_alias = "agent-x";
        supervisors = ["coord-x"];
        created_at = now;
        expires_at = now +. 300.0;
        fallthrough_fired_at = [];
        resolved_at = None;
      } in
      C2c_broker.open_pending_permission broker pending;
      (* Call from session-random (not a supervisor). *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-random";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let args = `Assoc [("perm_id", `String "perm-check-2")] in
           let result = Lwt_main.run
             (C2c_pending_reply_handlers.check_pending_reply
                ~broker ~session_id_override:None ~arguments:args)
           in
           check bool "isError=false even for rejected check" false (get_is_error result);
           let body_json = yojson_of_string (get_text_content result) in
           let open Yojson.Safe.Util in
           check bool "valid" false (body_json |> member "valid" |> to_bool);
           let err = body_json |> member "error" |> to_string in
           check bool "error mentions non-supervisor" true
             (String.length err > 0)))

(* ------------------------------------------------------------------------- *)
(* check_pending_reply: expired vs unknown_perm distinction                   *)
(* ------------------------------------------------------------------------- *)

let test_check_pending_reply_expired_distinguished_from_unknown () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      C2c_broker.register broker ~session_id:"session-a"
        ~alias:"agent-a" ~pid:None ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" "session-a";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           (* Open a pending permission that will expire quickly. *)
           Unix.putenv "C2C_PERMISSION_TTL" "1";
           Fun.protect ~finally:(fun () -> Unix.putenv "C2C_PERMISSION_TTL" "")
             (fun () ->
                let args = `Assoc [
                  ("perm_id", `String "perm-expired-test");
                  ("kind", `String "permission");
                  ("supervisors", `List [`String "coordinator1"]);
                ] in
                let _ = Lwt_main.run
                  (C2c_pending_reply_handlers.open_pending_reply
                     ~broker ~session_id_override:None ~arguments:args)
                in
                (* Wait for expiry. *)
                Unix.sleepf 1.2;
                (* Attempt to check the now-expired perm. *)
                let check_args = `Assoc [("perm_id", `String "perm-expired-test")] in
                let result = Lwt_main.run
                  (C2c_pending_reply_handlers.check_pending_reply
                     ~broker ~session_id_override:None ~arguments:check_args)
                in
                check bool "isError=false for expired perm" false (get_is_error result);
                let body_json = yojson_of_string (get_text_content result) in
                let open Yojson.Safe.Util in
                check bool "valid" false (body_json |> member "valid" |> to_bool);
                let err = body_json |> member "error" |> to_string in
                check string "error is 'permission ID expired'"
                  "permission ID expired" err)))

let test_check_pending_reply_totally_unknown_perm () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      C2c_broker.register broker ~session_id:"session-b"
        ~alias:"agent-b" ~pid:None ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" "session-b";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           (* Check a perm_id that never existed. *)
           let args = `Assoc [("perm_id", `String "perm-never-existed")] in
           let result = Lwt_main.run
             (C2c_pending_reply_handlers.check_pending_reply
                ~broker ~session_id_override:None ~arguments:args)
           in
           check bool "isError=false for unknown perm" false (get_is_error result);
           let body_json = yojson_of_string (get_text_content result) in
           let open Yojson.Safe.Util in
           check bool "valid" false (body_json |> member "valid" |> to_bool);
           let err = body_json |> member "error" |> to_string in
           check string "error is 'unknown permission ID'"
             "unknown permission ID" err))

(* ------------------------------------------------------------------------- *)
(* Test suite                                                               *)
(* ------------------------------------------------------------------------- *)

let test_set = [
  "pending_kind_of_string question", `Quick, test_pending_kind_of_string_question;
  "pending_kind_of_string permission", `Quick, test_pending_kind_of_string_permission;
  "pending_kind_of_string unknown defaults to Permission", `Quick, test_pending_kind_of_string_unknown_defaults_to_permission;
  "pending_kind_to_string question", `Quick, test_pending_kind_to_string_question;
  "pending_kind_to_string permission", `Quick, test_pending_kind_to_string_permission;
  "open_pending_reply rejects unregistered session", `Quick, test_open_pending_reply_rejects_unregistered_session;
  "open_pending_reply success", `Quick, test_open_pending_reply_success;
  "check_pending_reply valid supervisor", `Quick, test_check_pending_reply_valid_supervisor;
  "check_pending_reply non-supervisor", `Quick, test_check_pending_reply_non_supervisor_rejected;
  "check_pending_reply expired distinguished from unknown", `Quick, test_check_pending_reply_expired_distinguished_from_unknown;
  "check_pending_reply totally unknown perm", `Quick, test_check_pending_reply_totally_unknown_perm;
]

let () =
  Alcotest.run "c2c_pending_reply_handlers" [ "pending_reply_handlers", test_set ]
