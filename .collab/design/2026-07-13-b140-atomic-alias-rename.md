# B140 — `c2c rename <new-alias>`: deliberate atomic rename-everywhere

Status: in progress (b140-alias-rename worktree)
Ref: B135 (sticky-alias forbid — stays for implicit/unsafe paths)

## Problem

B135 forbade explicit alias rename (option-1) to kill the silent half-rename.
B140 is the sanctioned option-2: an explicit, deliberate `c2c rename` that
atomically updates every identity store so the new alias STICKS without a
session restart, with rollback on partial failure. The implicit/unsafe paths
(env-only `C2C_MCP_AUTO_REGISTER_ALIAS` drift, `register`/`init --alias` on a
live session) remain refused.

## Identity stores (audit)

| Store | Keyed by | Action on rename |
|---|---|---|
| Registry (`registrations` via broker root) | session_id row w/ `alias` field | update row in place (alias + canonical_alias) under registry lock |
| Room memberships (`rooms/<id>/members.json`) | session_id + alias | `rename_room_member_alias` per room from `my_rooms` (per-room lock) |
| Relay ed25519 identity (`<broker_root>/keys/<alias>.ed25519`) | alias filename | move old→new (refuse if target exists w/ different key) |
| Relay x25519 enc key (`$C2C_KEY_DIR or ~/.config/c2c/keys/<alias>.x25519`) | alias filename | move old→new (same rule) |
| TOFU pins (`relay_pins.json`: ed25519/x25519/min-version) | alias | move entries old→new under pins lock; refuse if new-alias pin differs |
| allowed_signers (`<broker_root>/allowed_signers`) | alias line | append entry for new alias after key move (old entry kept for historical verification) |
| Archives (`archive/<session_id>.jsonl`) | **session_id** | no move needed — history lookup resolves alias→session_id via registry. Append an `alias_renamed` marker entry for durable attribution mapping. |
| Inbox (`<session_id>.inbox.json`) | **session_id** | nothing — unaffected by rename |
| Managed instance config (`instances/<name>/config.json` `alias`) | session_id | `C2c_start.sync_instance_alias` (#159 Slice C, already exists) so restart doesn't resurrect the old alias / trip the sticky guard |
| Schedules (`.c2c/schedules/<alias>/`) | alias dir | best-effort dir move post-commit (repo-local; warning on failure) |
| Per-agent memory (`.c2c/memory/<alias>/`) | alias dir | best-effort dir move post-commit (repo-local; warning on failure) |
| Relay remote lease | alias, signed | NOT touched in-line: leases are TTL'd; next announce under new alias signs with the moved key. Old lease expires naturally. Logged. |

## Atomicity model

Perfect multi-file atomicity is impossible (N files, 3 lock domains). The
invariant delivered is **no half-rename ever sticks**: an undo stack of
completed steps is unwound in reverse on any failure, restoring the exact
prior state. Ordering:

1. **Pre-validate** (no mutation): name valid / not reserved / not
   blocklisted / session registered / target not held by an alive other
   session (casefold) / no pending permission state / no conflicting pin.
   Same-alias (exact) → no-op success. Casefold-equal, different case →
   allowed (case fix, self-rename).
2. **Key files move** (undo: move back).
3. **Pins move** under pins lock (undo: restore snapshot).
4. **Registry row update** under registry lock, with re-validation of the
   hijack/pending guards inside the lock (TOCTOU). Atomic tmp+rename write.
   (undo: write old row back).
5. **Rooms rename** per room (undo: rename back). A failure here unwinds 4→2.
6. **Post-commit, best-effort** (never trigger rollback; warnings only):
   allowed_signers entry, archive `alias_renamed` marker, `peer_renamed`
   room notices (c2c-system), broker.log `alias_renamed` event, managed
   instance-config sync, schedules dir move, memory dir move.

Lock discipline: locks are taken per-step, never nested across domains
(registry, per-room, pins are separate lock files) — no ordering inversion
with existing paths, which take them one-at-a-time too.

## Surfaces

- **Broker**: `Broker.rename_alias t ~session_id ~new_alias : (Yojson.Safe.t, string) result`
  — one implementation shared by both surfaces.
- **CLI**: `c2c rename <new-alias>` (`ocaml/cli/c2c_rename_cmd.ml`), Tier1.
  Session resolution identical to `c2c register` (env `C2C_MCP_SESSION_ID` /
  ambient). `--json`, `--broker-root`, `--cross-repo`.
- **MCP**: `rename` tool `{new_alias}` → `C2c_identity_handlers.rename`,
  same broker call. The live MCP session keeps working post-rename: inbox is
  session_id-keyed, and future implicit re-registers reuse the registry row's
  alias (the B046 reuse path), so a stale `C2C_MCP_AUTO_REGISTER_ALIAS` env
  cannot drag the name back (B135 guard refuses it explicitly).
- **B135 guard text**: `sticky_alias_error` now points at
  `c2c rename <new-alias>` as the sanctioned path.

## Tests

- Broker/MCP: happy path (registry+rooms+keys+pins all show new alias; old
  alias resolvable by nobody), no-op same alias, case-only rename, refusals
  (unregistered session, invalid/reserved/blocklisted target, alive holder,
  pin conflict) each proving zero mutation, and a forced mid-flight failure
  (read-only room dir) proving full rollback of registry+keys+pins.
- CLI: rename happy path, sticky-alias error mentions rename, unsafe paths
  still refused (existing B135 tests keep passing).
- E2E (wild): two real `c2c` processes in tmux panes on an isolated broker
  root — register peer A + B, rename A, assert B's `c2c list` shows the new
  alias and the old one is gone, rooms membership renamed.
