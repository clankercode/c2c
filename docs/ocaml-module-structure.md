# OCaml Module Structure: Current and Planned Extractions

**File:** `ocaml/cli/c2c.ml` (10,208 LOC)
**Status:** Pre-split; this doc maps current structure before Phase 1 extraction.

---

## Current Top-Level Sections

| Lines | Section | Description |
|-------|---------|-------------|
| 1–330 | Header | Copyright, library imports |
| 330–425 | `commands_by_safety_cmd` | Safety classification command |
| 426–502 | `send_cmd` | `c2c send <alias> <msg>` |
| 503–588 | `list_cmd` | `c2c list` |
| 589–625 | `whoami_cmd` | `c2c whoami` |
| 626–655 | `set_compact_cmd` | `c2c set-compact` |
| 656–673 | `clear_compact_cmd` | `c2c clear-compact` |
| 674–746 | `open_pending_reply_cmd` | `c2c open-pending-reply` |
| 747–793 | `check_pending_reply_cmd` | `c2c check-pending-reply` |
| 794–838 | `poll_inbox_cmd` | `c2c poll-inbox` |
| 839–882 | `send_all_cmd` | `c2c send-all` |
| 883–1072 | `sweep_cmd` | `c2c sweep` |
| 1073–1077 | `sweep_dryrun_cmd` | `c2c sweep-dryrun` |
| 1078–1368 | `history_cmd` | `c2c history` |
| 1369–1601 | `health_cmd` | `c2c health` |
| 1602–1824 | `status_cmd` | `c2c status` |
| 1825–1952 | `verify_cmd` | `c2c verify` |
| 1953–2020 | `git_cmd` | `c2c git` |
| 2021–2088 | `register_cmd` | `c2c register` |
| 2089–2142 | `tail_log_cmd` | `c2c tail-log` |
| 2143–2161 | `server_info_cmd` | `c2c server-info` |
| 2162–2208 | `my_rooms_cmd` | `c2c my-rooms` |
| 2209–2264 | `dead_letter_cmd` | `c2c dead-letter` |
| 2265–2289 | `prune_rooms_cmd` | `c2c prune-rooms` |
| 2290–2331 | `rooms_send_cmd` | `c2c rooms send` |
| 2332–2387 | `rooms_join_cmd` | `c2c rooms join` |
| 2388–2427 | `rooms_leave_cmd` | `c2c rooms leave` |
| 2428–2520 | `rooms_delete_cmd` | `c2c rooms delete` |
| 2521–2571 | `rooms_history_cmd` | `c2c rooms history` |
| 2572–2601 | `rooms_invite_cmd` | `c2c rooms invite` |
| 2602–2638 | `rooms_members_cmd` | `c2c rooms members` |
| 2639–2691 | `rooms_visibility_cmd` | `c2c rooms visibility` |
| 2692–2760 | `rooms_tail_cmd` | `c2c rooms tail` |
| 2761–3334 | **Room command group** | `c2c rooms <sub>` |
| 3335–3421 | `hook_cmd` | `c2c hook` |
| 3422–4623 | `start_cmd` + `run_ephemeral_agent` | `c2c start` + ephemeral dispatch |
| 4624–4657 | **Relay command group** | `c2c relay <sub>` |
| 4658–4970 | **Install command group** | `c2c install <client>` |
| 4971–5354 | `setup_codex` | Codex-specific setup logic |
| 5045–5095 | `setup_kimi` | Kimi-specific setup logic |
| 5096–5354 | `setup_opencode` | OpenCode-specific setup logic |
| 5355–5528 | `setup_claude` | Claude-specific setup logic |
| 5529–5613 | `setup_crush` | Crush-specific setup logic |
| 5614–5847 | `install_*_subcmd` | Install subcommand definitions |
| 5848–5863 | `install_common_args` | Shared install argument defs |
| 5866–5884 | `install_self_subcmd` | `c2c install self` |
| 5885–5902 | `install_client_subcmd` | `c2c install <client>` |
| 5903–5929 | `install_all_subcmd` | `c2c install all` |
| 5930–5931 | `install_default_term` | Default install target |
| 5932–10208 | **Agent command group** | `c2c agent <sub>` |

---

## Planned Extractions

### Phase 1: `c2c_setup.ml` (PROPOSED)

**Lines to move:** ~500 (setup_* helpers + install_* subcommand defs)

```
setup_codex          → c2c_setup.ml
setup_kimi          → c2c_setup.ml
setup_opencode      → c2c_setup.ml
setup_claude        → c2c_setup.ml
setup_crush         → c2c_setup.ml
install_subcommand_clients
install_client_error_list
install_client_pipe_list
install_common_args
install_self_subcmd
install_client_subcmd
install_all_subcmd
install_default_term
```

**What stays in `c2c.ml`:** Install command group wiring (the `Cmdliner.Cmd.group` that assembles `install all`, `install <client>`, `install self`).

---

### Phase 2: `c2c_commands.ml` (PROPOSED)

**Lines to move:** ~300 (command_tier_map + filter_commands + help text)

**What stays:** All actual command implementations.

---

### Phase 3: `c2c_room.ml`, `c2c_relay.ml`, `c2c_agent.ml`, `c2c_plugin.ml` (PROPOSED)

**What stays in `c2c.ml`:** Main `default_cmd` (top-level help), plus the command group assemblies that wire subcommands together.

---

## Decision Record

- **2026-04-24:** Phase 1 approved by coordinator. DOCS PR lands first to give reviewers a map.
