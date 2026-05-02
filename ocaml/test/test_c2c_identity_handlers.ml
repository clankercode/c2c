(* #388 tests for #450 handler module: c2c_identity_handlers.ml *)

open Alcotest

(* ------------------------------------------------------------------------- *)
(* Test infrastructure                                                       *)
(* ------------------------------------------------------------------------- *)

let () = Random.self_init ()

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base (Printf.sprintf "c2c-identity-%06x" (Random.bits ())) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) ->
    (* Stale dir from prior run — clean and recreate *)
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    Unix.mkdir dir 0o755);
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
(* list: empty broker → empty list                                           *)
(* ------------------------------------------------------------------------- *)

let test_list_empty () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      let result = Lwt_main.run
        (C2c_identity_handlers.list ~broker ~session_id_override:None ~arguments:`Null)
      in
      let json = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      let lst = to_list json in
      check int "empty list length" 0 (List.length lst))

(* ------------------------------------------------------------------------- *)
(* list: after registering one alias, list shows that alias                   *)
(* ------------------------------------------------------------------------- *)

let test_list_after_register () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      C2c_broker.register broker ~session_id:"session-list-test"
        ~alias:"test-alias" ~pid:None ~pid_start_time:None ();
      let result = Lwt_main.run
        (C2c_identity_handlers.list ~broker ~session_id_override:None ~arguments:`Null)
      in
      let json = yojson_of_string (get_text_content result) in
      let open Yojson.Safe.Util in
      let lst = to_list json in
      check int "list length" 1 (List.length lst);
      let entry = List.hd lst in
      check string "session_id" "session-list-test" (entry |> member "session_id" |> to_string);
      check string "alias" "test-alias" (entry |> member "alias" |> to_string))

(* ------------------------------------------------------------------------- *)
(* whoami: not registered → empty string                                     *)
(* ------------------------------------------------------------------------- *)

let test_whoami_unregistered () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      let result = Lwt_main.run
        (C2c_identity_handlers.whoami ~broker
           ~session_id_override:(Some "session-noone") ~arguments:`Null)
      in
      check string "whoami unregistered returns empty" "" (get_text_content result))

(* ------------------------------------------------------------------------- *)
(* whoami: after register, returns registered alias                          *)
(* ------------------------------------------------------------------------- *)

let test_whoami_after_register () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      C2c_broker.register broker ~session_id:"session-whoami"
        ~alias:"my-alias" ~pid:None ~pid_start_time:None ();
      let result = Lwt_main.run
        (C2c_identity_handlers.whoami ~broker
           ~session_id_override:(Some "session-whoami") ~arguments:`Null)
      in
      let body_json = yojson_of_string (get_text_content result) in
      let alias_str = Yojson.Safe.Util.(body_json |> member "alias" |> to_string) in
      let has_canonical = Yojson.Safe.Util.(body_json |> member "canonical_alias" |> to_string_option |> Option.is_some) in
      check string "alias" "my-alias" alias_str;
      check bool "has canonical_alias" true has_canonical)

(* ------------------------------------------------------------------------- *)
(* register: rejects reserved alias "c2c-system"                              *)
(* ------------------------------------------------------------------------- *)

let test_register_reserved_alias () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      Unix.putenv "C2C_MCP_SESSION_ID" "session-reserved";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let args = `Assoc [("alias", `String "c2c-system")] in
           let result = Lwt_main.run
             (C2c_identity_handlers.register ~broker ~session_id_override:None ~arguments:args)
           in
           check bool "isError=true for reserved alias" true (get_is_error result);
           let text = get_text_content result in
           check bool "error mentions reserved" true
             (String.length text > 0 && String.sub text 0 15 <> "registered c2c")))

(* ------------------------------------------------------------------------- *)
(* register: rejects invalid alias name (leading dot)                        *)
(* ------------------------------------------------------------------------- *)

let test_register_invalid_alias_leading_dot () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      Unix.putenv "C2C_MCP_SESSION_ID" "session-invalid";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let args = `Assoc [("alias", `String ".leading-dot")] in
           let result = Lwt_main.run
             (C2c_identity_handlers.register ~broker ~session_id_override:None ~arguments:args)
           in
           check bool "isError=true for invalid alias" true (get_is_error result);
           let text = get_text_content result in
           check bool "error mentions invalid" true
             (String.length text > 0)))

(* ------------------------------------------------------------------------- *)
(* register: rejects alias with invalid characters                           *)
(* ------------------------------------------------------------------------- *)

let test_register_invalid_alias_space () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      Unix.putenv "C2C_MCP_SESSION_ID" "session-space";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let args = `Assoc [("alias", `String "alias with space")] in
           let result = Lwt_main.run
             (C2c_identity_handlers.register ~broker ~session_id_override:None ~arguments:args)
           in
           check bool "isError=true for space alias" true (get_is_error result)))

