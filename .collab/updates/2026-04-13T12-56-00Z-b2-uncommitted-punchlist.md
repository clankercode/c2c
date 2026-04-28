# storm-beacon (c2c-r2-b2) — uncommitted work punch list

Timestamp: 2026-04-13 12:56 local

All of the following is in the working tree, NOT committed. Grouped by natural
commit boundaries; pick any subset to land.

## 1. c2c_poker.py + CLAUDE.md (Python, standalone)

Files:
- `c2c_poker.py` (new, ~215 lines)
- `CLAUDE.md` (one-line entry under Python Scripts)

What it does: generic PTY heartbeat poker for any interactive TUI client
(Claude, OpenCode, Codex, plain shells). Target resolution via
`--claude-session NAME_OR_ID`, `--pid N`, or explicit
`--terminal-pid P --pts N`. Supports `--once`, `--initial-delay`, `--pidfile`,
`--from`, `--alias`, `--event`, `--raw`, `--interval`, `--message`, and
`--only-if-idle-for SECONDS` (best-effort: skip injection when target's Claude
transcript mtime is within the window).

Default message updated from `(c2c heartbeat — ignore)` to
`(c2c heartbeat — continue with your current tasks)` per Max feedback.

Verification: end-to-end injection confirmed. Currently running in bg as
PID 1258350 for storm-beacon with `--only-if-idle-for 90`; skip path exercised
on first tick while active.

## 2. ocaml/c2c_mcp — broker liveness + registry lock + sweep

Files:
- `ocaml/c2c_mcp.ml`
- `ocaml/c2c_mcp.mli`
- `ocaml/test/test_c2c_mcp.ml`

Three logically distinct changes (could be one commit or three):

### 2a. Liveness
- `type registration = { session_id; alias; pid : int option }`
- `Broker.register ~pid`, `handle_tool_call "register"` captures
  `Unix.getppid()`
- `registration_is_alive` via `/proc/<pid>` probe (None → alive)
- `Broker.enqueue_message` picks first live match by alias; raises
  `Invalid_argument "recipient is not alive: <alias>"` when all dead
- Legacy pid-less `registry.json` entries still load + deliver
- `handle_tool_call "list"` emits pid field when present

### 2b. Registry lock
- `Broker.with_registry_lock` via `Unix.lockf` on `registry.json.lock` sidecar
- `Broker.register` wrapped
- Race reproduced 2/5 runs unlocked; 5/5 clean with lock.
  Addresses the 01:55Z registry purge pattern.

### 2c. Sweep
- `Broker.sweep : t -> sweep_result` under registry lock:
  - drops dead registrations
  - deletes their inbox files
  - deletes orphan inbox files with no matching registration
- Exposed as the `sweep` MCP tool, returns JSON
  `{dropped_regs:[{session_id,alias}], deleted_inboxes:[session_id]}`
- Useful target: the 135 zombie inbox files currently in `.git/c2c/mcp/`

Tests (all new, 8 total new, 23/23 pass):
- enqueue to dead peer raises
- enqueue picks live when zombie shares alias
- legacy pidless reg loads as alive
- pid persists through register/list round-trip
- concurrent register does not lose entries (12-child fork race)
- sweep drops dead reg and its inbox
- sweep deletes orphan inbox file
- sweep preserves live reg and its inbox
- sweep preserves legacy pidless reg

## Effect after restart

All changes are backwards compatible with legacy registry.json contents. After
Max rebuilds and restarts the MCP server:

- New `register` calls capture parent pid automatically.
- New `enqueue_message` error path signals dead recipients distinctly from
  unknown aliases.
- New `sweep` tool is available via `tools/call` (no existing session uses it
  unprompted; safe to introduce).
- Existing storm-beacon / storm-echo / codex-local entries stay alive because
  they have no pid field yet (treated as legacy → alive). They get pid fields
  only on re-register.

## Follow-ups (not started, flagged)

- pid re-capture at first RPC / storing start-time (field 22 of
  /proc/<pid>/stat) to defeat reparent-to-init false positives in liveness
  probe. Current approach is good enough in practice but theoretically
  defeatable when a session's parent claude process exits and its child gets
  reparented to init — /proc/1 always exists.
- Broker sweep could emit a last-seen timestamp rather than hard-deleting
  orphan inboxes, so a session that briefly exits and re-registers with the
  same session_id retains queued messages. Current behavior: delete. Safer
  default is delete given the 135 zombies, but worth revisiting.

## No conflicts expected with

- codex's `run-codex-inst*`, `tests/test_c2c_cli.py`, `tmp_status.txt`,
  `.goal-loops/active-goal.md`
- storm-echo's `poll_inbox` (already committed as f2d78bb)
