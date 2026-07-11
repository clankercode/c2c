(* test_hook_broker_root — unit + E2E coverage for
   C2c_hook_lib.resolve_hook_broker_root (hook-repo-broker slice).

   Live bug (2026-07-11): vanilla Claude/Codex hook processes have no
   C2C_MCP_BROKER_ROOT in their env, so the old `env-or-""` derivation never
   drained the per-repo broker — peer DMs sent via `c2c send <alias>` sat
   undrained while the PostToolUse hook reported "no messages". The fix routes
   the hook's repo-broker resolution through resolve_hook_broker_root, which
   falls back to the canonical repo-fingerprint broker
   ($C2C_STATE_HOME|$HOME/.c2c/repos/<fp>/broker) when the env is unset, but
   ONLY when that broker already exists on disk (registry.json present).

   HERMETICITY: every path here forces the fingerprint fallback into a fresh
   EMPTY temp tree via C2C_STATE_HOME (in-process) or HOME + C2C_STATE_HOME
   (subprocess), so nothing ever reads or drains the developer's live
   ~/.c2c broker. *)

open Alcotest

(* ------------------------------------------------------------------ *)
(* Filesystem + env helpers                                            *)
(* ------------------------------------------------------------------ *)

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-hbr-test-%08x" (Random.bits ()))
  in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) ->
     ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
     Unix.mkdir dir 0o700);
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let write_file path contents =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc contents)

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))