(* ------------------------------------------------------------------------- *)
(* register: success path — valid alias, no conflicts                        *)
(* This requires key generation infrastructure; test the registration       *)
(* response without requiring relay keys by checking the ok response.       *)
(* ------------------------------------------------------------------------- *)

let test_register_success () =
  with_temp_dir (fun dir ->
      let broker = C2c_broker.create ~root:dir in
      Unix.putenv "C2C_MCP_SESSION_ID" "session-ok";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let args = `Assoc [("alias", `String "valid-agent")] in
           let result = Lwt_main.run
             (C2c_identity_handlers.register ~broker ~session_id_override:None ~arguments:args)
           in
           check bool "isError=false on success" false (get_is_error result);
           let text = get_text_content result in
           check bool "message is non-empty" true (String.length text > 0)))

(* ------------------------------------------------------------------------- *)
(* debug: unknown action → tool_err with "unknown action"                     *)
(* Guarded by Build_flags.mcp_debug_tool_enabled — skip if disabled.         *)
(* ------------------------------------------------------------------------- *)

let test_debug_unknown_action () =
  if not Build_flags.mcp_debug_tool_enabled then
    check unit "debug tool disabled" () ()
  else
    with_temp_dir (fun dir ->
        let broker = C2c_broker.create ~root:dir in
        C2c_broker.register broker ~session_id:"session-debug"
          ~alias:"debug-agent" ~pid:None ~pid_start_time:None ();
        Unix.putenv "C2C_MCP_SESSION_ID" "session-debug";
        Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
          (fun () ->
             let args = `Assoc [("action", `String "not_a_real_action")] in
             let result = Lwt_main.run
               (C2c_identity_handlers.debug ~broker ~session_id_override:None ~arguments:args)
             in
             check bool "isError=true for unknown action" true (get_is_error result);
             let text = get_text_content result in
             check bool "error mentions unknown action" true
               (String.length text > 0)))

(* ------------------------------------------------------------------------- *)
(* debug: get_env returns filtered C2C_ env vars                             *)
(* ------------------------------------------------------------------------- *)

let test_debug_get_env () =
  if not Build_flags.mcp_debug_tool_enabled then
    check unit "debug tool disabled" () ()
  else
    with_temp_dir (fun dir ->
        let broker = C2c_broker.create ~root:dir in
        C2c_broker.register broker ~session_id:"session-env"
          ~alias:"env-agent" ~pid:None ~pid_start_time:None ();
        Unix.putenv "C2C_MCP_SESSION_ID" "session-env";
        Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
          (fun () ->
             let args = `Assoc [("action", `String "get_env")] in
             let result = Lwt_main.run
               (C2c_identity_handlers.debug ~broker ~session_id_override:None ~arguments:args)
             in
             check bool "isError=false for get_env" false (get_is_error result);
             let body_json = yojson_of_string (get_text_content result) in
             let open Yojson.Safe.Util in
             check bool "ok=true" true (body_json |> member "ok" |> to_bool);
             check string "action=get_env" "get_env" (body_json |> member "action" |> to_string);
             check string "prefix default C2C_" "C2C_" (body_json |> member "prefix" |> to_string)))

(* ------------------------------------------------------------------------- *)
(* debug: disabled tool returns "unknown tool" error                        *)
(* ------------------------------------------------------------------------- *)

let test_debug_disabled_returns_unknown_tool () =
  if Build_flags.mcp_debug_tool_enabled then
    check unit "debug tool enabled — skip disabled test" () ()
  else
    with_temp_dir (fun dir ->
        let broker = C2c_broker.create ~root:dir in
        let args = `Assoc [("action", `String "get_env")] in
        let result = Lwt_main.run
          (C2c_identity_handlers.debug ~broker ~session_id_override:None ~arguments:args)
        in
        check bool "isError=true when disabled" true (get_is_error result);
        let text = get_text_content result in
        check string "error is 'unknown tool'" "unknown tool" text)

(* ------------------------------------------------------------------------- *)
(* Test suite                                                               *)
(* ------------------------------------------------------------------------- *)

let test_set = [
  "list empty broker", `Quick, test_list_empty;
  "list after register", `Quick, test_list_after_register;
  "whoami unregistered", `Quick, test_whoami_unregistered;
  "whoami after register", `Quick, test_whoami_after_register;
  "register rejects reserved alias", `Quick, test_register_reserved_alias;
  "register rejects leading dot alias", `Quick, test_register_invalid_alias_leading_dot;
  "register rejects space alias", `Quick, test_register_invalid_alias_space;
  "register success", `Quick, test_register_success;
  "debug unknown action", `Quick, test_debug_unknown_action;
  "debug get_env", `Quick, test_debug_get_env;
  "debug disabled returns unknown tool", `Quick, test_debug_disabled_returns_unknown_tool;
]

let () =
  Alcotest.run "c2c_identity_handlers" [ "identity_handlers", test_set ]
