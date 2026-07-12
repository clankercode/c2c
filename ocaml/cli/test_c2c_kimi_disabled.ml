(* test_c2c_kimi_disabled — B146: kimi support temporarily disabled for release.

   Covers the SOFT/temporary disable:
   - the single toggle C2c_start.kimi_disabled_for_release is on;
   - kimi is filtered out of the advertised client lists (known_clients,
     init_configurable_clients) so `c2c install all` / `c2c init` skip it;
   - kimi STAYS in install_subcommand_clients + start_clients so an explicit
     `c2c install kimi` / `c2c start kimi` routes to the friendly disabled
     banner (exit 1) rather than an "unknown client" error.

   When kimi is re-enabled (flip the flag to [false]), this whole test file is
   part of the revert — delete it (or invert the assertions). Every assertion
   here is guarded on the flag so the suite stays self-consistent if the flag is
   flipped without deleting the file. *)

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

let disabled = C2c_start.kimi_disabled_for_release

(* ------------------------------------------------------------------ *)
(* Test 1: the single toggle is ON for this release                    *)
(* ------------------------------------------------------------------ *)

let test_flag_is_on () =
  Alcotest.(check bool) "kimi_disabled_for_release is true for this release"
    true disabled

(* ------------------------------------------------------------------ *)
(* Test 2: kimi absent from known_clients while disabled               *)
(* (so `c2c install all` does not iterate — and exit-1 — on kimi)       *)
(* ------------------------------------------------------------------ *)

let test_kimi_not_in_known_clients () =
  if disabled then
    Alcotest.(check bool) "kimi not in known_clients"
      false (List.mem "kimi" C2c_setup.known_clients)

(* ------------------------------------------------------------------ *)
(* Test 3: kimi absent from init_configurable_clients while disabled   *)
(* ------------------------------------------------------------------ *)

let test_kimi_not_in_init_configurable () =
  if disabled then
    Alcotest.(check bool) "kimi not in init_configurable_clients"
      false (List.mem "kimi" C2c_setup.init_configurable_clients)

(* ------------------------------------------------------------------ *)
(* Test 4: kimi STILL in install_subcommand_clients for routing        *)
(* (refused by the disabled guard, not by "unknown client")            *)
(* ------------------------------------------------------------------ *)

let test_kimi_in_install_subcommand_for_routing () =
  Alcotest.(check bool) "kimi in install_subcommand_clients for routing"
    true (List.mem "kimi" C2c_setup.install_subcommand_clients)

(* ------------------------------------------------------------------ *)
(* Test 5: init hint lists the still-supported clients, not kimi       *)
(* ------------------------------------------------------------------ *)

let test_init_hint_drops_kimi () =
  let list = C2c_setup.init_configurable_client_list in
  Alcotest.(check bool) "has claude" true (contains_substring ~haystack:list ~needle:"claude");
  Alcotest.(check bool) "has codex" true (contains_substring ~haystack:list ~needle:"codex");
  Alcotest.(check bool) "has opencode" true (contains_substring ~haystack:list ~needle:"opencode");
  if disabled then
    Alcotest.(check bool) "no kimi" false (contains_substring ~haystack:list ~needle:"kimi")

(* ------------------------------------------------------------------ *)
(* Subprocess helper                                                    *)
(* ------------------------------------------------------------------ *)

let find_c2c_binary () =
  let exe = Sys.executable_name in
  let test_dir = Filename.dirname exe in
  let candidate = test_dir // "c2c.exe" in
  if Sys.file_exists candidate then candidate
  else
    Alcotest.fail
      (Printf.sprintf
         "HERMETIC FAIL: cannot find in-worktree c2c.exe at %s (test exe = %s). \
          The dune (deps c2c.exe) stanza must guarantee this file exists."
         candidate exe)

let read_file p =
  try
    let ic = open_in p in
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  with _ -> ""

let run_and_capture cmd =
  let out = Filename.temp_file "c2c-kimi-disabled" ".out" in
  let err = Filename.temp_file "c2c-kimi-disabled" ".err" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove out with _ -> ());
      (try Sys.remove err with _ -> ()))
    (fun () ->
      let full = Printf.sprintf "%s > %s 2> %s" cmd
        (Filename.quote out) (Filename.quote err) in
      let rc = Sys.command full in
      (rc, read_file out ^ read_file err))

(* ------------------------------------------------------------------ *)
(* Test 6: c2c install kimi exits non-zero + mentions disabled         *)
(* ------------------------------------------------------------------ *)

let test_install_kimi_refuses () =
  if not disabled then ()
  else begin
    let c2c_bin = find_c2c_binary () in
    let rc, combined =
      run_and_capture (Printf.sprintf "%s install kimi --json" c2c_bin) in
    Alcotest.(check bool) "install kimi exits non-zero" true (rc <> 0);
    Alcotest.(check bool) "output signals a temporary disable"
      true
      (contains_substring ~haystack:combined ~needle:"disabled"
       || contains_substring ~haystack:combined ~needle:"DISABLED"
       || contains_substring ~haystack:combined ~needle:"temporarily")
  end

(* ------------------------------------------------------------------ *)
(* Test 7: c2c start kimi exits non-zero + mentions disabled           *)
(* ------------------------------------------------------------------ *)

let test_start_kimi_refuses () =
  if not disabled then ()
  else begin
    let c2c_bin = find_c2c_binary () in
    let rc, combined =
      run_and_capture (Printf.sprintf "%s start kimi kimi-disabled-test" c2c_bin) in
    Alcotest.(check bool) "start kimi exits non-zero" true (rc <> 0);
    Alcotest.(check bool) "output signals a temporary disable"
      true
      (contains_substring ~haystack:combined ~needle:"disabled"
       || contains_substring ~haystack:combined ~needle:"DISABLED"
       || contains_substring ~haystack:combined ~needle:"temporarily")
  end

let () =
  Alcotest.run "c2c_kimi_disabled"
    [ ( "kimi-not-advertised",
        [ Alcotest.test_case "toggle on for this release" `Quick test_flag_is_on
        ; Alcotest.test_case "kimi absent from known_clients" `Quick
            test_kimi_not_in_known_clients
        ; Alcotest.test_case "kimi absent from init_configurable_clients" `Quick
            test_kimi_not_in_init_configurable
        ; Alcotest.test_case "kimi in install_subcommand for routing" `Quick
            test_kimi_in_install_subcommand_for_routing
        ; Alcotest.test_case "init hint drops kimi" `Quick test_init_hint_drops_kimi
        ] )
    ; ( "kimi-refuses",
        [ Alcotest.test_case "c2c install kimi exits non-zero" `Quick
            test_install_kimi_refuses
        ; Alcotest.test_case "c2c start kimi exits non-zero" `Quick
            test_start_kimi_refuses
        ] )
    ]
