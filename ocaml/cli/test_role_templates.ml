(* test_role_templates — smoke tests for Role_templates.lookup / render *)
open Alcotest

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let test_lookup_known () =
  check (option string) "coder lookup" (Some "role_template_src|---")
    (Option.map (fun s -> String.sub s 0 14) (Role_templates.lookup "coder"));
  check (option string) "coordinator lookup" (Some "role_template_src|---")
    (Option.map (fun s -> String.sub s 0 14) (Role_templates.lookup "coordinator"));
  check (option string) "subagent lookup" (Some "role_template_src|---")
    (Option.map (fun s -> String.sub s 0 14) (Role_templates.lookup "subagent"))

let test_lookup_unknown () =
  check (option string) "unknown lookup" None
    (Role_templates.lookup "nonexistent-role-class");
  check (option string) "empty lookup" None
    (Role_templates.lookup "")

let test_render_known_coder () =
  match Role_templates.render ~role_class:"coder" ~alias:"test-alias" ~display_name_hint:" (aka TC)" with
  | None -> failwith "render returned None for known coder class"
  | Some body ->
      (* alias must be substituted — no remaining {alias} placeholder *)
      check bool "no remaining {alias} placeholder" false
        (string_contains body "{alias}");
      (* heartbeat block must be verbatim in output *)
      check bool "heartbeat block present" true
        (string_contains body "heartbeat 4.1m");
      (* peer-PASS sentence must be present *)
      check bool "peer-PASS sentence present" true
        (string_contains body "peer-PASS")

let test_render_known_coordinator () =
  match Role_templates.render ~role_class:"coordinator" ~alias:"coord-alias" ~display_name_hint:"" with
  | None -> failwith "render returned None for known coordinator class"
  | Some body ->
      check bool "heartbeat block present" true
        (string_contains body "heartbeat 4.1m");
      check bool "sitrep tick present" true
        (string_contains body "sitrep tick")

let test_render_unknown () =
  check (option string) "render unknown" None
    (Role_templates.render ~role_class:"unknown-class" ~alias:"x" ~display_name_hint:"")

let test_render_alias_substitution () =
  match Role_templates.render ~role_class:"subagent" ~alias:"my-alias" ~display_name_hint:"" with
  | None -> failwith "render returned None for subagent"
  | Some body ->
      (* no {alias} placeholder should remain *)
      check bool "no remaining alias placeholder" false
        (string_contains body "{alias}")

let () =
  run "role_templates" [
    "lookup", [
      test_case "known classes return Some"      `Quick test_lookup_known;
      test_case "unknown classes return None"    `Quick test_lookup_unknown;
    ];
    "render", [
      test_case "coder body has heartbeat + peer-PASS" `Quick test_render_known_coder;
      test_case "coordinator body has sitrep tick"     `Quick test_render_known_coordinator;
      test_case "unknown class returns None"            `Quick test_render_unknown;
      test_case "alias placeholder fully substituted"  `Quick test_render_alias_substitution;
    ];
  ]
