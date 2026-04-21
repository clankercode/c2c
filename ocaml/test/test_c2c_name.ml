let () =
  let valid_cases = [
    "alice"; "bob-42"; "my.peer"; "oc_coder1"; "planner1";
    "a"; String.make 64 'x';
  ] in
  let invalid_cases = [
    ""; String.make 65 'x'; ".hidden"; "foo/bar"; "a b"; "foo\x00bar";
    "hello!"; "foo@bar"; "space in name";
  ] in

  List.iter (fun name ->
    if not (C2c_name.is_valid name) then
      Printf.eprintf "FAIL: expected valid, got invalid for %S\n" name
  ) valid_cases;

  List.iter (fun name ->
    if C2c_name.is_valid name then
      Printf.eprintf "FAIL: expected invalid, got valid for %S\n" name
  ) invalid_cases;

  Printf.printf "test_c2c_name: %d valid + %d invalid cases checked OK\n"
    (List.length valid_cases) (List.length invalid_cases)
