(* Unit tests for C2c_post_compact_hook (slice #349b).
 *
 * Exercises format_post_compact_payload directly against an on-disk
 * fixture tree, no broker / no env / no exit. Each test builds a fresh
 * tmpdir under Filename.get_temp_dir_name (), populates the relevant
 * subdirs (.c2c/memory/<alias>, .collab/findings, etc.), and asserts on
 * substrings in the emitted JSON's additionalContext field.
 *)

open Alcotest

let temp_dir prefix =
  let base = Filename.get_temp_dir_name () in
  let rec loop n =
    let name = Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) n in
    let path = Filename.concat base name in
    try Unix.mkdir path 0o755; path
    with Unix.Unix_error (Unix.EEXIST, _, _) -> loop (n + 1)
  in
  loop 0

let rec rm_rf path =
  match (try Some (Unix.lstat path) with _ -> None) with
  | None -> ()
  | Some st ->
    if st.Unix.st_kind = Unix.S_DIR then begin
      let entries = try Sys.readdir path with _ -> [||] in
      Array.iter (fun n -> rm_rf (Filename.concat path n)) entries;
      (try Unix.rmdir path with _ -> ())
    end else
      (try Unix.unlink path with _ -> ())

let mkdir_p path =
  let parts = String.split_on_char '/' path in
  let acc = ref (if String.length path > 0 && path.[0] = '/' then "/" else ".") in
  List.iter (fun p ->
    if p <> "" then begin
      acc := Filename.concat !acc p;
      try Unix.mkdir !acc 0o755
      with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  ) parts

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc contents;
  close_out oc

(* Substring helper because OCaml stdlib lacks String.contains_substring. *)
let contains_substr s needle =
  let nlen = String.length needle in
  let slen = String.length s in
  if nlen = 0 then true
  else if nlen > slen then false
  else
    let rec scan i =
      if i + nlen > slen then false
      else if String.sub s i nlen = needle then true
      else scan (i + 1)
    in
    scan 0

