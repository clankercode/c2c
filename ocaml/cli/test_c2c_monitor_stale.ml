(* Hermetic unit tests for C2c_monitor_stale (I013). *)

module S = C2c_monitor_stale

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc contents)

let tmp_file ~suffix contents =
  let path = Filename.temp_file "c2c_mon_stale" suffix in
  write_file path contents;
  path

(* ---------- shell_quote / reconstruct ---------- *)

let test_shell_quote_safe () =
  Alcotest.(check string) "safe token unquoted" "c2c" (S.shell_quote "c2c");
  Alcotest.(check string) "path unquoted" "/home/x/.local/bin/c2c"
    (S.shell_quote "/home/x/.local/bin/c2c");
  Alcotest.(check string) "flag unquoted" "--broker-root"
    (S.shell_quote "--broker-root")

let test_shell_quote_spaces () =
  Alcotest.(check string) "spaces quoted" "'/tmp/my dir/broker'"
    (S.shell_quote "/tmp/my dir/broker")

let test_shell_quote_single_quote () =
  Alcotest.(check string) "embedded single quote"
    "'foo'\"'\"'bar'" (S.shell_quote "foo'bar")

let test_reconstruct_preserves_argv () =
  let argv =
    [| "/home/x/.local/bin/c2c"
     ; "monitor"
     ; "--alias"
     ; "lyra-quill"
     ; "--broker-root"
     ; "/tmp/my broker"
     ; "--relay-interval"
     ; "5.0"
    |]
  in
  let cmd = S.reconstruct_monitor_command ~argv () in
  Alcotest.(check string) "exact relaunch"
    "/home/x/.local/bin/c2c monitor --alias lyra-quill --broker-root '/tmp/my broker' --relay-interval 5.0"
    cmd

let test_reconstruct_empty_argv () =
  Alcotest.(check string) "empty argv fallback" "c2c monitor"
    (S.reconstruct_monitor_command ~argv:[||] ())

(* ---------- decide_binary_verdict ---------- *)

let action_label = function
  | S.Continue -> "continue"
  | S.Exit_stale r -> "exit:" ^ S.reason_label r

let action_testable =
  Alcotest.testable
    (fun ppf a -> Format.pp_print_string ppf (action_label a))
    (fun a b -> action_label a = action_label b)

let test_stale_verdict_exits () =
  Alcotest.check action_testable "Stale → exit" (S.Exit_stale S.Binary_upgraded)
    (S.decide_binary_verdict C2c_stale.Stale)

let test_current_continues () =
  Alcotest.check action_testable "Current → continue" S.Continue
    (S.decide_binary_verdict C2c_stale.Current)

let test_unknown_continues () =
  Alcotest.check action_testable "Unknown → continue" S.Continue
    (S.decide_binary_verdict (C2c_stale.Unknown "gone"))

(* ---------- format / json ---------- *)

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec go i =
      if i > hl - nl then false
      else if String.sub haystack i nl = needle then true
      else go (i + 1)
    in
    go 0

let test_format_contains_relaunch () =
  let msg =
    S.format_stale_exit ~now_hms:"[12:00:00]" ~reason:S.Binary_upgraded
      ~relaunch_command:"c2c monitor --alias me" ()
  in
  Alcotest.(check bool) "mentions stale" true
    (contains ~haystack:msg ~needle:"stale");
  Alcotest.(check bool) "has relaunch line" true
    (contains ~haystack:msg ~needle:"Relaunch with: c2c monitor --alias me");
  Alcotest.(check bool) "no auto-respawn note" true
    (contains ~haystack:msg ~needle:"do not auto-respawn")

