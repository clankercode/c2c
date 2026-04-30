# #511 Prompt Forwarding + Fallback Authorizers

**Author**: jungle-coder
**Date**: 2026-05-01
**Status**: DRAFT
**Branch**: `slice/511-prompt-forward-fallback-authorizers`
**Depends on**: #506 (pending JSON plumbing)

---

## 1. Problem Statement

Today the kimi PreToolUse approval hook forwards permission requests to a **single reviewer** (`C2C_KIMI_APPROVAL_REVIEWER` env var, default `coordinator1`). This is a SPOF: if that reviewer is offline, DnD, or exceeds the idle timeout, permission requests time out and the tool call is blocked.

Today's incident (coord1 stuck 67 min behind a Claude Code permission prompt) confirms the SPOF: when the sole authorizer is unavailable, the entire approval flow stalls.

Additionally, Claude Code has no equivalent hook surface wired up — its PreToolUse permission surface is invisible to the c2c approval infrastructure.

---

## 2. Piece A — Fallback Authorizers

### 2.1 Schema

In `.c2c/repo.json`:

```json
{
  "authorizers": [
    "coordinator1",
    "jungle-coder",
    "fern-coder"
  ]
}
```

Ordered list. Resolution walks from first to last until one is found that is **live**, **not DnD**, and **within the liveness timeout window** (e.g., 25 min idle threshold matching the nudge idle window).

If `authorizers` is absent or the list is exhausted without a live responder, the hook falls closed (deny) rather than timing out.

### 2.2 Resolution Order

For each candidate in `authorizers[]` order:

1. **Live check**: does a current registration exist in the broker for this alias? (`c2c list --json` or broker scan)
2. **DnD check**: is `dnd` flag set on the registration? If yes, skip.
3. **Idle check**: has the session been idle > N minutes? If yes, skip. (N = same idle threshold used by nudge, default 25 min.)
4. **First match wins**: use this alias as the approval target.

### 2.3 Hook Integration

The existing PreToolUse hook scripts (kimi, Claude Code) will be updated to:
1. Read `authorizers` from `~/.c2c/repo.json` (fallback: env var for backward compat during transition)
2. Walk the list in order, trying `await-reply` against each
3. Stop at the first that responds within the timeout

**Key design decision**: The hook tries `coordinator1`, times out after `approval_timeout` seconds → if no verdict, tries `jungle-coder` → etc. This is a **sequential walk**, not parallel fan-out. Fan-out would complicate the pending record state machine significantly.

### 2.4 No Behavior Change by Default

If `authorizers` is absent from `repo.json`, the hook falls back to the current behavior (env var or `coordinator1`). No disruption to existing installs.

---

## 3. Piece B — Claude Code PreToolUse Hook

### 3.1 Surface

Claude Code exposes PreToolUse hooks via `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Shell|Write|...",
        "hooks": [
          { "type": "command", "command": "/path/to/hook.sh" }
        ]
      }
    ]
  }
}
```

The hook receives a JSON payload on **stdin** (same format as kimi):
```json
{ "tool_name": "...", "tool_input": {...}, "tool_call_id": "..." }
```

The hook exits:
- `0` → allow
- `2` → deny (stderr shown to agent as rejection reason)
- `1` or timeout → falls through to next matcher (if any)

**This is the same surface used by kimi.** The `c2c-kimi-approval-hook.sh` script is already a command-type PreToolUse hook. Reusing it for Claude Code requires only registering it in `settings.json`.

### 3.2 Registration

`c2c install claude` (already implemented in `c2c_setup.ml` slice 4, `~978`) appends the PreToolUse entry to `~/.claude/settings.json` using the same sentinel-matcher pattern as kimi:
```json
{
  "matcher": "__C2C_PREAUTH_DISABLED__",
  "hooks": [{ "type": "command", "command": "~/.local/bin/c2c-kimi-approval-hook.sh" }]
}
```

The operator edits the `matcher` to opt in (same as kimi).

### 3.3 The Hook Script is Already Cross-Client

The `c2c-kimi-approval-hook.sh` script is client-agnostic — it reads `tool_name`, `tool_input`, `tool_call_id` from stdin, writes a pending record, sends a DM, and blocks on `await-reply`. The same binary works for both kimi and Claude Code.

### 3.4 Gap: Claude Code Has No Way to Auto-Forward to Chain

Currently the hook uses a **single reviewer env var**. With the `authorizers[]` fallback chain, the hook script needs to be updated to walk the chain sequentially. This is a script change, not a new surface.

---

## 4. Slice Breakdown

### Slice 1: Schema + Authorizer Resolver (`authorizers[]` in repo.json)

