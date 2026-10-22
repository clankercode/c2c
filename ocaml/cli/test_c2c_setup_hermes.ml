(* test_c2c_setup_hermes — the ~/.hermes/config.yaml merge, plus the
   install/uninstall round trip that uses it.

   Why this file exists at all: `c2c install hermes` is the only c2c install
   that edits a YAML file, and it edits a LARGE SHARED operator config —
   model providers, API keys, personalities, platform toolsets. A merge that
   emits structurally-wrong YAML does not fail loudly; PyYAML raises on the
   NEXT hermes start and the operator has no config. test_c2c_setup_agy and
   test_c2c_setup_grok exist for exactly this reason (#65: a bad shared-config
   merge silently broke a host), and this is the same hazard class.

   The shape that matters most is the one hermes itself writes — PyYAML's
   block style, where sequence items sit at the SAME column as their key:

     plugins:
       enabled:
       - c2c
       - model-providers/llmp
       disabled: []

   Emitting a hardcoded 4-space item indent against that produces
   `enabled:` / `    - c2c` / `  - model-providers/llmp`, which PyYAML rejects
   with "ParserError: while parsing a block mapping". Every expected string
   below was validated with `python3 -c 'import yaml; yaml.safe_load(...)'`
   while it was written; the committed assertions are self-contained OCaml
   (this repo has no YAML dependency, deliberately). *)

open Alcotest

let ( // ) = Filename.concat

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let with_temp_home f =
  let base = Filename.get_temp_dir_name () in
  let dir = base // Printf.sprintf "c2c-setup-hermes-%08x" (Random.bits ()) in
  Unix.mkdir dir 0o700;
  let prev_home = Sys.getenv_opt "HOME" in
  let prev_hermes = Sys.getenv_opt "HERMES_HOME" in
  Unix.putenv "HERMES_HOME" "";
  Unix.putenv "HOME" dir;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "HERMES_HOME" (Option.value prev_hermes ~default:"");
      (match prev_home with Some h -> Unix.putenv "HOME" h | None -> ());
      try remove_tree dir with _ -> ())
    (fun () -> f dir)

(* ---------------------------------------------------------------------- *)
(* Helpers over the merge result                                           *)
(* ---------------------------------------------------------------------- *)

let ok_exn = function
  | Ok v -> v
  | Error msg -> Alcotest.failf "merge refused the config: %s" msg

let lines_of s = String.split_on_char '\n' s

let count_lines_equal s needle =
  List.length (List.filter (fun l -> String.trim l = needle) (lines_of s))

let contains_line s needle = count_lines_equal s needle > 0

let enable s = ok_exn (C2c_hermes_config.enable s)
let disable s = ok_exn (C2c_hermes_config.disable s)

(* Structural invariant asserted on every "added" case: exactly one c2c entry,
   and it is reachable as an item of plugins.enabled. *)
let check_single_c2c_entry ~where out =
  let n =
    List.length
      (List.filter
         (fun l ->
            let t = String.trim l in
            t = "- c2c" || t = "- \"c2c\"" || t = "- 'c2c'")
         (lines_of out))
  in
  let inline =
    List.length
      (List.filter
         (fun l ->
            let t = String.trim l in
            String.length t > 9 && String.sub t 0 9 = "enabled: "
            && (let v = String.sub t 9 (String.length t - 9) in
                let hl = String.length v in
                let rec at i = i + 3 <= hl && (String.sub v i 3 = "c2c" || at (i + 1)) in
                at 0))
         (lines_of out))
  in
  check bool (where ^ ": exactly one c2c entry") true (n + inline = 1);
  check bool (where ^ ": is_enabled agrees") true (C2c_hermes_config.is_enabled out)

(* ---------------------------------------------------------------------- *)
(* 1. PyYAML block style — the real ~/.hermes/config.yaml shape             *)
(* ---------------------------------------------------------------------- *)

let real_shape =
  "session_reset:\n\
  \  at_hour: 4\n\
   plugins:\n\
  \  enabled:\n\
  \  - model-providers/llmp\n\
  \  disabled: []\n\
  \  entries:\n\
  \    model-providers/llmp:\n\
  \      allow_tool_override: false\n"

let test_pyyaml_block_style () =
  let out = enable real_shape in
  check string "item copies the key's column (PyYAML style)"
    "session_reset:\n\
    \  at_hour: 4\n\
     plugins:\n\
    \  enabled:\n\
    \  - model-providers/llmp\n\
    \  - c2c\n\
    \  disabled: []\n\
    \  entries:\n\
    \    model-providers/llmp:\n\
    \      allow_tool_override: false\n"
    out;
  check_single_c2c_entry ~where:"pyyaml block" out;
  check bool "disabled preserved" true (contains_line out "disabled: []");
  check bool "entries preserved" true (contains_line out "entries:");
  check bool "sibling top-level key preserved" true (contains_line out "session_reset:")

(* A hardcoded 4-space item against this shape is the ParserError the review
   found. Pin the column arithmetic directly so a regression is unmissable. *)
let test_item_column_matches_existing_items () =
  let out = enable real_shape in
  let indent_of l =
    let n = String.length l in
    let rec go i = if i < n && l.[i] = ' ' then go (i + 1) else i in
    go 0
  in
  let item_indents =
    List.filter_map
      (fun l ->
         let t = String.trim l in
         if String.length t >= 2 && String.sub t 0 2 = "- " then Some (indent_of l)
         else None)
      (lines_of out)
  in
  check (list int) "every enabled item shares one column" [ 2; 2 ] item_indents

(* ---------------------------------------------------------------------- *)
(* 2. Four-space item list                                                 *)
(* ---------------------------------------------------------------------- *)

let test_four_space_items () =
  let input =
    "plugins:\n  enabled:\n    - alpha\n  disabled: []\n"
  in
  let out = enable input in
  check string "new item copies the 4-space indent"
    "plugins:\n  enabled:\n    - alpha\n    - c2c\n  disabled: []\n" out;
  check_single_c2c_entry ~where:"4-space" out

