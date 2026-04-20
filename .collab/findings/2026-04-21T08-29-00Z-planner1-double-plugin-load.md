---
author: planner1
ts: 2026-04-21T08:29:00Z
severity: medium
status: documented — needs fix
---

# Double Plugin Load: global + project c2c.ts both fire

## Symptom

OpenCode loads the c2c plugin TWICE per session:
```
service=plugin path=file:///home/xertrov/.config/opencode/plugins/c2c.ts loading plugin
service=plugin path=file:///home/xertrov/src/c2c/.opencode/plugins/c2c.ts loading plugin
```

Both instances run concurrently. Both spawn `c2c monitor` subprocesses.
Both react to `📬` events. Both call `drainInbox()` — whichever runs
first gets the messages; the second gets `[]`.

## Impact

- Double monitor processes per session (resource waste)
- Race condition on inbox drain: two processes compete for the message
- Debug log entries appear in pairs (harmless but confusing)
- If one instance's `promptAsync` delivers, the second attempt delivers nothing (benign)

## Root Cause

Both `~/.config/opencode/plugins/c2c.ts` (global) and
`.opencode/plugins/c2c.ts` (project-level) exist. OpenCode loads
both. Our `setup_opencode` function copies the plugin to both locations
so the global one is available without the project directory, but the
project one is also always loaded when running in the c2c project dir.

## Fix Options

**Option A**: Dedup in the plugin — check a shared flag file at startup:
```typescript
const lockPath = path.join(process.cwd(), ".opencode", "c2c-plugin.lock");
if (fs.existsSync(lockPath)) { /* already running */ return {}; }
fs.writeFileSync(lockPath, process.pid.toString());
// cleanup on exit...
```
Problem: if both start simultaneously, race condition.

**Option B**: Remove global plugin, only use project-level:
Write a stub to `~/.config/opencode/plugins/c2c.ts` that loads the
project plugin dynamically. Stub detects project directory and defers.

**Option C**: Global plugin that checks for project override:
```typescript
// In global plugin: if project-level exists, exit early
const projectPlugin = path.join(process.cwd(), ".opencode", "plugins", "c2c.ts");
if (fs.existsSync(projectPlugin)) {
  // Project-level will handle delivery
  return {};
}
```
Simplest fix.

**Option D**: Use a `pid` file + `C2C_PLUGIN_INSTANCE_ID` env:
OpenCode could set a per-plugin env var to distinguish instances.
Not available with current OpenCode API.

## Recommended Fix: Option C

Global plugin returns early if project-level exists. Clean, no race condition,
works with current API.

## Related

- `.opencode/plugins/c2c.ts` — project plugin  
- `~/.config/opencode/plugins/c2c.ts` — global plugin
- `setup_opencode` in `ocaml/cli/c2c.ml` — copies to both locations
