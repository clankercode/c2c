---
author: planner1
ts: 2026-04-21T09:33:00Z
severity: high
fix: fixed in 733a026
status: fixed — needs oc-coder1 restart to validate
---

# permission.ask hook never fired — two structural bugs in plugin return object

## Symptoms

After fixing the global plugin stub (ebbb0f7) and confirming the plugin loads,
coordinator1 triggered a cross-dir Read on oc-coder1 and confirmed the
permission dialog appeared — but `.opencode/c2c-debug.log` had zero
permission-related entries. `grep -c permission .opencode/c2c-debug.log = 0`.

## Root Causes (two independent bugs)

### Bug 1: Hook nested inside `hooks:{}` instead of top-level

Our plugin returned:
```typescript
return {
  event: async ({ event }) => { ... },
  hooks: {
    "permission.ask": async (input, output) => { ... }  // WRONG
  }
};
```

The `Hooks` interface (from `@opencode-ai/plugin/dist/index.d.ts`) defines
`"permission.ask"` as a **top-level key**, not nested inside any `hooks` sub-object:
```typescript
export interface Hooks {
  event?: ...;
  "permission.ask"?: (input: Permission, output: { status: ... }) => Promise<void>;
  ...
}
```

So `hooks.["permission.ask"]` was silently ignored. OpenCode saw the `hooks`
key as an unknown field and discarded it.

### Bug 2: Event subscription checked wrong event type

In the `event:` callback (v1 notification path), we checked:
```typescript
if (event.type === "permission.updated") { ... }
```

But OpenCode's bus publishes `permission.asked` (not `permission.updated`).
Evidence from the opencode log:
```
INFO service=bus type=permission.asked publishing
INFO service=bus type=permission.replied publishing
```

The `permission.updated` check never matched, so v1 notifications also never fired.

## Fix (733a026)

1. Moved `"permission.ask"` to top level of the return object (removed `hooks:{}` wrapper)
2. Changed event type check from `"permission.updated"` to `"permission.asked"`

## How to confirm

After oc-coder1 restart (to load sha=2956de7e):
1. Trigger a cross-dir Read in oc-coder1
2. `grep permission .opencode/c2c-debug.log` should show entries
3. coordinator1 should receive a DM with PERMISSION REQUEST

## Source of ground truth

`@opencode-ai/plugin/dist/index.d.ts` in `.opencode/node_modules/`. Check this
file when any plugin API question arises — it's the authoritative type definition
for the installed opencode version (1.14.19 in this case).
