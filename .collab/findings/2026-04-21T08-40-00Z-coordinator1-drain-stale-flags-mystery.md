---
author: coordinator1
ts: 2026-04-21T08:40:00Z
severity: high
fix: not-started (mystery — needs focused investigation)
---

# drainInbox runs with flags that don't exist in the plugin source

## Symptom

Fresh oc-coder1 started post-8d37cea (which removed legacy `--file-fallback
--session-id --broker-root` args from drainInbox) still errors on every
delivery cycle:

```
[2026-04-20T22:35:58.931Z] drainInbox error: Error: Usage: c2c poll-inbox
c2c: unknown option --file-fallback unknown option --session-id
     unknown option --broker-root
```

Probes to oc-coder1 stay in `.git/c2c/mcp/oc-coder1.inbox.json` indefinitely.

## What's clean

- `.opencode/plugins/c2c.ts` (mtime 08:30, post-8d37cea): runC2c at line
  228–250 passes args verbatim; drainInbox at line 313 calls
  `runC2c(["poll-inbox", "--json"])`. No reference to `--file-fallback`,
  `--session-id`, or `--broker-root` anywhere in file.
- `run-opencode-inst.d/plugins/c2c.ts`: byte-identical to project plugin.
- `~/.config/opencode/plugins/c2c.ts`: was a 9-byte stub (`// plugin`);
  deleted entirely. Doesn't export drainInbox regardless.
- `c2c` binary itself: `poll-inbox` subcommand genuinely doesn't accept
  those flags (that's the OCaml side; Python-era CLI had them).

## What's happening

Every 30s the plugin's delivery loop fires twice (doubled `tryDeliver` +
`deliverMessages` log lines at ~1ms apart), both call `drainInbox`, both
invocations fail with the legacy-flags error. Inbox never drains.
`deliverMessages` reports `spooled=0 fresh=0 total=0` because drain
returned empty array after catch.

## Hypotheses

1. **bun/opencode plugin compile cache** — bun may have transpiled a
   pre-8d37cea snapshot and is reusing it. No obvious cache at
   `~/.cache/opencode/` or `~/.bun/install/cache/`, but there's a
   `node_modules` tree under `~/.config/opencode/` that could hold a
   stale compiled plugin.
2. **Doubled plugin instances** — two tryDeliver/deliverMessages lines
   per cycle suggests two instances of drainInbox running. The 4947634
   defer-to-project mechanism should prevent this, but it only works if
   the *global* plugin is the real plugin (it was a stub until I
   deleted it; deletion may help future launches but not the already-
   loaded process).
3. **Env-injected args** — unlikely; runC2c uses `spawn(command, args, …)`
   with the args array passed directly. No shell, no env interpolation.

## Why this is hard to see

- Inbox JSON stays untouched, so from outside it looks exactly like a
  "plugin not loaded" failure.
- Normal "plugin loaded" log line DOES appear — plugin thinks it's fine.
- `tryDeliver` and `deliverMessages` both succeed until drainInbox;
  error text is buried at the end of the chain.

## Recommended next step (not me, this session is over context)

1. Nuke all opencode process trees AND `~/.config/opencode/node_modules/`
   + `~/.cache/opencode/` — then start fresh oc-coder1.
2. Before launch, `sed -i 's/drainInbox: got/drainInbox[v2]: got/'
   .opencode/plugins/c2c.ts` — if the tagged log line doesn't appear
   but old-flag error still does, the plugin running is NOT the file on
   disk → caching confirmed.
3. If bun cache is confirmed: add a build-stamp check in plugin init
   that logs the file's sha256 on load, so future stale-compile cases
   are visible instantly.

## Workaround

None. oc-coder1 is alive + registered + MCP tools function, but plugin
auto-delivery of inbound DMs is silent-dropped. Can still read inbox via
`mcp__c2c__poll_inbox` from the session, but only if the user types into
the TUI to wake the agent loop.

## Related

- `.collab/findings/2026-04-21T07-47-00Z-coordinator1-opencode-delivery-gaps.md`
  — two earlier gaps (global stub + cold-boot promptAsync).
- Commits 8d37cea (drain fix), 4947634 (global defer), ecb638b
  (supervisor liveness, already merged).