(* ---------------------------------------------------------------------- *)
(* 3/4. Inline flow lists                                                  *)
(* ---------------------------------------------------------------------- *)

let test_empty_flow_list () =
  (* `enabled: []` is the natural shape of a freshly-created block. Appending a
     block item under it yields `enabled: []` followed by `- c2c`, which is not
     valid YAML — the flow list must be rewritten in place. *)
  let out = enable "plugins:\n  enabled: []\n  disabled: []\n" in
  check string "flow list rewritten in place"
    "plugins:\n  enabled: [c2c]\n  disabled: []\n" out;
  check bool "no stray block item emitted" false (contains_line out "- c2c");
  check_single_c2c_entry ~where:"empty flow" out

let test_populated_flow_list () =
  let out = enable "plugins:\n  enabled: [foo]\n" in
  check string "appended inside the flow list"
    "plugins:\n  enabled: [foo, c2c]\n" out;
  check_single_c2c_entry ~where:"populated flow" out

let test_flow_list_keeps_trailing_comment () =
  let out = enable "plugins:\n  enabled: []  # nothing yet\n" in
  check string "trailing comment preserved"
    "plugins:\n  enabled: [c2c] # nothing yet\n" out

(* ---------------------------------------------------------------------- *)
(* 5. Idempotency                                                          *)
(* ---------------------------------------------------------------------- *)

let test_already_enabled_is_byte_identical () =
  let input = "plugins:\n  enabled:\n  - c2c\n  - other\n  disabled: []\n" in
  check string "no rewrite when already enabled" input (enable input);
  check bool "is_enabled true" true (C2c_hermes_config.is_enabled input);
  check string "second application still identical" input (enable (enable input))

let test_already_enabled_in_flow_list () =
  let input = "plugins:\n  enabled: [c2c, foo]\n" in
  check string "flow list untouched" input (enable input);
  check bool "is_enabled true" true (C2c_hermes_config.is_enabled input)

(* ---------------------------------------------------------------------- *)
(* 6. c2c under `disabled:`                                                *)
(* ---------------------------------------------------------------------- *)

let test_disabled_entry_is_not_enabled () =
  (* The state-machine bug: `in_enabled` never reset at `disabled:`, so a c2c
     under disabled satisfied the "already enabled" test and install no-opped
     while printing success — and the plugin never loaded. *)
  let input = "plugins:\n  enabled:\n  - alpha\n  disabled:\n  - c2c\n" in
  check bool "c2c under disabled is NOT enabled" false
    (C2c_hermes_config.is_enabled input);
  let out = enable input in
  check string "moved out of disabled into enabled"
    "plugins:\n  enabled:\n  - alpha\n  - c2c\n  disabled: []\n" out;
  check_single_c2c_entry ~where:"disabled block" out

let test_disabled_flow_entry_stripped () =
  let input = "plugins:\n  enabled: []\n  disabled: [c2c, other]\n" in
  check bool "not enabled" false (C2c_hermes_config.is_enabled input);
  let out = enable input in
  check string "stripped from the disabled flow list"
    "plugins:\n  enabled: [c2c]\n  disabled: [other]\n" out

(* ---------------------------------------------------------------------- *)
(* 7. `plugins:` with no `enabled:` key                                    *)
(* ---------------------------------------------------------------------- *)

let test_plugins_without_enabled_key_keeps_siblings () =
  (* Appending a second top-level `plugins:` is silent destruction: PyYAML
     keeps the LAST duplicate key, so `disabled:` and `entries:` vanish. *)
  let input =
    "plugins:\n\
    \  disabled: []\n\
    \  entries:\n\
    \    model-providers/llmp:\n\
    \      allow_tool_override: false\n"
  in
  let out = enable input in
  check string "enabled inserted under the existing plugins key"
    "plugins:\n\
    \  enabled:\n\
    \  - c2c\n\
    \  disabled: []\n\
    \  entries:\n\
    \    model-providers/llmp:\n\
    \      allow_tool_override: false\n"
    out;
  check int "exactly one top-level plugins key" 1 (count_lines_equal out "plugins:");
  check bool "disabled survived" true (contains_line out "disabled: []");
  check bool "entries survived" true (contains_line out "entries:");
  check_single_c2c_entry ~where:"no enabled key" out

(* ---------------------------------------------------------------------- *)
(* 8. Unrelated `enabled:` elsewhere in the file                           *)
(* ---------------------------------------------------------------------- *)

let test_unrelated_enabled_key_untouched () =
  let input =
    "plugins:\n\
    \  enabled:\n\
    \  - alpha\n\
     mcp_servers:\n\
    \  foo:\n\
    \    enabled: true\n"
  in
  let out = enable input in
  check string "only plugins.enabled edited"
    "plugins:\n\
    \  enabled:\n\
    \  - alpha\n\
    \  - c2c\n\
     mcp_servers:\n\
    \  foo:\n\
    \    enabled: true\n"
    out;
  check bool "mcp_servers.foo.enabled preserved verbatim" true
    (contains_line out "enabled: true");
  check_single_c2c_entry ~where:"unrelated enabled" out

let test_unrelated_enabled_before_plugins () =
  let input =
    "mcp_servers:\n\
    \  foo:\n\
    \    enabled: true\n\
     plugins:\n\
    \  enabled: []\n"
  in
  let out = enable input in
  check string "plugins block located, not the first `enabled:` seen"
    "mcp_servers:\n\
    \  foo:\n\
    \    enabled: true\n\
     plugins:\n\
    \  enabled: [c2c]\n"
    out

(* ---------------------------------------------------------------------- *)
(* 9/10. Missing `plugins:` key / missing file                             *)
(* ---------------------------------------------------------------------- *)

let test_no_plugins_key_appends_block () =
  let out = enable "model:\n  default: grok-4.5\n" in
  check string "well-formed block appended"
    "model:\n  default: grok-4.5\nplugins:\n  enabled:\n  - c2c\n  disabled: []\n"
    out;
  check_single_c2c_entry ~where:"append" out

