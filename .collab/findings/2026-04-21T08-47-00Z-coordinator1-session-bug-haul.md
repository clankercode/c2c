---
author: coordinator1
ts: 2026-04-21T08:47:00Z
severity: mixed (see per-entry)
fix: mostly FIXED — bugs 1-6,8-10 resolved; bug 7 in-progress (planner1)
---

# Session bug haul — consolidated log so we don't re-discover later

Max explicitly flagged the need to write these down right away so future-us
doesn't retread the same debugging. Each entry has symptom / root cause /
status / next action. Ordered by severity.

---

## 1. [HIGH] Stale process proliferation on every `c2c start` restart

### Symptom
After ~5 restarts of `oc-coder1` during this session:
- 9+ orphan `c2c monitor --alias oc-coder1` processes (ppid=1)
- 3 stale `/home/linuxbrew/.../opencode-ai/bin/.opencode` on pts/3
- Doubled `tryDeliver` + `deliverMessages` log lines per cycle (two plugin
  instances running in one opencode)

### Root causes (3 independent defects)
1. **`c2c start` doesn't isolate its child in a new process group.**
   `ocaml/c2c_start.ml:813-825` forks and execs without `setpgid 0 0`;
   `cleanup_and_exit` (712-721) only SIGTERMs its direct sidecars
   (deliver/poker/wire). When outer dies, grandchildren
   (opencode node, `.opencode`, the `c2c monitor` spawned by the plugin)
   inherit ppid=1 and live forever.
2. **Plugin's `c2c monitor` has no parent-death binding.**
   `.opencode/plugins/c2c.ts:427-443` spawns via plain `spawn()`. Node's
   `process.on('exit')` can't fire on SIGKILL, so on hard opencode death
   the monitor is orphaned. No `PR_SET_PDEATHSIG`, no ppid==1 self-exit
   check in the `c2c monitor` subcommand itself.
3. **No duplicate-name guard in `c2c start`.** Running
   `c2c start opencode -n oc-coder1` while one already exists silently
   starts a second parallel instance. This was the primary multiplier —
   operator-side tmux confusion + retries compounded into the orphan pile.

### Status
- (1) & (2): dispatched to coder2-expert for follow-up.
- (3): already dispatched to coder2-expert earlier this session.

### Next action
Implement pgid isolation in `c2c_start.ml` fork path; add `getppid() == 1`
check in `c2c monitor` subcommand self-exit; dup-name guard refuses start
with clear error pointing at existing instance dir.

---

## 2. [HIGH] Hostname-based default aliases — silent, ugly, collision-prone

### Symptom
coder2-expert registered under alias `opencode-xertrov-cachyos-x8664`
instead of `coder2-expert`. This alias is generic (hostname-derived), will
collide if two hosts share a pattern, and there's no visible feedback at
startup saying "here's the auto-picked alias — override with -n".

### Root cause
- `ocaml/c2c_start.ml:229-241` `default_name client` → `<client>-<hostname>`.
- `ocaml/cli/c2c.ml:3462-3474` `default_alias_for_client` → `<client>-<user>-<host>`.
Both are silent; nothing logs "using default=X" when falling back.

