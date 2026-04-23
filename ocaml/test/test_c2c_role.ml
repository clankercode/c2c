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

let () =
  Alcotest.run "c2c_role" [ "renderers", tests ]
