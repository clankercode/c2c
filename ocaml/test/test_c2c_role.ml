(* Test for c2c_role renderer regression coverage *)

let input_yaml = {|
---
description: Test role for regression
role: primary
c2c:
  alias: test-agent
  auto_join_rooms: [swarm-lounge, dev-room]
opencode:
  theme: exp33-black
claude:
  tools: [Read, Bash, Edit]
codex:
  option: value
kimi:
  setting: test
---

You are a test agent.
|}

let input_yaml_with_steps = {|
---
description: Role with user-set steps
role: primary
opencode:
  steps: 500
---

You are a test agent.
|}

let role_input = C2c_role.parse_string input_yaml
let role_input_with_steps = C2c_role.parse_string input_yaml_with_steps

let check_output ~msg ~pattern output =
  Alcotest.(check bool) msg true (Str.string_match (Str.regexp_string pattern) output 0)

let contains ~msg ~pattern output =
  Alcotest.(check bool) msg true (try ignore (Str.search_forward (Str.regexp_string pattern) output 0); true with Not_found -> false)

let contains_not ~msg ~pattern output =
  Alcotest.(check bool) msg true (try ignore (Str.search_forward (Str.regexp_string pattern) output 0); false with Not_found -> true)

let test_opencode_renderer () =
  let output = C2c_role.OpenCode_renderer.render role_input in
  contains ~msg:"opencode: description field present" ~pattern:"description: Test role for regression" output;
  contains ~msg:"opencode: role field present" ~pattern:"role: primary" output;
  contains ~msg:"opencode: c2c section present" ~pattern:"c2c:" output;
  contains ~msg:"opencode: opencode section present" ~pattern:"opencode:" output

let test_opencode_renderer_default_steps () =
  let output = C2c_role.OpenCode_renderer.render role_input in
  contains ~msg:"opencode: default steps injected" ~pattern:"steps: 9999" output

let test_opencode_renderer_user_steps_preserved () =
  let output = C2c_role.OpenCode_renderer.render role_input_with_steps in
  contains ~msg:"opencode: user-set steps preserved" ~pattern:"steps: 500" output;
  contains_not ~msg:"opencode: default steps NOT injected when user-set" ~pattern:"steps: 9999" output

let test_claude_renderer () =
  let output = C2c_role.Claude_renderer.render role_input in
  contains ~msg:"claude: description field present" ~pattern:"description: Test role for regression" output;
  contains ~msg:"claude: role field present" ~pattern:"role: primary" output;
  contains ~msg:"claude: c2c commented" ~pattern:"# c2c:" output;
  contains ~msg:"claude: claude section present" ~pattern:"claude:" output

let test_codex_renderer () =
  let output = C2c_role.Codex_renderer.render role_input in
  contains ~msg:"codex: description field present" ~pattern:"description: Test role for regression" output;
  contains ~msg:"codex: role field present" ~pattern:"role: primary" output;
  contains ~msg:"codex: c2c commented" ~pattern:"# c2c:" output;
  contains ~msg:"codex: codex section present" ~pattern:"codex:" output

let test_kimi_renderer () =
  let output = C2c_role.Kimi_renderer.render role_input in
  contains ~msg:"kimi: description field present" ~pattern:"description: Test role for regression" output;
  contains ~msg:"kimi: role field present" ~pattern:"role: primary" output;
  contains ~msg:"kimi: c2c commented" ~pattern:"# c2c:" output;
  contains ~msg:"kimi: kimi section present" ~pattern:"kimi:" output

let test_roundtrip_opencode () =
  let rendered = C2c_role.OpenCode_renderer.render role_input in
  let re_parsed = C2c_role.parse_string rendered in
  Alcotest.(check string) "roundtrip: description preserved" "Test role for regression" re_parsed.C2c_role.description;
  Alcotest.(check string) "roundtrip: role preserved" "primary" re_parsed.C2c_role.role;
  Alcotest.(check int) "roundtrip: c2c_auto_join_rooms count" 2 (List.length re_parsed.C2c_role.c2c_auto_join_rooms)