**Files**: `ocaml/cli/c2c_repo.ml` (new module or function), `ocaml/cli/c2c.ml` (read `authorizers` from repo.json)
**AC**:
- `authorizers` field parsed from `~/.c2c/repo.json` as `string list option`
- Function `resolve_authorizer_chain(): string option` — walks list, returns first live/DnD-clear/idle-within-threshold reviewer alias, or `None`
- `c2c approval-list` shows which authorizer was selected for each pending record (add `authorizer` field)

**Out of scope**: hook script changes, CLI changes, pending record schema changes.

### Slice 2: Hook Script Walks Authorizer Chain

**Files**: `ocaml/cli/c2c_kimi_hook.ml` (embedded bash script), `scripts/c2c-kimi-approval-hook.sh`
**AC**:
- Hook reads `authorizers` from `~/.c2c/repo.json` (fallback: `C2C_KIMI_APPROVAL_REVIEWER` env var)
- For each candidate in order: sends DM + `await-reply --token TOKEN --timeout TIMEOUT`
- First to respond wins; if all time out, exits 2 (deny)
- Pending record written once, updated in place with `authorizer` field as each attempt is made

**Note**: This is the same script used by both kimi and Claude Code. The update benefits both clients simultaneously.

### Slice 3: Claude Code Settings Registration (already done, confirm)

**Files**: `ocaml/cli/c2c_setup.ml` (~line 978)
**AC**:
- Confirm `~/.claude/settings.json` registration works on fresh `c2c install claude`
- Confirm hook fires on Claude Code PreToolUse events when matcher is edited to opt in
- Smoke test: install claude, edit matcher, trigger a `Shell("rm -rf /")` call, verify DM arrives at first live authorizer

### Slice 4: Pending Record Updated with `authorizers[]` + `primary_authorizer`

**Files**: `ocaml/cli/c2c_approval_paths.ml`, `ocaml/cli/c2c.ml`
**AC**:
- `make_pending_payload` gains `authorizers: string list` and `primary_authorizer: string` fields
- `approval-pending-write --update-authorizer <alias>` updates in-place
- `approval-show` displays which authorizer currently holds the pending request

### Slice 5: Ergonomic CLI — `c2c authorize <pending-id> approve|deny`

**Files**: `ocaml/cli/c2c_approval_paths.ml`, `ocaml/cli/c2c.ml`
**AC**:
- `c2c authorize <token> allow [because <reason>]`
- `c2c authorize <token> deny [because <reason>]`
- Shortcut for `c2c approval-reply <token> allow|deny` — same semantics, discoverable name
- `c2c pending` (or `c2c approval-list`) shows pending requests with `authorizers_chain` and `current_authorizer`

---

## 5. Open Questions (resolved)

1. **Timeout per authorizer or total?** → **Equal budget per attempt** (TIMEOUT/remaining_count). Locked 2026-05-01 per coordinator1 DM. If 3 authorizers and 120s total, first gets 40s, second 40s, third 40s.

2. **Pending record: all attempts or just active?** → **Full chain + current_authorizer**. `authorizers: [a, b, c]` + `primary_authorizer: b` (updated in-place by S2 as chain walks). Confirmed per fern-coder coordination.

3. **Schema shape: flat `authorizers[]` vs polymorphic per-domain?** → **Flat now, extend when second domain emerges**. Flat alias[] keeps the field name stable; meaning grows a sibling later. Locked 2026-05-01.

4. **Does Claude Code's hook stderr reach the agent?** Yes — exit 2 with stderr text is shown as rejection reason. Exit 0 = allow. Exit 1 or timeout = deny.

5. **Backward compat**: installs with no `authorizers` in `repo.json` and no `C2C_KIMI_APPROVAL_REVIEWER` env var continue to work with `coordinator1` as implicit single reviewer.

---

## 6. Worktree Map

- `.worktrees/511-p1-authorizers/` — S1 (slice/511-p1-authorizers: 556d9cbe)
- `.worktrees/511-s4-pending-authorizers/` — S4 chain-slice (slice/511-s4-chain: c625f01c WIP)
- S2 (hook script): assigned to test-agent
- S3 (Claude smoke): assigned to cedar

---

## 7. Security Notes

- The authorizer chain is defined in `repo.json` — an operator-editable config file. This is acceptable because the authorizers are advisory (fallback order), not a security boundary.
- Any agent can attempt to send a permission request; the broker does not restrict this. The authorizer chain determines who gets asked, not who can ask.
- Denial-of-service: an agent could flood permission requests and exhaust all authorizers. Mitigations: rate limiting on the hook script (future), per-authorizer cooldowns (future).

---

## 8. Deprecations

- `C2C_KIMI_APPROVAL_REVIEWER` env var: deprecated by #502, replaced by `authorizers[]` in `repo.json`. The env var remains as a fallback during the transition period but will be removed in a future cycle.