(* Pull the additionalContext field out of the JSON the lib emits. *)
let extract_additional_context json_str =
  match Yojson.Safe.from_string json_str with
  | `Assoc top ->
    (match List.assoc_opt "hookSpecificOutput" top with
     | Some (`Assoc inner) ->
       (match List.assoc_opt "additionalContext" inner with
        | Some (`String s) -> s
        | _ -> failwith "additionalContext not a string")
     | _ -> failwith "hookSpecificOutput missing")
  | _ -> failwith "payload not a JSON object"

let with_fixture f =
  let dir = temp_dir "c2c-post-compact-test" in
  let cleanup () = rm_rf dir in
  Fun.protect ~finally:cleanup (fun () -> f dir)

let payload_of ~alias ~repo =
  let args = C2c_post_compact_hook.Args.make
      ~alias ~repo ~ts:"2026-04-28T00:00:00Z"
  in
  C2c_post_compact_hook.format_post_compact_payload args

(* ---------- tests ---------- *)

(* T1: own memory entries within the configured window (max_entries=5
   in the binary; we drop several files and confirm recent ones land
   in the emitted block). *)
let test_recent_memory_in_window () =
  with_fixture (fun repo ->
    let alias = "test-quill" in
    let mem_dir = Filename.concat repo (".c2c/memory/" ^ alias) in
    write_file (Filename.concat mem_dir "alpha-note.md")
      "---\nname: alpha-note\ndescription: Alpha description here.\nshared: false\n---\nbody\n";
    write_file (Filename.concat mem_dir "beta-note.md")
      "---\nname: beta-note\ndescription: Beta description here.\nshared: false\n---\nbody\n";
    let payload = payload_of ~alias ~repo in
    let ctx = extract_additional_context payload in
    check bool "alpha-note present"  true (contains_substr ctx "alpha-note");
    check bool "alpha desc present"  true (contains_substr ctx "Alpha description");
    check bool "beta-note present"   true (contains_substr ctx "beta-note"))

(* T2: window/cap excludes entries beyond max_entries=5. We write 7
   own-memory files; by reverse-sorted name, the bottom 2 must NOT
   appear in the output. *)
let test_memory_window_excludes_overflow () =
  with_fixture (fun repo ->
    let alias = "test-quill" in
    let mem_dir = Filename.concat repo (".c2c/memory/" ^ alias) in
    let names = ["a01"; "a02"; "a03"; "a04"; "a05"; "a06"; "a07"] in
    List.iter (fun n ->
      write_file (Filename.concat mem_dir (n ^ ".md"))
        (Printf.sprintf "---\nname: %s\ndescription: desc-%s\nshared: false\n---\nbody\n" n n)
    ) names;
    let payload = payload_of ~alias ~repo in
    let ctx = extract_additional_context payload in
    (* Sort is reverse-lexicographic, capped at 5 -> a07..a03 keeps,
       a02 & a01 drop out of memory section. *)
    check bool "a07 (newest) kept" true  (contains_substr ctx "desc-a07");
    check bool "a03 (5th) kept"    true  (contains_substr ctx "desc-a03");
    check bool "a02 outside window dropped" false (contains_substr ctx "desc-a02");
    check bool "a01 outside window dropped" false (contains_substr ctx "desc-a01"))

(* T3: empty memory tree — payload still well-formed, all envelope
   sections present, and the memory section body is empty. *)
let test_empty_memory_graceful () =
  with_fixture (fun repo ->
    let alias = "test-quill" in
    (* Don't create any memory dirs at all. *)
    let payload = payload_of ~alias ~repo in
    let ctx = extract_additional_context payload in
    check bool "envelope kind"      true (contains_substr ctx "kind=\"post-compact\"");
    check bool "reflex section"     true (contains_substr ctx "operational-reflex-reminder");
    check bool "memory section tag" true (contains_substr ctx "label=\"memory-entries\"");
    check bool "no own- prefix"     false (contains_substr ctx "(own)");
    check bool "no shared from"     false (contains_substr ctx "(from "))

(* T4: privacy — peer notes are visible only when shared_with includes
   our alias; private peer notes (shared: false, no shared_with) stay
   hidden. *)
let test_privacy_shared_with_me () =
  with_fixture (fun repo ->
    let alias = "test-quill" in
    let peer = "peer-fox" in
    let bystander = "peer-private" in
    let peer_dir = Filename.concat repo (".c2c/memory/" ^ peer) in
    let bystander_dir = Filename.concat repo (".c2c/memory/" ^ bystander) in
    write_file (Filename.concat peer_dir "shared-note.md")
      (Printf.sprintf
        "---\nname: shared-note\ndescription: Hand-off for quill.\nshared_with: [%s]\n---\nbody\n"
        alias);
    write_file (Filename.concat bystander_dir "private-note.md")
      "---\nname: private-note\ndescription: Strictly private.\nshared: false\n---\nbody\n";
    let payload = payload_of ~alias ~repo in
    let ctx = extract_additional_context payload in
    check bool "shared_with peer note visible"
      true  (contains_substr ctx "shared-note");
    check bool "shared_with peer note attributed"
      true  (contains_substr ctx ("(from " ^ peer ^ ")"));
    check bool "private peer note hidden"
      false (contains_substr ctx "private-note");
    check bool "private peer not attributed"
      false (contains_substr ctx ("(from " ^ bystander ^ ")")))

(* T5: findings filter — only files whose name contains `-<alias>-`
   land in the recent-findings section. *)
let test_findings_alias_filter () =
  with_fixture (fun repo ->
    let alias = "test-quill" in
    let findings_dir = Filename.concat repo ".collab/findings" in
    write_file
      (Filename.concat findings_dir
        (Printf.sprintf "2026-04-28T00-00-00Z-%s-mine.md" alias))
      "# Title\n\nMy own finding paragraph.\n";
    write_file
      (Filename.concat findings_dir
        "2026-04-28T01-00-00Z-someone-else-theirs.md")
      "# Their title\n\nNot for us.\n";
    let payload = payload_of ~alias ~repo in
    let ctx = extract_additional_context payload in
    check bool "alias-matched finding present"
      true  (contains_substr ctx "mine.md");
    check bool "alias-matched paragraph present"
      true  (contains_substr ctx "My own finding paragraph");
    check bool "non-matching finding excluded"
      false (contains_substr ctx "theirs.md"))

let () =
  Alcotest.run "post_compact_hook"
    [ "format_post_compact_payload",
      [ "recent memory entries appear",        `Quick, test_recent_memory_in_window;
        "entries past window excluded",        `Quick, test_memory_window_excludes_overflow;
        "empty memory handled gracefully",     `Quick, test_empty_memory_graceful;
        "privacy: shared_with_me vs private",  `Quick, test_privacy_shared_with_me;
        "findings filtered by alias",          `Quick, test_findings_alias_filter;
      ] ]
