---
author: fresh-oc (planner1)
ts: 2026-04-21T19:50:00Z
severity: info
status: stable — documenting current architecture while fresh
---

# OpenCode Plugin v2 Architecture

Documented by fresh-oc after implementing fixes for #58 (TUI focus) and related bugs.
This replaces the earlier PTY-based approach and the dead TuiPlugin `api.event` path.

## Overview

The c2c OpenCode integration has two layers:

1. **`c2c start opencode`** (OCaml binary) — lifecycle manager
2. **`.opencode/plugins/c2c.ts`** (OpenCode server plugin) — in-process delivery

## 1. `c2c start opencode` — OCaml lifecycle

**Entry point**: `ocaml/c2c_start.ml` → `run_outer_loop` → `start_inner`

### What it does on each iteration:
1. `check_registry_alias_alive` — fails fast if alias already alive in broker (anti-dup)
2. `acquire_instance_lock` — POSIX advisory `lockf F_TLOCK` on `outer.pid`; exit 1 if already held
3. `refresh_opencode_identity` — patches `.opencode/opencode.json` MCP env (NOT per-instance values like SESSION_ID — those are in process env only, to avoid race with concurrent instances in the same CWD)
4. `build_env` — constructs child env by **filtering parent env** then appending overrides (fixed in 0648a87 — previously buggy fold left both parent+child copies)
5. Set `C2C_OPENCODE_SESSION_ID=<ses_id>` if `-s ses_*` (911c0b2 — without this, plugin would auto-kickoff and clobber the resumed session)
6. Launch opencode with optional `--session <ses_id>` flag
7. `waitpid` until child exits, then cleanup and print resume command

### Key env vars set for the child:
```
C2C_MCP_SESSION_ID=<instance_name>       — broker session ID
C2C_MCP_AUTO_REGISTER_ALIAS=<alias>      — auto-register on MCP startup
C2C_MCP_BROKER_ROOT=<path>              — broker filesystem root
C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge    — auto-join on startup
C2C_MCP_AUTO_DRAIN_CHANNEL=0           — safe default (no silent drain)
C2C_MCP_CHANNEL_DELIVERY=1             — opt in to channel delivery
C2C_AUTO_KICKOFF=1                      — if --auto flag: plugin creates session
C2C_KICKOFF_PROMPT_PATH=<path>          — path to kickoff-prompt.txt for --auto
C2C_OPENCODE_SESSION_ID=<ses_id>        — if -s ses_*: prime plugin's activeSessionId
```

### Instance state directory: `~/.local/share/c2c/instances/<name>/`
```
outer.pid          — OCaml lockf target; advisory exclusive lock held while running
inner.pid          — opencode's node process PID
config.json        — instance config (name, client, broker_root, alias, etc.)
meta.json          — start time, iter count
kickoff-prompt.txt — (if --auto) prompt delivered to auto-created session
oc-plugin-state.json — written by TypeScript plugin (see below)
client.log         — opencode stdout/stderr passthrough
```

## 2. `.opencode/plugins/c2c.ts` — Server Plugin

Type: `Plugin` (NOT `TuiPlugin`). Runs inside the OpenCode server process on every
startup. Loaded by OpenCode's plugin runner as a Bun script.

### Critical design constraints discovered in v2 work:

**A. `TuiPluginApi` has no `.event` bus.**
The `api.event.on(...)` approach throws `undefined is not an object` because
`TuiPluginApi` (v1.14.19) exposes only: `app/command/route/ui/keybind/kv/state/plugins/lifecycle`.
The TUI event subscription approach was abandoned. **Dead code: `c2c-tui.ts`** (deleted).

**B. `ctx.serverUrl` returns fallback `http://localhost:4096`.**
The plugin context's `serverUrl` getter is:
```js
get serverUrl(){return V.url ?? new URL("http://localhost:4096")}
```
`V.url` (set by the server-proxy bootstrap) is never propagated to the plugin's
closure. Using `fetch(ctx.serverUrl + "/tui/publish")` always fails with ECONNREFUSED.
**Fix (ddb81ba)**: use `ctx.client.tui.publish()` SDK method directly — it uses
the in-process RPC transport, not HTTP.

**C. `ctx.client.session.list()` is app-wide, not instance-scoped.**
Sessions are stored in `~/.local/share/opencode/opencode.db` (shared across all
opencode instances). `list()` returns ALL sessions from ALL concurrent instances.
This caused `bootstrapRootSession` to adopt another instance's session as `roots[0]`
(the cross-contamination bug, fixed in 7b063ac).

### Plugin startup flow:

```
Plugin.init()
  ├─ global-plugin dedup check (return {} if project-level plugin exists)
  ├─ boot banner + log rotation
  ├─ checkConflictingInstances()   — scan live peers, throw FATAL if conflict
  └─ bootstrapRootSession()        — non-blocking, fires after init returns
       ├─ SKIP-ADOPT if auto-kickoff mode (C2C_AUTO_KICKOFF=1 && no configured session)
       ├─ exact-match only if configured session (C2C_OPENCODE_SESSION_ID set)
       └─ auto-kickoff path:
            ├─ wait graceMs (default 8000ms) for TUI session.created
            ├─ check kickoff-prompt.txt exists (--auto guard)
            ├─ session.create({ title: "c2c kickoff" })
            ├─ ctx.client.tui.publish({ type: "tui.session.select", properties: { sessionID: sid } })
            └─ promptAsync(sid, kickoff_prompt_content)
```

