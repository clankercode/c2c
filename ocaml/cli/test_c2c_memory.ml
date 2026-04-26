(* Tests for c2c_memory CLI helpers.
 *
 * Exercises the pure helpers — frontmatter parsing, entry rendering, listing,
 * and shared-flag toggling — using a temp dir as the memory root.
 *
 * The cmdliner-wrapped commands themselves are integration-tested via the
 * built binary (not here); these unit tests cover the underlying logic. *)

open Alcotest

let with_temp_dir f =
  let dir = Filename.temp_file "c2c_memory_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let cleanup () =
    let rec rm_rf path =
      if Sys.is_directory path then begin
        Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
        Unix.rmdir path
      end else
        Sys.remove path
    in
    try rm_rf dir with _ -> ()
  in
  Fun.protect ~finally:cleanup (fun () -> f dir)

(* parse_frontmatter ---------------------------------------------------------- *)

let test_parse_frontmatter_full () =
  let content = "---\nname: test entry\ndescription: a sample\ntype: feedback\nshared: true\n---\nbody line 1\nbody line 2\n" in
  let e = C2c_memory.parse_frontmatter content in
  check (option string) "name" (Some "test entry") e.C2c_memory.name;
  check (option string) "description" (Some "a sample") e.C2c_memory.description;
  check (option string) "type" (Some "feedback") e.C2c_memory.type_;
  check bool "shared" true e.C2c_memory.shared;
  check string "body" "body line 1\nbody line 2\n" e.C2c_memory.body

let test_parse_frontmatter_minimal () =
  let content = "---\nname: x\n---\njust the body\n" in
  let e = C2c_memory.parse_frontmatter content in
  check (option string) "name" (Some "x") e.C2c_memory.name;
  check (option string) "description" None e.C2c_memory.description;
  check (option string) "type" None e.C2c_memory.type_;
  check bool "shared default false" false e.C2c_memory.shared

let test_parse_frontmatter_no_frontmatter () =
  let content = "raw content without frontmatter\n" in
  let e = C2c_memory.parse_frontmatter content in
  check (option string) "name absent" None e.C2c_memory.name;
  check string "body preserved" "raw content without frontmatter\n" e.C2c_memory.body

(* render_entry --------------------------------------------------------------- *)

let test_render_roundtrip () =
  let rendered = C2c_memory.render_entry ~name:"r1" ~description:"d1" ~type_:"note"
    ~shared:true ~body:"hello\n" () in
  let parsed = C2c_memory.parse_frontmatter rendered in
  check (option string) "name" (Some "r1") parsed.C2c_memory.name;
  check (option string) "description" (Some "d1") parsed.C2c_memory.description;
  check (option string) "type" (Some "note") parsed.C2c_memory.type_;
  check bool "shared" true parsed.C2c_memory.shared;
  check string "body" "hello\n" parsed.C2c_memory.body

let contains_substr ~needle s =
  try ignore (Str.search_forward (Str.regexp_string needle) s 0); true
  with Not_found -> false

let test_render_omits_unset_optional_fields () =
  let rendered = C2c_memory.render_entry ~name:"min" ~shared:false ~body:"x" () in
  check bool "no description line" false (contains_substr ~needle:"description:" rendered);
  check bool "no type line" false (contains_substr ~needle:"type:" rendered);
  check bool "has name line" true (contains_substr ~needle:"name: min" rendered)

let test_render_appends_trailing_newline () =
  let rendered = C2c_memory.render_entry ~name:"n" ~shared:false ~body:"no newline" () in
  check char "trailing newline" '\n' rendered.[String.length rendered - 1]

(* memory_base_dir + override ------------------------------------------------- *)

let test_memory_base_dir_uses_override () =
  with_temp_dir (fun dir ->
    Unix.putenv "C2C_MEMORY_ROOT_OVERRIDE" dir;
    let resolved = C2c_memory.memory_base_dir "alice" in
    check string "alias dir under override" (Filename.concat dir "alice") resolved;
    Unix.putenv "C2C_MEMORY_ROOT_OVERRIDE" "")

(* ensure_memory_dir + entry_filename ---------------------------------------- *)

