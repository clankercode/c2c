# Client matrix audit: `c2c start <client>` adapters

Author: cairn (subagent of coordinator1)
Date: 2026-04-29
Sources:
- `ocaml/c2c_start.ml` — adapters @ lines 1187 (OpenCode), 2688 (Claude),
  2733 (Codex), 2776 (Kimi), 2825 (Gemini); hashtbl `clients` registry
  @ 1112-1177; dispatch `prepare_launch_args` @ 2407-2517; daemon wiring
  @ 3870-4036; restart @ 4498-4663.
- `ocaml/cli/c2c_setup.ml` — `c2c install <client>` per-client setup
  funcs @ 273 (codex), 352 (kimi), 410 (gemini), 473 (opencode), 768
  (claude), 968 (crush); `client_configured` detector @ 1112-1192.
- `ocaml/test/test_c2c_start.ml` — adapter unit coverage.

Scope: 5 clients per request — claude, codex, opencode, kimi, gemini.
Crush noted in passing because the registry includes it but no adapter
module exists.

---

## Adapter shape (per `module type CLIENT_ADAPTER`, c2c_start.ml:1060)

Required fields: `name`, `config_dir`, `agent_dir`, `instances_subdir`,
`binary`, `needs_deliver`, `needs_wire_daemon`, `needs_poker`,
`poker_event`, `poker_from`, `extra_env`, `session_id_env`,
`build_start_args`, `refresh_identity`, `probe_capabilities`.

Two parallel registries exist:
- `clients : (string, client_config) Hashtbl.t` (1110) — drives daemon
  wiring (`needs_deliver` / `needs_wire_daemon` / `needs_poker`).
- `client_adapters : (string, (module CLIENT_ADAPTER)) Hashtbl.t`
  (1184) — drives `build_start_args` / `refresh_identity` /
  `probe_capabilities`.

The two are kept in sync by hand. **Drift risk** — see Gap 1 below.

---

## Per-client matrix

### claude (ClaudeAdapter @ 2688)

