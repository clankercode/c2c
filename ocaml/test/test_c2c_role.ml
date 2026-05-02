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

let input_yaml_with_pronouns = {|
---
description: Role with pronouns
role: primary
pronouns: she/her
---

You are a test agent.
|}

let role_input = C2c_role.parse_string input_yaml
let role_input_with_steps = C2c_role.parse_string input_yaml_with_steps
let role_input_with_pronouns = C2c_role.parse_string input_yaml_with_pronouns

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
  let output = C2c_role.Claude_renderer.render role_input ~name:"test-agent" in
  contains ~msg:"claude: name field present" ~pattern:"name: test-agent" output;
  contains ~msg:"claude: description field present" ~pattern:"description: Test role for regression" output;
  contains ~msg:"claude: prompt prepends body" ~pattern:"primary\n\nYou are a test agent" output;
  contains ~msg:"claude: claude section present" ~pattern:"claude:" output

let test_codex_renderer () =
  let output = C2c_role.Codex_renderer.render role_input in
  contains ~msg:"codex: description field present" ~pattern:"description: Test role for regression" output;
  contains ~msg:"codex: role field present" ~pattern:"role: primary" output;
  contains ~msg:"codex: c2c commented" ~pattern:"# c2c:" output;
  contains ~msg:"codex: codex section present" ~pattern:"codex:" output

let test_kimi_renderer () =
  let output = C2c_role.Kimi_renderer.render role_input ~name:"test-role" in
  contains ~msg:"kimi: version present" ~pattern:"version: 1" output;
  contains ~msg:"kimi: agent section present" ~pattern:"agent:" output;
  contains ~msg:"kimi: name present" ~pattern:"name: test-role" output;
  contains ~msg:"kimi: system_prompt_path present" ~pattern:"system_prompt_path: ./system.md" output;
  contains ~msg:"kimi: extend default present" ~pattern:"extend: default" output

let test_roundtrip_opencode () =
  let rendered = C2c_role.OpenCode_renderer.render role_input in
  let re_parsed = C2c_role.parse_string rendered in
  Alcotest.(check string) "roundtrip: description preserved" "Test role for regression" re_parsed.C2c_role.description;
  Alcotest.(check string) "roundtrip: role preserved" "primary" re_parsed.C2c_role.role;
  Alcotest.(check int) "roundtrip: c2c_auto_join_rooms count" 2 (List.length re_parsed.C2c_role.c2c_auto_join_rooms)

