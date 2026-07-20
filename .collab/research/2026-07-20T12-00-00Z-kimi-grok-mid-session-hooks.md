# Research: Kimi Code + Grok Build mid-session hook events (#59)

**Date:** 2026-07-20  
**Issue:** [#59](https://github.com/clankercode/c2c/issues/59) — Grok and Kimi hook rows cannot decay (no activity-backed anchor)  
**Constraint for this task:** do **not** widen `hook_anchor_is_activity_backed`.  
**CLI versions probed:** Kimi Code `0.28.0`; Grok Build `0.2.106` (`bde89716f6`).  
**Worktree:** `.worktrees/i59-kimi-grok-hooks` branch `research/i59-kimi-grok-mid-session-hooks`.

---

## Question

Which mid-session hook events do **Kimi Code** and **Grok Build** actually emit (or document), such that c2c could install a repeating hook and later (separate change) opt them into #51 decay?

---

## Summary answer

| Client | c2c currently installs | Upstream documents mid-session events? | Empirically fires mid-session? | Safe #59 path |
|---|---|---|---|---|
| **Kimi Code** | `SessionStart` only (`c2c hook kimi`); optional commented `PreToolUse` approval block | Yes — full lifecycle set in `kimi_cli`/config schema | **Yes** — `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop` (+ `SessionStart`/`SessionEnd`) | **Install mid-session c2c hooks** (prefer `PostToolUse` + `Stop` and/or `UserPromptSubmit`); extend `c2c hook kimi` to touch activity on those events. REST probe is backup, not primary. |
| **Grok Build** | `SessionStart` + `SessionEnd` only (`~/.grok/hooks/c2c-session.json` → `c2c hook grok`) | Yes — full table in `~/.grok/docs/user-guide/10-hooks.md` | **Yes** — `user_prompt_submit`, `pre_tool_use`, `post_tool_use`, `stop` (+ `session_start`). `SessionEnd` not observed on headless `-p` exit. | **Install mid-session c2c hooks** (`PostToolUse` + `Stop` and/or `UserPromptSubmit`); extend `c2c hook grok` to accept those events and touch. No local REST liveness surface today — hooks are the real fix. |

Both clients already fire repeating mid-session hooks. The #59 carve-out is **stale relative to upstream capability**: c2c simply does not install or handle those events for kimi/grok. No new upstream feature request is required for the cheap fix.

---

## Installed c2c surface (before any change)

### Kimi (`c2c install kimi` / `C2c_kimi_hook` + `setup_kimi`)

- Active managed block: **only**
  ```toml
  [[hooks]]
  event = "SessionStart"
  command = "c2c hook kimi"
  ```
  (`session_start_toml_block_template` in `ocaml/cli/c2c_kimi_hook.ml`).
- Separate optional **commented** `PreToolUse` approval-hook block (`c2c-kimi-approval-hook.sh`) — not an activity anchor and not auto-enabled as a c2c touch path.
- Handler `c2c hook kimi` allowlists **`kimi_session_events = [SessionStart; SessionEnd]`** and **exits 0 on any other event** (`ocaml/cli/c2c_hook_cmd.ml`) — so even if operators added `PostToolUse` pointing at `c2c hook kimi`, the binary would no-op today.

**Live host install** (`~/.kimi-code/config.toml`, 2026-07-20):

| Source | Events |
|---|---|
| herdr integration | `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `SubagentStart`, `PreCompact`, `PermissionRequest`, `PermissionResult`, `Stop`, `Interrupt` |
| c2c (duplicated twice) | `SessionStart` → `c2c hook kimi` only |
| c2c SessionEnd | **not installed** |

Third-party herdr already treats mid-session kimi events as real; c2c does not.

### Grok (`c2c install grok` / `grok_hooks_json`)

Installed file `~/.grok/hooks/c2c-session.json`:

```json
{
  "hooks": {
    "SessionStart": [ { "hooks": [ { "type": "command", "command": "c2c hook grok", "timeout": 10 } ] } ],
    "SessionEnd":   [ { "hooks": [ { "type": "command", "command": "c2c hook grok", "timeout": 10 } ] } ]
  }
}
```

Handler `c2c hook grok` allowlists **`grok_session_events = [SessionStart; SessionEnd]`** and hard-exits on anything else — same no-op trap as kimi.

---

## Upstream documentation / schema

### Kimi Code

- Installed Python package `kimi_cli.hooks.config.HookEventType` (legacy/tooling package still present under uv tools) enumerates:

  `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionStart`, `SessionEnd`, `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact`, `Notification`.

- Live host also configures **`PermissionRequest`**, **`PermissionResult`**, **`Interrupt`** via herdr — present in the native `kimi` binary string table and accepted by `[[hooks]] event = ...` on this host (0.28.0). Treat those as additional supported events beyond the older `kimi_cli` Literal if needed; they are not required for #59.

- Payload builders (`kimi_cli.hooks.events`) use `hook_event_name` + `session_id` + `cwd` (PascalCase event names).

### Grok Build

Official local doc `~/.grok/docs/user-guide/10-hooks.md` **Hook Events** table:

| Event | When | Blocking? |
|---|---|---|
| `SessionStart` | session starts | No |
| `UserPromptSubmit` | user submits a prompt | No |
| `PreToolUse` | tool about to run | Yes — can deny |
| `PostToolUse` | tool succeeds | No |
| `PostToolUseFailure` | tool fails | No |
| `PermissionDenied` | permission system denies | No |
| `Stop` | agent turn ends | No |
| `StopFailure` | turn ends on API error | No |
| `Notification` | agent notification | No |
| `SubagentStart` / `SubagentStop` | subagent lifecycle | No |
| `PreCompact` / `PostCompact` | compaction | No |
| `SessionEnd` | session ends | No |

JSON lives under `~/.grok/hooks/*.json`. Docs explicitly recommend `PostToolUse` for “log every tool execution”.

**Payload naming quirk (load-bearing for c2c):** Grok’s runtime stdin uses **snake_case** `hookEventName` values (`session_start`, `post_tool_use`, …) and `sessionId`, while c2c’s normalizer today only maps `session_start`/`session_end` and then requires membership in the PascalCase allowlist. Mid-session install must normalize snake_case → PascalCase for **all** events it handles (or key off the already-set `GROK_HOOK_EVENT` env).

---

## Empirical probes (this session)

Method: temporary logger hooks that append `timestamp \t event \t keys` to a probe log; configs restored immediately after each run. Evidence copies under  
`.collab/research/i59-probe-evidence/`.

### Kimi (`kimi -p …`, workdir throwaway under `/tmp`)

**No tools** (`Reply with exactly OK…`):

```
SessionStart
UserPromptSubmit
Stop
SessionEnd
```

**With tool** (read `hello.txt`):

```
SessionStart
UserPromptSubmit
PreToolUse          (tool_name=Read)
PostToolUse         (tool_name=Read, tool_output present)
Stop
SessionEnd
```

Payload field is PascalCase `hook_event_name`. Session ids look like `session_<uuid>`.

**Conclusion (kimi):** mid-session events **do fire** on real turns. Best activity anchors:

1. **`PostToolUse`** — every successful tool (matches codex/claude/agy pattern).
2. **`Stop`** — end of every agent turn, including tool-less turns (important: pure chat still advances the anchor).
3. **`UserPromptSubmit`** — every user turn start (also tool-less).

`SessionStart`/`SessionEnd` alone remain age, not activity.

### Grok (`grok -p … --always-approve`, same throwaway pattern)

Observed fire order:

```
session_start
user_prompt_submit
pre_tool_use        (toolName=read_file)
post_tool_use
stop                (reason=end_turn)
```

`SessionEnd` **did not fire** on this headless single-turn exit (process ended after `stop`). Do not rely on SessionEnd as the only teardown signal for headless grok; for #59 activity that is fine — we need mid-session, not teardown.

Env on hook process includes `GROK_HOOK_EVENT`, `GROK_SESSION_ID`, `GROK_HOOK_NAME`. Debug log confirmed dispatcher:

- `hook completed … user_prompt_submit`
- `hook allowed … pre_tool_use`
- `hook completed … post_tool_use`
- `hook completed … stop`

**Conclusion (grok):** mid-session events **do fire**. Same preferred anchors as kimi: `PostToolUse` + `Stop` (+ optional `UserPromptSubmit`). No REST session endpoint observed for out-of-band probe (issue #59 option 2 remains weak for grok).

---

## Mapping to #59 options

From the issue:

1. **Confirm upstream hook events → install + allowlist** — **CONFIRMED for both clients.** This is the cheapest real fix and is now testable the same way as #52/`test_c2c_hook_anchor`.
2. **Out-of-band liveness probe** — Kimi still has a local REST server (existing notifier path); useful as defense-in-depth for idle sessions that receive no user/tool events, but **not required** once mid-session hooks touch. Grok: no such surface → hooks only.
3. **Upstream ask** — **not needed** for repeating hooks; both already emit them. Still relevant only for a true idle-wake path (orthogonal; #37 class).

---

## Recommendation (for a follow-up implementation; not done here)

**Do not widen `hook_anchor_is_activity_backed` until install + handler + anchor test land together.**

### Preferred design

| Client | Install | Handler change | Then allowlist |
|---|---|---|---|
| Kimi | Add active `[[hooks]]` for at least `PostToolUse` and `Stop` (and optionally `UserPromptSubmit`) → `c2c hook kimi`. Keep `SessionStart`. Consider `SessionEnd` if teardown desired (already handled in binary; not installed today). | Expand `kimi_session_events`; on mid-session events call `touch_hook_activity` (and any cheap drain already used by other clients). Keep hard fail-open. | Add `"kimi-hook"` to `hook_anchor_is_activity_backed` **only after** `test_c2c_hook_anchor` proves mid-session events touch. |
| Grok | Extend `~/.grok/hooks/c2c-session.json` with `PostToolUse` (+ matcher `""` or omit), `Stop`, optional `UserPromptSubmit`. | Expand `grok_session_events`; normalize snake_case `hookEventName` / `sessionId` for all handled events; touch on mid-session. | Add `"grok-hook"` the same way. |

### Why `PostToolUse` + `Stop` (not only `PostToolUse`)

- Tool-less turns (chat-only) never hit `PostToolUse` / `PreToolUse`.
- `Stop` / `UserPromptSubmit` cover those turns.
- Idle-but-alive with **no** user/model activity still will not refresh — same honest limit as claude/codex/agy anchors; that is activity, not wall-clock liveness. Accept it; do not pretend `poll_inbox` is an anchor (#59 already rejects that).

### Explicit non-goals for the first fix

- Do **not** treat herdr’s existing kimi hooks as c2c’s anchor (third-party, may be absent).
- Do **not** opt clients into the allowlist based on docs alone without install+handler+test (issue’s own severity argument).
- Do **not** use `c2c send` / model-chosen CLI as liveness.

### Doctor follow-up (issue “also worth doing”)

After install lands: `c2c doctor` should compare installed kimi/grok hook events against the allowlist expectation (adjacent to #50). Out of scope for the research commit.

---

## Evidence index

| Artifact | Path |
|---|---|
| Kimi no-tools event log | `.collab/research/i59-probe-evidence/kimi-no-tools.events.log` |
| Kimi with-tools event log | `.collab/research/i59-probe-evidence/kimi-with-tools.events.log` |
| Kimi `PostToolUse` sample payload | `.collab/research/i59-probe-evidence/kimi-PostToolUse.json` |
| Grok with-tools event log | `.collab/research/i59-probe-evidence/grok-with-tools.events.log` |
| Grok `post_tool_use` sample | `.collab/research/i59-probe-evidence/grok-post_tool_use.json` |
| c2c install (kimi) | `ocaml/cli/c2c_kimi_hook.ml` (`session_start_toml_block_template`) |
| c2c install (grok) | `ocaml/cli/c2c_setup.ml` (`grok_hooks_json`) |
| Handlers / allowlists | `ocaml/cli/c2c_hook_cmd.ml` (`kimi_session_events`, `grok_session_events`) |
| Decay allowlist (untouched) | `ocaml/c2c_broker.ml` (`hook_anchor_is_activity_backed`) |
| Grok upstream hook docs | `~/.grok/docs/user-guide/10-hooks.md` |
| Kimi event schema (package) | `kimi_cli/hooks/config.py` + `events.py` (uv tools tree) |

---

## Bottom line for #59

Upstream **already emits** repeating mid-session hooks on both Kimi Code and Grok Build. c2c’s immortal rows are an **install/handler gap**, not an upstream gap. Next implementation step: install `PostToolUse`+`Stop` (optional `UserPromptSubmit`), teach `c2c hook {kimi,grok}` to touch on those events, prove it in `test_c2c_hook_anchor`, **then** add `kimi-hook` / `grok-hook` to `hook_anchor_is_activity_backed`. Prefer that over a REST probe; keep the carve-out until the test is green.