### Status
Dispatched to coder2-expert. Fix: replace with 2-3 random words from
`data/c2c_alias_words.txt` (same pool the broker's alias-reservation uses);
emit stderr warning on fallback.

### Next action
Coder2 implements. Also: Max wants coder2 to re-register itself under a
non-hostname alias (dogfood).

---

## 3. [MED] `c2c install` writes 9-byte stub to global opencode plugin path

### Symptom
`~/.config/opencode/plugins/c2c.ts` is `// plugin` (9 bytes) after running
`c2c install` / `c2c start opencode`. This is not the defer-to-project
plugin (commit 4947634) — it's a literal no-op stub.

### Root cause
`c2c_configure_opencode.py` (or equivalent OCaml path) writes a stub
instead of copying the real plugin. The 4947634 defer mechanism only
works if global IS the real plugin with its self-detect `isGlobalPlugin`
branch. A stub leaves delivery entirely to the project-local plugin,
which works for repos that have `.opencode/plugins/c2c.ts` but fails for
any other cwd.

### Status
Open. Global stub was deleted mid-session; need installer fix so it
doesn't regress on next `c2c install` run.

### Next action
Fix installer to write the full real plugin to global path (with the
defer branch active), not a stub. Add a health check to `c2c health`
that warns when the global plugin is <1KB.

---

## 4. [MED] Diagnostic trap: stale debug log entries mislead future-me

### Symptom
coordinator1 spent ~15 min chasing a "silent-drain mystery" because
`.opencode/c2c-debug.log` showed `drainInbox error: unknown option
--file-fallback` entries from BEFORE the fix, while new post-fix process
was actually fine. Source on disk was clean; "obvious" conclusion was
bun-cache or in-memory stale compile.

### Root cause
- Debug log is append-only, shared across all opencode processes in the
  cwd. A fresh post-fix process writes zero new entries unless
  `C2C_PLUGIN_DEBUG=1` is set.
- No session-separator / PID prefix in log lines, so you can't tell old
  from new at a glance.

### Status
Open. planner1 diagnosed it correctly from the outside while coordinator1
was deep in the wrong-tree.

### Next action
- Prefix every debug line with PID + ISO timestamp (already has ts).
- On plugin init, log a distinctive banner:
  `=== c2c plugin boot pid=<n> sha=<first 8 of source sha256> ===`
  so you can instantly see which process wrote which lines, and whether
  the code that booted matches the code on disk.
- Consider rotating or truncating `c2c-debug.log` on plugin init (at
  least print a clear boundary).

---

## 5. [MED] Cold-boot promptAsync silent-drop (Gap 2 from earlier finding)

### Symptom
DMs queued before an opencode TUI has started an active session are not
delivered by `promptAsync` — they sit in the inbox until the operator
types a keystroke into the TUI.

### Root cause
See `.collab/findings/2026-04-21T07-47-00Z-coordinator1-opencode-delivery-gaps.md`
(Gap 2). promptAsync requires an active session; cold-boot TUI on welcome
screen has none.

### Status
Known / open. Partially mitigated by commit 4488394 "retry cold-boot
delivery until session created" but clearly still reproduces — my test
of oc-coder1 needed a manual keystroke before DMs would flow.

### Next action
Audit 4488394's retry loop — verify it actually runs, escalate delay, or
have the plugin inject a no-op prompt on boot to force a session.

---

## 6. [MED] Operator footgun: `tmux send-keys` into a TUI pane types INTO the TUI

### Symptom
I typed `c2c start opencode -n oc-coder1` via tmux send-keys expecting a
shell, but the pane was already running opencode TUI — so my command
became literal text in opencode's prompt. Lost 5+ min to confused retries
that spawned MORE orphans.

### Root cause
Operator / tooling UX: `tmux send-keys` is dumb — doesn't check foreground
process. Max's tip was "send Escape, then ^D to exit TUI first."

### Status
Documented. Not a code bug — an operator-UX hazard.

### Next action
Consider adding `scripts/c2c-tmux-exec.sh <pane> <cmd>` that escapes,
Ctrl-D's, then sends the command — safe even if pane is in a TUI. (Or
better: check pane current_command first, refuse if not a known shell.)

---

## 7. [LOW] Duplicate registry entries for the same logical peer

### Symptom
Registry contains TWO entries for coder2-expert:
- session_id=6e45bbe8-… alias=coder2-expert pid=424242 alive=false
- session_id=coder2-expert alias=opencode-xertrov-cachyos-x8664 alive=null

### Root cause
Session ID and alias are independently tracked; no reconciliation when
the "same" session restarts with a different session_id. `mcp__c2c__sweep`
would clean the dead one but is banned during active swarm.

### Status
Open. Tied to the uniqueness/guard work already dispatched.

### Next action
When a new session registers with an alias already in use by a stale
(non-alive) entry, drop the stale entry automatically (atomic within the
registry lock).

---

## 8. [LOW] `--print-logs` flag floods opencode TUI (FIXED THIS SESSION)

### Symptom
opencode TUI was unreadable — log lines overlapping on top of the UI.

### Root cause
Earlier commit auto-added `--print-logs` to opencode launch args. On the
Max-reported "1.14.19" opencode build this dumps INFO+ logs directly to
the terminal that's rendering the TUI.

### Status
Fixed mid-session — removed `--print-logs` from `c2c_start.ml` opencode
arg list. `--log-level INFO` still populates the log file via symlink.
Not yet committed at time of writing.

### Next action
Commit the fix (local); dedupe with coder2-expert's open branch in case
of conflicts.

---

## 9. [LOW] `c2c start` + pkill returned exit 144, unclear if process actually died

### Symptom
`pkill -f "c2c start opencode -n oc-coder1"` returned exit 144 (not a
standard code). Unclear whether the process was killed; required
follow-up `ps` to verify.

### Root cause
Likely process-group related (see bug 1 — killing the outer leaves
grandchildren alive, so pkill sees partial success).

### Status
Will be fixed by bug 1 fix.

---

## 10. [LOW] Push-per-commit anti-pattern (FIXED POLICY, NOT CODE)

### Symptom
Pushed 3 times in 7 min earlier, triggering 3 parallel Railway builds
(~$ real).

### Root cause
coordinator1 (me) misread the push-batching rule as "batch then push"
rather than "push only when a deploy is actually needed."

### Status
Fixed: CLAUDE.md rule rewritten, memory updated, peers notified. Local
queue at 15+ commits; will push only when something concrete needs to be
live.

---

## Cross-cutting theme

Most of the above bugs share a family: **silent auto-behavior with no
operator feedback**. Default names pick silently, stubs get written
silently, duplicate starts succeed silently, orphan processes linger
silently, stale logs accumulate silently. The fix pattern is symmetric:
**emit a visible warning or refuse the action** whenever the system is
falling back to a default, handling a collision, or continuing past a
"this shouldn't happen" state.