| Aspect | Value |
| --- | --- |
| Delivery | MCP `notifications/claude/channel` (dev-channels flag) + PostToolUse hook fallback (`~/.claude/hooks/c2c-inbox-check.sh`) |
| `needs_deliver` | false |
| `needs_wire_daemon` | false |
| `needs_poker` | false |
| Inbox drain | broker push via channel notification; PostToolUse hook calls `c2c poll-inbox` after each tool turn |
| Restart | `c2c restart claude` (SIGTERM PGID + outer relaunch); `c2c restart-self` from inside; `kill -USR1` is **not** wired for claude |
| Install scope | dual: project `<cwd>/.mcp.json` (default since #334) **or** user-global `~/.claude.json` (`--global`); detector accepts either |
| Footguns | (a) **dev-channel consent prompt** — first launch pops "trust this server?" prompt; #399 wired tmux auto-answer (`auto_answer_dev_channel_prompt` @ 1647) but it depends on running inside tmux. (b) Heartbeats start without `deliver_started` flag (claude has no deliver daemon) — push-aware swap requires `automated_delivery=true` lookup. (c) **Slate finding 2026-04-28** (`coordinator1-slate-fresh-claude-idles-without-auto.md`) — fresh claude install can idle when automated-delivery isn't seeded. (d) Claude session UUID resolution: `claude_session_exists` (2383) decides `--resume` vs `--session-id` per launch; if session file is missing the resume becomes a fresh session (silent). |
| Test coverage | strong: `test_prepare_launch_args_claude_uses_development_channel_flag` (57), model/agent/extra-args (161/169/199), force-capabilities env (276-360), 12+ cases. |

### codex (CodexAdapter @ 2733)

| Aspect | Value |
| --- | --- |
| Delivery | OCaml deliver daemon writes XML to `--xml-input-fd 4` (codex alpha binary only); falls back to PTY-inject notify-only when fd unsupported |
| `needs_deliver` | true |
| `needs_wire_daemon` | false |
| `needs_poker` | false |
| Inbox drain | deliver daemon polls broker, pipes XML envelopes onto fd4; the codex binary translates that into a turn |
| Restart | `c2c restart codex` (SIGTERM PGID); inner-PID is the codex TUI; codex-headless variant uses positive `kill(pid)` (different PGID layout); managed heartbeat fires every 240s (codex_heartbeat_interval_s @ 172) |
| Install scope | user-global `~/.codex/config.toml` (TOML literal `[mcp_servers.c2c]`) |
| Footguns | (a) **Dual-binary trap** — CLAUDE.md documents two `codex` on PATH; `[default_binary] codex` in `.c2c/config.toml` must point at the alpha binary or `--xml-input-fd` is unavailable and deliver daemon falls back to notify-only. (b) `codex_xml_input_fd` is **not** part of the adapter interface — `prepare_launch_args` (2493-2500) prepends `--xml-input-fd`, `--server-request-events-fd`, `--server-request-responses-fd` outside the adapter, leaving the adapter contract incomplete. (c) Heavy historical bug list: thread-id leak (lyra-quill 2026-04-24), permission forwarding regressions (lyra/galaxy 2026-04-25), exit-122 hang (galaxy 2026-04-24), sidecar fd leak (lyra-quill 2026-04-24, jungle 2026-04-26 #312). (d) `refresh_identity` is a no-op — relies on `c2c install codex` having seeded `~/.codex/config.toml` with envs. If that config drifts (e.g. broker-root changed), no per-launch correction. |
| Test coverage | medium: prepare_launch_args extra-args (217), heartbeat interval (373), heartbeat enablement (377), env-stripping (330), no thread-id seed (303). **Missing**: build_start_args resume "" → resume --last, model+resume composition. |

### opencode (OpenCodeAdapter @ 1187)

| Aspect | Value |
| --- | --- |
| Delivery | TypeScript plugin (`.opencode/plugins/c2c.ts`) calls `client.session.promptAsync` in-process |
| `needs_deliver` | false |
| `needs_wire_daemon` | false |
| `needs_poker` | false |
| Inbox drain | plugin polls broker; plugin writes a heartbeat statefile that c2c monitors |
| Fallback | `try_opencode_native_fallback_once` (3070) — if plugin stale (`should_enable_opencode_fallback` @ 2990, 60s grace + 60s heartbeat-stale window), c2c PTY-injects via `inject_message_via_c2c` (3038). Requires `cap_sys_ptrace=ep` on the pty_inject helper. |
| Restart | `c2c restart opencode`; **OR** `kill -USR1 <inner-pid>` (plugin reconnects to broker without full restart, per CLAUDE.md). `c2c install opencode` writes `.opencode/opencode.json` with c2c MCP entry and **symlinks** the plugin from `data/opencode-plugin/c2c.ts` into `~/.config/opencode/plugins/c2c.ts`. |
| Install scope | per-project `<cwd>/.opencode/opencode.json` + global plugin symlink |
| Footguns | (a) **Bare model rejected** — `normalize_model_override_for_client` requires provider prefix (`anthropic:claude-sonnet-4-7`), bare `claude-sonnet-4-7` errors out. Tested @ 93. (b) **Agent-flag instance-vs-role pitfall** — opencode resolves `--agent <name>` to `.opencode/agents/<name>.md`; c2c writes that file at *instance* name, so it must pass the instance name, not the role name. Documented at 178-198 with a regression test. (c) **Plugin staleness** silently disables delivery — fallback fires only if `cap_sys_ptrace` is set; otherwise messages stall until plugin recovers. (d) `refresh_identity` writes both `.opencode/opencode.json` (mcp.c2c.environment) and a sidecar `c2c-plugin.json` — write paths can race a running plugin reading the JSON; renames are atomic but in-flight reads see old data. (e) Role pollution finding (jungle 2026-04-24 #140). (f) `agent_dir = "agents"` is set but no other adapter populates it — convention drift. |
| Test coverage | medium-strong: bare-model rejection (93), provider-prefix rewrite (98), agent-flag instance-name regression (178), extra-args (209), model+provider (225), env-strip (342). **Missing**: refresh_identity round-trip, plugin-stale fallback path, `should_enable_opencode_fallback` boundary cases. |

### kimi (KimiAdapter @ 2776)

| Aspect | Value |
| --- | --- |
| Delivery | File-based notification store — `C2c_kimi_notifier` writes inbound c2c messages into kimi's on-disk notification store; kimi reads them on its own cadence. No wire bridge, no PTY injection. Replaces the deprecated wire-bridge path (post-Slice-4, 2026-04-29). |
| `needs_deliver` | false |
| `needs_wire_daemon` | false (notification-store path; the legacy `needs_wire_daemon=true` claim was retired with Slice 4) |
| `needs_poker` | true (`poker_event = "heartbeat"`, `poker_from = "kimi-poker"`) |
| Inbox drain | notification-store reader on kimi's own cadence; poker keeps the agent active when idle |
| Restart | `c2c restart kimi`; legacy PTY deliver path is deprecated (CLAUDE.md). Per-instance MCP config is rewritten on every launch by `build_start_args` (2803). |
| Install scope | user-global `~/.kimi/mcp.json` (written by `c2c install kimi`). At `start` time, `KimiAdapter.build_start_args` writes a *second* per-instance config to `instance_dir/<name>/...` and prepends `--mcp-config-file <path>` unless extra_args already has one. |
| Footguns | (a) **Resume not supported** — `?resume_session_id:_` is ignored (2791). Restart effectively starts a fresh agent each time (relies on memory + room history). (b) **No PTY input** — direct `/dev/pts/<N>` slave writes display text without submitting (CLAUDE.md). The notification-store path sidesteps this entirely. (c) `KIMI_SESSION_ID` (`session_id_env`) collides with parent `CLAUDE_SESSION_ID` if launched from inside Claude Code without explicit override. CLAUDE.md documents this (kimi-probe pattern). (d) Two install configs (~/.kimi/mcp.json AND per-instance) means drift if one is updated without the other. (e) Long history of idle-delivery gaps (multiple 2026-04-13/14 findings) preceded the migration off the wire bridge; the notification-store path (live 2026-04-29) is the current canonical mitigation. |
| Test coverage | weak: kimi appears in test_clean_stale fixtures (2102) only — **no direct adapter unit test** for KimiAdapter.build_start_args or refresh_identity. |

### gemini (GeminiAdapter @ 2825)

| Aspect | Value |
| --- | --- |
| Delivery | First-class MCP server entry in `~/.gemini/settings.json` (with `trust: true` to bypass tool-call confirmation prompts) |
| `needs_deliver` | false |
| `needs_wire_daemon` | false |
| `needs_poker` | false |
| Inbox drain | Standard MCP — gemini calls `mcp__c2c__poll_inbox` etc. via its built-in MCP runtime; **no broker push** wired today (no channel notification for gemini) |
| Restart | `c2c restart gemini`. **No SIGUSR1 path**, no auto-answer dance (settings-based trust gate). Gemini has no CLI session-id env var (`session_id_env = None`); resume is `--resume <idx>|latest`. |
| Install scope | user-global `~/.gemini/settings.json` |
| Footguns | (a) **OAuth seeding caveat** — first managed launch fails if `~/.gemini/oauth_creds.json` is missing. Operator must run `gemini` once interactively. `c2c install gemini` (468-469) prints a one-line reminder but does not pre-seed. (b) **Resume index drift** — c2c stores `session_id : string` (alias-derived); GeminiAdapter falls back to `--resume latest` on non-numeric, which may pick the wrong session if the operator launched another gemini in the same project. No round-tripping of the actual chosen index back to `instance_config`. (c) **No automated-delivery push** — without a deliver daemon or wire daemon, the agent must explicitly poll. Heartbeat is the only wakeup. (d) Newest adapter (#406b, 2026-04-28) — minimal field exposure. |
| Test coverage | strong (only because it's new): 5 cases under `gemini_adapter` group (2379-2390) — fresh, resume-default, numeric-index, model, empty-resume. **Missing**: refresh_identity behavior (no-op contract) and probe_capabilities. |

---

## Cross-cutting gaps

### Gap 1: Adapter interface incomplete for codex (HIGH)

`codex_xml_input_fd`, `thread_id_fd`, `server_request_events_fd`,
`server_request_responses_fd` are passed to `prepare_launch_args` but
**not** to `CodexAdapter.build_start_args`. They're prepended at
2493-2500 by direct `match client with "codex" -> ...`. A future
adapter for `codex-headless` would need the same out-of-band shape, or
a richer adapter signature. This is the single biggest reason codex
keeps accumulating bug findings.

### Gap 2: Crush has no adapter module (MEDIUM)

`crush` is in the `clients` hashtbl (1141) and `c2c install crush`
exists (968), and it's listed in `install_subcommand_clients` (1052).
But there's no `CrushAdapter` module. `prepare_launch_args` falls
through to `| _ -> []` (2489); `--model` is appended via the generic
post-adapter path (2505-2510). Resume + agent-flag + extra-args are
silently dropped. Out-of-scope for this audit but worth filing.

### Gap 3: KimiAdapter has zero unit tests (MEDIUM)

No test calls `KimiAdapter.build_start_args` or
`KimiAdapter.refresh_identity`. The per-instance MCP config write is
load-bearing (broker root, alias, room auto-join) and entirely
untested. The historical kimi-wire findings (2026-04-13/14) suggest
this surface needs coverage.

### Gap 4: ClaudeAdapter delivery-path coverage thin for fresh installs (MEDIUM)

Slate's 2026-04-28 finding ("fresh-claude-idles-without-auto") points
at `automated_delivery_for_alias` (375) returning false for newly
registered aliases, which suppresses `push_aware_heartbeat_content`
swap. No regression test exercises the fresh-install heartbeat path.

### Gap 5: GeminiAdapter resume index not round-tripped (LOW)

Storing only the alias-derived session-id string means the chosen
`--resume <idx>` is never persisted. Restart picks `latest` again,
which can pick someone else's session if another gemini ran in the
same project dir.

### Gap 6: Clients hashtbl + adapter hashtbl drift (LOW-MED)

Two parallel registries kept in hand sync. If a future client adds
`needs_poker = true` to `clients` but the adapter has
`poker_event = None`, daemon wiring will crash at run-time. There's
no startup assertion that the two agree. Easy fix: derive
`client_config` from the adapter at boot.

---

## Most-broken client

**Codex.** Largest finding count by far (>15 in the last six weeks
covering thread-id leak, permission forwarding, exit-122 hang, sidecar
fd leak, deliver unavailable, MCP stale transport, harness fd leak,
PATH dual-binary trap), and its adapter signature is the only one
where load-bearing flags (`--xml-input-fd`, three server-request fds)
bypass the adapter contract entirely. Even its `refresh_identity` is a
no-op while config-toml drift is a recurring complaint.

Runner-up: kimi — historical wire-bridge fragility (now migrated to the notification-store path post-Slice-4) with no adapter test coverage.

---

## Suggested next slices

1. **#codex-adapter-completeness** — extend `CLIENT_ADAPTER` so codex's
   fd parameters live in the adapter, not in `prepare_launch_args`'s
   special case. Same shape would unblock a `CrushAdapter`.
2. **#kimi-adapter-tests** — fixture-gated unit tests for
   `build_start_args` (config write path, alias override, --mcp-config
   detection) and `refresh_identity` (no-op contract).
3. **#crush-adapter** — add `CrushAdapter` mirroring `CodexAdapter`
   (deliver-daemon based) so resume/agent flags work.
4. **#gemini-resume-roundtrip** — persist the chosen `--resume` index
   into `instance_config.gemini_resume_index` so restart picks the
   same session.
5. **#client-adapter-startup-assert** — at boot, verify
   `client_adapters` agrees with `clients` hashtbl on
   `needs_deliver` / `needs_wire_daemon` / `needs_poker`.
