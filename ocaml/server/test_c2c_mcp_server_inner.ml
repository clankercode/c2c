(* #346: test auto_drain_channel_enabled default-flip *)
open Alcotest

let set_env v = Unix.putenv "C2C_MCP_AUTO_DRAIN_CHANNEL" v
let clear_env () = set_env ""

let test_default_true_when_env_unset () =
  (* Env is not set; verify default is now true (was false pre-#346). *)
  clear_env ();
  check bool "default is true when env unset" true
    (C2c_mcp_server_inner.auto_drain_channel_enabled ())

let test_parses_zero_as_false () =
  set_env "0";
  check bool "0 → false" false (C2c_mcp_server_inner.auto_drain_channel_enabled ());
  set_env "false";
  check bool "false → false" false (C2c_mcp_server_inner.auto_drain_channel_enabled ());
  set_env "off";
  check bool "off → false" false (C2c_mcp_server_inner.auto_drain_channel_enabled ());
  clear_env ()

let test_parses_one_as_true () =
  set_env "1";
  check bool "1 → true" true (C2c_mcp_server_inner.auto_drain_channel_enabled ());
  set_env "true";
  check bool "true → true" true (C2c_mcp_server_inner.auto_drain_channel_enabled ());
  set_env "yes";
  check bool "yes → true" true (C2c_mcp_server_inner.auto_drain_channel_enabled ());
  clear_env ()

let test_parses_case_insensitive () =
  set_env "FALSE";
  check bool "FALSE → false" false (C2c_mcp_server_inner.auto_drain_channel_enabled ());
  set_env "True";
  check bool "True → true" true (C2c_mcp_server_inner.auto_drain_channel_enabled ());
  set_env "  1  ";
  check bool "whitespace-padded 1 → true" true (C2c_mcp_server_inner.auto_drain_channel_enabled ());
  clear_env ()

let env_lookup env key =
  Array.to_list env |> List.find_map (fun entry ->
    let prefix = key ^ "=" in
    if String.starts_with ~prefix entry then
      Some (String.sub entry (String.length prefix) (String.length entry - String.length prefix))
    else None)

let test_hermes_connection_env () =
  let foreign = [| "HOME=/fixture/home"; "PATH=/fixture/bin"; "HERMES_HOME=/fixture/hermes"
    ; "C2C_MCP_SESSION_ID=codex-foreign"; "C2C_MCP_AUTO_REGISTER_ALIAS=foreign"
    ; "C2C_MCP_CLIENT_PID=1"; "C2C_MCP_BROKER_ROOT=/foreign/broker"
    ; "C2C_STATE_HOME=/foreign/state"; "C2C_CODEX_APPSERVER_SESSION=foreign"
    ; "CODEX_THREAD_ID=foreign"; "CLAUDE_SESSION_ID=foreign"; "KIMI_SESSION_ID=foreign"
    ; "C2C_MCP_FORCE_CAPABILITIES=claude/channel"; "C2C_TMUX_LOCATION=foreign"
    ; "C2C_HERMES_CONNECTION_READY=foreign"; "HERDR_PANE_ID=foreign"
    ; "C2C_MCP_DISABLED=1"; "C2C_HOST_OWNED_MAILBOX=1"; "C2C_NO_AUTO_REGISTER=1" |] in
  let make () = C2c_mcp_server_inner.hermes_connection_env ~broker_root:None foreign in
  let env = make () in
  let get = env_lookup env in
  let sid = Option.get (get "C2C_MCP_SESSION_ID") in
  check bool "unique connection identity" true (String.starts_with ~prefix:"hermes-mcp-" sid);
  check (option string) "alias belongs to connection" (Some sid) (get "C2C_MCP_AUTO_REGISTER_ALIAS");
  check bool "different connection gets new identity" true
    (get "C2C_MCP_SESSION_ID" <> env_lookup (make ()) "C2C_MCP_SESSION_ID");
  check (option string) "server owns PID" (Some (string_of_int (Unix.getpid ()))) (get "C2C_MCP_CLIENT_PID");
  check (option string) "Hermes client" (Some "hermes") (get "C2C_MCP_CLIENT_TYPE");
  List.iter (fun key -> check (option string) ("scrubbed " ^ key) None (get key))
    [ "C2C_MCP_BROKER_ROOT"; "C2C_STATE_HOME"; "C2C_CODEX_APPSERVER_SESSION"
    ; "CODEX_THREAD_ID"; "CLAUDE_SESSION_ID"; "KIMI_SESSION_ID"
    ; "C2C_TMUX_LOCATION"; "HERDR_PANE_ID"; "C2C_MCP_FORCE_CAPABILITIES" ];
  List.iter (fun key -> check (option string) ("prohibition retained " ^ key) (Some "1") (get key))
    [ "C2C_MCP_DISABLED"; "C2C_HOST_OWNED_MAILBOX"; "C2C_NO_AUTO_REGISTER" ];
  List.iter (fun key -> check (option string) ("delivery opt-out " ^ key) (Some "0") (get key))
    [ "C2C_MCP_CHANNEL_DELIVERY"; "C2C_MCP_AUTO_DRAIN_CHANNEL"; "C2C_MCP_SCHEDULE_TIMER" ];
  check (option string) "Hermes active home preserved" (Some "/fixture/hermes") (get "HERMES_HOME");
  check (option string) "explicit root retained" (Some "/intentional/broker")
    (env_lookup (C2c_mcp_server_inner.hermes_connection_env ~broker_root:(Some "/intentional/broker") foreign)
       "C2C_MCP_BROKER_ROOT")

let test_hermes_metadata_isolation () =
  let request = `Assoc ["method", `String "tools/call"; "params", `Assoc
    ["name", `String "whoami"; "arguments", `Assoc [];
     "_meta", `Assoc ["x-codex-turn-metadata", `Assoc ["session_id", `String "foreign"];
                       "keep", `String "metadata"]]] in
  let saved = Sys.getenv_opt "C2C_HERMES_CONNECTION_READY" in
  Fun.protect ~finally:(fun () -> Unix.putenv "C2C_HERMES_CONNECTION_READY" (Option.value saved ~default:""))
    (fun () ->
      Unix.putenv "C2C_HERMES_CONNECTION_READY" "";
      check bool "generic client routing unchanged" true
        (C2c_mcp_server_inner.connection_request request = request);
      Unix.putenv "C2C_HERMES_CONNECTION_READY" (string_of_int (Unix.getpid ()));
      let clean = C2c_mcp_server_inner.connection_request request in
      let open Yojson.Safe.Util in
      check bool "connection ignores foreign session metadata" true
        (clean |> member "params" |> member "_meta" |> member "x-codex-turn-metadata" = `Null);
      check string "other metadata preserved" "metadata"
        (clean |> member "params" |> member "_meta" |> member "keep" |> to_string))

let test_hermes_rejects_foreign_session () =
  let keys = ["C2C_HERMES_CONNECTION_READY"; "C2C_MCP_SESSION_ID"] in
  let saved = List.map (fun k -> k, Sys.getenv_opt k) keys in
  Fun.protect ~finally:(fun () -> List.iter (fun (k, v) -> Unix.putenv k (Option.value v ~default:"")) saved)
    (fun () ->
      Unix.putenv "C2C_HERMES_CONNECTION_READY" (string_of_int (Unix.getpid ()));
      Unix.putenv "C2C_MCP_SESSION_ID" "owned-connection";
      List.iter (fun tool ->
        let request = `Assoc ["id", `Int 1; "method", `String "tools/call";
          "params", `Assoc ["name", `String tool; "arguments", `Assoc ["session_id", `String "foreign"]]] in
        let response = Lwt_main.run
          (C2c_mcp_server_inner.handle_connection_request ~broker_root:"/must-not-be-created" request) in
        let open Yojson.Safe.Util in
        check bool (tool ^ " refuses foreign session") true
          (Option.get response |> member "result" |> member "isError" |> to_bool))
        ["whoami"; "register"; "poll_inbox"; "rename"; "send"])

let () =
  run "c2c_mcp_server_inner"
    [ ( "B376 connection identity",
        [ test_case "scrub foreign env and mint identity" `Quick test_hermes_connection_env
        ; test_case "isolate per-request thread metadata" `Quick test_hermes_metadata_isolation
        ; test_case "refuse foreign session argument" `Quick test_hermes_rejects_foreign_session ])
    ; ( "#346 auto_drain_channel_enabled default-flip",
        [ test_case "default true when env unset" `Quick test_default_true_when_env_unset
        ; test_case "0/false/off → false" `Quick test_parses_zero_as_false
        ; test_case "1/true/yes → true" `Quick test_parses_one_as_true
        ; test_case "case-insensitive + whitespace trimmed" `Quick test_parses_case_insensitive
        ] )
    ]
