(* test_c2c_kimi_hook — slice 2 of #142.

   Covers:
   - Embedded artifacts are non-empty + well-formed
   - Marker substring is present in the rendered template
   - Idempotent toml-append (run twice -> single block)
   - Script install writes file with 0755
   - render_toml_block substitutes the {hook_path} placeholder *)

let ( // ) = Filename.concat

let mktemp_dir () =
  let base = Filename.get_temp_dir_name () in
  let name = Printf.sprintf "c2c-kimi-hook-test-%d-%d"
    (Unix.getpid ()) (Random.int 1_000_000) in
  let p = base // name in
  Unix.mkdir p 0o755;
  p

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))

let count_substr ~haystack ~needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 then 0
  else
    let rec loop i acc =
      if i + nlen > hlen then acc
      else if String.sub haystack i nlen = needle
      then loop (i + nlen) (acc + 1)
      else loop (i + 1) acc
    in
    loop 0 0

(* ------------------------------------------------------------------ *)
(* Embedded artifacts: shape checks                                     *)
(* ------------------------------------------------------------------ *)

let test_script_content_nonempty () =
  Alcotest.(check bool) "script content is non-empty" true
    (String.length C2c_kimi_hook.approval_hook_script_content > 100)

let test_script_content_has_shebang () =
  Alcotest.(check bool) "script starts with #!/usr/bin/env bash" true
    (let prefix = "#!/usr/bin/env bash" in
     let plen = String.length prefix in
     String.length C2c_kimi_hook.approval_hook_script_content >= plen
     && String.sub C2c_kimi_hook.approval_hook_script_content 0 plen = prefix)

let test_script_content_has_await_reply () =
  Alcotest.(check bool) "script invokes c2c await-reply" true
    (let s = C2c_kimi_hook.approval_hook_script_content in
     count_substr ~haystack:s ~needle:"await-reply" > 0)

let test_toml_template_has_marker () =
  Alcotest.(check bool) "toml template contains marker substring" true
    (let s = C2c_kimi_hook.toml_block_template in
     count_substr ~haystack:s ~needle:C2c_kimi_hook.toml_block_marker > 0)

let test_toml_template_has_placeholder () =
  Alcotest.(check bool) "toml template references {hook_path}" true
    (let s = C2c_kimi_hook.toml_block_template in
     count_substr ~haystack:s ~needle:"{hook_path}" > 0)

(* ------------------------------------------------------------------ *)
(* render_toml_block substitution                                       *)
(* ------------------------------------------------------------------ *)

let test_render_substitutes_hook_path () =
  let rendered = C2c_kimi_hook.render_toml_block ~hook_path:"/tmp/HOOKED" in
  Alcotest.(check bool) "rendered block contains the hook path" true
    (count_substr ~haystack:rendered ~needle:"/tmp/HOOKED" > 0);
  Alcotest.(check bool) "rendered block has no remaining placeholder" false
    (count_substr ~haystack:rendered ~needle:"{hook_path}" > 0)

let test_render_substitutes_all_three_examples () =
  (* The template has three commented [[hooks]] blocks (A/B/C), each
     referencing {hook_path}. After render, hook_path should appear at
     least 3 times. *)
  let rendered = C2c_kimi_hook.render_toml_block ~hook_path:"/X/Y/Z" in
  let count = count_substr ~haystack:rendered ~needle:"/X/Y/Z" in
  Alcotest.(check bool) "hook path appears at least 3 times after render"
    true (count >= 3)

(* ------------------------------------------------------------------ *)
(* append_toml_block: creation, idempotency, append                     *)
(* ------------------------------------------------------------------ *)

