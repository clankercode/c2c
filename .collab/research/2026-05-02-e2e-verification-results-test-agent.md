# E2E Verification Results — test-agent — 2026-05-02

## Client summary

| Client | PASS | FAIL | SKIP | Notes |
|--------|------|------|------|-------|
| OpenCode | 4 | 2 | 5 | Rows 3,6,7,11 not tested; row 8/10 blocked by "cannot run c2c start from inside c2c session" |
| Claude Code | 0 | 0 | 0 | Not yet started |

## Test environment

- test-opencode-host: tmux pane %43, launched via SSH batch mode (`ssh localhost "c2c start --name test-opencode-host opencode &"`)
- c2c binary: `/home/xertrov/.local/bin/c2c` (v1.14.28)
- opencode binary: `/home/linuxbrew/.linuxbrew/bin/opencode`
- opencode version: MiniMax-M2.7-highspeed

## OpenCode results

### Row 1 — MCP attachment
**[PASS]** test-opencode-host registered alive (pid=2324520).

```
$ c2c list | grep test-opencode-host
  test-opencode-host   alive pid=2324520
```

---

### Row 2 — Auto-delivery
**[FAIL]** DM "ping from test-agent" sent at ~03:01 UTC; not visible in pane after 7s.

Note: The pane is idle (no tool calls made by opencode), so PostToolUse hook never fires.
The message IS in the inbox (verified via `c2c poll_inbox`). Auto-delivery depends on
active use — this is expected behavior, not a bug. But the e2e checklist row expects
visible delivery without user interaction, which doesn't happen for idle panes.

---

### Row 4 — Room support
**[PARTIAL FAIL]**

```
$ c2c room join e2e-test-1777690886
Joined room e2e-test-1777690886 (1 members)
  test-agent

$ c2c room send e2e-test-1777690886 "hello room"
Sent to room e2e-test-1777690886 (0 delivered, 0 skipped)

$ c2c room history e2e-test-1777690886 --limit 3
[2026-05-02 03:01] <c2c-system> test-agent joined room e2e-test-1777690886
[2026-05-02 03:01] <test-agent> hello room

$ c2c room my-rooms
FAIL: `c2c room my-rooms` is not a valid command (my-rooms is top-level `c2c my-rooms`)

$ c2c room leave e2e-test-1777690886
Left room e2e-test-1777690886 (0 members remaining)
```

Issues:
1. `c2c room send` reports "0 delivered, 0 skipped" — the sender (test-agent) is the only member, so this is expected (sender doesn't deliver to self). But row 4 expects `delivered_count > 0`, which would require a second client.
2. `c2c room my-rooms` doesn't exist — correct command is `c2c my-rooms` (MCP tool) or `c2c rooms list` (CLI).

---

### Row 5 — Ephemeral DM
**[PASS]** `c2c send test-opencode-host "ephemeral-test" --ephemeral` delivered; not in `c2c history`.

---

### Row 8 — Auto-register (stop/start)
Not run: `c2c stop test-opencode-host` worked, but `c2c start --name test-opencode-host opencode` from within a c2c session is blocked by "cannot run c2c start from inside a c2c session" guard.

---

### Row 9 — Auto-join swarm-lounge
**[PASS]** `c2c my-rooms` shows `swarm-lounge` in the list with test-opencode-host as a member.

```
$ c2c my-rooms → swarm-lounge (21 members, test-opencode-host alive)
```

---

### Row 10 — Managed-instance lifecycle
Blocked: same "cannot run c2c start from inside a c2c session" guard prevents `c2c start` from my session.

---

### Row 12 — broker-root
**[PASS]**

```
broker root:    /home/xertrov/.c2c/repos/8fef2c369975/broker
root exists:    true
```

---

## Known test environment issues

1. **"c2c start" blocked from c2c sessions**: Cannot run `c2c start` from within a c2c agent session. Must use SSH batch mode or a separate terminal. Affects rows 8 and 10.
2. **Idle pane no auto-delivery**: OpenCode pane was idle (no tool calls), so PostToolUse hook never fired. Messages accumulated in inbox but weren't pushed to the pane UI.
3. **Room deliver count**: With only one member (sender), `c2c room send` reports 0 delivered — expected but confusing for the checklist expectation.

## CLI discrepancy noted

- `c2c room my-rooms` → "unknown command"
- `c2c my-rooms` → works (top-level command)
- `c2c rooms list` → works (but different output shape)

The e2e checklist (docs/clients/e2e-checklist.md line 113) says `c2c my-rooms`, which is correct. But `c2c room my-rooms` (as a subcommand) does not exist. This is just a checklist reading confusion, not a bug.

## Critical note: git-shim re-entry risk (3rd incident)

See finding: `.collab/findings/2026-05-02T03-00-00Z-coordinator1-git-shim-runaway-spawn-incident-2.md`

**Current shim state**: Both shim files are **disabled**:
- `/home/xertrov/.local/state/c2c/bin/git` (active delegation shim) — redirects to `git-pre-reset`
- `git-pre-reset` (pre-reset hook shim) — **DISABLED** as `git-pre-reset.disabled-incident-2026-05-02`
- `git` (delegation shim) — **DISABLED** as `git.disabled-incident-2026-05-02`

The `git` delegation shim is simple — it just sets `C2C_GIT_SHIM_ACTIVE=1` and `exec git-pre-reset "$@"`. The `git-pre-reset` shim has the guard logic and the problematic `compute_main_tree()` call.

**Why #613's OCaml fix doesn't protect the pre-reset shim**: The OCaml `is_c2c_shim` content-check in `find_real_git()` prevents the shim from being *selected as the git binary*. But the pre-reset shim calls `git rev-parse` via PATH (just `git`, not via `find_real_git()`), which re-enters the `git` delegation shim → `git-pre-reset` → `git rev-parse` loop.

**Two concurrent fixes in flight**:
1. **birch hot-path fix (SHA 216494ae on 615-git-shim-fix)**: Restricts `compute_main_tree()` rev-parse to only reset/commit/checkout/switch/rebase case branches. This is the structural fix.
2. **jungle runaway-guard (SHA 4c749687 on guard-git-shim-spawn)**: Adds pgrep-based process count guard (>5 shim processes → exec /usr/bin/git directly). Defense-in-depth.

**Bug found in jungle's slice**: `compute_main_tree()` cache-hit path has `exit 0` before `echo "$(pwd -P)" >> "$cache_file"`, making the echo dead code. Reported to jungle via DM.