(* [#423 Stage 1] array fields that were silently dropped in rendering:
   compatible_clients, required_capabilities, include_.  These must survive
   a parse → OpenCode_renderer.render → parse roundtrip. *)
let test_roundtrip_array_fields () =
  let input = {|
---
description: Array fields test
role: primary
include: [snippet-a, snippet-b]
compatible_clients: [opencode, claude]
required_capabilities: [mcp, stdio]
---
body
|}
  in
  let role = C2c_role.parse_string input in
  Alcotest.(check (list string)) "parse: include_" ["snippet-a"; "snippet-b"] role.C2c_role.include_;
  Alcotest.(check (list string)) "parse: compatible_clients" ["opencode"; "claude"] role.C2c_role.compatible_clients;
  Alcotest.(check (list string)) "parse: required_capabilities" ["mcp"; "stdio"] role.C2c_role.required_capabilities;
  let rendered = C2c_role.OpenCode_renderer.render role in
  let re_parsed = C2c_role.parse_string rendered in
  Alcotest.(check (list string)) "roundtrip: include_ preserved" ["snippet-a"; "snippet-b"] re_parsed.C2c_role.include_;
  Alcotest.(check (list string)) "roundtrip: compatible_clients preserved" ["opencode"; "claude"] re_parsed.C2c_role.compatible_clients;
  Alcotest.(check (list string)) "roundtrip: required_capabilities preserved" ["mcp"; "stdio"] re_parsed.C2c_role.required_capabilities

let test_pronouns_parse () =
  Alcotest.(check (option string)) "pronouns parsed from input" (Some "she/her") role_input_with_pronouns.C2c_role.pronouns

let test_pronouns_render_opencode () =
  let output = C2c_role.OpenCode_renderer.render role_input_with_pronouns in
  contains ~msg:"opencode: pronouns field present" ~pattern:"pronouns: she/her" output

let test_pronouns_render_claude () =
  let output = C2c_role.Claude_renderer.render role_input_with_pronouns ~name:"test-agent" in
  contains_not ~msg:"claude: pronouns NOT emitted (not spec-compliant)" ~pattern:"pronouns:" output

let test_pronouns_render_codex () =
  let output = C2c_role.Codex_renderer.render role_input_with_pronouns in
  contains ~msg:"codex: pronouns field present" ~pattern:"pronouns: she/her" output

let test_pronouns_render_kimi () =
  let output = C2c_role.Kimi_renderer.render role_input_with_pronouns ~name:"test-pronouns" in
  contains ~msg:"kimi: name present" ~pattern:"name: test-pronouns" output;
  contains ~msg:"kimi: when_to_use from description" ~pattern:"when_to_use: Role with pronouns" output

let test_pronouns_roundtrip () =
  let rendered = C2c_role.OpenCode_renderer.render role_input_with_pronouns in
  let re_parsed = C2c_role.parse_string rendered in
  Alcotest.(check (option string)) "roundtrip: pronouns preserved" (Some "she/her") re_parsed.C2c_role.pronouns

let test_c2c_heartbeat_frontmatter_parse () =
  let role =
    C2c_role.parse_string
      "---\n\
       description: Heartbeat role\n\
       role: primary\n\
       role_class: coordinator\n\
       c2c:\n\
       \  heartbeat:\n\
       \    message: \"Role default tick\"\n\
       \    interval: 5m\n\
       \  heartbeats:\n\
       \    sitrep:\n\
       \      interval: 1h\n\
       \      message: \"Write sitrep\"\n\
       \    quota:\n\
       \      interval: 15m\n\
       \      command: \"printf quota\"\n\
       ---\n\
       body\n"
  in
  Alcotest.(check (option string)) "default message"
    (Some "Role default tick")
    (List.assoc_opt "c2c.heartbeat.message" role.C2c_role.c2c_heartbeat);
  Alcotest.(check (option string)) "default interval"
    (Some "5m")
    (List.assoc_opt "c2c.heartbeat.interval" role.C2c_role.c2c_heartbeat);
  Alcotest.(check (option string)) "named sitrep interval"
    (Some "1h")
    (List.assoc_opt "c2c.heartbeats.sitrep.interval"
       role.C2c_role.c2c_heartbeats);
  Alcotest.(check (option string)) "named quota command"
    (Some "printf quota")
    (List.assoc_opt "c2c.heartbeats.quota.command"
       role.C2c_role.c2c_heartbeats)

let test_c2c_heartbeat_roundtrip_opencode () =
  let role =
    C2c_role.parse_string
      "---\n\
       description: Heartbeat role\n\
       role: primary\n\
       c2c:\n\
       \  heartbeat:\n\
       \    message: \"Role default tick\"\n\
       \  heartbeats:\n\
       \    sitrep:\n\
       \      schedule: \"@1h+7m\"\n\
       \      message: \"Write sitrep\"\n\
       ---\n\
       body\n"
  in
  let rendered = C2c_role.OpenCode_renderer.render role in
  let reparsed = C2c_role.parse_string rendered in
  Alcotest.(check (option string)) "roundtrip default message"
    (Some "Role default tick")
    (List.assoc_opt "c2c.heartbeat.message"
       reparsed.C2c_role.c2c_heartbeat);
  Alcotest.(check (option string)) "roundtrip named schedule"
    (Some "@1h+7m")
    (List.assoc_opt "c2c.heartbeats.sitrep.schedule"
       reparsed.C2c_role.c2c_heartbeats)

let tests = [
  "opencode_renderer",            `Quick, test_opencode_renderer;
  "opencode_renderer_default_steps", `Quick, test_opencode_renderer_default_steps;
  "opencode_renderer_user_steps", `Quick, test_opencode_renderer_user_steps_preserved;
  "claude_renderer",             `Quick, test_claude_renderer;
  "codex_renderer",              `Quick, test_codex_renderer;
  "kimi_renderer",               `Quick, test_kimi_renderer;
  "roundtrip",                   `Quick, test_roundtrip_opencode;
  "roundtrip_array_fields",      `Quick, test_roundtrip_array_fields;
  "pronouns_parse",              `Quick, test_pronouns_parse;
  "pronouns_render_opencode",     `Quick, test_pronouns_render_opencode;
  "pronouns_render_claude",       `Quick, test_pronouns_render_claude;
  "pronouns_render_codex",        `Quick, test_pronouns_render_codex;
  "pronouns_render_kimi",         `Quick, test_pronouns_render_kimi;
  "pronouns_roundtrip",           `Quick, test_pronouns_roundtrip;
  "c2c_heartbeat_frontmatter_parse", `Quick, test_c2c_heartbeat_frontmatter_parse;
  "c2c_heartbeat_roundtrip_opencode", `Quick, test_c2c_heartbeat_roundtrip_opencode;
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

(* ---------- model field suppression by compatible_clients ---------- *)

let role_single_client_with_model = {|
---
description: Single-client role
role: primary
model: claude-sonnet-4-6
compatible_clients: [claude]
---

You are a test agent.
|}

let role_multi_client_with_model = {|
---
description: Multi-client role
role: primary
model: claude-sonnet-4-6
compatible_clients: [claude, opencode, codex]
---

You are a test agent.
|}

let role_single_client_no_model = {|
---
description: Single-client role no model
role: primary
compatible_clients: [opencode]
---

You are a test agent.
|}

let role_multi_client_no_model = {|
---
description: Multi-client role no model
role: primary
compatible_clients: [claude, codex]
---

You are a test agent.
|}

let test_model_single_client_emits () =
  let r = C2c_role.parse_string role_single_client_with_model in
  Alcotest.(check (option string)) "single-client: model parsed" (Some "claude-sonnet-4-6") r.C2c_role.model;
  Alcotest.(check int) "single-client: compatible_clients count" 1 (List.length r.C2c_role.compatible_clients);
  let output = C2c_role.Claude_renderer.render r ~name:"test" in
  Alcotest.(check bool) "single-client: model emitted in claude renderer" true
    (try ignore (Str.search_forward (Str.regexp_string "model: claude-sonnet-4-6") output 0); true with Not_found -> false)

let test_model_multi_client_suppressed () =
  let r = C2c_role.parse_string role_multi_client_with_model in
  Alcotest.(check (option string)) "multi-client: model parsed" (Some "claude-sonnet-4-6") r.C2c_role.model;
  Alcotest.(check int) "multi-client: compatible_clients count" 3 (List.length r.C2c_role.compatible_clients);
  let output = C2c_role.Claude_renderer.render r ~name:"test" in
  Alcotest.(check bool) "multi-client: model SUPPRESSED in claude renderer" true
    (try ignore (Str.search_forward (Str.regexp_string "model:") output 0); false with Not_found -> true)

let test_model_opencode_single_client_emits () =
  let r = C2c_role.parse_string role_single_client_with_model in
  let r_opencode = { r with C2c_role.compatible_clients = ["opencode"] } in
  let output = C2c_role.OpenCode_renderer.render r_opencode in
  Alcotest.(check bool) "opencode single-client: model emitted" true
    (try ignore (Str.search_forward (Str.regexp_string "model: claude-sonnet-4-6") output 0); true with Not_found -> false)

let test_model_opencode_multi_client_suppressed () =
  let r = C2c_role.parse_string role_multi_client_with_model in
  let output = C2c_role.OpenCode_renderer.render r in
  Alcotest.(check bool) "opencode multi-client: model SUPPRESSED" true
    (try ignore (Str.search_forward (Str.regexp_string "model:") output 0); false with Not_found -> true)

let test_model_codex_multi_client_suppressed () =
  let r = C2c_role.parse_string role_multi_client_with_model in
  let output = C2c_role.Codex_renderer.render r in
  Alcotest.(check bool) "codex multi-client: model SUPPRESSED" true
    (try ignore (Str.search_forward (Str.regexp_string "model:") output 0); false with Not_found -> true)

let test_model_kimi_multi_client_suppressed () =
  let r = C2c_role.parse_string role_multi_client_with_model in
  let output = C2c_role.Kimi_renderer.render r ~name:"test" in
  Alcotest.(check bool) "kimi multi-client: model SUPPRESSED" true
    (try ignore (Str.search_forward (Str.regexp_string "model:") output 0); false with Not_found -> true)

let test_no_model_always_ok () =
  let r_multi = C2c_role.parse_string role_multi_client_no_model in
  let r_single = C2c_role.parse_string role_single_client_no_model in
  let output_multi = C2c_role.Claude_renderer.render r_multi ~name:"test" in
  let output_single = C2c_role.Claude_renderer.render r_single ~name:"test" in
  Alcotest.(check bool) "no model multi-client: no model field" true
    (try ignore (Str.search_forward (Str.regexp_string "model:") output_multi 0); false with Not_found -> true);
  Alcotest.(check bool) "no model single-client: no model field (pmodel not set)" true
    (try ignore (Str.search_forward (Str.regexp_string "model:") output_single 0); false with Not_found -> true)

let model_suppression_tests = [
  "single_client_emits",      `Quick, test_model_single_client_emits;
  "multi_client_suppressed",   `Quick, test_model_multi_client_suppressed;
  "opencode_single_client_emits", `Quick, test_model_opencode_single_client_emits;
  "opencode_multi_client_suppressed", `Quick, test_model_opencode_multi_client_suppressed;
  "codex_multi_client_suppressed", `Quick, test_model_codex_multi_client_suppressed;
  "kimi_multi_client_suppressed", `Quick, test_model_kimi_multi_client_suppressed;
  "no_model_always_ok",       `Quick, test_no_model_always_ok;
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

let test_role_class_to_room_reviewer () =
  Alcotest.(check (option string)) "reviewer -> reviewers"
    (Some "reviewers") (C2c_role.role_class_to_room "reviewer")

let test_role_class_to_room_coder () =
  Alcotest.(check (option string)) "coder -> coders"
    (Some "coders") (C2c_role.role_class_to_room "coder")

let test_role_class_to_room_empty () =
  Alcotest.(check (option string)) "empty string -> None"
    None (C2c_role.role_class_to_room "")

let test_role_class_to_room_whitespace () =
  Alcotest.(check (option string)) "whitespace only -> None"
    None (C2c_role.role_class_to_room "   ")

let test_role_class_to_room_security_review () =
  Alcotest.(check (option string)) "security-review -> security-reviews"
    (Some "security-reviews") (C2c_role.role_class_to_room "security-review")

let role_class_tests = [
  "reviewer",         `Quick, test_role_class_to_room_reviewer;
  "coder",            `Quick, test_role_class_to_room_coder;
  "empty_string",     `Quick, test_role_class_to_room_empty;
  "whitespace",       `Quick, test_role_class_to_room_whitespace;
  "security-review",  `Quick, test_role_class_to_room_security_review;
]

let () =
  Alcotest.run "c2c_role" [
    "renderers", tests;
    "pmodel", pmodel_tests;
    "frontmatter", frontmatter_tests;
    "role_class", role_class_tests;
    "model_suppression", model_suppression_tests;
  ]
