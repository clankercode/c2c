(* test_c2c_new_cmd — B245: `c2c new` accepts codex | kimi.

   Focused CLI subprocess tests against the freshly-built c2c.exe. We never
   require a real kimi/codex binary for the success path: routing is asserted
   by the error surface (missing binary / codex-only flags / unsupported
   client) rather than by launching a full managed session. *)

open Alcotest

let ( // ) = Filename.concat

let c2c_binary =
  let exe = Sys.executable_name in
  let dir = Filename.dirname exe in
  Filename.concat dir "c2c.exe"

let mkdir_p path =
  let rec loop p =
    if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  if path <> "" && path <> Filename.dirname path then loop path

let with_temp_dir f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-new-cmd-%08x" (Random.bits ()))
  in
  mkdir_p dir;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let contains ~haystack ~needle =
  let hlen = String.length haystack and nlen = String.length needle in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  nlen = 0 || loop 0

let run_c2c ~home ?(path_prefix="") args =
  let broker = home // "broker" in
  mkdir_p home;
  mkdir_p broker;
  let out = home // "out.txt" in
  let env =
    Printf.sprintf
      "HOME=%s XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s \
       C2C_MCP_BROKER_ROOT=%s C2C_CLI_FORCE=1 \
       C2C_MCP_SESSION_ID= C2C_MCP_AUTO_REGISTER_ALIAS= C2C_WRAPPER_SELF= \
       PATH=%s:/usr/bin:/bin"
      (Filename.quote home)
      (Filename.quote (home // ".config"))
      (Filename.quote (home // ".local" // "state"))
      (Filename.quote broker)
      (if path_prefix = "" then "/usr/bin:/bin"
       else Filename.quote path_prefix)
  in
  let argv =
    String.concat " " (List.map Filename.quote (c2c_binary :: args))
  in
  let cmd =
    Printf.sprintf "%s %s > %s 2>&1" env argv (Filename.quote out)
  in
  let rc = Sys.command cmd in
  let content =
    if Sys.file_exists out then
      let ic = open_in out in
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        really_input_string ic (in_channel_length ic))
    else ""
  in
  (rc, content)

(* ------------------------------------------------------------------ *)
(* Help surface                                                       *)
(* ------------------------------------------------------------------ *)

let test_new_help_lists_kimi () =
  with_temp_dir (fun home ->
      let rc, out = run_c2c ~home [ "new"; "--help" ] in
      check int "new --help exits 0" 0 rc;
      check bool "help mentions kimi" true (contains ~haystack:out ~needle:"kimi");
      check bool "help mentions codex" true (contains ~haystack:out ~needle:"codex"))

(* ------------------------------------------------------------------ *)
(* Client routing                                                     *)
(* ------------------------------------------------------------------ *)

let test_new_kimi_routes_past_codex_only_gate () =
  (* With no kimi on PATH, cmd_start should refuse with the missing-binary
     message — proving we reached the kimi start path, not require_codex_client. *)
  with_temp_dir (fun home ->
      let rc, out = run_c2c ~home [ "new"; "kimi" ] in
      check bool "exits non-zero without kimi binary" true (rc <> 0);
      check bool "not the old codex-only gate"
        false
        (contains ~haystack:out ~needle:"only 'codex' is supported");
      check bool "missing-binary (or install) guidance"
        true
        (contains ~haystack:out ~needle:"kimi"
         && (contains ~haystack:out ~needle:"not found"
             || contains ~haystack:out ~needle:"Install"
             || contains ~haystack:out ~needle:"install")))

let test_new_rejects_unsupported_client () =
  with_temp_dir (fun home ->
      let rc, out = run_c2c ~home [ "new"; "claude" ] in
      check bool "exits non-zero for claude" true (rc <> 0);
      check bool "error names supported clients"
        true
        (contains ~haystack:out ~needle:"codex"
         && contains ~haystack:out ~needle:"kimi");
      check bool "suggests c2c start"
        true
        (contains ~haystack:out ~needle:"c2c start claude"))

let test_new_missing_client_mentions_both () =
  with_temp_dir (fun home ->
      let rc, out = run_c2c ~home [ "new" ] in
      check bool "exits non-zero when client missing" true (rc <> 0);
      check bool "mentions codex" true (contains ~haystack:out ~needle:"codex");
      check bool "mentions kimi" true (contains ~haystack:out ~needle:"kimi"))

(* ------------------------------------------------------------------ *)
(* Codex-only flags on kimi                                           *)
(* ------------------------------------------------------------------ *)

let test_new_kimi_rejects_thread_id () =
  with_temp_dir (fun home ->
      let rc, out =
        run_c2c ~home [ "new"; "--thread-id"; "thread-abc"; "kimi" ]
      in
      check bool "exits non-zero" true (rc <> 0);
      check bool "thread-id codex-only"
        true
        (contains ~haystack:out ~needle:"--thread-id"
         && contains ~haystack:out ~needle:"codex-only"))

let test_new_kimi_rejects_yolo_flag () =
  with_temp_dir (fun home ->
      let rc, out = run_c2c ~home [ "new"; "--yolo"; "kimi" ] in
      check bool "exits non-zero" true (rc <> 0);
      check bool "yolo codex-only"
        true
        (contains ~haystack:out ~needle:"--yolo"
         && contains ~haystack:out ~needle:"codex-only"))

(* ------------------------------------------------------------------ *)
(* resume remains codex-only                                          *)
(* ------------------------------------------------------------------ *)

let test_resume_still_codex_only () =
  with_temp_dir (fun home ->
      let rc, out = run_c2c ~home [ "resume"; "kimi"; "some-alias" ] in
      check bool "exits non-zero" true (rc <> 0);
      check bool "resume still codex-only gate"
        true
        (contains ~haystack:out ~needle:"only 'codex' is supported"
         || contains ~haystack:out ~needle:"only 'codex'"))

let () =
  Random.self_init ();
  run "c2c_new_cmd"
    [ ( "help",
        [ ("new --help lists kimi", `Quick, test_new_help_lists_kimi) ] )
    ; ( "routing",
        [ ( "new kimi routes past codex-only gate", `Quick,
            test_new_kimi_routes_past_codex_only_gate )
        ; ( "new rejects unsupported client", `Quick,
            test_new_rejects_unsupported_client )
        ; ( "new missing client mentions both", `Quick,
            test_new_missing_client_mentions_both )
        ] )
    ; ( "codex_only_flags",
        [ ( "new kimi rejects --thread-id", `Quick,
            test_new_kimi_rejects_thread_id )
        ; ( "new kimi rejects --yolo", `Quick, test_new_kimi_rejects_yolo_flag )
        ] )
    ; ( "resume",
        [ ( "resume remains codex-only", `Quick, test_resume_still_codex_only )
        ] )
    ]
