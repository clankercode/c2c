# Kimi-notifier silently stuck on stale `C2C_MCP_BROKER_ROOT` env

- **Filed**: 2026-04-30T23:50:10Z by coordinator1 (Cairn-Vigil)
- **Severity**: HIGH (silent message non-delivery; reproducible)
- **Class**: kimi delivery / broker-root split-brain
- **Cross-link**: #503, #518, #522 (broker-root resolver bug family); #512 (`c2c migrate-broker`)

## Symptom

Bughunter session bringing up `tyyni-test` (kimi peer). 3 DMs queued to her
inbox; pane shows `context: 0.0% (0/262.1k)` — kimi never woken; no
notification ever displayed. `lumi-test` in the same session works fine.

## Discovery

1. `~/.c2c/repos/<fp>/broker/tyyni-test.inbox.json` contains 3 messages
   (broker.log shows three `dm_enqueue` events, all `inbox_path=<canonical>`).
2. `~/.kimi/sessions/<wh>/<sid>/notifications/` — the kimi notification-store
   directory — does NOT exist for tyyni's session. (Lumi has hers.)
3. `~/.local/share/c2c/kimi-notifiers/tyyni-test.log` is **0 bytes** despite
   the daemon (PID 105835) being alive 5+ minutes.
4. `/proc/105835/environ` reveals:
   ```
   C2C_MCP_BROKER_ROOT=/home/xertrov/src/c2c/.git/c2c/mcp
   ```
   Stale **legacy** path. Inherited from the launching shell (pts/18).
5. `/proc/85651/environ` (lumi's notifier) has NO `C2C_MCP_BROKER_ROOT` set.
   She falls through to the canonical default
   (`~/.c2c/repos/<fp>/broker/`), which matches where everyone else writes.
6. Therefore `C2c_mcp.Broker.read_inbox` for tyyni polls the LEGACY directory
   — `tyyni-test.inbox.json` does not exist there → returns `[]` → `run_once`
   short-circuits at `match all_messages with | [] -> 0`, **logs nothing**,
   sleeps 2s, repeats forever.

## Root cause

`c2c start kimi -n <alias>` does not normalize / migrate / refuse stale
`C2C_MCP_BROKER_ROOT`. It propagates whatever the launching shell had into
the spawned `c2c-kimi-notif` daemon. Meanwhile the broker (and any peer
sending DMs) uses the canonical resolver to land messages at the canonical
path. Split-brain → silent non-delivery.

`#518` fix (73cfb6ee) covered **empty-string** fallthrough but not stale
**non-empty** values. `#512` (`c2c migrate-broker`) rewrites MCP-config
pins but does not touch live environment variables of the launching shell.

## Reproduction

```sh
export C2C_MCP_BROKER_ROOT=/some/legacy/path  # any non-canonical value
c2c start kimi -n test-stale-env
# DM the alias from another peer; observe:
#   - inbox file lands at canonical
#   - notifier log stays 0 bytes
#   - kimi pane never wakes
```

## Severity rationale

- Silent failure: no warning to operator, no log line, no error.
- Hard to diagnose without `/proc/<pid>/environ` archaeology.
- Bites whenever a shell has a stale legacy `C2C_MCP_BROKER_ROOT` —
  which is common right after `migrate-broker` runs (the MCP configs
  rewrite, but the operator's existing tmux panes / shells keep the
  old export).
- Affects new kimi peer bring-up, which is the dogfood path Max just
  asked us to exercise.

## Mitigations (proposed)

1. **`c2c start <client>` warns or refuses on stale broker_root.** If
   the env var is set to a non-canonical path (i.e. doesn't match
   `c2c-resolver` output), either:
   - Warn loudly + unset before forking child daemons, OR
   - Refuse to start with `c2c migrate-broker` hint.
2. **`c2c-kimi-notif` daemon logs a startup banner** with `broker_root`,
   `session_id`, `alias`, and the resolved inbox path. Empty 0-byte
   log files for live daemons should be impossible.
3. **`c2c-kimi-notif` polls broker.log liveness check**: on each tick,
   if `broker_root` doesn't exist or is empty, log a warning every
   N seconds.
4. Cross-reference with `#512` follow-up: extend
   `c2c migrate-broker --suggest-shell-export` to print
   `unset C2C_MCP_BROKER_ROOT` for stale shells.

## Immediate workaround

```sh
# In the tmux pane that has the stale env:
unset C2C_MCP_BROKER_ROOT
c2c stop tyyni-test
c2c start kimi -n tyyni-test
```

## Other observations from this dogfood pass

- **Interactive role-prompt friction**: `c2c start kimi -n <new-alias>` blocks
  on a TUI role-creation prompt. Skippable, but not obvious it's
  skippable, and slows automation.
- **Kimi MCP introspection gap** (lumi report): an agent can't see her
  own session_id / broker_root via MCP tools. Useful for self-diagnosis
  in cases like this one.
- **`authlib.jose` deprecation warning** on kimi launch — third-party,
  not c2c-owned.

— Cairn-Vigil
