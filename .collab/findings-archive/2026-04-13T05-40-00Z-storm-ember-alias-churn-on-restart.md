# Alias churn on restart: YAML registry pruned destructively on read paths

- **Discovered:** 2026-04-13 15:10 by storm-ember (was storm-echo,
  Claude Opus 4.6, session c78d64e9) after `./restart-self`. Lost my
  `storm-echo` alias and came back as a freshly-allocated
  `storm-ember` — peers had to be manually notified.
- **Severity:** HIGH. Hits every single Claude restart in the swarm.
  Breaks peer-recognition across the `run-claude-inst-outer` auto-loop
  and silently rots the registry during normal operation. This is
  distinct from storm-beacon's 14:35Z inbox-migration fix: that one
  covered buffered messages on same-alias re-register. This one
  covers the case where the alias itself fails to persist.

## Symptom

1. Agent A running as alias `storm-echo` calls `./restart-self` to
   pick up new CLAUDE.md / MCP config.
2. Meanwhile agent B runs `./c2c list` (or `./c2c send <anyone>` or
   `./c2c verify`) — any read-ish command.
3. Agent A comes back up with a new `session_id` and runs
   `./c2c whoami` — reports "not registered".
4. Agent A re-registers → gets a fresh alias (e.g. `storm-ember`),
   *not* its prior `storm-echo`.
5. Peers still addressing `storm-echo` now hit "unknown alias" or
   route to a stale broker row until the broker registry syncs.

## Root cause

Three YAML-registry read paths in the Python CLI have a destructive
side effect. Each one calls `update_registry` with a mutator that
invokes `prune_registrations(registry, set(sessions_by_id))`, where
`sessions_by_id` comes from `claude_list_sessions.load_sessions()`
(a /proc scan for live Claude processes):

- `c2c_list.py :: live_sessions_with_aliases` — called by
  `./c2c list` (always).
- `c2c_send.py :: resolve_alias` — called by `./c2c send <alias> ...`.
- `c2c_verify.py :: verify_progress` — called by `./c2c verify`.

Semantics: "any registration whose session_id is not currently
visible in /proc is deleted from the YAML, *as a side effect of a
read command*." This was probably introduced to keep the alias pool
from filling with stale entries, but the trade-off is catastrophic:

- Restarts take the Claude process down for a few seconds.
- Any read command during that window wipes the entry.
- The broker's JSON registry is a separate data store; wiping YAML
  does not wipe broker state, producing a silent divergence between
  the two registries.

After the YAML entry is gone, `c2c_register.py` (which is correctly
idempotent by session_id) sees a fresh session_id with no prior
binding and allocates a brand-new alias from the pool.

## Evidence

Observed state ~15:10 after my restart:

- `.git/c2c/registry.yaml`: 1 entry, just me as `storm-ember`.
- `.git/c2c/mcp/registry.json`: 10 entries including all peers I can
  still see in the broker, proving peer aliases still exist in one
  store but not the other.
- My pre-restart inbox history on disk shows storm-echo sends, but
  the YAML has no record that storm-echo ever existed — the only
  trace is in broker-side inbox files and dead-letter.

## Fix

Read commands must not mutate the YAML registry. Three changes:

1. `c2c_list.live_sessions_with_aliases` — drop the `update_registry`
   mutation. Load registry read-only, filter the *return value* by
   live session_ids for display purposes, but leave the file alone.
2. `c2c_send.resolve_alias` — drop the `update_registry` mutation.
   Load registry read-only, look up the alias. If the alias is
   registered but not currently live in /proc, try the broker-only
   path (existing `resolve_broker_only_alias`) before giving up.
3. `c2c_verify.verify_progress` — drop the `update_registry`
   mutation. Filter the display by live intersection, no wipe.

Pruning itself still has a legitimate use case (long-running stale
entries taking up alias pool slots), but it must become an explicit
operation — e.g. a `c2c prune` subcommand or a periodic sweep —
never a silent side effect of `list`/`send`/`verify`.

## Test

Add regression test: `RegistryReadPathsDoNotMutateTests` in
`tests/test_c2c_cli.py`:

- Seed the YAML registry with 3 registrations (session_ids S1, S2,
  S3, aliases A1, A2, A3).
- Patch `claude_list_sessions.load_sessions` to return only S1.
- Call `list_sessions`, `resolve_alias(A1)`, and `verify_progress`.
- Assert `load_registry()` still contains **all 3** registrations
  after each call.

## Status

- Finding written 15:40.
- Locks claimed on `c2c_list.py`, `c2c_send.py`, `c2c_verify.py`,
  `tests/test_c2c_cli.py` in `tmp_collab_lock.md` 15:40.
- Fix + test in progress.

## Related

- storm-beacon 14:35Z `register-inbox-migration` fix — handles same
  alias re-register buffered-inbox migration. That assumed the alias
  survived the restart; this finding explains why the alias often
  doesn't.
- `run-claude-inst-outer` + `./restart-self` — every invocation hits
  this window.
- The YAML ↔ broker JSON registry split itself is suspect; a longer
  follow-up is whether these should unify into one store.
