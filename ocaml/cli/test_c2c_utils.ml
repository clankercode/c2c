(* test_c2c_utils.ml — tests for C2c_utils helpers *)

(* Replicates the with_env pattern from test_c2c_stats.ml:
   Unix.putenv key "" to unset, Fun.protect for cleanup. *)
let with_env key value f =
  let old = Sys.getenv_opt key in
  (match value with
   | "" -> Unix.putenv key ""
   | v -> Unix.putenv key v);
  Fun.protect ~finally:(fun () ->
    match old with
    | Some v -> Unix.putenv key v
    | None -> ())
    f

let test_some_trimmed () =
  (* Whitespace-only values are treated as absent (matches C2c_utils behavior) *)
  Alcotest.(check (option string)) "whitespace-only → None"
    None
    (with_env "C2C_MCP_AUTO_REGISTER_ALIAS" "   " (fun () -> C2c_utils.alias_from_env_only ()))

let test_some_with_whitespace () =
  Alcotest.(check (option string)) "spaces around value trimmed"
    (Some "peer-alias")
    (with_env "C2C_MCP_AUTO_REGISTER_ALIAS" "  peer-alias  " (fun () -> C2c_utils.alias_from_env_only ()))

let test_none_on_empty () =
  Alcotest.(check (option string)) "empty string → None"
    None
    (with_env "C2C_MCP_AUTO_REGISTER_ALIAS" "" (fun () -> C2c_utils.alias_from_env_only ()))

let test_some_plain () =
  Alcotest.(check (option string)) "plain value → Some"
    (Some "test-alias")
    (with_env "C2C_MCP_AUTO_REGISTER_ALIAS" "test-alias" (fun () -> C2c_utils.alias_from_env_only ()))

(* Tests for trimmed_env_value (#518): treats empty-string env values as unset. *)
let test_trimmed_env_empty_string () =
  Alcotest.(check (option string)) "empty string → None"
    None
    (with_env "C2C_TEST_TRIMMED_518" "" (fun () -> C2c_utils.trimmed_env_value "C2C_TEST_TRIMMED_518"))

let test_trimmed_env_whitespace_only () =
  Alcotest.(check (option string)) "whitespace-only → None"
    None
    (with_env "C2C_TEST_TRIMMED_518" "   " (fun () -> C2c_utils.trimmed_env_value "C2C_TEST_TRIMMED_518"))

let test_trimmed_env_value_trimmed () =
  Alcotest.(check (option string)) "value with surrounding whitespace → trimmed"
    (Some "/my/broker/root")
    (with_env "C2C_TEST_TRIMMED_518" "  /my/broker/root  " (fun () -> C2c_utils.trimmed_env_value "C2C_TEST_TRIMMED_518"))

let test_trimmed_env_plain () =
  Alcotest.(check (option string)) "plain value → Some"
    (Some "/canonical/broker/root")
    (with_env "C2C_TEST_TRIMMED_518" "/canonical/broker/root" (fun () -> C2c_utils.trimmed_env_value "C2C_TEST_TRIMMED_518"))

let () =
  Alcotest.run "c2c_utils" [
    "alias_from_env_only", [
      Alcotest.test_case "whitespace-only → None"   `Quick test_some_trimmed;
      Alcotest.test_case "spaces trimmed"           `Quick test_some_with_whitespace;
      Alcotest.test_case "empty string → None"     `Quick test_none_on_empty;
      Alcotest.test_case "Some plain"              `Quick test_some_plain;
    ];
    "trimmed_env_value", [
      Alcotest.test_case "empty string → None"        `Quick test_trimmed_env_empty_string;
      Alcotest.test_case "whitespace-only → None"     `Quick test_trimmed_env_whitespace_only;
      Alcotest.test_case "value trimmed"               `Quick test_trimmed_env_value_trimmed;
      Alcotest.test_case "plain value → Some"         `Quick test_trimmed_env_plain;
    ]
  ]
