---
author: planner1
ts: 2026-04-20T21:05:00Z
severity: info
status: spec — ready for implementation by coder2-expert
---

# c2c init — Supervisor Config + TUI Checklist Spec

## Background

Max requested a `c2c init` command that:
1. Sets up a per-repo supervisor list (alias(es) to DM for permission approvals, alerts, etc.)
2. Provides a TUI checklist when called interactively with no args
3. Supports multiple supervisors (fallback or round-robin)
4. Plugin reads repo config; env var per-agent stays as override

---

## Config File: `.opencode/c2c-plugin.json` Extension

The sidecar config already exists. Extend it with a `supervisors` key:

```json
{
  "session_id": "opencode-test",
  "broker_root": "/path/to/.git/c2c/mcp",
  "supervisors": ["coordinator1", "planner1"],
  "supervisor_strategy": "first-alive"
}
```

**Fields**:
- `supervisors`: array of aliases; can be a single string for backwards compat
- `supervisor_strategy`: `"first-alive"` (default) | `"round-robin"` | `"broadcast"`
  - `first-alive`: try supervisors in order, use first one that's registered in broker
  - `round-robin`: rotate through the list per request
  - `broadcast`: DM all supervisors simultaneously

**Env var override** (per-agent, highest priority):
- `C2C_PERMISSION_SUPERVISOR` — single alias, overrides config entirely
- `C2C_SUPERVISORS` — comma-separated list, overrides config supervisors list

---

## c2c init Command

### Interactive mode (no args)

```
$ c2c init
```

Displays a TUI checklist:

```
c2c project setup
─────────────────
[✓] broker root:   .git/c2c/mcp
[✓] session ID:    (from C2C_MCP_SESSION_ID or prompts)
[ ] supervisors:   none configured
[ ] relay:         not connected

Actions:
  1. Set supervisor aliases (comma-separated): _
  2. Connect to relay (https://relay.c2c.im): [y/N]
  3. Write .opencode/c2c-plugin.json:          [y/N]
  4. Write env vars to .opencode/.env:          [y/N]
```

Output: updated `.opencode/c2c-plugin.json` with all configured values.

### Non-interactive mode (flags)

```bash
c2c init --supervisor coordinator1 --supervisor planner1 --strategy first-alive
c2c init --supervisor coordinator1  # single supervisor, updates sidecar
c2c init --relay-url https://relay.c2c.im  # configure relay endpoint
c2c init --json  # print resulting config as JSON, no writes
```

### What c2c init writes

1. `.opencode/c2c-plugin.json` — merged with existing, preserves unknown keys
2. Optionally `.opencode/.env` — env vars for the session (C2C_MCP_SESSION_ID etc.)

---

## Plugin Changes Required

In `.opencode/plugins/c2c.ts`, update supervisor resolution:

```typescript
// Priority: C2C_PERMISSION_SUPERVISOR > C2C_SUPERVISORS > sidecar.supervisors > "coordinator1"
const supervisors: string[] = (() => {
  if (process.env.C2C_PERMISSION_SUPERVISOR) return [process.env.C2C_PERMISSION_SUPERVISOR];
  if (process.env.C2C_SUPERVISORS) return process.env.C2C_SUPERVISORS.split(",").map(s => s.trim());
  if (Array.isArray(sidecar.supervisors)) return sidecar.supervisors as string[];
  if (typeof sidecar.permission_supervisor === "string") return [sidecar.permission_supervisor];
  return ["coordinator1"];
})();
const supervisorStrategy: string = sidecar.supervisor_strategy || "first-alive";
```

Add `selectSupervisor()` helper:
```typescript
async function selectSupervisor(): Promise<string> {
  if (supervisors.length === 1 || supervisorStrategy === "round-robin") {
    // round-robin: rotate index in a module-level counter
    return supervisors[roundRobinIndex++ % supervisors.length];
  }
  if (supervisorStrategy === "broadcast") return supervisors[0]; // caller handles broadcast
  // first-alive: check broker for liveness (c2c list --json, filter alive)
  // for now: just return first; liveness check is a v2 improvement
  return supervisors[0];
}
```

---

## Acceptance Criteria

1. `c2c init` with no args shows interactive checklist and writes config on confirmation
2. `c2c init --supervisor coordinator1,planner1` writes sidecar with both aliases
3. Plugin reads sidecar `supervisors` array and uses it for permission notifications
4. `C2C_PERMISSION_SUPERVISOR` still overrides for per-agent control
5. `c2c init --json` prints resulting config without writing

---

## Implementation Notes

- `c2c init` should be idempotent — re-running updates only the fields specified, leaves others untouched
- If `.opencode/c2c-plugin.json` doesn't exist, create it
- If it exists, merge (not replace)
- The TUI checklist needs minimal deps — use existing `Printf` / `read_line` pattern, no heavy TUI library

---

## Related

- `.collab/findings/2026-04-20T18-31-00Z-planner1-opencode-permission-hook-research.md` (permission hook design)
- `.opencode/plugins/c2c.ts` (current supervisor resolution)
- `.opencode/c2c-plugin.json` (sidecar config)
