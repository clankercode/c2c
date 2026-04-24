(* c2c_commands.ml — command tier map and visibility filtering.
   Extracted from c2c.ml (#152 Phase 2). *)

open C2c_types

let safety_to_string = function
  | Tier1 -> "tier1" | Tier2 -> "tier2" | Tier3 -> "tier3" | Tier4 -> "tier4"

let safety_to_label = function
  | Tier1 -> "TIER 1 — SAFE FOR AGENTS (messaging, queries)"
  | Tier2 -> "TIER 2 — SAFE WITH CARE (lifecycle, side effects)"
  | Tier3 -> "TIER 3 — UNSAFE FOR AGENTS (systemic, requires operator)"
  | Tier4 -> "TIER 4 — INTERNAL (hidden without --all)"

(* Map from command name to safety tier.
   This is used by filter_commands to determine which commands to hide
   when running inside an agent session. *)
let command_tier_map () : (string * safety) list =
  [ "send", Tier1
  ; "list", Tier1
  ; "whoami", Tier1
  ; "poll-inbox", Tier1
  ; "peek-inbox", Tier1
  ; "send-all", Tier1
  ; "sweep", Tier1
  ; "sweep-dryrun", Tier1
  ; "monitor", Tier1
  ; "screen", Tier1
  ; "history", Tier1
  ; "health", Tier1
  ; "dead-letter", Tier1
  ; "tail-log", Tier1
  ; "set-compact", Tier1
  ; "clear-compact", Tier1
  ; "open-pending-reply", Tier1
  ; "check-pending-reply", Tier1
  ; "prune-rooms", Tier1
  ; "rooms", Tier1
  ; "room", Tier1
  ; "my-rooms", Tier1
  ; "register", Tier1
  ; "refresh-peer", Tier1
  ; "instances", Tier1
  ; "doctor", Tier1
  ; "verify", Tier1
  ; "status", Tier1
  ; "commands", Tier1
  ; "monitor", Tier1      (* read-only inbox/archive event stream — required by agent recovery-snippet *)
  ; "skills", Tier1
  (* relay subcommands (serve, gc, connect, setup, status, list, rooms, poll-inbox) are
     not top-level commands; they inherit tier from the relay parent and are not
     independently filtered by filter_commands. *)
  ; "start", Tier2
  ; "stop", Tier2
  ; "agent", Tier2
  ; "restart", Tier2
  ; "reset-thread", Tier2
  (* rooms subcommands (send, join, leave, list, members, history, tail, delete, visibility, invite)
     are not top-level commands; they inherit tier from the rooms parent. *)
  ; "agent", Tier2
  ; "roles-validate", Tier2
  ; "config", Tier2
  ; "config-show", Tier2
  ; "wire-daemon", Tier2
  (* wire-daemon subcommands (list, status) are not top-level. *)
  ; "init", Tier2
  ; "repo", Tier2
   ; "restart-self", Tier3
   ; "relay", Tier2
   (* relay subcommands (serve, gc, setup, connect, register, dm, status, list, rooms, poll-inbox)
      are not top-level commands. *)
   ; "setcap", Tier3
   ; "install", Tier2
   ; "gui", Tier3
   ; "diag", Tier3
   ; "smoke-test", Tier3
  ; "inject", Tier4
  (* hook, oc-plugin, cc-plugin: internal plumbing invoked by plugin subprocesses
     (OC plugin via spawn, CC via PostToolUse hook). They MUST remain invokable
     even inside agent sessions — the plugin running inside every managed session
     sets C2C_MCP_SESSION_ID and would otherwise be blocked from draining its own
     inbox. Tier1 so the filter accepts them unconditionally. *)
  ; "hook", Tier1
  ; "serve", Tier4
  ; "mcp", Tier4
  ; "oc-plugin", Tier1
  ; "cc-plugin", Tier1
  ; "state-read", Tier4
  ; "state-write", Tier4
  ; "wire-daemon-start", Tier4
  ; "wire-daemon-stop", Tier4
  ; "wire-daemon-format-prompt", Tier4
  ; "wire-daemon-spool-write", Tier4
  ; "wire-daemon-spool-read", Tier4
  ; "supervisor", Tier4
  ; "supervisor-answer", Tier4
  ; "supervisor-question-reject", Tier4
  ; "supervisor-approve", Tier4
  ; "supervisor-reject", Tier4
  (* room subcommands (send, join, leave, list, members, history, tail, delete, visibility)
     are not top-level commands. *)
  ; "room-invite", Tier4
  ]

(* Returns true when running inside a c2c agent session *)
let is_agent_session () =
  match C2c_mcp.session_id_from_env () with Some _ -> true | None -> false

(* Hide tier-3 and tier-4 commands when running as an agent *)
let tier_visible tier =
  match tier with
  | Tier1 | Tier2 -> true
  | Tier3 | Tier4 -> not (is_agent_session ())

(* Filter a command list: keep only commands whose tier is visible.
   Command name is extracted from the cmd's info. *)
let filter_commands ~cmds =
  let tier_map = command_tier_map () in
  let get_tier cmd_name =
    match List.assoc_opt cmd_name tier_map with
    | Some t -> t
    | None -> Tier2  (* unknown / newly-added commands default to visible-with-care, not hidden-from-agents. prevents regressions like monitor-silently-removed 2026-04-22. *)
  in
  List.filter
    (fun cmd ->
      let cmd_name = Cmdliner.Cmd.name cmd in
      tier_visible (get_tier cmd_name))
    cmds
