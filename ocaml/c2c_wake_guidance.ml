(* C2c_wake_guidance — pure copy for install/start/doctor about idle wake.

   A **wake** is an external push into an *idle* agent with no model decision
   (see docs/wake-contract.md). Clients whose primary path is activity-only
   (hooks at turn boundary) need an explicit receive path: arm `c2c monitor`
   or poll with `c2c poll-inbox`. This module is the single place that text
   lives so install, managed start, and docs stay aligned.
*)

type wake_class =
  | Guaranteed
  | Conditional
  | None_idle

type receive_advice = {
  client : string;
  wake : wake_class;
  primary : string;
  (** True when the operator/agent must arm poll/monitor for idle receive. *)
  manual_inbox_required : bool;
  warning_lines : string list;
}

let wake_class_label = function
  | Guaranteed -> "GUARANTEED"
  | Conditional -> "CONDITIONAL"
  | None_idle -> "NONE"

let advice ~(client : string) ~(context : [ `Install | `Managed_start ]) :
    receive_advice =
  let c = String.lowercase_ascii (String.trim client) in
  match c, context with
  | "opencode", _ ->
      { client = c
      ; wake = Guaranteed
      ; primary = "in-process plugin (session.idle + promptAsync)"
      ; manual_inbox_required = false
      ; warning_lines = []
      }
  | "codex", `Managed_start ->
      { client = c
      ; wake = Guaranteed
      ; primary =
          "managed app-server inject + gated auto-turn for local-broker mail \
           (remote/@host/# fail closed to inject-only)"
      ; manual_inbox_required = false
      ; warning_lines =
          [ "[c2c] codex managed: idle local mail wakes via app-server \
             (no poll_inbox needed)."
          ; "[c2c] If you later run plain `codex` outside `c2c start`, \
             idle wake is NOT guaranteed — arm Monitor on `c2c monitor` or \
             use `c2c poll-inbox`."
          ]
      }
  | "codex", `Install | "codex-headless", _ ->
      { client = c
      ; wake = None_idle
      ; primary =
          "hooks at activity boundary only; managed `c2c start codex` is the \
           arrival-time path (app-server)"
      ; manual_inbox_required = true
      ; warning_lines =
          [ "[c2c WARNING] Codex install alone does NOT wake an idle session."
          ; "  Hooks deliver at the next UserPromptSubmit/tool boundary only."
          ; "  Prefer:  c2c start codex -n <name>   # managed app-server wake"
          ; "  Or arm:  Monitor({ command: \"c2c monitor\", persistent: true })"
          ; "  Fallback: c2c poll-inbox"
          ]
      }
  | "kimi", `Managed_start ->
      { client = c
      ; wake = Conditional
      ; primary = "REST notifier POST /api/v1/sessions/{id}/prompts"
      ; manual_inbox_required = false
      ; warning_lines =
          [ "[c2c] kimi managed: notifier should inject via REST when alive \
             (CONDITIONAL — if DEAF, `c2c doctor hooks --rearm` or poll-inbox)."
          ]
      }
  | "kimi", `Install ->
      { client = c
      ; wake = Conditional
      ; primary = "managed notifier, or Monitor / poll-inbox when unmanaged"
      ; manual_inbox_required = true
      ; warning_lines =
          [ "[c2c WARNING] Unmanaged kimi has no arrival-time wake by default."
          ; "  Prefer:  c2c start kimi -n <name>   # arms REST notifier"
          ; "  Or arm:  Monitor({ command: \"c2c monitor\", persistent: true })"
          ; "  Fallback: c2c poll-inbox"
          ]
      }
  | "agy", `Managed_start ->
      { client = c
      ; wake = Conditional
      ; primary =
          "deliver-watch + agy agentapi (agy-env auto-discovered from CLI log)"
      ; manual_inbox_required = false
      ; warning_lines =
          [ "[c2c] agy managed: deliver-watch injects via agentapi when \
             agy-env resolves (CONDITIONAL on sidecar + LS)."
          ]
      }
  | "agy", `Install ->
      { client = c
      ; wake = Conditional
      ; primary = "managed deliver-watch agentapi; hooks alone do not idle-wake"
      ; manual_inbox_required = true
      ; warning_lines =
          [ "[c2c WARNING] agy hooks alone do NOT wake an idle TUI."
          ; "  Prefer:  c2c start agy -n <name>   # deliver-watch + agentapi"
          ; "  Fallback: c2c poll-inbox / c2c monitor"
          ]
      }
  | "claude", _ ->
      { client = c
      ; wake = None_idle
      ; primary =
          "PostToolUse/Stop/SessionStart hooks (activity-only); optional \
           experimental channel"
      ; manual_inbox_required = true
      ; warning_lines =
          [ "[c2c WARNING] Claude Code cannot be idle-woken from inside c2c \
             (no local inject API)."
          ; "  Mail is durable and appears at the next activity-triggered hook."
          ; "  For idle receive: arm Monitor({ command: \"c2c monitor\", \
             persistent: true }) or poll with `c2c poll-inbox`."
          ]
      }
  (* Hermes ships an in-process Python plugin whose background watcher drains
     the broker and calls ctx.inject_message — a real external push, so CLI
     sessions are GUARANTEED and need no poll/monitor. Gateway sessions
     (Telegram/Discord/...) have no CLI reference, inject_message returns
     False there, and wake is NONE — stated as a warning rather than folded
     into the class, because the operator picks the mode, not c2c. *)
  | "hermes", _ ->
      { client = c
      ; wake = Guaranteed
      ; primary =
          "in-process plugin watcher (BrokerWatcher -> c2c poll-inbox -> \
           ctx.inject_message), CLI mode"
      ; manual_inbox_required = false
      ; warning_lines =
          [ "[c2c WARNING] Hermes idle wake is CLI-mode only."
          ; "  In gateway mode (Telegram/Discord/...) there is no CLI \
             reference, inject_message fails, and idle wake is NONE."
          ; "  For gateway sessions: c2c poll-inbox, or arm \
             Monitor({ command: \"c2c monitor\", persistent: true })"
          ]
      }
  | "grok", _ ->
      { client = c
      ; wake = None_idle
      ; primary = "SessionStart register + skill; agent must arm Monitor"
      ; manual_inbox_required = true
      ; warning_lines =
          [ "[c2c WARNING] Grok has NONE idle wake inside c2c."
          ; "  Arm receive NOW: Monitor({ command: \"c2c monitor\", \
             persistent: true })"
          ; "  Fallback: c2c poll-inbox"
          ]
      }
  | other, _ ->
      { client = other
      ; wake = None_idle
      ; primary = "unknown / poll-inbox"
      ; manual_inbox_required = true
      ; warning_lines =
          [ Printf.sprintf
              "[c2c WARNING] Client '%s': treat idle receive as manual — use \
               `c2c poll-inbox` or arm `c2c monitor`."
              other
          ]
      }

let print_warning_lines ?(oc = stderr) (adv : receive_advice) : unit =
  if adv.manual_inbox_required || adv.warning_lines <> [] then
    List.iter
      (fun line ->
        output_string oc line;
        output_char oc '\n')
      adv.warning_lines;
  flush oc

let print_install_receive_footer ~(client : string) () : unit =
  let adv = advice ~client ~context:`Install in
  print_warning_lines adv;
  if not adv.manual_inbox_required then
    Printf.eprintf
      "[c2c] receive primary: %s (wake=%s)\n%!"
      adv.primary (wake_class_label adv.wake)

let print_managed_start_receive_footer ~(client : string) () : unit =
  let adv = advice ~client ~context:`Managed_start in
  print_warning_lines adv
