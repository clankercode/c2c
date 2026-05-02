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

let () =
  run "c2c_mcp_server_inner"
    [ ( "#346 auto_drain_channel_enabled default-flip",
        [ test_case "default true when env unset" `Quick test_default_true_when_env_unset
        ; test_case "0/false/off → false" `Quick test_parses_zero_as_false
        ; test_case "1/true/yes → true" `Quick test_parses_one_as_true
        ; test_case "case-insensitive + whitespace trimmed" `Quick test_parses_case_insensitive
        ] )
    ]