let json_list_length path =
  match Yojson.Safe.from_string (String.trim (read_file path)) with
  | `List items -> List.length items
  | _ -> Alcotest.fail ("expected JSON list in " ^ path)

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

(* Save/set/restore env vars. OCaml's stdlib has no unsetenv; setting a var to
   "" is treated as unset by both env_nonempty and resolve_broker_root (they
   check String.trim <> ""), which is exactly the semantics we need. *)
let getenv_opt = Sys.getenv_opt

let setenv name = function
  | Some v -> Unix.putenv name v
  | None -> Unix.putenv name ""

let with_env bindings f =
  let saved = List.map (fun (k, _) -> (k, getenv_opt k)) bindings in
  List.iter (fun (k, v) -> Unix.putenv k v) bindings;
  Fun.protect
    ~finally:(fun () -> List.iter (fun (k, v) -> setenv k v) saved)
    f

(* SHA-256 fingerprint of a git remote URL, mirroring
   C2c_repo_fp.repo_fingerprint_uncached exactly (first 12 hex of the digest). *)
let fp_of_url url =
  let hex = Digestif.SHA256.(to_hex (digest_string url)) in
  String.sub hex 0 12

(* ------------------------------------------------------------------ *)
(* Unit tests (in-process)                                             *)
(* ------------------------------------------------------------------ *)

(* Env override wins and is returned verbatim (trimmed), WITHOUT any
   existence gate — the broker dir is created lazily for that path
   (managed-session contract), so a not-yet-created root still resolves. *)
let test_env_override_wins () =
  with_env
    [ ("C2C_MCP_BROKER_ROOT", "  /tmp/c2c-hbr-explicit-nonexistent  ") ]
    (fun () ->
      check string "env override returned trimmed, not existence-gated"
        "/tmp/c2c-hbr-explicit-nonexistent"
        (C2c_hook_lib.resolve_hook_broker_root ()))

(* Env unset: resolution uses the canonical fingerprint broker, but is
   existence-gated. C2C_STATE_HOME points at an empty temp tree so:
     - before any broker exists -> "" (old no-op behavior preserved),
     - after a broker (registry.json) is created at the resolved fp path
       -> that path is returned. *)
let test_fp_fallback_existence_gated () =
  with_temp_dir (fun state_home ->
    with_env
      [ ("C2C_MCP_BROKER_ROOT", "")   (* unset *)
      ; ("C2C_STATE_HOME", state_home)
      ]
      (fun () ->
        (* The exact path the hook fallback will resolve to (fp from cwd). *)
        let path = C2c_repo_fp.resolve_broker_root () in
        check bool "resolved path is under the hermetic state home" true
          (string_contains path state_home);
        check string "no broker on disk yet -> empty (no-op preserved)"
          "" (C2c_hook_lib.resolve_hook_broker_root ());
        (* Create a real broker there (register writes registry.json). *)
        let broker = C2c_mcp.Broker.create ~root:path in
        C2c_mcp.Broker.register broker ~session_id:"hbr-unit-sid"
          ~alias:"zz-hbr-unit-agent" ~pid:None ~pid_start_time:None ();
        check bool "registry.json now present" true
          (Sys.file_exists (Filename.concat path "registry.json"));
        check string "broker exists -> fp path returned"
          path (C2c_hook_lib.resolve_hook_broker_root ())))

(* ------------------------------------------------------------------ *)
(* E2E subprocess test — the exact live-failure scenario               *)
(* ------------------------------------------------------------------ *)

let abs_path p =
  if Filename.is_relative p then Filename.concat (Unix.getcwd ()) p else p

let inbox_hook_bin () : string =
  let exe = abs_path Sys.executable_name in
  let ocaml_dir = Filename.dirname (Filename.dirname exe) in
  let hook = Filename.concat ocaml_dir "tools/c2c_inbox_hook.exe" in
  if not (Sys.file_exists hook) then
    Alcotest.fail
      (Printf.sprintf "hook binary not found at %s (test exe=%s)" hook exe);
  hook

(* With C2C_MCP_BROKER_ROOT UNSET and the process cwd inside a git repo, the
   PostToolUse hook must resolve the repo-fingerprint broker from cwd and
   deliver a queued repo-broker DM. This is precisely the vanilla-claude case
   that regressed: a message sitting in ~/.c2c/repos/<fp>/broker while the
   hook reported "no messages". *)
let test_e2e_vanilla_hook_delivers_repo_broker_dm () =
  with_temp_dir (fun state_home ->
    with_temp_dir (fun repo ->
      with_temp_dir (fun sessions ->
        (* Make [repo] a git repo with a deterministic remote so the hook's
           fingerprint resolution is reproducible. *)
        let url = "https://example.com/c2c-hook-repo-broker-e2e.git" in
        let init_rc =
          Sys.command
            (Printf.sprintf
               "git init -q %s && git -C %s config remote.origin.url %s"
               (Filename.quote repo) (Filename.quote repo)
               (Filename.quote url))
        in
        check int "git repo init ok" 0 init_rc;
        let fp = fp_of_url url in
        let broker_root =
          List.fold_left Filename.concat state_home
            [ "c2c"; "repos"; fp; "broker" ]
        in
        (* Seed the repo broker with a DM addressed to a registered session. *)
        let sid = "hbr-e2e-sid" in
        let broker = C2c_mcp.Broker.create ~root:broker_root in
        C2c_mcp.Broker.register broker ~session_id:sid
          ~alias:"zz-hbr-rcpt" ~pid:None ~pid_start_time:None ();
        ignore
          (C2c_mcp.Broker.register broker ~session_id:"hbr-e2e-sender"
             ~alias:"zz-hbr-sender" ~pid:None ~pid_start_time:None ());
        C2c_mcp.Broker.enqueue_message broker ~from_alias:"zz-hbr-sender"
          ~to_alias:"zz-hbr-rcpt"
          ~content:"repo-broker DM delivered via fp fallback" ();
        let repo_inbox = Filename.concat broker_root (sid ^ ".inbox.json") in
        check int "repo inbox seeded with the DM" 1
          (json_list_length repo_inbox);
        (* Run the hook exactly as a vanilla session would: no
           C2C_MCP_BROKER_ROOT, cwd inside the git repo, HOME +
           C2C_STATE_HOME hermetically pinned to [state_home]. *)
        let out = Filename.temp_file "c2c-hbr-e2e" ".out" in
        let err = Filename.temp_file "c2c-hbr-e2e" ".err" in
        Fun.protect
          ~finally:(fun () ->
            (try Sys.remove out with _ -> ());
            (try Sys.remove err with _ -> ()))
          (fun () ->
            let payload =
              Printf.sprintf
                {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid
            in
            let cmd =
              Printf.sprintf
                "cd %s && printf %%s %s | env -u C2C_MCP_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u C2C_NO_AUTO_REGISTER -u \
                 C2C_MCP_BROKER_ROOT HOME=%s C2C_STATE_HOME=%s \
                 C2C_SESSIONS_BROKER_ROOT=%s C2C_POST_TOOL_FULL_INJECT=1 \
                 %s > %s 2> %s"
                (Filename.quote repo) (Filename.quote payload)
                (Filename.quote state_home) (Filename.quote state_home)
                (Filename.quote sessions) (Filename.quote (inbox_hook_bin ()))
                (Filename.quote out) (Filename.quote err)
            in
            let rc = Sys.command cmd in
            check int "hook exits 0" 0 rc;
            let stdout = read_file out in
            check bool "hook emitted output (not silent)" true
              (String.trim stdout <> "");
            let json = Yojson.Safe.from_string (String.trim stdout) in
            let open Yojson.Safe.Util in
            let context =
              json |> member "hookSpecificOutput"
              |> member "additionalContext" |> to_string
            in
            check bool "delivered the repo-broker DM body" true
              (string_contains context
                 "repo-broker DM delivered via fp fallback");
            check bool "delivered as a c2c envelope" true
              (string_contains context "<c2c ");
            check int "repo inbox drained by the vanilla hook" 0
              (json_list_length repo_inbox)))))

(* ------------------------------------------------------------------ *)
(* Runner                                                              *)
(* ------------------------------------------------------------------ *)

let () =
  Alcotest.run "hook_broker_root"
    [ ( "resolve_hook_broker_root",
        [ ( "env override wins (not existence-gated)", `Quick,
            test_env_override_wins )
        ; ( "fp fallback is existence-gated (empty until broker exists)",
            `Quick, test_fp_fallback_existence_gated )
        ] )
    ; ( "e2e",
        [ ( "vanilla hook (no broker env) delivers repo-broker DM", `Quick,
            test_e2e_vanilla_hook_delivers_repo_broker_dm )
        ] )
    ]