let test_no_plugins_key_without_trailing_newline () =
  let out = enable "model:\n  default: grok-4.5" in
  check string "block still starts on its own line"
    "model:\n  default: grok-4.5\nplugins:\n  enabled:\n  - c2c\n  disabled: []\n"
    out

let test_empty_content_creates_block () =
  check string "empty file yields just the block"
    "plugins:\n  enabled:\n  - c2c\n  disabled: []\n" (enable "");
  check_single_c2c_entry ~where:"empty" (enable "")

(* ---------------------------------------------------------------------- *)
(* 11. CRLF / no trailing newline                                          *)
(* ---------------------------------------------------------------------- *)

let test_crlf_preserved () =
  let input = "plugins:\r\n  enabled:\r\n  - alpha\r\n  disabled: []\r\n" in
  check string "CRLF preserved on every line"
    "plugins:\r\n  enabled:\r\n  - alpha\r\n  - c2c\r\n  disabled: []\r\n"
    (enable input)

let test_no_trailing_newline_preserved () =
  check string "no trailing newline is not added"
    "plugins:\n  enabled:\n  - alpha\n  - c2c"
    (enable "plugins:\n  enabled:\n  - alpha")

let test_mixed_line_endings_refused () =
  match C2c_hermes_config.enable "plugins:\r\n  enabled: []\n" with
  | Ok _ -> Alcotest.fail "mixed line endings must be refused, not normalised"
  | Error _ -> ()

let test_tab_indent_refused () =
  match C2c_hermes_config.enable "plugins:\n\tenabled: []\n" with
  | Ok _ -> Alcotest.fail "tab-indented config must be refused, not corrupted"
  | Error _ -> ()

