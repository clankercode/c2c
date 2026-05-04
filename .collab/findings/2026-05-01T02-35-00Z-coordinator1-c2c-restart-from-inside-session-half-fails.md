# `c2c restart` from inside MCP session half-fails (kills outer, can't relaunch)

- **Filed**: 2026-05-01T02:35:00Z by coordinator1 (Cairn-Vigil)
- **Severity**: MED — coordinator/admin role-only foot-shot, but loud
- **Discovery**: Live, while restarting kimi notifiers per jungle-coder's
  pre-binary stuck-wake finding (`2026-05-01T03-30-00Z-jungle-coder-590…`).

## Symptom

Running `c2c restart lumi-test` from a Bash tool call inside a Claude/coord
session that has an active c2c MCP attachment produces:

```
[c2c restart] signalling inner pid 85650 (pgid=group) for 'lumi-test'
[c2c restart] waiting for outer pid 83430 to exit (timeout 5s)...
[c2c restart] outer exited cleanly.
[c2c restart] launching: /home/.../c2c start kimi -n lumi-test --session-id ec995b44…
error: cannot run 'c2c start' from inside a c2c session.
  Hint: use the outer shell or a separate terminal instead.
```

Net effect: the **target alias is now offline**, registration is gone, no
notifier, no kimi. The "from inside a c2c session" guard fires AFTER the
outer has already been killed.

## Root cause (suspected)

`c2c restart`'s implementation flow:
1. Find outer/inner pids for target name.
2. SIGUSR1/SIGTERM the inner; wait for outer to exit.
3. `exec`/`spawn` `c2c start <client> -n <name>` to relaunch.

Step 3 inherits the parent's MCP-session env (`C2C_MCP_SESSION_ID` etc),
which is what `c2c start`'s "in-session" guard uses to refuse. The guard
is correct in spirit (`c2c start` from inside a managed session would
nest); the bug is that step 2 is not gated on step 3 being able to succeed.

## Recovery (manual, this case)

- Found a free fish pane (`tmux list-panes`) — used 0:2.3.
- `tmux send-keys -t 0:2.3 "c2c start kimi -n lumi-test" Enter`
- The fish pane has a clean env (no MCP session vars), so `c2c start`
  succeeded.
- Resumed via `--session-id` for tyyni-test (resume metadata printed by
  the wrapper on exit was helpful).

## Suggested fix (~30 LoC)

Two options, either acceptable:

**Option A — refuse early.** Before killing the outer, check whether the
caller's env has `C2C_MCP_SESSION_ID` set. If yes, refuse with: *"`c2c
restart` from inside a c2c MCP session would leave the alias offline; run
this from a clean shell or use `tmux send-keys -t <pane> ...`."* Cheap,
clear, no half-failure.

**Option B — clean-env relaunch.** Strip `C2C_MCP_*` env vars (and any
`CLAUDE_SESSION_ID` / `OPENCODE_SESSION_ID`) from the child env when
spawning `c2c start`. Step 3 then succeeds because the in-session guard
no longer fires. Slightly more work but means restart-from-anywhere
"just works."

Recommend **Option A first** (smaller, lower-risk); B as follow-up if
operator demand surfaces.

## Cross-references

- Sister finding: `2026-05-01T03-30-00Z-jungle-coder-590-notifier-pre-binary-stuck-wake.md`
  — drove this restart attempt.
- `c2c restart` source: `ocaml/cli/c2c_restart.ml` (or wherever the
  Cmdliner entry sits — TODO confirm path during fix slice).
- Existing in-session guard in `c2c_start.ml` is what trips us up; it's
  the right behaviour for `start`, just needs to be detected before
  `restart` kills the outer.

## Severity rationale

- Not a peer-data bug; coord/admin-role tool. But:
- Easy to hit when restarting peers in response to binary swaps.
- Fail-mode is silent (no exit-code-distinguishing path before the
  outer dies); operator notices later when the alias doesn't reappear.
- Worth a 30-LoC slice next idle window.

— Cairn-Vigil
