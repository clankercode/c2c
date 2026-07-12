(* test_c2c_gemini_deprecation — Slice S2: Gemini CLI removal + init hint.

   Tests:
   - gemini is NOT in known_clients / init_configurable_clients
   - init no-client hint lists exactly the four supported clients
   - c2c install gemini refuses with exit 1 (subprocess test) *)

let ( // ) = Filename.concat

let contains_substring ~haystack ~needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if nlen = 0 then true
  else if nlen > hlen then false
  else
    let rec match_at i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else match_at (i + 1)
    in
    match_at 0

(* ------------------------------------------------------------------ *)
(* Test 1: gemini absent from known_clients                            *)
(* ------------------------------------------------------------------ *)

let test_gemini_not_in_known_clients () =
  Alcotest.(check bool) "gemini not in known_clients"
    false (List.mem "gemini" C2c_setup.known_clients)

(* ------------------------------------------------------------------ *)
(* Test 2: gemini absent from init_configurable_clients                *)
(* ------------------------------------------------------------------ *)

let test_gemini_not_in_init_configurable () =
  Alcotest.(check bool) "gemini not in init_configurable_clients"
    false (List.mem "gemini" C2c_setup.init_configurable_clients)

(* ------------------------------------------------------------------ *)
(* Test 3: install_subcommand_clients still has gemini for routing     *)
(* (gemini is refused by the deprecation guard in do_install_client)   *)
(* ------------------------------------------------------------------ *)

let test_gemini_in_install_subcommand_for_routing () =
  (* gemini must remain in install_subcommand_clients so Cmdliner recognizes
     the subcommand and routes it to the deprecation guard. *)
  Alcotest.(check bool) "gemini in install_subcommand_clients for routing"
    true (List.mem "gemini" C2c_setup.install_subcommand_clients)

(* ------------------------------------------------------------------ *)
(* Test 4: init_configurable_client_list has the four clients          *)
(* ------------------------------------------------------------------ *)

let test_init_hint_has_four_clients () =
  let list = C2c_setup.init_configurable_client_list in
  Alcotest.(check bool) "has claude" true (contains_substring ~haystack:list ~needle:"claude");
  Alcotest.(check bool) "has codex" true (contains_substring ~haystack:list ~needle:"codex");
  Alcotest.(check bool) "has opencode" true (contains_substring ~haystack:list ~needle:"opencode");
  (* B146: kimi is temporarily filtered out of the init hint while disabled;
     assert its presence only when it is re-enabled. Full kimi-disabled coverage
     lives in test_c2c_kimi_disabled.ml. *)
  (if not C2c_start.kimi_disabled_for_release then
     Alcotest.(check bool) "has kimi" true (contains_substring ~haystack:list ~needle:"kimi"));
  Alcotest.(check bool) "no gemini" false (contains_substring ~haystack:list ~needle:"gemini");
  Alcotest.(check bool) "no crush" false (contains_substring ~haystack:list ~needle:"crush")

(* ------------------------------------------------------------------ *)
(* Test 5: install_client_error_list includes gemini for routing       *)
(* (refused by deprecation guard, not by "unknown client" error)       *)
(* ------------------------------------------------------------------ *)

let test_install_error_list_has_gemini_for_routing () =
  let list = C2c_setup.install_client_error_list in
  Alcotest.(check bool) "gemini in install error list for routing"
    true (contains_substring ~haystack:list ~needle:"gemini")

(* ------------------------------------------------------------------ *)
(* Test 6: c2c install gemini exits non-zero (subprocess)              *)
(* ------------------------------------------------------------------ *)

let find_c2c_binary () =
  let exe = Sys.executable_name in
  let test_dir = Filename.dirname exe in
  let candidate = test_dir // "c2c.exe" in
  if Sys.file_exists candidate then candidate
  else
    Alcotest.fail
      (Printf.sprintf
         "HERMETIC FAIL: cannot find in-worktree c2c.exe at %s \
          (test exe = %s). The dune (deps c2c.exe) stanza must \
          guarantee this file exists."
         candidate exe)

let test_install_gemini_refuses () =
  let c2c_bin = find_c2c_binary () in
  let out = Filename.temp_file "c2c-gemini-test" ".out" in
  let err = Filename.temp_file "c2c-gemini-test" ".err" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove out with _ -> ());
      (try Sys.remove err with _ -> ()))
    (fun () ->
      let cmd = Printf.sprintf "%s install gemini --json > %s 2> %s"
        c2c_bin (Filename.quote out) (Filename.quote err) in
      let rc = Sys.command cmd in
      Alcotest.(check bool) "exits non-zero" true (rc <> 0);
      let stderr = try
        let ic = open_in err in
        Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
          really_input_string ic (in_channel_length ic))
      with _ -> "" in
      let stdout = try
        let ic = open_in out in
        Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
          really_input_string ic (in_channel_length ic))
      with _ -> "" in
      let combined = stdout ^ stderr in
      Alcotest.(check bool) "output mentions DEPRECATED/gemini"
        true (contains_substring ~haystack:combined ~needle:"DEPRECATED"
              || contains_substring ~haystack:combined ~needle:"Gemini"
              || contains_substring ~haystack:combined ~needle:"gemini"))

(* ------------------------------------------------------------------ *)

let () =
  Alcotest.run "c2c_gemini_deprecation"
    [ ("gemini-not-advertised",
        [ Alcotest.test_case "gemini absent from known_clients" `Quick
            test_gemini_not_in_known_clients
        ; Alcotest.test_case "gemini absent from init_configurable_clients" `Quick
            test_gemini_not_in_init_configurable
        ; Alcotest.test_case "gemini in install_subcommand for routing" `Quick
            test_gemini_in_install_subcommand_for_routing
        ; Alcotest.test_case "init hint has four clients, no gemini" `Quick
            test_init_hint_has_four_clients
        ; Alcotest.test_case "install error list has gemini for routing" `Quick
            test_install_error_list_has_gemini_for_routing
        ] )
    ; ("gemini-install-refuses",
        [ Alcotest.test_case "c2c install gemini exits non-zero" `Quick
            test_install_gemini_refuses
        ] )
    ]
