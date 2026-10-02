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

(* B353: muse Tier-0 is CLI-only — NONE in both contexts with the verbatim
   #414 Monitor recipe. *)
let test_muse_none_both_contexts () =
  let i = C2c_wake_guidance.advice ~client:"muse" ~context:`Install in
  let m = C2c_wake_guidance.advice ~client:"muse" ~context:`Managed_start in
  Alcotest.(check bool) "install manual" true i.manual_inbox_required;
  Alcotest.(check bool) "managed manual" true m.manual_inbox_required;
  Alcotest.(check string) "install NONE"
    "NONE" (C2c_wake_guidance.wake_class_label i.wake);
  Alcotest.(check string) "managed NONE"
    "NONE" (C2c_wake_guidance.wake_class_label m.wake);
  let has_monitor_recipe (adv : C2c_wake_guidance.receive_advice) =
    List.exists
      (fun s ->
        let needle = "Monitor({ command: \"c2c monitor\", persistent: true })" in
        let nl = String.length needle and hl = String.length s in
        nl <= hl
        && (let rec loop k =
              k + nl <= hl
              && (String.sub s k nl = needle || loop (k + 1))
            in
            loop 0))
      adv.warning_lines
  in
  Alcotest.(check bool) "install has Monitor recipe" true (has_monitor_recipe i);
  Alcotest.(check bool) "managed has Monitor recipe" true (has_monitor_recipe m)

(* B358: managed muse keeps NONE + manual (hooks are activity-only, no
   out-of-process sender) and states the interim truth: pre-B361 the
   SessionStart hook drains the NATIVE row, not the managed alias row, so
   managed-alias mail needs Monitor or poll-inbox even at SessionStart. *)
let test_muse_managed_names_hook_posture () =
  let m = C2c_wake_guidance.advice ~client:"muse" ~context:`Managed_start in
  let contains hay needle =
    let hl = String.length hay and nl = String.length needle in
    nl <= hl
    && (let rec loop k =
          k + nl <= hl
          && (String.sub hay k nl = needle || loop (k + 1))
        in
        loop 0)
  in
  Alcotest.(check bool) "primary names B361 interim" true
    (contains m.primary "B361");
  Alcotest.(check bool) "primary names Monitor" true
    (contains m.primary "Monitor");
  Alcotest.(check bool) "warns no auto-drain pre-B361" true
    (List.exists (fun s -> contains s "does NOT auto-drain") m.warning_lines)

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
        ; Alcotest.test_case "grok manual" `Quick test_grok_manual
        ; Alcotest.test_case "muse none both contexts" `Quick
            test_muse_none_both_contexts
        ; Alcotest.test_case "muse managed names hook posture" `Quick
            test_muse_managed_names_hook_posture ] )
    ]