let test_ensure_memory_dir_creates_path () =
  with_temp_dir (fun dir ->
    Unix.putenv "C2C_MEMORY_ROOT_OVERRIDE" dir;
    let _ = C2c_memory.ensure_memory_dir "bob" in
    let expected = Filename.concat dir "bob" in
    check bool "alias dir exists" true (Sys.file_exists expected);
    check bool "is directory" true (Sys.is_directory expected);
    Unix.putenv "C2C_MEMORY_ROOT_OVERRIDE" "")

let test_entry_filename_sanitizes () =
  with_temp_dir (fun dir ->
    Unix.putenv "C2C_MEMORY_ROOT_OVERRIDE" dir;
    let p1 = C2c_memory.entry_filename "alice" "good-name_42" in
    check bool "clean name passthrough" true
      (Filename.basename p1 = "good-name_42.md");
    let p2 = C2c_memory.entry_filename "alice" "bad/name with:colons" in
    check bool "unsafe chars replaced with _" true
      (Filename.basename p2 = "bad_name_with_colons.md");
    Unix.putenv "C2C_MEMORY_ROOT_OVERRIDE" "")

(* list_entry_files ----------------------------------------------------------- *)

let write_test_entry dir name ~shared ~body =
  let path = Filename.concat dir (name ^ ".md") in
  let content = C2c_memory.render_entry ~name ~shared ~body () in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc content)

let test_list_entry_files_skips_index_and_non_md () =
  with_temp_dir (fun dir ->
    Unix.putenv "C2C_MEMORY_ROOT_OVERRIDE" dir;
    let mdir = C2c_memory.ensure_memory_dir "alice" in
    write_test_entry mdir "a" ~shared:false ~body:"x";
    write_test_entry mdir "b" ~shared:true ~body:"y";
    write_test_entry mdir "MEMORY" ~shared:false ~body:"index";
    let oc = open_out (Filename.concat mdir "ignore.txt") in
    output_string oc "ignored"; close_out oc;
    let names = C2c_memory.list_entry_files mdir in
    check (list string) "two .md entries excluding MEMORY.md" ["a.md"; "b.md"] names;
    Unix.putenv "C2C_MEMORY_ROOT_OVERRIDE" "")

let test_list_entry_files_missing_dir_is_empty () =
  let names = C2c_memory.list_entry_files "/tmp/c2c-memory-nonexistent-xyz-12345" in
  check (list string) "missing dir → []" [] names

(* shared-flag toggle (in-memory) -------------------------------------------- *)

let test_render_shared_toggle () =
  let initial = C2c_memory.render_entry ~name:"r" ~description:"d" ~shared:false
    ~body:"hello\n" () in
  let parsed = C2c_memory.parse_frontmatter initial in
  let toggled = C2c_memory.render_entry
    ~name:(Option.value parsed.C2c_memory.name ~default:"r")
    ?description:parsed.C2c_memory.description
    ?type_:parsed.C2c_memory.type_
    ~shared:true
    ~body:parsed.C2c_memory.body () in
  let reparsed = C2c_memory.parse_frontmatter toggled in
  check bool "shared became true" true reparsed.C2c_memory.shared;
  check string "body unchanged" "hello\n" reparsed.C2c_memory.body;
  check (option string) "description preserved" (Some "d") reparsed.C2c_memory.description

let () =
  run "c2c_memory"
    [ ( "frontmatter",
        [ test_case "parse full" `Quick test_parse_frontmatter_full
        ; test_case "parse minimal" `Quick test_parse_frontmatter_minimal
        ; test_case "parse no frontmatter" `Quick test_parse_frontmatter_no_frontmatter
        ] )
    ; ( "render",
        [ test_case "round-trip" `Quick test_render_roundtrip
        ; test_case "omits unset optional fields" `Quick test_render_omits_unset_optional_fields
        ; test_case "appends trailing newline" `Quick test_render_appends_trailing_newline
        ] )
    ; ( "paths",
        [ test_case "memory_base_dir uses override" `Quick test_memory_base_dir_uses_override
        ; test_case "ensure_memory_dir creates path" `Quick test_ensure_memory_dir_creates_path
        ; test_case "entry_filename sanitizes" `Quick test_entry_filename_sanitizes
        ] )
    ; ( "listing",
        [ test_case "skips index and non-md" `Quick test_list_entry_files_skips_index_and_non_md
        ; test_case "missing dir is empty" `Quick test_list_entry_files_missing_dir_is_empty
        ] )
    ; ( "shared",
        [ test_case "render shared toggle" `Quick test_render_shared_toggle
        ] )
    ]
