(* test_c2c_approval_paths.ml — slice 5a unit tests for the file-based
   approval side-channel (#490). *)

let with_tmp_dir f =
  let tmp =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c_approval_paths_test_%d_%f"
         (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  Unix.mkdir tmp 0o700;
  Fun.protect
    ~finally:(fun () ->
      let rec rm path =
        match (Unix.lstat path).st_kind with
        | Unix.S_DIR ->
            Sys.readdir path
            |> Array.iter (fun e -> rm (Filename.concat path e));
            (try Unix.rmdir path with _ -> ())
        | _ -> (try Sys.remove path with _ -> ())
      in
      try rm tmp with _ -> ())
    (fun () -> f tmp)

let test_sanitize_token () =
  Alcotest.(check string)
    "alnum-passthrough" "ka_abc123"
    (C2c_approval_paths.sanitize_token "ka_abc123");
  Alcotest.(check string)
    "dot-dash-underscore-allowed" "a.b-c_d"
    (C2c_approval_paths.sanitize_token "a.b-c_d");
  Alcotest.(check string)
    "slash-becomes-underscore" "ka_a_b"
    (C2c_approval_paths.sanitize_token "ka_a/b");
  Alcotest.(check string)
    "spaces-become-underscore" "a__b"
    (C2c_approval_paths.sanitize_token "a  b");
  Alcotest.(check string)
    "empty-becomes-underscore" "_"
    (C2c_approval_paths.sanitize_token "")

let test_path_layout () =
  with_tmp_dir (fun root ->
      let pdir = C2c_approval_paths.pending_dir ~override_root:root () in
      let vdir = C2c_approval_paths.verdict_dir ~override_root:root () in
      Alcotest.(check string)
        "pending under root"
        (Filename.concat root "approval-pending") pdir;
      Alcotest.(check string)
        "verdict under root"
        (Filename.concat root "approval-verdict") vdir;
      let pf =
        C2c_approval_paths.pending_file ~override_root:root ~token:"ka_x" ()
      in
      Alcotest.(check string)
        "pending file shape"
        (Filename.concat pdir "ka_x.json") pf)

let test_ensure_dirs () =
  with_tmp_dir (fun root ->
      C2c_approval_paths.ensure_dirs ~override_root:root ();
      Alcotest.(check bool)
        "pending exists" true
        (Sys.file_exists
           (C2c_approval_paths.pending_dir ~override_root:root ()));
      Alcotest.(check bool)
        "verdict exists" true
        (Sys.file_exists
           (C2c_approval_paths.verdict_dir ~override_root:root ())))

let test_write_and_read_verdict () =
  with_tmp_dir (fun root ->
      C2c_approval_paths.ensure_dirs ~override_root:root ();
      let token = "ka_test_001" in
      let payload =
        C2c_approval_paths.make_verdict_payload
          ~token ~verdict:"allow" ~reason:""
          ~reviewer_alias:"stanza-coder" ~ts:1234567890
      in
      let _ =
        C2c_approval_paths.write_verdict ~override_root:root
          ~token ~payload ()
      in
      match
        C2c_approval_paths.read_verdict ~override_root:root ~token ()
      with
      | None -> Alcotest.fail "verdict file not readable after write"
      | Some s ->
          Alcotest.(check string) "round-trip" payload s;
          (match C2c_approval_paths.parse_verdict_field s with
           | Some v -> Alcotest.(check string) "verdict field" "allow" v
           | None -> Alcotest.fail "parse_verdict_field returned None"))

let test_parse_verdict_deny () =
  let payload =
    C2c_approval_paths.make_verdict_payload
      ~token:"ka_q" ~verdict:"deny" ~reason:"unsafe rm"
      ~reviewer_alias:"x" ~ts:0
  in
  match C2c_approval_paths.parse_verdict_field payload with
  | Some v -> Alcotest.(check string) "deny extracted" "deny" v
  | None -> Alcotest.fail "parse_verdict_field returned None"

let test_parse_verdict_no_field () =
  let s = "{\"foo\":\"bar\"}" in
  match C2c_approval_paths.parse_verdict_field s with
  | None -> ()
  | Some v ->
      Alcotest.failf "expected None, got %s" v

let test_cleanup () =
  with_tmp_dir (fun root ->
      C2c_approval_paths.ensure_dirs ~override_root:root ();
      let token = "ka_clean" in
      let pl =
        C2c_approval_paths.make_pending_payload
          ~token ~agent_alias:"a" ~tool_name:"Shell"
          ~tool_input:"{}" ~timeout_at:0 ~reviewer_alias:"r"
          ~broker_root:root
      in
      let _ =
        C2c_approval_paths.write_pending ~override_root:root
          ~token ~payload:pl ()
      in
      let vl =
        C2c_approval_paths.make_verdict_payload
          ~token ~verdict:"allow" ~reason:""
          ~reviewer_alias:"r" ~ts:0
      in
      let _ =
        C2c_approval_paths.write_verdict ~override_root:root
          ~token ~payload:vl ()
      in
      C2c_approval_paths.cleanup ~override_root:root ~token ();
      Alcotest.(check bool) "pending gone" false
        (Sys.file_exists
           (C2c_approval_paths.pending_file ~override_root:root ~token ()));
      Alcotest.(check bool) "verdict gone" false
        (Sys.file_exists
           (C2c_approval_paths.verdict_file ~override_root:root ~token ())))

let test_atomic_write_perms () =
  with_tmp_dir (fun root ->
      C2c_approval_paths.ensure_dirs ~override_root:root ();
      let token = "ka_perm" in
      let _ =
        C2c_approval_paths.write_verdict ~override_root:root
          ~token ~payload:"{\"verdict\":\"allow\"}" ()
      in
      let path =
        C2c_approval_paths.verdict_file ~override_root:root ~token ()
      in
      let st = Unix.stat path in
      Alcotest.(check int) "0600 file mode" 0o600 (st.st_perm land 0o777))

(* slice 5b additions *)

let test_list_pending_tokens () =
  with_tmp_dir (fun root ->
      C2c_approval_paths.ensure_dirs ~override_root:root ();
      Alcotest.(check (list string))
        "empty start" []
        (C2c_approval_paths.list_pending_tokens ~override_root:root ());
      let mk t =
        let pl =
          C2c_approval_paths.make_pending_payload
            ~token:t ~agent_alias:"a" ~tool_name:"Shell"
            ~tool_input:"{}" ~timeout_at:0 ~reviewer_alias:"r"
            ~broker_root:root
        in
        ignore
          (C2c_approval_paths.write_pending ~override_root:root
             ~token:t ~payload:pl ())
      in
      mk "ka_a";
      mk "ka_b";
      mk "ka_c";
      Alcotest.(check (list string))
        "three sorted"
        [ "ka_a"; "ka_b"; "ka_c" ]
        (C2c_approval_paths.list_pending_tokens ~override_root:root ()))

let test_has_verdict () =
  with_tmp_dir (fun root ->
      C2c_approval_paths.ensure_dirs ~override_root:root ();
      Alcotest.(check bool) "no verdict initially" false
        (C2c_approval_paths.has_verdict ~override_root:root ~token:"ka_x" ());
      let _ =
        C2c_approval_paths.write_verdict ~override_root:root ~token:"ka_x"
          ~payload:"{\"verdict\":\"allow\"}" ()
      in
      Alcotest.(check bool) "verdict present after write" true
        (C2c_approval_paths.has_verdict ~override_root:root ~token:"ka_x" ()))

let test_read_pending () =
  with_tmp_dir (fun root ->
      C2c_approval_paths.ensure_dirs ~override_root:root ();
      Alcotest.(check (option string))
        "missing file -> None" None
        (C2c_approval_paths.read_pending ~override_root:root
           ~token:"ka_unknown" ());
      let pl =
        C2c_approval_paths.make_pending_payload
          ~token:"ka_y" ~agent_alias:"k" ~tool_name:"Shell"
          ~tool_input:"{\"x\":1}" ~timeout_at:42 ~reviewer_alias:"r"
          ~broker_root:root
      in
      let _ =
        C2c_approval_paths.write_pending ~override_root:root
          ~token:"ka_y" ~payload:pl ()
      in
      match
        C2c_approval_paths.read_pending ~override_root:root ~token:"ka_y" ()
      with
      | None -> Alcotest.fail "read_pending None after write"
      | Some s -> Alcotest.(check string) "round-trip" pl s)

(* slice 5c additions *)

let test_list_verdict_tokens () =
  with_tmp_dir (fun root ->
      C2c_approval_paths.ensure_dirs ~override_root:root ();
      Alcotest.(check (list string))
        "empty start" []
        (C2c_approval_paths.list_verdict_tokens ~override_root:root ());
      let _ =
        C2c_approval_paths.write_verdict ~override_root:root
          ~token:"ka_v1" ~payload:"{\"verdict\":\"allow\"}" ()
      in
      let _ =
        C2c_approval_paths.write_verdict ~override_root:root
          ~token:"ka_v2" ~payload:"{\"verdict\":\"deny\"}" ()
      in
      Alcotest.(check (list string))
        "two sorted"
        [ "ka_v1"; "ka_v2" ]
        (C2c_approval_paths.list_verdict_tokens ~override_root:root ()))

let test_parse_int_field () =
  Alcotest.(check (option int)) "present"
    (Some 1234567890)
    (C2c_approval_paths.parse_int_field
       "{\"timeout_at\":1234567890,\"x\":1}" "timeout_at");
  Alcotest.(check (option int)) "missing"
    None
    (C2c_approval_paths.parse_int_field "{\"foo\":1}" "timeout_at");
  Alcotest.(check (option int)) "negative"
    (Some (-1))
    (C2c_approval_paths.parse_int_field "{\"x\":-1}" "x");
  Alcotest.(check (option int)) "string-value not int"
    None
    (C2c_approval_paths.parse_int_field "{\"x\":\"abc\"}" "x")

let test_read_pending_timeout_at () =
  with_tmp_dir (fun root ->
      C2c_approval_paths.ensure_dirs ~override_root:root ();
      let pl =
        C2c_approval_paths.make_pending_payload
          ~token:"ka_t" ~agent_alias:"a" ~tool_name:"Shell"
          ~tool_input:"{}" ~timeout_at:9876 ~reviewer_alias:"r"
          ~broker_root:root
      in
      let _ =
        C2c_approval_paths.write_pending ~override_root:root
          ~token:"ka_t" ~payload:pl ()
      in
      Alcotest.(check (option int)) "round-trip"
        (Some 9876)
        (C2c_approval_paths.read_pending_timeout_at
           ~override_root:root ~token:"ka_t" ()))

(* #506 additions *)

let test_parse_string_field () =
  Alcotest.(check (option string))
    "present"
    (Some "/home/user/.c2c/repos/abc123/broker")
    (C2c_approval_paths.parse_string_field
       "{\"broker_root\":\"/home/user/.c2c/repos/abc123/broker\",\"token\":\"ka_x\"}"
       "broker_root");
  Alcotest.(check (option string))
    "missing field"
    None
    (C2c_approval_paths.parse_string_field
       "{\"token\":\"ka_x\"}" "broker_root");
  Alcotest.(check (option string))
    "empty string value"
    (Some "")
    (C2c_approval_paths.parse_string_field
       "{\"broker_root\":\"\",\"token\":\"ka_x\"}" "broker_root");
  Alcotest.(check (option string))
    "with escaped chars"
    (Some "/home/user/a b")
    (C2c_approval_paths.parse_string_field
       "{\"broker_root\":\"/home/user/a b\",\"token\":\"ka_x\"}" "broker_root")

let test_broker_root_in_pending_payload () =
  with_tmp_dir (fun root ->
      let pl =
        C2c_approval_paths.make_pending_payload
          ~token:"ka_br" ~agent_alias:"a" ~tool_name:"Shell"
          ~tool_input:"{}" ~timeout_at:0 ~reviewer_alias:"r"
          ~broker_root:root
      in
      Alcotest.(check (option string))
        "broker_root round-trips through payload"
        (Some root)
        (C2c_approval_paths.parse_string_field pl "broker_root"))

let test_read_pending_broker_root () =
  with_tmp_dir (fun root ->
      C2c_approval_paths.ensure_dirs ~override_root:root ();
      let pl =
        C2c_approval_paths.make_pending_payload
          ~token:"ka_rb" ~agent_alias:"a" ~tool_name:"Shell"
          ~tool_input:"{}" ~timeout_at:0 ~reviewer_alias:"r"
          ~broker_root:root
      in
      let _ =
        C2c_approval_paths.write_pending ~override_root:root
          ~token:"ka_rb" ~payload:pl ()
      in
      match
        C2c_approval_paths.read_pending ~override_root:root ~token:"ka_rb" ()
      with
      | None -> Alcotest.fail "read_pending None after write"
      | Some s ->
          Alcotest.(check (option string))
            "read_pending preserves broker_root field"
            (Some root)
            (C2c_approval_paths.parse_string_field s "broker_root"))

let () =
  Alcotest.run "c2c_approval_paths"
    [
      ( "core",
        [
          Alcotest.test_case "sanitize_token" `Quick test_sanitize_token;
          Alcotest.test_case "path_layout" `Quick test_path_layout;
          Alcotest.test_case "ensure_dirs" `Quick test_ensure_dirs;
          Alcotest.test_case "write+read verdict" `Quick
            test_write_and_read_verdict;
          Alcotest.test_case "parse_verdict deny" `Quick
            test_parse_verdict_deny;
          Alcotest.test_case "parse_verdict no field" `Quick
            test_parse_verdict_no_field;
          Alcotest.test_case "cleanup" `Quick test_cleanup;
          Alcotest.test_case "atomic write perms" `Quick
            test_atomic_write_perms;
          Alcotest.test_case "list_pending_tokens" `Quick
            test_list_pending_tokens;
          Alcotest.test_case "has_verdict" `Quick test_has_verdict;
          Alcotest.test_case "read_pending" `Quick test_read_pending;
          Alcotest.test_case "list_verdict_tokens" `Quick
            test_list_verdict_tokens;
           Alcotest.test_case "parse_int_field" `Quick test_parse_int_field;
           Alcotest.test_case "read_pending_timeout_at" `Quick
             test_read_pending_timeout_at;
           Alcotest.test_case "parse_string_field" `Quick
             test_parse_string_field;
           Alcotest.test_case "broker_root in payload" `Quick
             test_broker_root_in_pending_payload;
           Alcotest.test_case "read_pending preserves broker_root" `Quick
             test_read_pending_broker_root;
         ] );
    ]