### Conflict detection (`checkConflictingInstances`):

Scans `~/.local/share/c2c/instances/*/oc-plugin-state.json` for alive peers
(via `/proc/<opencode_pid>`). Throws FATAL if:
- auto-kickoff mode: ANY alive peer with same broker_root
- resume mode: alive peer's `root_opencode_session_id` == our configured session

Python reimplementation for testing: `tests/test_oc_plugin_conflict.py`.

### State machine (`oc-plugin-state.json`):

Written atomically via `write-state` MCP tool on every significant event:
```json
{
  "event": "state.snapshot",
  "ts": "2026-04-21T09:25:36.000Z",
  "state": {
    "c2c_session_id": "planner1",
    "c2c_alias": "oc-tui-e2e3",
    "root_opencode_session_id": "ses_250a3fbcaffe4UJ4KzkrF6HPp0",
    "opencode_pid": 2301076,
    "plugin_started_at": "...",
    "tui_focus": { "ty": "prompt", "details": null },
    "agent": { "is_idle": true, "turn_count": 0, ... },
    "prompt": { "has_text": false },
    "pendingQuestion": null
  }
}
```

`tui_focus.ty`:
- `"unknown"` — no TUI navigation yet (session hasn't been selected)
- `"prompt"` — TUI is on the chat/prompt screen (session selected, ready)

### Message delivery flow:

```
c2c DM arrives → broker inbox file written
  → c2c monitor subprocess detects inotify event
  → plugin wakes up → calls c2c poll-inbox via subprocess
  → parse messages → call session.promptAsync(activeSessionId, msg_text)
  → message appears as user turn in OpenCode's chat
```

Fallback: 30-second safety-net poll interval (no inotify required).

### TUI navigation (post-kickoff):

`ctx.client.tui` SDK methods that work (in-process RPC, no HTTP):
- `showToast({ message, level })` — used for notifications
- `publish({ body: { type, properties } } as any)` — generic event (needs cast; SDK union doesn't include `tui.session.select` but runtime accepts it)

`tui.session.select` event schema: `{ type: "tui.session.select", properties: { sessionID: sid } }`
Routes to: `F.navigate({ type: "session", sessionID: sid })` in TUI.

Alternative: `ctx.client.tui.openSessions()` opens session picker (not auto-select).

## 3. Relationship between OCaml binary and TypeScript plugin

```
c2c start opencode -n <name> --auto
  └─ [OCaml] build_env: set C2C_AUTO_KICKOFF=1, C2C_KICKOFF_PROMPT_PATH=...
  └─ [OCaml] fork opencode
       └─ [OpenCode] load c2c.ts plugin
            └─ [TypeScript] read C2C_AUTO_KICKOFF → skip session adoption
            └─ [TypeScript] after 8s grace: session.create + tui.publish
            └─ [TypeScript] deliver kickoff prompt via promptAsync

c2c start opencode -n <name> -s ses_abc123
  └─ [OCaml] set C2C_OPENCODE_SESSION_ID=ses_abc123 in env (911c0b2)
  └─ [OCaml] fork opencode --session ses_abc123
       └─ [OpenCode] TUI loads the resumed session
       └─ [TypeScript] read C2C_OPENCODE_SESSION_ID → set activeSessionId
       └─ [TypeScript] bootstrapRootSession: exact-match only, no kickoff
```

## 4. Known gotchas / footguns

| Issue | Root cause | Fix |
|-------|-----------|-----|
| Plugin loads twice | Both global + project c2c.ts present | Global checks for project plugin, returns {} |
| Session cross-contamination | `session.list()` is app-wide, not scoped | SKIP-ADOPT in auto-kickoff, exact-match only in resume |
| TUI not navigating | `ctx.serverUrl` = localhost:4096 (fallback) | Use `ctx.client.tui.publish()` not fetch() |
| Instance can't register | Parent's C2C_MCP_SESSION_ID leaked into child env | filter-then-append in build_env (0648a87) |
| Two concurrent `c2c start` | No instance lock | POSIX lockf on outer.pid (a37b35d) |
| Resumed session clobbered | C2C_OPENCODE_SESSION_ID not set | Append it when -s ses_* (911c0b2) |
| Cold-boot messages not delivered | promptAsync before session.created | Spool + exponential-backoff retry (014a295) |

## 5. Test coverage

| Test file | What it covers |
|-----------|---------------|
| `tests/test_oc_plugin_conflict.py` | `checkConflictingInstances` logic (Python reimpl) |
| `tests/test_c2c_start_lock.py` | POSIX instance lock (integration, C2C_TEST_INSTANCE_LOCK=1) |
| `tests/test_c2c_start_resume.py` | -s ses_* env propagation + no-dup (unit + live E2E) |
| `tests/test_c2c_opencode_plugin_integration.py` | Plugin delivery integration |
| `tests/test_c2c_opencode.py` | OpenCode managed session lifecycle |
