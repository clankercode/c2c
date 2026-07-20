(* Pure wake guidance — install vs managed-start manual-inbox flags. *)

let test_codex_install_requires_manual () =
  let a = C2c_wake_guidance.advice ~client:"codex" ~context:`Install in
  Alcotest.(check bool) "codex install manual" true a.manual_inbox_required;
  Alcotest.(check string) "wake NONE"
    "NONE" (C2c_wake_guidance.wake_class_label a.wake);
  Alcotest.(check bool) "has WARNING" true
    (List.exists (fun s -> String.length s > 10 && String.sub s 0 5 = "[c2c ") a.warning_lines)

let test_codex_managed_not_manual () =
  let a = C2c_wake_guidance.advice ~client:"codex" ~context:`Managed_start in
  Alcotest.(check bool) "managed codex not manual" false a.manual_inbox_required;
  Alcotest.(check string) "wake GUARANTEED"
    "GUARANTEED" (C2c_wake_guidance.wake_class_label a.wake)

let test_claude_always_manual () =
  let i = C2c_wake_guidance.advice ~client:"claude" ~context:`Install in
  let m = C2c_wake_guidance.advice ~client:"claude" ~context:`Managed_start in
  Alcotest.(check bool) "install" true i.manual_inbox_required;
  Alcotest.(check bool) "managed still NONE idle" true m.manual_inbox_required

let test_opencode_never_manual () =
  let a = C2c_wake_guidance.advice ~client:"opencode" ~context:`Install in
  Alcotest.(check bool) "opencode" false a.manual_inbox_required;
  Alcotest.(check string) "GUARANTEED"
    "GUARANTEED" (C2c_wake_guidance.wake_class_label a.wake)

let test_kimi_install_manual_managed_not () =
  let i = C2c_wake_guidance.advice ~client:"kimi" ~context:`Install in
  let m = C2c_wake_guidance.advice ~client:"kimi" ~context:`Managed_start in
  Alcotest.(check bool) "install manual" true i.manual_inbox_required;
  Alcotest.(check bool) "managed conditional auto" false m.manual_inbox_required

let test_agy_install_manual_managed_not () =
  let i = C2c_wake_guidance.advice ~client:"agy" ~context:`Install in
  let m = C2c_wake_guidance.advice ~client:"agy" ~context:`Managed_start in
  Alcotest.(check bool) "install" true i.manual_inbox_required;
  Alcotest.(check bool) "managed" false m.manual_inbox_required

let test_grok_manual () =
  let a = C2c_wake_guidance.advice ~client:"grok" ~context:`Install in
  Alcotest.(check bool) "grok" true a.manual_inbox_required

let () =
  Alcotest.run "c2c_wake_guidance"
    [ ( "advice",
        [ Alcotest.test_case "codex install manual" `Quick
            test_codex_install_requires_manual
        ; Alcotest.test_case "codex managed guaranteed" `Quick
            test_codex_managed_not_manual
        ; Alcotest.test_case "claude none idle" `Quick test_claude_always_manual
        ; Alcotest.test_case "opencode guaranteed" `Quick
            test_opencode_never_manual
        ; Alcotest.test_case "kimi install vs managed" `Quick
            test_kimi_install_manual_managed_not
        ; Alcotest.test_case "agy install vs managed" `Quick
            test_agy_install_manual_managed_not
        ; Alcotest.test_case "grok manual" `Quick test_grok_manual ] )
    ]