(* ---------------------------------------------------------------------- *)
(* 11b. Key RECOGNITION is total                                           *)
(*                                                                          *)
(* A key shape the parser fails to *recognise* is far more dangerous than    *)
(* one it fails to parse: "no match" used to mean "the key is absent", so    *)
(* the writer appended a second `plugins:` / a second `enabled:`. PyYAML     *)
(* keeps the LAST duplicate, so the operator's real mapping silently         *)
(* disappeared while install reported success. Each of these must bail with  *)
(* the file untouched.                                                       *)
(* ---------------------------------------------------------------------- *)

let bom = "\xef\xbb\xbf"

(* Refusal has to hold in BOTH directions: install must not corrupt the file,
   and uninstall must not "clean up" a mapping it cannot read. *)
let refuses ~what input =
  (match C2c_hermes_config.enable input with
   | Ok out -> Alcotest.failf "enable must refuse %s; it produced:\n%s" what out
   | Error _ -> ());
  (match C2c_hermes_config.disable input with
   | Ok out when out <> input ->
       Alcotest.failf "disable must not rewrite %s; it produced:\n%s" what out
   | Ok _ | Error _ -> ());
  check bool "an unreadable config never reads as enabled" false
    (C2c_hermes_config.is_enabled input)

(* A BOM is the one shape of the four that is genuinely SUPPORTED: it is held
   aside for parsing and put back on write, so the file round-trips. *)
let test_bom_parsed_and_preserved () =
  let input = bom ^ "plugins:\n  enabled:\n  - alpha\n  disabled: []\n" in
  let out = enable input in
  check string "BOM kept, list edited in place"
    (bom ^ "plugins:\n  enabled:\n  - alpha\n  - c2c\n  disabled: []\n")
    out;
  check bool "is_enabled sees through the BOM" true
    (C2c_hermes_config.is_enabled out);
  check string "disable restores the original bytes" input (disable out)

let test_quoted_plugins_key_refused () =
  refuses ~what:"a quoted \"plugins\": key"
    "\"plugins\":\n  enabled:\n  - alpha\n  disabled: []\n  entries: {}\n"

let test_space_before_colon_refused () =
  refuses ~what:"`plugins :` (whitespace before the colon)"
    "plugins :\n  enabled:\n  - alpha\n  disabled: []\n"

let test_quoted_enabled_key_refused () =
  refuses ~what:"a quoted \"enabled\": key"
    "plugins:\n  \"enabled\":\n  - alpha\n  disabled: []\n"

let test_quoted_disabled_key_refused () =
  (* Missing this one is quieter but still wrong: c2c would be added to
     `enabled` while staying in a `disabled` list it could not see, so install
     "succeeds" and the plugin never loads. *)
  refuses ~what:"a quoted \"disabled\": key"
    "plugins:\n  enabled:\n  - alpha\n  \"disabled\":\n  - c2c\n"

let test_unparsed_duplicate_plugins_key_refused () =
  (* Editing the first of two `plugins:` keys edits a mapping hermes never
     reads — PyYAML resolves duplicates to the last one. *)
  refuses ~what:"a quoted duplicate after a plain plugins:"
    "plugins:\n  enabled:\n  - alpha\n\"plugins\":\n  enabled:\n  - beta\n"

let test_colon_inside_a_value_is_not_a_key () =
  (* The loose recogniser must not fire on a scalar that merely mentions the
     name, or ordinary configs become uneditable. *)
  let input = "note: \"plugins: not a key\"\nplugins:\n  enabled:\n  - alpha\n" in
  check string "value text ignored; the real key is still edited"
    "note: \"plugins: not a key\"\nplugins:\n  enabled:\n  - alpha\n  - c2c\n"
    (enable input)

(* ---------------------------------------------------------------------- *)
(* 11c. VALUE-shape recognition is total too                                *)
(*                                                                          *)
(* Recognising the `plugins` KEY is not enough: its value has to be a block  *)
(* mapping. A sequence value (`plugins:` / `- alpha`) is legal YAML that an  *)
(* operator guessing the schema might well write, and inserting `enabled:`   *)
(* into it either retypes the node or produces a file PyYAML cannot parse.   *)
(* ---------------------------------------------------------------------- *)

let test_plugins_sequence_at_key_column_refused () =
  (* The nastiest of the three: `block_end` stops at the first `- ` line, so
     the mapping looks merely EMPTY and the insert lands mid-sequence. *)
  refuses ~what:"`plugins:` with a sequence value at the key's column"
    "plugins:\n- alpha\n- beta\n"

let test_plugins_indented_sequence_refused () =
  refuses ~what:"`plugins:` with an indented sequence value"
    "plugins:\n  - alpha\n  - beta\n"

let test_whole_document_flow_mapping_refused () =
  refuses ~what:"a whole-document flow mapping"
    "{plugins: {enabled: [alpha]}}\n"

let test_root_sequence_document_refused () =
  refuses ~what:"a document whose root is a sequence"
    "- alpha\n- beta\n"

(* A leading `---` is neither a sequence item nor a flow opener, so a
   known-bad-shapes guard reads straight past it and appends anyway. The root
   test is therefore positive: the line must LOOK like a block mapping key. *)
let test_doc_marker_then_flow_root_refused () =
  refuses ~what:"a flow root behind a `---` marker"
    "---\n{plugins: {enabled: [alpha]}}\n"

let test_bare_scalar_document_refused () =
  refuses ~what:"a bare scalar document" "hello\n"

let test_content_on_doc_marker_refused () =
  (* `--- model: x` starts the root mapping at column 4, so every column
     assumption in this module is wrong for it. *)
  refuses ~what:"content sitting on the document-start marker" "--- model: gpt\n"

(* The leniency half: skipping markers and directives must not start refusing
   ordinary configs. *)
let test_doc_marker_then_block_mapping_still_edits () =
  check string "appends after a `---` marker"
    "---\nmodel: gpt\nplugins:\n  enabled:\n  - c2c\n  disabled: []\n"
    (enable "---\nmodel: gpt\n");
  check string "edits a real plugins: key behind a `---` marker"
    "---\nplugins:\n  enabled:\n  - alpha\n  - c2c\n"
    (enable "---\nplugins:\n  enabled:\n  - alpha\n");
  check string "a %YAML directive is skipped too"
    "%YAML 1.2\n---\nmodel: gpt\nplugins:\n  enabled:\n  - c2c\n  disabled: []\n"
    (enable "%YAML 1.2\n---\nmodel: gpt\n")

let test_comment_only_document_appends () =
  check string "comments carry no root shape"
    "# just a comment\nplugins:\n  enabled:\n  - c2c\n  disabled: []\n"
    (enable "# just a comment\n")

let test_sequence_item_is_not_a_key () =
  let input = "items:\n- plugins: x\nplugins:\n  enabled: []\n" in
  check string "`- plugins:` under another key is not the plugins mapping"
    "items:\n- plugins: x\nplugins:\n  enabled: [c2c]\n"
    (enable input)

(* ---------------------------------------------------------------------- *)
(* 11d. The atomic write path the merge depends on                          *)
(*                                                                          *)
(* [C2c_io.write_file_atomic] is shared surface, but ~/.hermes/config.yaml   *)
(* is the caller that motivated ?perm (it is 0600 on real machines, unlike   *)
(* every other client config) and the caller whose failure path sits next    *)
(* to an operator file. Both properties are covered here.                    *)
(* ---------------------------------------------------------------------- *)

let with_temp_dir f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-io-test-%d-%d" (Unix.getpid ()) (Random.int 100000))
  in
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let test_atomic_write_perm () =
  with_temp_dir (fun dir ->
    let path = dir // "cfg.yaml" in
    write_file path "old\n";
    Unix.chmod path 0o600;
    (match C2c_io.write_file_atomic ~perm:0o600 path "new\n" with
     | Ok () -> ()
     | Error e -> Alcotest.failf "write failed: %s" e);
    check int "mode carried across the rename" 0o600
      ((Unix.stat path).Unix.st_perm);
    check string "content replaced" "new\n" (read_file path);
    (* ?perm is optional, and since #84 omitting it PRESERVES the mode rather
       than resetting it to the umask default. The general contract lives in
       test_c2c_io_modes.ml; asserted here because ~/.hermes/config.yaml is the
       0600 config that motivated it. *)
    check bool "?perm really is optional" true
      (match C2c_io.write_file_atomic path "newer\n" with
       | Ok () -> true
       | Error _ -> false);
    check int "mode still 0600 with ?perm omitted" 0o600
      ((Unix.stat path).Unix.st_perm))

let test_atomic_write_no_stray_tmp () =
  with_temp_dir (fun dir ->
    let path = dir // "cfg.yaml" in
    (match C2c_io.write_file_atomic path "x\n" with
     | Ok () -> ()
     | Error e -> Alcotest.failf "write failed: %s" e);
    check bool "no leftover temp file" false (Sys.file_exists (path ^ ".tmp")))

let test_atomic_write_keeps_foreign_tmp () =
  with_temp_dir (fun dir ->
    let path = dir // "cfg.yaml" in
    let tmp = path ^ ".tmp" in
    write_file path "config\n";
    (* A pre-existing `<path>.tmp` that c2c did not create. Read-only, so the
       open fails — which is exactly when the cleanup must not fire. *)
    write_file tmp "operator data\n";
    Unix.chmod tmp 0o444;
    (match C2c_io.write_file_atomic path "new\n" with
     | Ok () -> Alcotest.fail "write should have failed on the read-only temp"
     | Error _ -> ());
    check bool "foreign temp file still exists" true (Sys.file_exists tmp);
    check string "and still holds its content" "operator data\n" (read_file tmp);
    check string "target untouched" "config\n" (read_file path))

(* ---------------------------------------------------------------------- *)
(* 12. Uninstall direction                                                 *)
(* ---------------------------------------------------------------------- *)

let test_disable_strips_entry_only () =
  let input =
    "plugins:\n\
    \  enabled:\n\
    \  - model-providers/llmp\n\
    \  - c2c\n\
    \  disabled: []\n\
    \  entries:\n\
    \    c2c:\n\
    \      allow_tool_override: false\n"
  in
  let out = disable input in
  check string "only the enabled entry removed"
    "plugins:\n\
    \  enabled:\n\
    \  - model-providers/llmp\n\
    \  disabled: []\n\
    \  entries:\n\
    \    c2c:\n\
    \      allow_tool_override: false\n"
    out;
  check bool "no longer enabled" false (C2c_hermes_config.is_enabled out);
  check bool "entries.c2c left alone (hermes owns it)" true
    (contains_line out "c2c:")

let test_disable_last_entry_yields_explicit_empty_list () =
  (* A bare `enabled:` parses as null, not []. hermes iterates the value. *)
  check string "collapses to an explicit empty flow list"
    "plugins:\n  enabled: []\n  disabled: []\n"
    (disable "plugins:\n  enabled:\n  - c2c\n  disabled: []\n")

let test_disable_flow_list () =
  check string "removed from the flow list"
    "plugins:\n  enabled: [foo]\n"
    (disable "plugins:\n  enabled: [foo, c2c]\n")

let test_disable_is_noop_when_absent () =
  let input = "plugins:\n  enabled:\n  - foo\n" in
  check string "byte-identical when c2c is not listed" input (disable input);
  check string "no plugins key at all is a no-op" "model: {}\n"
    (disable "model: {}\n")

let test_enable_disable_round_trip () =
  let out = disable (enable real_shape) in
  check string "round trip restores the original bytes" real_shape out

(* ---------------------------------------------------------------------- *)
(* End-to-end: setup_hermes against a temp HOME                            *)
(* ---------------------------------------------------------------------- *)

let run_setup ~alias =
  C2c_setup.setup_hermes ~with_mcp:false ~server_path:"" ~broker_root_opt:None ~output_mode:C2c_types.Json ~dry_run:false
    ~root:"/fake/broker/root" ~alias_val:alias ~alias_from_auto_gen:false

let config_path home = home // ".hermes" // "config.yaml"
let plugin_dir home = home // ".hermes" // "plugins" // "c2c"

let test_install_writes_plugin_and_enables () =
  with_temp_home (fun home ->
    Unix.mkdir (home // ".hermes") 0o700;
    write_file (config_path home) real_shape;
    let res = run_setup ~alias:"hermes-fixture-aa" in
    List.iter
      (fun (rel, _) ->
         check bool
           (Printf.sprintf "plugin file written: %s" rel)
           true
           (Sys.file_exists (plugin_dir home // rel)))
      C2c_hermes_plugin_embedded.files;
    let out = read_file (config_path home) in
    check bool "config now enables c2c" true (C2c_hermes_config.is_enabled out);
    check_single_c2c_entry ~where:"install" out;
    check bool "operator's other plugin preserved" true
      (contains_line out "- model-providers/llmp");
    check bool "entries preserved" true (contains_line out "entries:");
    let shared =
      List.filter
        (fun (a : C2c_install_manifest.artifact) -> a.kind = "shared-key")
        res.C2c_setup.artifacts
    in
    check int "one shared-key artifact recorded" 1 (List.length shared);
    match shared with
    | [ a ] ->
        check (option string) "shared key names the yaml format" (Some "yaml") a.format;
        check (option string) "shared key path" (Some "plugins.enabled.c2c") a.key
    | _ -> ())

let test_install_is_idempotent () =
  with_temp_home (fun home ->
    Unix.mkdir (home // ".hermes") 0o700;
    write_file (config_path home) real_shape;
    ignore (run_setup ~alias:"hermes-fixture-ab");
    let once = read_file (config_path home) in
    ignore (run_setup ~alias:"hermes-fixture-ab");
    let twice = read_file (config_path home) in
    check string "second install changes nothing" once twice;
    check_single_c2c_entry ~where:"idempotent install" twice)

let test_install_with_no_config_file () =
  with_temp_home (fun home ->
    ignore (run_setup ~alias:"hermes-fixture-ac");
    check bool "config.yaml created" true (Sys.file_exists (config_path home));
    check string "fresh block written"
      "plugins:\n  enabled:\n  - c2c\n  disabled: []\n"
      (read_file (config_path home)))

let test_install_dry_run_writes_nothing () =
  with_temp_home (fun home ->
    Unix.mkdir (home // ".hermes") 0o700;
    write_file (config_path home) real_shape;
    ignore
      (C2c_setup.setup_hermes ~with_mcp:false ~server_path:"" ~broker_root_opt:None ~output_mode:C2c_types.Json ~dry_run:true
         ~root:"/fake/broker/root" ~alias_val:"hermes-fixture-ad"
         ~alias_from_auto_gen:false);
    check string "config untouched by --dry-run" real_shape
      (read_file (config_path home));
    check bool "no plugin file written" false
      (Sys.file_exists (plugin_dir home // "plugin.yaml")))

let test_install_refuses_tab_indented_config_without_corrupting_it () =
  with_temp_home (fun home ->
    Unix.mkdir (home // ".hermes") 0o700;
    let hostile = "plugins:\n\tenabled: []\n" in
    write_file (config_path home) hostile;
    ignore (run_setup ~alias:"hermes-fixture-ae");
    check string "config left exactly as it was" hostile
      (read_file (config_path home));
    check bool "plugin files still written" true
      (Sys.file_exists (plugin_dir home // "plugin.yaml")))

(* B376 opt-in MCP, ownership and foreign identity regressions. *)
let mcp_enable ?(root=None) input =
  ok_exn (C2c_hermes_config.enable_mcp ~server_path:"/opt/c2c-mcp-server"
    ~broker_root:root input)

let test_mcp_surgical_round_trip () =
  let input = "model: private\nplugins:\n  enabled: [c2c]\nmcp_servers:\n  foreign:\n    command: keep\n# operator tail\n" in
  let out, managed = mcp_enable input in
  check bool "new stanza is owned" true managed;
  check bool "MCP detected" true (C2c_hermes_config.mcp_configured out);
  check bool "foreign command preserved" true (contains_line out "command: keep");
  check string "idempotent" out (fst (mcp_enable out));
  check string "surgical uninstall round-trip" input
    (ok_exn (C2c_hermes_config.disable_mcp out));
  let changed = Str.global_replace (Str.regexp_string "--hermes-connection") "--operator-choice" out in
  check string "modified managed entry retained" changed
    (ok_exn (C2c_hermes_config.disable_mcp changed))

let test_mcp_foreign_preserved () =
  let input = "mcp_servers:\n  c2c:\n    command: foreign\n    env:\n      CUSTOM: keep\n  other:\n    command: keep\n" in
  let out, managed = mcp_enable input in
  check string "no foreign override" input out;
  check bool "foreign entry not claimed" false managed;
  check string "foreign entry not uninstalled" input
    (ok_exn (C2c_hermes_config.disable_mcp input))

let test_mcp_shape_safety () =
  List.iter (fun input ->
    match C2c_hermes_config.enable_mcp ~server_path:"server" ~broker_root:None input with
    | Error _ -> ()
    | Ok _ -> failf "unsafe YAML accepted: %S" input)
    [ "\"mcp_\\u0073ervers\":\n  foreign:\n    command: keep\n"
    ; "plugins:\n  \"en\\u0061bled\": [keep]\n"
    ; "plugins:\n  !!str enabled: [keep]\n"
    ; "plugins:\n  ? enabled\n  : [keep]\n"
    ; "!!str mcp_servers:\n  foreign: {}\n"
    ; "? mcp_servers\n: {}\n"
    ; "mcp_servers:\n  \"c2\\u0063\": {}\n"
    ; "mcp_servers:\n  !!str c2c: {}\n"
    ; "mcp_servers:\n  ? c2c\n  : {}\n"
    ; "\"mcp_servers\": {}\n"; "mcp_servers : {}\n"
    ; "mcp_servers:\n  \"c2c\": {}\n"
    ; "mcp_servers:\n  c2c: {}\n  c2c: {}\n"
    ; "mcp_servers: {}\nmcp_servers: {}\n"
    ; "mcp_servers:\n- other\n"; "mcp_servers: [other]\n"
    ; "mcp_servers: &shared\n  other: {}\n"; "<<: *defaults\n"
    ; "---\nmodel: x\n---\nmcp_servers: {}\n"
    ; "model: x\n...\n"; "{model: x}\n"
    ; "description: [\nmcp_servers:\n  other: keep\n]\n"
    ; "description: {\nmcp_servers: keep\n}\n"
    ; "  model: keep\n"
    ; "mcp_servers:\n\tc2c: {}\n" ];
  let out, _ = mcp_enable "mcp_servers: {} # keep\n" in
  check bool "empty flow map accepts insert" true (C2c_hermes_config.mcp_configured out);
  check bool "flow map comment retained" true (contains_line out "mcp_servers: # keep");
  check string "uninstall retains mapping comment" "mcp_servers: {} # keep\n"
    (ok_exn (C2c_hermes_config.disable_mcp out))

let test_mcp_bom_crlf_no_newline () =
  let input = "\xef\xbb\xbfmcp_servers:\r\n  other:\r\n    command: keep" in
  let out, _ = mcp_enable input in
  check string "BOM/CRLF/no trailing newline round-trip" input
    (ok_exn (C2c_hermes_config.disable_mcp out));
  let explicit, _ = mcp_enable ~root:(Some "/intentional/broker") "" in
  check bool "explicit root is argument" true
    (contains_line explicit "args: [\"--hermes-connection\", \"--broker-root\", \"/intentional/broker\"]")

let with_env vars f =
  let prev = List.map (fun (k, _) -> (k, Sys.getenv_opt k)) vars in
  List.iter (fun (k, v) -> Unix.putenv k v) vars;
  Fun.protect ~finally:(fun () -> List.iter (fun (k, v) ->
    Unix.putenv k (Option.value v ~default:"")) prev) f

let test_mcp_installer_opt_in_and_identity () =
  with_temp_home (fun home ->
    with_env [ "C2C_MCP_SESSION_ID", "foreign-codex-session"
             ; "C2C_MCP_AUTO_REGISTER_ALIAS", "foreign-codex-alias"
             ; "C2C_MCP_BROKER_ROOT", "/foreign/codex/broker" ] (fun () ->
      let default = run_setup ~alias:"installer-hint" in
      check bool "default leaves MCP absent" false
        (C2c_hermes_config.mcp_configured (read_file (config_path home)));
      check bool "recommendation returned" true
        (List.mem_assoc "mcp_recommendation" default.C2c_setup.extra_json);
      check bool "formatting canary recommendation returned" true
        (List.mem_assoc "gateway_canary_recommendation" default.C2c_setup.extra_json);
      check bool "formatting canary is not sent by setup" true
        (List.assoc "gateway_canary_recommendation" default.C2c_setup.extra_json
         = `String C2c_setup.hermes_gateway_canary_recommendation);
      let run () = C2c_setup.setup_hermes ~with_mcp:true
        ~server_path:"/opt/c2c-mcp-server" ~broker_root_opt:None
        ~output_mode:C2c_types.Json ~dry_run:false ~root:"/installer/root"
        ~alias_val:"installer-hint" ~alias_from_auto_gen:false in
      let result = run () in
      let out = read_file (config_path home) in
      check bool "opt-in detected by upgrade path" true (C2c_setup.client_mcp_configured "hermes");
      check bool "Hermes in upgrade set" true (List.mem "hermes" C2c_setup.mcp_upgrade_check_clients);
      check bool "connection startup mode" true (contains_line out "args: [\"--hermes-connection\"]");
      List.iter (fun forbidden -> check bool ("no captured " ^ forbidden) false
        (try ignore (Str.search_forward (Str.regexp_string forbidden) out 0); true with Not_found -> false))
        [ "foreign-codex"; "/foreign/codex"; "/installer/root"; "installer-hint"; "env:"; "cwd:" ];
      check bool "MCP ownership recorded" true
        (List.exists (fun (a : C2c_install_manifest.artifact) -> a.key = Some "mcp_servers.c2c") result.artifacts);
      ignore (run ());
      check string "second install identical" out (read_file (config_path home));
      check int "private config mode" 0o600 ((Unix.stat (config_path home)).Unix.st_perm)))

let test_mcp_dry_run_and_active_home () =
  with_temp_home (fun home ->
    let active = home // "active-hermes" in
    with_env ["HERMES_HOME", active] (fun () ->
      let run dry_run = C2c_setup.setup_hermes ~with_mcp:true
        ~server_path:"/opt/c2c-mcp-server" ~broker_root_opt:None
        ~output_mode:C2c_types.Json ~dry_run ~root:"unused"
        ~alias_val:"unused" ~alias_from_auto_gen:false in
      ignore (run true);
      check bool "dry-run writes nothing" false (Sys.file_exists active);
      ignore (run false);
      check bool "active config written" true (Sys.file_exists (active // "config.yaml"));
      check bool "default profile untouched" false (Sys.file_exists (config_path home));
      check bool "active config detected" true (C2c_setup.client_mcp_configured "hermes")))

let test_mcp_multiline_scalar_refused () =
  List.iter (fun quote ->
    let input = "description: " ^ quote ^ "\nplugins:\n  enabled: [keep]\nmcp_servers:\n  other:\n    command: keep\n    " ^ quote ^ "\n" in
    check bool "scalar content is not MCP config" false (C2c_hermes_config.mcp_configured input);
    (match C2c_hermes_config.disable_mcp input with
     | Error _ -> () | Ok _ -> fail "multiline scalar uninstall must refuse");
    List.iter (fun with_mcp -> with_temp_home (fun home ->
      Unix.mkdir (home // ".hermes") 0o700;
      write_file (config_path home) input;
      let result = C2c_setup.setup_hermes ~with_mcp ~server_path:"server" ~broker_root_opt:None
        ~output_mode:C2c_types.Json ~dry_run:false ~root:"unused" ~alias_val:"hint" ~alias_from_auto_gen:false in
      check string "both config edits refused before plugin merge" input (read_file (config_path home));
      check bool "refusal reported" true (List.mem_assoc "warning" result.extra_json))) [false; true])
    ["\""; "'"]

let test_mcp_line_separators_refused () =
  List.iter (fun separator ->
    let input = String.concat separator
      ["model: keep"; "mcp_servers:"; "  foreign:"; "    command: keep"] ^ "\n" in
    check bool "hidden MCP mapping not accepted" false (C2c_hermes_config.mcp_configured input);
    (match C2c_hermes_config.disable_mcp input with
     | Error _ -> () | Ok _ -> fail "unsupported line separators must refuse uninstall");
    with_temp_home (fun home ->
      Unix.mkdir (home // ".hermes") 0o700;
      write_file (config_path home) input;
      let result = C2c_setup.setup_hermes ~with_mcp:true ~server_path:"server" ~broker_root_opt:None
        ~output_mode:C2c_types.Json ~dry_run:false ~root:"unused" ~alias_val:"hint" ~alias_from_auto_gen:false in
      check string "line separator refusal preserves bytes" input (read_file (config_path home));
      check bool "line separator refusal reported" true (List.mem_assoc "warning" result.extra_json)))
    ["\r"; "\194\133"; "\226\128\168"; "\226\128\169"]

let test_mcp_foreign_identity_report () =
  with_temp_home (fun home ->
    Unix.mkdir (home // ".hermes") 0o700;
    write_file (config_path home) "mcp_servers:\n  c2c:\n    command: foreign\n";
    List.iter (fun with_mcp ->
      let result = C2c_setup.setup_hermes ~with_mcp ~server_path:"server" ~broker_root_opt:None
        ~output_mode:C2c_types.Json ~dry_run:false ~root:"unused" ~alias_val:"hint" ~alias_from_auto_gen:false in
      check bool "foreign identity explicitly unverified" true
        (List.assoc "mcp_identity" result.extra_json = `String "unverified; existing foreign MCP configuration preserved");
      check bool "foreign warning in either mode" true (List.mem_assoc "warning" result.extra_json))
      [false; true])

let test_mcp_human_recommendation () =
  with_temp_home (fun home ->
    let path = home // "stdout" in
    let oc = open_out path in
    flush stdout;
    let saved = Unix.dup Unix.stdout in
    Fun.protect ~finally:(fun () -> flush stdout; Unix.dup2 saved Unix.stdout; Unix.close saved; close_out oc)
      (fun () ->
        Unix.dup2 (Unix.descr_of_out_channel oc) Unix.stdout;
        ignore (C2c_setup.setup_hermes ~with_mcp:false ~server_path:""
          ~broker_root_opt:None ~output_mode:C2c_types.Human ~dry_run:false
          ~root:"unused" ~alias_val:"hint" ~alias_from_auto_gen:false));
    let out = read_file path in
    List.iter (fun expected -> check bool expected true
      (try ignore (Str.search_forward (Str.regexp_string expected) out 0); true with Not_found -> false))
      [ "Recommended: c2c install hermes --with-mcp"; "explicit opt-in"
      ; "separate connection-owned identity"; "do not enable inbound wake or grant injection consent"
      ; "Optional formatting canary (never sent by setup)"
      ; "literal <markup> & emoji" ])

let () =
  run "c2c_setup_hermes"
    [ ( "B376 MCP opt-in",
        [ test_case "surgical merge and managed uninstall" `Quick test_mcp_surgical_round_trip
        ; test_case "foreign config preserved" `Quick test_mcp_foreign_preserved
        ; test_case "ambiguous YAML refused" `Quick test_mcp_shape_safety
        ; test_case "BOM CRLF and intentional root" `Quick test_mcp_bom_crlf_no_newline
        ; test_case "installer opt-in and foreign identity" `Quick test_mcp_installer_opt_in_and_identity
        ; test_case "dry run and active home" `Quick test_mcp_dry_run_and_active_home
        ; test_case "multiline quoted scalar refused" `Quick test_mcp_multiline_scalar_refused
        ; test_case "unsupported line separators refused" `Quick test_mcp_line_separators_refused
        ; test_case "foreign identity unverified" `Quick test_mcp_foreign_identity_report
        ; test_case "human recommendation" `Quick test_mcp_human_recommendation ])
    ; ( "config.yaml merge"
      , [ test_case "PyYAML block style (real config shape)" `Quick
            test_pyyaml_block_style
        ; test_case "new item shares the existing item column" `Quick
            test_item_column_matches_existing_items
        ; test_case "4-space item list" `Quick test_four_space_items
        ; test_case "enabled: [] inline flow list" `Quick test_empty_flow_list
        ; test_case "enabled: [foo] inline flow list" `Quick
            test_populated_flow_list
        ; test_case "flow list trailing comment preserved" `Quick
            test_flow_list_keeps_trailing_comment
        ; test_case "already enabled is byte-identical" `Quick
            test_already_enabled_is_byte_identical
        ; test_case "already enabled in a flow list" `Quick
            test_already_enabled_in_flow_list
        ; test_case "c2c under disabled is not enabled" `Quick
            test_disabled_entry_is_not_enabled
        ; test_case "c2c stripped from a disabled flow list" `Quick
            test_disabled_flow_entry_stripped
        ; test_case "plugins: without enabled: keeps siblings" `Quick
            test_plugins_without_enabled_key_keeps_siblings
        ; test_case "unrelated enabled: after plugins untouched" `Quick
            test_unrelated_enabled_key_untouched
        ; test_case "unrelated enabled: before plugins untouched" `Quick
            test_unrelated_enabled_before_plugins
        ; test_case "no plugins: key appends a block" `Quick
            test_no_plugins_key_appends_block
        ; test_case "no plugins: key and no trailing newline" `Quick
            test_no_plugins_key_without_trailing_newline
        ; test_case "empty content creates the block" `Quick
            test_empty_content_creates_block
        ; test_case "CRLF preserved" `Quick test_crlf_preserved
        ; test_case "missing trailing newline preserved" `Quick
            test_no_trailing_newline_preserved
        ; test_case "mixed line endings refused" `Quick
            test_mixed_line_endings_refused
        ; test_case "tab indentation refused" `Quick test_tab_indent_refused
        ] )
    ; ( "key recognition is total"
      , [ test_case "UTF-8 BOM parsed and preserved" `Quick
            test_bom_parsed_and_preserved
        ; test_case "quoted \"plugins\": key refused" `Quick
            test_quoted_plugins_key_refused
        ; test_case "`plugins :` (space before colon) refused" `Quick
            test_space_before_colon_refused
        ; test_case "quoted \"enabled\": key refused" `Quick
            test_quoted_enabled_key_refused
        ; test_case "quoted \"disabled\": key refused" `Quick
            test_quoted_disabled_key_refused
        ; test_case "unparsed duplicate plugins: key refused" `Quick
            test_unparsed_duplicate_plugins_key_refused
        ; test_case "a colon inside a value is not a key" `Quick
            test_colon_inside_a_value_is_not_a_key
        ; test_case "`- plugins:` sequence item is not a key" `Quick
            test_sequence_item_is_not_a_key
        ] )
    ; ( "value shape recognition is total"
      , [ test_case "plugins: sequence at the key column refused" `Quick
            test_plugins_sequence_at_key_column_refused
        ; test_case "plugins: indented sequence refused" `Quick
            test_plugins_indented_sequence_refused
        ; test_case "whole-document flow mapping refused" `Quick
            test_whole_document_flow_mapping_refused
        ; test_case "root sequence document refused" `Quick
            test_root_sequence_document_refused
        ; test_case "flow root behind a `---` marker refused" `Quick
            test_doc_marker_then_flow_root_refused
        ; test_case "bare scalar document refused" `Quick
            test_bare_scalar_document_refused
        ; test_case "content on the `---` marker refused" `Quick
            test_content_on_doc_marker_refused
        ; test_case "`---` / %YAML then a block mapping still edits" `Quick
            test_doc_marker_then_block_mapping_still_edits
        ; test_case "comment-only document appends" `Quick
            test_comment_only_document_appends
        ] )
    ; ( "atomic write (the merge's write path)"
      , [ test_case "?perm is applied before the rename" `Quick
            test_atomic_write_perm
        ; test_case "a successful write leaves no .tmp" `Quick
            test_atomic_write_no_stray_tmp
        ; test_case "a failed open does not delete a foreign .tmp" `Quick
            test_atomic_write_keeps_foreign_tmp
        ] )
    ; ( "uninstall direction"
      , [ test_case "strips only the enabled entry" `Quick
            test_disable_strips_entry_only
        ; test_case "last entry collapses to []" `Quick
            test_disable_last_entry_yields_explicit_empty_list
        ; test_case "flow list entry removed" `Quick test_disable_flow_list
        ; test_case "no-op when c2c is absent" `Quick
            test_disable_is_noop_when_absent
        ; test_case "enable then disable round-trips" `Quick
            test_enable_disable_round_trip
        ] )
    ; ( "setup_hermes end-to-end"
      , [ test_case "writes plugin files and enables the plugin" `Quick
            test_install_writes_plugin_and_enables
        ; test_case "install is idempotent" `Quick test_install_is_idempotent
        ; test_case "creates config.yaml when absent" `Quick
            test_install_with_no_config_file
        ; test_case "--dry-run writes nothing" `Quick
            test_install_dry_run_writes_nothing
        ; test_case "refuses a tab-indented config without corrupting it" `Quick
            test_install_refuses_tab_indented_config_without_corrupting_it
        ] )
    ]
