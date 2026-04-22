open Alcotest

let is_valid = C2c_name.is_valid

let valid_cases = [
  ("alice", true); ("bob-42", true); ("my.peer", true); ("oc_coder1", true);
  ("planner1", true); ("a", true); (String.make 64 'x', true);
]

let invalid_cases = [
  ("", false); (String.make 65 'x', false); (".hidden", false); ("foo/bar", false);
  ("a b", false); ("foo\x00bar", false); ("hello!", false); ("foo@bar", false);
  ("space in name", false);
]

let test_valid_cases () =
  List.iter (fun (name, expected) ->
    Alcotest.(check bool) (Printf.sprintf "valid: %S" name) expected (is_valid name)
  ) valid_cases

let test_invalid_cases () =
  List.iter (fun (name, expected) ->
    Alcotest.(check bool) (Printf.sprintf "invalid: %S" name) expected (is_valid name)
  ) invalid_cases

let tests = [
  "valid cases",    `Quick, test_valid_cases;
  "invalid cases", `Quick, test_invalid_cases;
]

let () = Alcotest.run "c2c_name" [ "is_valid", tests ]
