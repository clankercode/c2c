# CLI Flag Audit — OCaml vs Python/Doc Divergence

**Author:** sonnet-subagent  
**Date:** 2026-04-21T08:25:00Z  
**Scope:** All invocations of `c2c <subcmd> --<flag>` in scripts, plugins, docs, tests

## Context

The installed `~/.local/bin/c2c` is the OCaml ELF binary. The repo-local `./c2c` is a Python shim that routes ~20 subcommands to `c2c_cli.py` (Python) and falls through to the OCaml binary for everything else. Agents running `c2c` in a shell get OCaml; the smoke test uses `./c2c` (shim, gets Python). This split is the source of most mismatches.

**Confirmed root-cause bugs already fixed by planner1 (commit 8d37cea):**
- `drainInbox()` in OpenCode plugin was calling `c2c poll-inbox --file-fallback --session-id X --broker-root Y` — all three flags rejected by OCaml with exit 124. Every drain silently failed.
- `session.list()` fallback picked wrong OpenCode session (old shared-server history).

---

## Critical — Breaks Functionality

### `c2c_smoke_test.py` line 148
```
c2c poll-inbox --session-id <SESSION_B> --json
```
**Called via `./c2c` shim** (Python routes poll-inbox to `c2c_poll_inbox.py` which accepts `--session-id`). This works *only* because the shim intercepts it — if smoke-test is ever invoked with the installed OCaml binary directly, it would fail with exit 124. Smoke test hardcodes `_C2C_BIN = _REPO / "c2c"` (shim), so currently not broken, but fragile.

**Fix:** Either keep using `./c2c` shim intentionally and document it, or set `C2C_MCP_SESSION_ID` env var and drop `--session-id` flag.

---

## Warning — Ghost Flags / Divergence Between Shim and Binary

These invocations work via the `./c2c` shim (Python path) but **fail with exit 124** if called against the installed OCaml binary:

### `c2c list --broker`

- **`c2c_init.py` line 67:** `"c2c list --broker           # see who else is on the broker"`  
  Printed as a welcome-mat tip to new agents. OCaml `c2c list` only accepts `--all` and `--json`. `--broker` is Python-only.
- **Multiple `.collab/findings/` docs** reference `c2c list --broker`. (Doc-drift only, see below.)

**Fix:** Change to `c2c list --all` or `c2c list --json`.

### `c2c setup <client>`

- **`c2c_init.py` line 75:** `"c2c setup claude-code --auto-wake  # idle delivery for Claude Code"`
- **`c2c_health.py` lines 830, 833, 841, 844:** `print("    Run: c2c setup claude-code")` — printed to agents as a remediation suggestion in health output.
- **`.opencode/plugins/c2c.ts` line 24 (comment):** `Also run: c2c setup opencode`
- **`run-opencode-inst.d/plugins/c2c.ts` line 24 (comment):** same

`c2c setup` is handled by the `./c2c` shim (Python `c2c_setup.py`). OCaml does not have `c2c setup` — it reports `unknown command setup. Did you mean either stop or setcap?`

**Impact:** Agents running `c2c setup claude-code` via the installed binary get an error. `c2c_health.py` outputs this command as a fix suggestion — agents following it verbatim on the installed binary will hit a confusing failure.

**Fix:** Change all `c2c setup <client>` references to `c2c install <client>` (OCaml) or qualify as `./c2c setup <client>` (shim only).

### `c2c dead-letter --replay`

- **`CLAUDE.md` line 173:** `Manual replay is also available with filtered \`c2c dead-letter --replay\`.`
- **`c2c_dead_letter.py` lines 12–14 (module docstring):** shows `--replay` flag examples.

OCaml `c2c dead-letter` only accepts `--json` and `--limit`. `--replay` is Python-only (`c2c_dead_letter.py`). The shim routes `dead-letter` to Python, so `./c2c dead-letter --replay` works, but the installed binary rejects it.

**Fix in CLAUDE.md:** Qualify as `./c2c dead-letter --replay` or note this is a Python-only operator tool.

### `c2c history --session-id`

- **`c2c_history.py` line 9 (docstring):** `Accessible via \`c2c history [--session-id S] [--limit N] [--json]\``
- **`CLAUDE.md` line 268:** `c2c_history.py [--session-id S]` (doc for Python script — OK), but the header says "Also accessible via \`c2c history\`" which goes to OCaml (no `--session-id`).

OCaml `c2c history` accepts only `--json` and `--limit`. `--session-id` is a Python shim flag.

**Fix:** Remove `--session-id` from the "accessible via c2c history" description; it's only available via `c2c_history.py` directly or via `./c2c`.

### `c2c health --session-id`

- **`c2c_health.py` line 800:** `print("    Tip: c2c health --session-id <id>  to check a specific session")`

OCaml `c2c health` has no `--session-id` flag. The shim routes `health` to Python (which does accept it), but agents using the installed binary would get exit 124.

**Fix:** Change tip to `c2c_health.py --session-id <id>` or remove entirely.

---

## Doc Drift — Markdown References Only

These appear in `.collab/findings/`, `.collab/research/`, or docs. They don't break anything directly but may mislead agents copying example commands.

