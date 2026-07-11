# Claude ↔ Codex integration parity review

- **Date:** 2026-07-10 (UTC)
- **Author:** Max-driven Claude session (Fable), two opus investigator subagents (read-only sweep of main tree @ `afb8c646`)
- **Framing:** the two clients have *different intended default modes* — Claude: **CLI + Monitor** (Monitor's advantage: it can reprompt/wake an idle agent); Codex: **CLI + hooks** (hooks deliver at activity points but can never wake an idle session). The review judges each integration against "best use of what the host client offers", not byte-for-byte parity.

## Method

Two parallel investigators mapped each client's full integration surface against a shared
10-point checklist (install/uninstall, identity, inbound delivery, idle wake, outbound,
prompt surfaces, managed sessions, approvals, doctor/health, known gaps), citing code
(not docs) throughout. This doc is the synthesis; the raw inventories are summarized
inline with file:function citations preserved where load-bearing.

## Parity matrix

| Surface | Claude | Codex |
|---|---|---|
| MCP config written by install | ✓ project `.mcp.json` (default) or global `.claude.json`; `resolve_claude_dir` honors `CLAUDE_CONFIG_DIR` + symlinks | ✓ `~/.codex/config.toml` `[mcp_servers.c2c]` |
| `C2C_MCP_CLIENT_TYPE` pinned | ✗ (inferred from env — hijack-guard class relies on inference) | ✓ pinned `"codex"` |
| MCP tool availability | full surface, no allowlist needed | ✓ all 39 tools enumerated with `approval_mode="auto"` |
| Hooks installed | PostToolUse (**nudge-only** by default) + Stop (block-to-deliver); PreToolUse approval hook present but sentinel-disabled | UserPromptSubmit + PostToolUse + SessionStart + SessionEnd → `c2c hook codex`, pre-trusted hashes; **full drain at turn boundaries, push-only mid-turn** |
| Vanilla session self-onboarding | ✗ no SessionStart hook → no auto-register, no onboarding text | ✓ auto-register + onboarding text on first hook fire |
| Session-end deregistration | ✗ | ✓ (vanilla `codex-hook` registrations only) |
| Skill install | ✓ `~/.claude/skills/c2c/SKILL.md` | ✓ `~/.codex/skills/c2c/SKILL.md` (ca4ea838) |
| Skill **auto-update** | ✗ only on `install`/`init` | ✓ SessionStart refresh (`refresh_codex_skill_if_stale`) |
| Global orientation block | ✗ nothing written to `~/.claude/CLAUDE.md` | ✓ `~/.codex/AGENTS.md` managed block |
| Mid-turn inbound (vanilla) | nudge line only ("N messages waiting"; full-inject env opt-in `C2C_POST_TOOL_FULL_INJECT`) | real message bodies via PostToolUse (non-deferrable only) |
| Turn-boundary inbound | Stop hook `decision=block` extends the turn with messages | UserPromptSubmit / SessionStart full drain incl. deferrable + global broker |
| **Idle wake (vanilla)** | ✗ from c2c alone; **Monitor + heartbeat** is the documented, working recipe (skill + runbook) | ✗ **nothing** — no Monitor equivalent; best current pattern is `c2c wait-inbox` as a blocking in-turn wait |
| **Idle wake (managed)** | ✓ real: `C2C_MCP_FORCE_CAPABILITIES=claude_channel` + inbox watcher → channel push into live transcript; schedule timer self-DMs ride the same path | ✗ heartbeat + schedule self-DMs are enqueued but **nothing surfaces them while idle** (xml_fd transport dead since codex v0.142.5; deliver daemon is log-only `Mode_inotify_print`) |
| Managed kickoff prompt | ✓ transcript prepend + dev-channel consent auto-answer (#399) | ✗ dead (XML-pipe kickoff gated on dead `codex_xml_pipe`) — sessions start blank, only SessionStart wake text |
| Cold-boot / post-compact context (#317) | binaries exist (`c2c-cold-boot-hook`, `c2c-post-compact-hook`) but **not wired** by `c2c install claude` | ✗ no equivalent (SessionStart wake text is a partial analogue) |
| Uninstall completeness | ✓ settings hooks always cleaned, incl. sentinel PreToolUse | ⚠ recompute fallback (`recompute_codex_artifacts`) omits the hooks config-block and AGENTS.md block markers — manifest-less uninstall orphans them |
| Doctor/health depth | dangling-hook check; health = substring `"c2c"` in hooks blob (weak) | managed-block staleness + trust-index drift (strong); but nothing flags the dead delivery path / idle-wake gap |
| Known live bugs | channel-push selective miss (HIGH, `.collab/findings` `channel-push-selective-miss.md`); dev-channel consent friction | dead fd-4 deliver-watch would *destructively* drain to a broken fd if it ever ran (B013); `delivery_mode` reports `pty_notify`/`unavailable`, not the real hooks path |

## The crux: wake/reprompt asymmetry

What actually **starts a turn** on an idle agent, per client:

- **Claude managed**: channel-push notification (`notifications/claude/channel`) from the
  inbox watcher — true wake. Schedule fires (wake.toml self-DMs) ride this. Working.
- **Claude vanilla**: only an armed Monitor (`heartbeat 4.1m …`) — external to c2c but
  documented as the default mode. Working, by design (CLI + Monitor).
- **Codex managed**: *was* xml_fd injection; dead since v0.142.5. Heartbeat
  (`builtin_managed_heartbeat`, 240s idle-gated) still enqueues self-DMs that rot in the
  inbox until the next hook fire. **Non-functional.**
- **Codex vanilla**: never existed. Hooks are activity-gated by definition.

Codex has no Monitor-analogue, so an idle codex can only be woken from *outside* the
session. Available primitives, in order of viability:

1. **PTY injection** (`pty_inject` capability + `Mode_pty` in `c2c_deliver_inbox`) — the
   transport the old wire-bridge used; capability probe still exists and
   `delivery_mode` even advertises `pty_notify`, but `start_deliver_daemon` never passes
   a `pty_master_fd` for codex. Re-wiring deliver-watch → PTY is the natural successor
   to xml_fd for managed sessions.
2. **tmux send-keys** (scripts/c2c_tmux.py) — works today, operator-driven, not wired
   as an automatic path.
3. **`c2c wait-inbox` as a blocking tail-call** — turns "idle" into "in-turn wait"; the
   AGENTS.md block documents it. Zero-infrastructure, but depends on the agent
   remembering to call it and holds a turn open.

## Ranked gaps

### Codex side

1. **[P0] No idle wake at all.** Restore a managed-codex wake transport: wire
   deliver-watch/deliver-daemon to PTY injection (capability exists; replaces dead
   xml_fd), or an equivalent nudge-injector. Until then, heartbeats and native
   schedules silently don't work for codex — worse than absent, because
   `c2c schedule list` implies they do.
2. **[P1] Dead xml_fd plumbing still ships and is dangerous.** `pre-deliver.sh`
   hardcodes `C2C_DELIVER_XML_FD=4`; `c2c deliver watch` drains **destructively** — if
   the supervisor ever runs, messages are consumed into a broken fd (loss). Filed
   follow-up ("port managed delivery to hooks",
   `2026-07-06T10-24-24Z-fable-scribe-codex-xml-input-fd-removed.md`) not yet done.
3. **[P1] Managed kickoff prompt dead** — `c2c start codex` sessions start blank.
   Port kickoff to the SessionStart hook (`additionalContext`) or to a first-turn
   `codex exec`-style injection.
4. **[P2] `delivery_mode` misreports** (`pty_notify`/`unavailable` vs actual hooks) —
   misleads operators and `c2c instances`.
5. **[P2] Uninstall recompute fallback omits hooks + AGENTS.md blocks.**
6. **[P2] Alias churn for vanilla codex** — fresh `codex-*` alias per conversation; no
   sticky per-operator alias file.
7. **[P3] Doctor blind spot** — reports codex healthy while idle delivery is
   non-functional; add a delivery-path liveness check.

### Claude side

1. **[P1] No SessionStart/SessionEnd hooks** — the mirror image of what codex just got.
   Claude Code supports these hook events; `c2c install claude` wires neither. One
   SessionStart hook would buy: vanilla self-onboarding (auto-register + onboarding
   text, codex-parity), **skill auto-refresh** (codex-parity, ca4ea838), cold-boot
   context injection (#317 — binaries exist, currently unreachable by default), and
   session hygiene. SessionEnd → deregistration.
2. **[P1] Vanilla mid-turn delivery is nudge-only** while codex delivers real bodies.
   Also latent divergence: the installed binary nudges, but the `c2c hook post-tool`
   CLI fallback full-delivers — whichever fallback runs changes semantics.
3. **[P2] Cold-boot/post-compact hooks unwired** (subsumed by #1 for cold-boot;
   post-compact needs PreCompact/SessionStart wiring decision).
4. **[P2] Health check is substring `"c2c"`** on the hooks blob — false-green prone,
   ignores Stop hook and matcher correctness; doctor has the real check, health should
   reuse it.
5. **[P3] No `C2C_MCP_CLIENT_TYPE` pin** for claude MCP entries (codex/kimi pin to
   prevent the session-hijack class).
6. **[P3] Channel-push selective miss** (HIGH finding) — delivery-correctness bug in
   the watcher/drain interaction; predates this review, re-flagged because managed
   claude's whole idle story rides that path.

### Judged against "best use of available features"

- **Claude + Monitor**: correctly exploited — skill/runbooks push Monitor+heartbeat for
  vanilla, managed sessions get native channel push. The miss is on the *hooks* half:
  Claude's hook surface is richer than what c2c installs (no SessionStart/End).
- **Codex + hooks**: hooks half is excellent (4 events, pre-trusted, full/push drain
  split, self-onboarding, skill refresh). The miss is the *wake* half: nothing replaced
  xml_fd, so the "reprompting" role Monitor plays for Claude has no codex counterpart
  wired today.

## Suggested slice order (if/when picked up)

1. codex idle wake: deliver-watch → PTY injection for managed codex (+ remove dead
   xml_fd plumbing in the same arc; unblocks heartbeat + schedules).
2. claude SessionStart/SessionEnd hooks (self-onboard, skill refresh, cold-boot, dereg).
3. managed codex kickoff via SessionStart hook.
4. honesty fixes: `delivery_mode` truthfulness + doctor delivery-liveness check +
   health substring fix + codex uninstall recompute fallback.
5. quality-of-life: vanilla-codex sticky alias, claude client-type pin, PostToolUse
   full-inject default decision.
