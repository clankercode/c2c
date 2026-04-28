(* test_c2c_health.ml — unit tests for the legacy-broker-root detection
   surfaced by `c2c health` / `c2c doctor` (#352).

   The detector itself is a pure helper in C2c_utils; we test it directly
   plus assert the warning text contains the operator-facing migrate
   command. End-to-end CLI invocation is exercised via the doctor.sh
   smoke and is left out of this module to avoid a binary dependency. *)

open Alcotest

let test_legacy_path_detected () =
  let pinned = "/home/xertrov/src/c2c/.git/c2c/mcp" in
  check bool "legacy .git/c2c/mcp path detected" true
    (C2c_broker_root_check.is_legacy_broker_root pinned)

let test_legacy_path_with_trailing_slash () =
  let pinned = "/some/repo/.git/c2c/mcp/" in
  check bool "legacy path with trailing slash detected" true
    (C2c_broker_root_check.is_legacy_broker_root pinned)

let test_canonical_path_not_flagged () =
  let canonical = "/home/xertrov/.c2c/repos/8fef2c369975/broker" in
  check bool "canonical $HOME/.c2c/repos path NOT flagged" false
    (C2c_broker_root_check.is_legacy_broker_root canonical)

let test_xdg_path_not_flagged () =
  let xdg = "/home/xertrov/.local/state/c2c/repos/abc123/broker" in
  check bool "XDG_STATE_HOME path NOT flagged" false
    (C2c_broker_root_check.is_legacy_broker_root xdg)

let test_empty_path_not_flagged () =
  check bool "empty string NOT flagged" false
    (C2c_broker_root_check.is_legacy_broker_root "");
  check bool "whitespace-only NOT flagged" false
    (C2c_broker_root_check.is_legacy_broker_root "   ")

let test_warning_text_mentions_migrate_command () =
  let warning = C2c_broker_root_check.legacy_broker_warning_text "/some/.git/c2c/mcp" in
  let contains needle =
    let nl = String.length needle and hl = String.length warning in
    let rec loop i =
      if i + nl > hl then false
      else if String.sub warning i nl = needle then true
      else loop (i + 1)
    in
    loop 0
  in
  check bool "warning contains LEGACY label" true (contains "LEGACY");
  check bool "warning contains migrate-broker --dry-run" true
    (contains "c2c migrate-broker --dry-run");
  check bool "warning contains live migrate command" true
    (contains "c2c migrate-broker");
  check bool "warning cites #360 unblock" true (contains "#360");
  check bool "warning shows the resolved root" true
    (contains "/some/.git/c2c/mcp")

let test_canonical_path_no_warning_text_match () =
  (* Sanity: the warning helper emits text only when called; the call-site
     guards on is_legacy_broker_root. Verify the canonical path returns
     false so the call-site won't render the warning at all. *)
  let canonical = "/home/agent/.c2c/repos/deadbeef0001/broker" in
  check bool "canonical path keeps health output clean" false
    (C2c_broker_root_check.is_legacy_broker_root canonical)

let () =
  run "c2c_health"
    [ ( "legacy_broker_detection"
      , [ test_case "legacy path emits warning"   `Quick test_legacy_path_detected
        ; test_case "legacy with trailing slash"  `Quick test_legacy_path_with_trailing_slash
        ; test_case "canonical path no warning"   `Quick test_canonical_path_not_flagged
        ; test_case "XDG path no warning"         `Quick test_xdg_path_not_flagged
        ; test_case "empty path no warning"       `Quick test_empty_path_not_flagged
        ; test_case "warning text content"        `Quick test_warning_text_mentions_migrate_command
        ; test_case "canonical no warning text"   `Quick test_canonical_path_no_warning_text_match
        ] )
    ]