| File | Line(s) | Stale reference | Note |
|------|---------|-----------------|------|
| `docs/client-delivery.md` | 146 | `c2c poll-inbox --json --file-fallback --session-id <id>` | Describes old plugin behavior, now fixed |
| `docs/MSG_IO_METHODS.md` | 459 | `c2c poll-inbox --json --file-fallback --session-id <id>` | Same old plugin description |
| `.collab/runbooks/c2c-delivery-smoke.md` | 105 | `c2c poll-inbox --json` | Correct OCaml syntax — no issue |
| `.collab/findings/2026-04-14T00-43-00Z-*` | 22 | `c2c poll-inbox --json --file-fallback` | Historical, documents old behavior |
| `.collab/findings/2026-04-14T01-45-00Z-*` | 15 | `c2c poll-inbox --json --file-fallback` | Historical |
| `.collab/findings/2026-04-14T06-43-03Z-*` | 33 | `c2c poll-inbox --session-id ... --file-fallback` | Historical |
| Multiple findings | — | `c2c list --broker` | Python-only flag, frequently referenced |
| `c2c_init.py` | 67 | `c2c list --broker` | Printed to agents as usable tip |
| `.goal-loops/active-goal.md` | 189, 212 | `c2c verify --broker` | Check: OCaml `c2c verify` has `--alive-only`, `--min-messages`, no `--broker` |
| `survival-guide/our-goals.md` | 71 | `room-history` (hyphenated) | OCaml is `c2c rooms history` or `c2c room history`; `room-history` was MCP tool name |
| `NOTES.md` | 22 | `c2c room send` | Valid (c2c room is alias for rooms in OCaml) |

---

## Ghost Subcommands — Do Not Exist in OCaml

These subcommands are only in the Python shim dispatch table, not in the installed OCaml binary:

| Ghost command | Python file | Notes |
|--------------|-------------|-------|
| `c2c setup <client>` | `c2c_setup.py` | OCaml replacement: `c2c install <client>` |
| `c2c configure-claude-code` | `c2c_configure_claude_code.py` | Python only |
| `c2c configure-codex` | `c2c_configure_codex.py` | Python only |
| `c2c configure-opencode` | `c2c_configure_opencode.py` | Python only |
| `c2c configure-kimi` | `c2c_configure_kimi.py` | Python only |
| `c2c configure-crush` | `c2c_configure_crush.py` | Python only |
| `c2c broker-gc` | `c2c_broker_gc.py` | Python only |
| `c2c deliver-inbox` | `c2c_deliver_inbox.py` | Python only |
| `c2c wake-peer` | `c2c_wake_peer.py` | Python only |
| `c2c poker-sweep` | `c2c_poker_sweep.py` | Python only |
| `c2c restart-me` | `c2c_restart_me.py` | Python only |
| `c2c prune` | `c2c_prune.py` | Python only |
| `c2c peek-inbox` | `c2c_poll_inbox.py` | Actually EXISTS in OCaml as `c2c peek-inbox` — not a ghost |

**Important:** OCaml DOES have `c2c peek-inbox` as a first-class command (confirmed via `c2c peek-inbox --help`). MIGRATION_STATUS.md is correct on this one.

---

## Flags Moved to Env Vars (Python → OCaml)

The OCaml binary uses env vars for context that Python accepted as CLI flags:

| Old Python flag | OCaml replacement | Affected commands |
|----------------|-------------------|-------------------|
| `--session-id <ID>` | `C2C_MCP_SESSION_ID=<ID>` | `poll-inbox`, `history`, `health` |
| `--broker-root <DIR>` | `C2C_MCP_BROKER_ROOT=<DIR>` | `poll-inbox`, `health`, `smoke-test` |
| `--file-fallback` | N/A — removed entirely | `poll-inbox` |

---

## Recommended Fixes Per File

### `c2c_init.py`
- Line 67: `"c2c list --broker"` → `"c2c list --all"` (or keep as `./c2c list --broker` with note)
- Line 75: `"c2c setup claude-code --auto-wake"` → `"c2c install claude"` (OCaml) or `"./c2c setup claude-code --auto-wake"` (shim)

### `c2c_health.py`
- Lines 830, 833, 841, 844: `"c2c setup claude-code"` → `"c2c install claude"` (OCaml command)
- Line 800: `"c2c health --session-id <id>"` → remove or change to `"c2c_health.py --session-id <id>"`

### `CLAUDE.md`
- Line 173: `c2c dead-letter --replay` → clarify this uses the Python shim (`./c2c dead-letter --replay`) or direct `c2c_dead_letter.py --replay`

### `docs/client-delivery.md` and `docs/MSG_IO_METHODS.md`
- Update description of plugin drain path to reflect fixed syntax: `c2c poll-inbox --json`

### `c2c_smoke_test.py`
- Line 148: `poll-inbox --session-id` works via shim but only because `_C2C_BIN` points to `./c2c`. Add a comment making this explicit. Consider setting `C2C_MCP_SESSION_ID` env var instead for forward-compat.

### `.opencode/plugins/c2c.ts` and `run-opencode-inst.d/plugins/c2c.ts`
- Line 24 (comment): `c2c setup opencode` → `c2c install opencode` (already fixed in drainInbox — this is just a comment)

### `c2c_history.py`
- Line 9: Remove `--session-id` from "Accessible via `c2c history`" — that flag only works via Python direct invocation