let test_json_event_type () =
  let j =
    S.stale_exit_json ~reason:S.Binary_upgraded
      ~relaunch_command:"c2c monitor --json"
  in
  match j with
  | `Assoc fields ->
      Alcotest.(check (option string)) "event_type"
        (Some "monitor.stale-exit")
        (match List.assoc_opt "event_type" fields with
         | Some (`String s) -> Some s
         | _ -> None);
      Alcotest.(check (option string)) "reason"
        (Some "binary_upgraded")
        (match List.assoc_opt "reason" fields with
         | Some (`String s) -> Some s
         | _ -> None);
      Alcotest.(check (option string)) "relaunch_command"
        (Some "c2c monitor --json")
        (match List.assoc_opt "relaunch_command" fields with
         | Some (`String s) -> Some s
         | _ -> None)
  | _ -> Alcotest.fail "expected assoc"

(* ---------- resolve_installed_exe ---------- *)

let test_resolve_prefers_regular_argv0 () =
  let f = tmp_file ~suffix:".bin" "fake-c2c-image" in
  match S.resolve_installed_exe ~argv0:f ~home:"/nonexistent-home-for-test" () with
  | Some p -> Alcotest.(check string) "argv0 wins" f p
  | None -> Alcotest.fail "expected Some"

let test_resolve_skips_proc () =
  (* Even if argv0 is /proc/self/exe, it must not be chosen as installed. *)
  match
    S.resolve_installed_exe ~argv0:"/proc/self/exe"
      ~home:"/nonexistent-home-for-test" ()
  with
  | Some p when String.length p >= 6 && String.sub p 0 6 = "/proc/" ->
      Alcotest.fail ("must not return /proc path: " ^ p)
  | Some _ | None -> () (* ok: either nothing, or a non-proc fallback *)

(* ---------- end-to-end pure: compare_images feeds decide ---------- *)

let test_different_content_decides_exit () =
  let a = tmp_file ~suffix:".bin" "running-image-AAAA" in
  let b = tmp_file ~suffix:".bin" "installed-image-BBBB" in
  let v = C2c_stale.compare_images ~target:a ~installed:b in
  Alcotest.check action_testable "diff images → exit"
    (S.Exit_stale S.Binary_upgraded) (S.decide_binary_verdict v)

let test_same_content_decides_continue () =
  let a = tmp_file ~suffix:".bin" "same-bytes" in
  let b = tmp_file ~suffix:".bin" "same-bytes" in
  let v = C2c_stale.compare_images ~target:a ~installed:b in
  Alcotest.check action_testable "same content → continue" S.Continue
    (S.decide_binary_verdict v)

let () =
  Alcotest.run "c2c_monitor_stale"
    [ ( "shell_quote",
        [ Alcotest.test_case "safe tokens unquoted" `Quick test_shell_quote_safe
        ; Alcotest.test_case "spaces quoted" `Quick test_shell_quote_spaces
        ; Alcotest.test_case "single quote escaped" `Quick
            test_shell_quote_single_quote
        ] )
    ; ( "reconstruct",
        [ Alcotest.test_case "preserves argv" `Quick
            test_reconstruct_preserves_argv
        ; Alcotest.test_case "empty argv fallback" `Quick
            test_reconstruct_empty_argv
        ] )
    ; ( "decide",
        [ Alcotest.test_case "stale exits" `Quick test_stale_verdict_exits
        ; Alcotest.test_case "current continues" `Quick test_current_continues
        ; Alcotest.test_case "unknown continues" `Quick test_unknown_continues
        ; Alcotest.test_case "diff content → exit" `Quick
            test_different_content_decides_exit
        ; Alcotest.test_case "same content → continue" `Quick
            test_same_content_decides_continue
        ] )
    ; ( "format",
        [ Alcotest.test_case "format has relaunch" `Quick
            test_format_contains_relaunch
        ; Alcotest.test_case "json event shape" `Quick test_json_event_type
        ] )
    ; ( "resolve",
        [ Alcotest.test_case "prefers regular argv0" `Quick
            test_resolve_prefers_regular_argv0
        ; Alcotest.test_case "skips /proc paths" `Quick test_resolve_skips_proc
        ] )
    ]
