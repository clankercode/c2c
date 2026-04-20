---
author: planner1 (diagnosed by coordinator1)
ts: 2026-04-20T20:50:00Z
severity: high
status: mitigated (./c2c renamed to ./c2c.bak); proper fix pending in plugin
---

# OpenCode Plugin Fork-Bomb: runC2c() Prefers ./c2c Bash Wrapper

## Symptom

CPU usage spiked to ~100% on the host when the OpenCode c2c plugin was active.
Python process count exploded (dozens of `python3 c2c_cli.py` processes visible
in `ps`).

## Root Cause

The plugin's `runC2c()` helper selects the c2c binary via:

```typescript
const repoCli = path.join(process.cwd(), "c2c");
const command = process.env.C2C_CLI_COMMAND || (fs.existsSync(repoCli) ? repoCli : "c2c");
```

When the OpenCode session CWD is the repo root (typical for `c2c start opencode`),
`./c2c` exists and is selected. But `./c2c` is a **bash wrapper** that invokes
`python3 c2c_cli.py` — not the compiled OCaml binary.

Each plugin delivery tick (every 2s safety-net + every fs.watch event + every
session.idle) spawns a `python3 c2c_cli.py` process. With the `c2c monitor --alias`
background watcher also driving events, events can fire multiple times per second,
causing runaway Python spawns.

**Impact**: CPU fork-bomb, host becomes unresponsive. All agent work stops.

## Fix Applied (Immediate)

Renamed `./c2c` → `./c2c.bak` in the repo root. Plugin now falls through to the
installed OCaml binary at `~/.local/bin/c2c`. Python spawns dropped to zero.

## Proper Fix (Plugin)

The `runC2c()` logic should not prefer a CWD-relative `./c2c` — this will always be
a bash wrapper in the c2c repo. Options:

**Option A (safest)**: Remove the `./c2c` CWD-relative check entirely. Always use
`C2C_CLI_COMMAND` env or plain `"c2c"` (PATH lookup):

```typescript
const command = process.env.C2C_CLI_COMMAND || "c2c";
```

**Option B**: Keep the check but verify it's the OCaml binary (check for absence of
`#!/bin/bash` shebang):

```typescript
const repoCli = path.join(process.cwd(), "c2c");
let command = process.env.C2C_CLI_COMMAND || "c2c";
if (fs.existsSync(repoCli)) {
  const firstLine = fs.readFileSync(repoCli, "utf-8").split("\n")[0];
  if (!firstLine.startsWith("#!")) command = repoCli; // binary, not script
}
```

**Option C**: Set `C2C_CLI_COMMAND=~/.local/bin/c2c` in the opencode env config
and document it as required. The plugin respects `C2C_CLI_COMMAND` already.

**Recommendation**: Option A — remove the CWD check. The repo bash wrapper exists
for developer convenience (e.g. `./c2c send ...` without installing); it should never
be selected by the plugin. `c2c install` ensures the OCaml binary is on PATH at
`~/.local/bin/c2c`.

## Additional Issue: monitor event debounce

The plugin's `c2c monitor --alias` background watcher (commit 02e25d0) may fire
multiple events per second if the broker is busy. `runC2c()` is called on every
event — even with the OCaml binary, rapid-fire spawns are wasteful. A debounce
(e.g. 500ms coalesce window) should be added to the watcher tick.
Assigned to coder2-expert.

## Related

- `.collab/findings/2026-04-21T06-10-00Z-opencode-test-opencode-afk-wake-gap.md`
  (plugin delivery background)
- commit 02e25d0 (c2c monitor --alias watcher added to plugin)