let test_append_creates_when_missing () =
  let dir = mktemp_dir () in
  let cfg = dir // "config.toml" in
  let result =
    C2c_kimi_hook.append_toml_block
      ~config_path:cfg ~hook_path:"/bin/h" ~dry_run:false
  in
  Alcotest.(check bool) "result is `Created when file did not exist" true
    (result = `Created);
  let body = read_file cfg in
  Alcotest.(check int) "marker present exactly once" 1
    (count_substr ~haystack:body ~needle:C2c_kimi_hook.toml_block_marker)

let test_append_appends_when_exists_without_marker () =
  let dir = mktemp_dir () in
  let cfg = dir // "config.toml" in
  (* Pre-populate with unrelated content *)
  let oc = open_out cfg in
  output_string oc "default_model = \"foo\"\nhooks = []\n";
  close_out oc;
  let result =
    C2c_kimi_hook.append_toml_block
      ~config_path:cfg ~hook_path:"/bin/h" ~dry_run:false
  in
  Alcotest.(check bool) "result is `Appended when file existed" true
    (result = `Appended);
  let body = read_file cfg in
  Alcotest.(check int) "marker present exactly once" 1
    (count_substr ~haystack:body ~needle:C2c_kimi_hook.toml_block_marker);
  Alcotest.(check bool) "pre-existing content preserved" true
    (count_substr ~haystack:body ~needle:"default_model" > 0)

let test_append_idempotent_when_marker_present () =
  let dir = mktemp_dir () in
  let cfg = dir // "config.toml" in
  let _ = C2c_kimi_hook.append_toml_block
            ~config_path:cfg ~hook_path:"/bin/h" ~dry_run:false in
  let result2 = C2c_kimi_hook.append_toml_block
                  ~config_path:cfg ~hook_path:"/bin/h" ~dry_run:false in
  Alcotest.(check bool) "second call returns `Already_present" true
    (result2 = `Already_present);
  let body = read_file cfg in
  Alcotest.(check int) "marker still present exactly once after second call" 1
    (count_substr ~haystack:body ~needle:C2c_kimi_hook.toml_block_marker)

let test_append_dry_run_no_write () =
  let dir = mktemp_dir () in
  let cfg = dir // "config.toml" in
  let result =
    C2c_kimi_hook.append_toml_block
      ~config_path:cfg ~hook_path:"/bin/h" ~dry_run:true
  in
  Alcotest.(check bool) "dry run reports `Created" true (result = `Created);
  Alcotest.(check bool) "dry run did not create the file" false
    (Sys.file_exists cfg)

(* ------------------------------------------------------------------ *)
(* install_approval_hook_script: write + chmod                          *)
(* ------------------------------------------------------------------ *)

let test_install_script_writes_file_with_perms () =
  let dir = mktemp_dir () in
  let dest_subdir = dir // "bin" in
  let installed =
    C2c_kimi_hook.install_approval_hook_script
      ~dest_dir:dest_subdir ~dry_run:false
  in
  Alcotest.(check bool) "returned path matches dest_dir/filename" true
    (installed = dest_subdir // C2c_kimi_hook.approval_hook_filename);
  Alcotest.(check bool) "file exists at returned path" true
    (Sys.file_exists installed);
  let st = Unix.stat installed in
  Alcotest.(check int) "file is exactly the embedded length"
    (String.length C2c_kimi_hook.approval_hook_script_content)
    st.Unix.st_size;
  (* Mode comparison — bottom 9 bits, expect rwxr-xr-x = 0o755 *)
  Alcotest.(check int) "file mode is 0755 (low 9 bits)"
    0o755 (st.Unix.st_perm land 0o777)

let test_install_script_dry_run_no_write () =
  let dir = mktemp_dir () in
  let dest_subdir = dir // "bin" in
  let _ =
    C2c_kimi_hook.install_approval_hook_script
      ~dest_dir:dest_subdir ~dry_run:true
  in
  Alcotest.(check bool) "dry run did not create the file" false
    (Sys.file_exists (dest_subdir // C2c_kimi_hook.approval_hook_filename))

(* ------------------------------------------------------------------ *)

let () =
  Random.self_init ();
  Alcotest.run "c2c_kimi_hook"
    [ ( "embedded-artifacts",
        [ Alcotest.test_case "script non-empty" `Quick
            test_script_content_nonempty
        ; Alcotest.test_case "script has shebang" `Quick
            test_script_content_has_shebang
        ; Alcotest.test_case "script invokes await-reply" `Quick
            test_script_content_has_await_reply
        ; Alcotest.test_case "toml template has marker" `Quick
            test_toml_template_has_marker
        ; Alcotest.test_case "toml template has hook_path placeholder" `Quick
            test_toml_template_has_placeholder
        ] )
    ; ( "render-toml-block",
        [ Alcotest.test_case "substitutes hook path" `Quick
            test_render_substitutes_hook_path
        ; Alcotest.test_case "all three example blocks reference path" `Quick
            test_render_substitutes_all_three_examples
        ] )
    ; ( "append-toml-block",
        [ Alcotest.test_case "creates when missing" `Quick
            test_append_creates_when_missing
        ; Alcotest.test_case "appends when exists without marker" `Quick
            test_append_appends_when_exists_without_marker
        ; Alcotest.test_case "idempotent when marker present" `Quick
            test_append_idempotent_when_marker_present
        ; Alcotest.test_case "dry run does not write" `Quick
            test_append_dry_run_no_write
        ] )
    ; ( "install-approval-hook-script",
        [ Alcotest.test_case "writes file with 0755 perms" `Quick
            test_install_script_writes_file_with_perms
        ; Alcotest.test_case "dry run does not write" `Quick
            test_install_script_dry_run_no_write
        ] )
    ]
