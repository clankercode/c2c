open Alcotest

let ( // ) = Filename.concat

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else
    Sys.remove path

let mkdir_p path =
  let rec loop p =
    if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      Unix.mkdir p 0o755
    end
  in
  if path <> "" && path <> Filename.dirname path then loop path

let with_temp_dir f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-stats-test-%d-%06x" (Unix.getpid ()) (Random.bits ()))
  in
  mkdir_p dir;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists dir then remove_tree dir)
    (fun () -> f dir)

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let test_sitrep_path_uses_utc_hour () =
  let ts = 1777124530.0 in
  let path = C2c_stats.sitrep_path ~repo_root:"/repo" ~now:ts in
  check string "path" ("/repo" // ".sitreps" // "2026" // "04" // "25" // "13.md") path

let test_append_stats_creates_stub_and_replaces_block () =
  with_temp_dir @@ fun repo ->
  let now = 1777122000.0 in
  let first_stats = "## Swarm stats — first\n\n| alias |\n|---|\n| a |\n" in
  let second_stats = "## Swarm stats — second\n\n| alias |\n|---|\n| b |\n" in
  let path =
    match C2c_stats.append_stats_to_sitrep ~repo_root:repo ~now ~stats_markdown:first_stats with
    | Ok p -> p
    | Error e -> fail e
  in
  check bool "created sitrep" true (Sys.file_exists path);
  let created = read_file path in
  check bool "stub header present" true
    (string_contains created "# Sitrep — 2026-04-25 13:00 UTC");
  check bool "first block present" true (string_contains created "## Swarm stats — first");
  ignore
    (match C2c_stats.append_stats_to_sitrep ~repo_root:repo ~now ~stats_markdown:second_stats with
     | Ok p -> p
     | Error e -> fail e);
  let replaced = read_file path in
  check bool "second block present" true (string_contains replaced "## Swarm stats — second");
  check bool "first block removed" false (string_contains replaced "## Swarm stats — first")

let test_append_stats_replaces_existing_block_without_duplication () =
  with_temp_dir @@ fun repo ->
  let now = 1777122000.0 in
  let path = C2c_stats.sitrep_path ~repo_root:repo ~now in
  Unix.mkdir (repo // ".sitreps") 0o755;
  Unix.mkdir (repo // ".sitreps" // "2026") 0o755;
  Unix.mkdir (repo // ".sitreps" // "2026" // "04") 0o755;
  Unix.mkdir (repo // ".sitreps" // "2026" // "04" // "25") 0o755;
  write_file path
    "# Existing sitrep\n\nintro\n\n<!-- c2c-stats:start -->\nold\n<!-- c2c-stats:end -->\n\noutro\n";
  let stats = "## Swarm stats — new\n\nbody\n" in
  ignore
    (match C2c_stats.append_stats_to_sitrep ~repo_root:repo ~now ~stats_markdown:stats with
     | Ok p -> p
     | Error e -> fail e);
  let content = read_file path in
  check bool "new block present" true (string_contains content "## Swarm stats — new");
  check bool "old block removed" false (string_contains content "\nold\n");
  check bool "prefix preserved" true (string_contains content "intro");
  check bool "suffix preserved" true (string_contains content "outro")

let test_append_stats_reports_write_failure () =
  with_temp_dir @@ fun repo ->
  write_file (repo // ".sitreps") "not a directory";
  match C2c_stats.append_stats_to_sitrep
          ~repo_root:repo
          ~now:1777122000.0
          ~stats_markdown:"## Swarm stats\n" with
  | Ok path -> fail ("unexpected success writing " ^ path)
  | Error _ -> ()

(* Token extraction tests — always create fixtures in temp dirs *)
let with_claude_code_fixture f =
  with_temp_dir @@ fun tmpdir ->
  let uuid = "test-session-uuid-1234" in
  let sl_out_dir = tmpdir // ".claude" // "sl_out" // uuid in
  mkdir_p sl_out_dir;
  let json_path = sl_out_dir // "input.json" in
  let json_cmd = Printf.sprintf "python3 -c \"import json; d={'session_name':'test-alias','model':{'id':'claude-opus-4-7'},'context_window':{'total_input_tokens':50000,'total_output_tokens':100000},'cost':{'total_cost_usd':12.50}}; open('%s','w').write(json.dumps(d))\" '%s'" json_path json_path in
  ignore (Sys.command json_cmd);
  f ~uuid ~alias:"test-alias" ~tmpdir

let with_codex_fixture f =
  with_temp_dir @@ fun tmpdir ->
  let codex_dir = tmpdir // ".codex" in
  mkdir_p codex_dir;
  let db_path = codex_dir // "state_5.sqlite" in
  let sqlite_cmd =
    Printf.sprintf "sqlite3 %s \"CREATE TABLE threads(id TEXT PRIMARY KEY, tokens_used INTEGER);\"" db_path
  in
  ignore (Sys.command sqlite_cmd);
  let ins_cmd =
    Printf.sprintf "sqlite3 %s \"INSERT INTO threads VALUES('test-codex-session', 98765);\"" db_path
  in
  ignore (Sys.command ins_cmd);
  let old_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" tmpdir;
  Fun.protect
    ~finally:(fun () ->
      (match old_home with Some h -> Unix.putenv "HOME" h | None -> ()))
    (fun () -> f ~db_path)

let with_opencode_fixture f =
  with_temp_dir @@ fun tmpdir ->
  let inst_dir = tmpdir // ".local" // "share" // "c2c" // "instances" // "test-opencode" in
  mkdir_p inst_dir;
  let json_path = inst_dir // "oc-plugin-state.json" in
  let json =
    `Assoc [
      ("state", `Assoc [
        ("c2c_alias", `String "test-opencode");
        ("c2c_session_id", `String "test-opencode");
        ("context_usage", `Assoc [
          ("tokens_input", `Int 12345);
          ("tokens_output", `Int 6789);
          ("cost_usd", `Float 3.21);
        ]);
      ]);
    ]
  in
  let oc = open_out json_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> Yojson.Safe.pretty_to_channel oc json);
  let old_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" tmpdir;
  Fun.protect
    ~finally:(fun () ->
      (match old_home with Some h -> Unix.putenv "HOME" h | None -> ()))
    (fun () -> f ~alias:"test-opencode")

let test_get_claude_code_tokens_by_uuid () =
  with_claude_code_fixture @@ fun ~uuid ~alias:_ ~tmpdir ->
  let old_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" tmpdir;
  Fun.protect
    ~finally:(fun () -> match old_home with Some h -> Unix.putenv "HOME" h | None -> ())
    (fun () ->
  let data = C2c_stats.get_claude_code_tokens ~session_id:uuid in
  check (string) "token_source" "claude-code" (Option.value data.C2c_stats.token_source ~default:"");
  check (option int) "tokens_in" (Some 50000) data.C2c_stats.tokens_in;
  check (option int) "tokens_out" (Some 100000) data.C2c_stats.tokens_out;
  check (option int) "cost_cents" (Some 1250) (Option.map (fun c -> int_of_float (c *. 100.0)) data.C2c_stats.cost_usd))

let test_get_claude_code_tokens_by_alias_fallback () =
  with_claude_code_fixture @@ fun ~uuid ~alias ~tmpdir ->
  let old_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" tmpdir;
  Fun.protect
    ~finally:(fun () -> match old_home with Some h -> Unix.putenv "HOME" h | None -> ())
    (fun () ->
  (* Use alias name as session_id (the fallback path) *)
  let data = C2c_stats.get_claude_code_tokens ~session_id:alias in
  check (string) "token_source" "claude-code" (Option.value data.C2c_stats.token_source ~default:"");
  check (option int) "tokens_in" (Some 50000) data.C2c_stats.tokens_in)

let test_get_codex_tokens () =
  with_codex_fixture @@ fun ~db_path ->
  (* Codex reads from ~/.codex/state_5.sqlite; db_path = $HOME/.codex/state_5.sqlite *)
  let old_home = Sys.getenv_opt "HOME" in
  let top = Filename.dirname (Filename.dirname db_path) in
  Unix.putenv "HOME" top;
  Fun.protect
    ~finally:(fun () -> match old_home with Some h -> Unix.putenv "HOME" h | None -> ())
    (fun () ->
  let data = C2c_stats.get_codex_tokens ~session_id:"test-codex-session" in
  check (string) "token_source" "codex" (Option.value data.C2c_stats.token_source ~default:"");
  check (option int) "tokens (combined)" (Some 98765) data.C2c_stats.tokens_in;
  check bool "tokens_out is None" true (data.C2c_stats.tokens_out = None);
  check bool "cost is None" true (data.C2c_stats.cost_usd = None))

let test_get_opencode_tokens () =
  with_opencode_fixture @@ fun ~alias ->
  let data = C2c_stats.get_opencode_tokens ~alias in
  check (string) "token_source" "opencode" (Option.value data.C2c_stats.token_source ~default:"");
  check (option int) "tokens_in" (Some 12345) data.C2c_stats.tokens_in;
  check (option int) "tokens_out" (Some 6789) data.C2c_stats.tokens_out;
  check (option int) "cost_cents" (Some 321) (Option.map (fun c -> int_of_float (c *. 100.0)) data.C2c_stats.cost_usd)

let test_get_token_data_unknown_session_returns_empty () =
  let data = C2c_stats.get_token_data ~session_id:"nonexistent-session-xyz" in
  check bool "source is None" true (data.C2c_stats.token_source = None);
  check bool "tokens_in is None" true (data.C2c_stats.tokens_in = None)

let () =
  Random.self_init ();
  run "c2c_stats"
    [ ( "sitrep_append",
        [ test_case "sitrep path uses UTC hour" `Quick test_sitrep_path_uses_utc_hour
        ; test_case "creates stub and replaces block" `Quick
            test_append_stats_creates_stub_and_replaces_block
        ; test_case "replaces existing block without duplication" `Quick
            test_append_stats_replaces_existing_block_without_duplication
        ; test_case "reports write failure" `Quick test_append_stats_reports_write_failure
        ] )
    ; ( "token_extraction",
        [ test_case "claude-code tokens by UUID" `Quick test_get_claude_code_tokens_by_uuid
        ; test_case "claude-code tokens by alias fallback" `Quick test_get_claude_code_tokens_by_alias_fallback
        ; test_case "codex tokens from sqlite" `Quick test_get_codex_tokens
        ; test_case "opencode tokens from statefile" `Quick test_get_opencode_tokens
        ; test_case "unknown session returns empty" `Quick test_get_token_data_unknown_session_returns_empty
        ] )
    ]