let tests = [
  "opencode_renderer",            `Quick, test_opencode_renderer;
  "opencode_renderer_default_steps", `Quick, test_opencode_renderer_default_steps;
  "opencode_renderer_user_steps", `Quick, test_opencode_renderer_user_steps_preserved;
  "claude_renderer",             `Quick, test_claude_renderer;
  "codex_renderer",              `Quick, test_codex_renderer;
  "kimi_renderer",               `Quick, test_kimi_renderer;
  "roundtrip",                   `Quick, test_roundtrip_opencode;
]

(* ---------- pmodel resolution ---------- *)

let role_with_pmodel = {|
---
description: Role with pmodel override
role: primary
pmodel: ":groq:openai/gpt-oss-120b"
role_class: coder
---

body
|}

let role_with_class_only = {|
---
description: Role with class only
role: primary
role_class: coder
---

body
|}

let role_with_neither = {|
---
description: Plain role
role: primary
---

body
|}

(* Fake class lookup simulating a config.toml [pmodel] table. *)
let class_lookup = function
  | "coder" -> Some "anthropic:claude-sonnet-4-6"
  | "default" -> Some "anthropic:claude-opus-4-7"
  | _ -> None

let test_resolve_pmodel_role_override_wins () =
  let r = C2c_role.parse_string role_with_pmodel in
  match C2c_role.resolve_pmodel r ~class_lookup with
  | Some s -> Alcotest.(check string) "role override wins" ":groq:openai/gpt-oss-120b" s
  | None -> Alcotest.fail "expected role-file pmodel to win"

let test_resolve_pmodel_class_lookup () =
  let r = C2c_role.parse_string role_with_class_only in
  match C2c_role.resolve_pmodel r ~class_lookup with
  | Some s -> Alcotest.(check string) "class lookup" "anthropic:claude-sonnet-4-6" s
  | None -> Alcotest.fail "expected class-level pmodel"

let test_resolve_pmodel_falls_back_to_default () =
  let r = C2c_role.parse_string role_with_neither in
  match C2c_role.resolve_pmodel r ~class_lookup with
  | Some s -> Alcotest.(check string) "default fallback" "anthropic:claude-opus-4-7" s
  | None -> Alcotest.fail "expected default fallback"

let test_resolve_pmodel_none_when_lookup_empty () =
  let r = C2c_role.parse_string role_with_neither in
  match C2c_role.resolve_pmodel r ~class_lookup:(fun _ -> None) with
  | Some _ -> Alcotest.fail "expected None when no class lookup matches"
  | None -> ()

let pmodel_tests = [
  "resolve_pmodel_role_override_wins", `Quick, test_resolve_pmodel_role_override_wins;
  "resolve_pmodel_class_lookup", `Quick, test_resolve_pmodel_class_lookup;
  "resolve_pmodel_falls_back_to_default", `Quick, test_resolve_pmodel_falls_back_to_default;
  "resolve_pmodel_none_when_lookup_empty", `Quick, test_resolve_pmodel_none_when_lookup_empty;
]

(* ---------- split_frontmatter noise-line tolerance ---------- *)

let role_with_html_comment_before_frontmatter = {|
<!-- NOTE: this comment should be skipped -->
---
description: Role with leading HTML comment
role: primary
---
Body text here.
|}

let test_split_frontmatter_skips_html_comment () =
  let r = C2c_role.parse_string role_with_html_comment_before_frontmatter in
  Alcotest.(check string) "html comment: description parsed correctly"
    "Role with leading HTML comment" r.C2c_role.description;
  Alcotest.(check string) "html comment: role parsed correctly"
    "primary" r.C2c_role.role;
  Alcotest.(check string) "html comment: body preserved"
    "Body text here." r.C2c_role.body

let role_with_shebang_before_frontmatter = {|
#!/bin/env python3
---
description: Role with shebang
role: subagent
---
Body.
|}

let test_split_frontmatter_skips_shebang () =
  let r = C2c_role.parse_string role_with_shebang_before_frontmatter in
  Alcotest.(check string) "shebang: description parsed" "Role with shebang" r.C2c_role.description;
  Alcotest.(check string) "shebang: role parsed" "subagent" r.C2c_role.role

(* ---------- load_snippet double-.md defense ---------- *)

let with_snippet_tmpdir ~f =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) "c2c_test_snippets" in
  (try Sys.mkdir dir 0o700 with Sys_error _ -> ());
  let snippet_file = Filename.concat dir "test-snippet.md" in
  let ch = open_out snippet_file in
  output_string ch "This is the snippet body.\n";
  close_out ch;
  Fun.protect ~finally:(fun () -> try Sys.remove snippet_file with _ -> ()) (fun () -> f dir)

let test_load_snippet_accepts_bare_name () =
  with_snippet_tmpdir ~f:(fun dir ->
    let r = C2c_role.parse_string ~snippets_dir:dir
      ("---\ninclude: [test-snippet]\n---\nmain body\n")
    in
    Alcotest.(check string) "bare name: snippet loaded into body"
      "This is the snippet body.\n\nmain body" r.C2c_role.body)

let test_load_snippet_accepts_md_suffix () =
  with_snippet_tmpdir ~f:(fun dir ->
    let r = C2c_role.parse_string ~snippets_dir:dir
      ("---\ninclude: [test-snippet.md]\n---\nmain body\n")
    in
    Alcotest.(check string) "md suffix: snippet loaded into body"
      "This is the snippet body.\n\nmain body" r.C2c_role.body)

let frontmatter_tests = [
  "skips_html_comment",    `Quick, test_split_frontmatter_skips_html_comment;
  "skips_shebang",        `Quick, test_split_frontmatter_skips_shebang;
  "load_snippet_bare",    `Quick, test_load_snippet_accepts_bare_name;
  "load_snippet_md_suffix", `Quick, test_load_snippet_accepts_md_suffix;
]

let () =
  Alcotest.run "c2c_role" [
    "renderers", tests;
    "pmodel", pmodel_tests;
    "frontmatter", frontmatter_tests;
  ]
