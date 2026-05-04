# `c2c migrate-broker` silent data loss — HIGH severity

**Author:** stanza-coder
**Date:** 2026-04-28 14:50 AEST (UTC 04:50)
**Severity:** HIGH (data loss, no warning, documented user command)
**Status:** CLOSED (2026-05-04) — `c2c_migrate.ml` completely rewritten (#360 hotfix) with walk-all-classify model, default-COPY policy, dry-run, two-phase commit (copy→verify→remove), and fail-loud on Unknown entries. Every item from the original copy-set gap (keys/, broker.log, room_history.d/, top-level *.inbox.json, allowed_signers, .monitor-locks/, pending-orphan-replay.*) is now covered by the default-COPY policy. Process-local files (.pid, .lock) are explicitly denied. See `ocaml/cli/c2c_migrate.ml`.
**Discovered during:** #352 investigation
  (`.collab/research/2026-04-28T04-44-00Z-stanza-coder-352-doctor-broker-root-investigation.md`)

## TL;DR

`c2c migrate-broker` is documented as the canonical way to move from
the legacy `.git/c2c/mcp/` broker to `$HOME/.c2c/repos/<fp>/broker/`.
But its hardcoded copy-set at `ocaml/cli/c2c.ml:1132-1139` is
incomplete. Multiple real legacy artifacts are NOT copied:

- `keys/` — relay-cert / peer keys
- `allowed_signers` — peer-pass signature trust file
- `broker.log` — RPC + subsystem audit log (the file every diagnostic
  reads)
- `room_history.d/` — room message archives
- top-level `*.inbox.json` and `*.inbox.lock` — **on this host the
  inboxes are stored top-level, NOT under `inbox.json.d/`** (which the
  migrator does copy)
- `.monitor-locks/`
- `pending-orphan-replay.*`

If an agent runs `c2c migrate-broker` today, the new broker dir will be
missing all of the above. The legacy dir gets removed (verify in
`migrate-broker --help` for the exact behavior — but the command is
intended to be one-way), so the omitted artifacts are lost.

## Evidence

On this host:

```
LEGACY=/home/xertrov/src/c2c/.git/c2c/mcp
$ ls "$LEGACY" | wc -l
107

CANONICAL=$HOME/.c2c/repos/8fef2c369975/broker  # SHA-fp truncated
$ ls "$CANONICAL" | wc -l
3
```

Canonical exists but is a stub — only ever populated by a probe; no
real migration has run. 107 entries in legacy include the artifact
classes above.

`migrate-broker` copy-set (verbatim from investigation):

```
ocaml/cli/c2c.ml:1132-1139
```

(read it directly — has only ~7 specific paths whitelisted, omits the
above categories).

## Why this is HIGH severity

1. **Documented user command**: CLAUDE.md tells operators to run it.
2. **No dry-run**: there's no `--dry-run` flag listing what will move
   and what will not.
3. **No warning on legacy presence**: the migrator silently picks up
   only what it knows about.
4. **Silent loss**: `broker.log` and `keys/` are load-bearing for
   diagnostics + peer-pass infrastructure. Their loss won't surface
   immediately — only the next time someone tries to verify a signed
   artifact or read recent broker traces.
5. **Cross-cutting**: this is the upstream blocker on #352 (doctor
   migration prompt). #352 would direct operators to a destructive
   command.

## Why no one's hit it yet

Best guess: nobody has actually run `c2c migrate-broker` on this
swarm. The legacy dir on this host has been live since ~2026-04-13;
the canonical dir is just a probe. Stale pinning via:

- `~/.codex/config.toml:278` `C2C_MCP_BROKER_ROOT=.git/c2c/mcp`
  (written by pre-#294 `c2c install codex`)
- `c2c start` snapshots `broker_root` into
  `~/.local/share/c2c/instances/<alias>/config.json` and re-injects
  on resume (`c2c_start.ml:2100`, loaded at `:1825/:4403`)

Both keep agents pointed at legacy without anyone noticing. Once
someone DOES try to migrate, the loss will be silent and irreversible
(or recoverable only by hand-copying from a git ref-log if the
legacy dir is in `.git/`, which it is — small saving grace, but
broker.log isn't tracked, neither are inboxes).

## Suggested fix slice (priority order)

1. **`c2c migrate-broker --dry-run`** — list every file/dir found in
   the legacy root, mark each as "will copy" (in the whitelist) vs
   "WILL NOT copy" (not in whitelist) vs "will skip (already at
   canonical)". Operator can audit before invoking.
2. **Expand the copy-set** to a `cp -a` shape — copy the entire legacy
   dir tree into canonical, with explicit deny-list for anything
   that's intentionally process-local (PID files, lockfiles whose
   contents won't survive a move).
3. **Fail loud on unknown** — if the migrator encounters an artifact
   it doesn't know how to classify, it should ABORT with a clear
   error (not silently skip).
4. **Two-phase**: copy + verify (compare file lists/sizes), THEN
   remove legacy. Don't delete on failure.

## Sequencing

This **must ship before**:

- #352 (doctor migration-prompt) — would direct operators to a
  destructive command.
- Any swarm-wide migration push — coordinator would be telling
  agents to run a buggy command.

This **should ship after**:

- Or in parallel with: ensure all 6 install paths
  (`c2c install <client>`) write the canonical broker root, not
  legacy. (`~/.codex/config.toml:278` is one example of stale install
  output.) Otherwise a fresh install will re-pin legacy and migration
  will need to re-run.

## Open question

Should `migrate-broker` be removed from the documented surface
entirely until the fix lands? Currently CLAUDE.md mentions it as the
escape hatch. If we keep the doc but the command is broken,
operators may try it. If we remove the doc reference, swarm has no
documented migration path.

Recommend: short-term, add a warning to the `--help` text:
`WARNING: this command does not currently copy keys/, broker.log,
or top-level inbox files. Use --dry-run to audit before invoking.
See finding 2026-04-28T04-50-00Z for status.` Until the fix lands.

## Notes

- File line-references checked against HEAD `9344160d` + worktree
  contents.
- Co-discovered during #352 investigation; full investigation report
  is at the path in the heading.
- DM'd coord1 with urgent flag.

— stanza-coder
