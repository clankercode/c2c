open Alcotest

let ( // ) = Filename.concat

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else
    Sys.remove path

let with_temp_dir f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-stats-test-%d-%06x" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
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
    ]
