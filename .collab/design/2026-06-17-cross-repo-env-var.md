# `C2C_CROSS_REPO` env var — automatic cross-repo rendezvous via the sessions broker

**Goal**: make `c2c` Just Work across repos on a single local machine, with a single env var.

**Date**: 2026-06-17. Pre-implementation design.

## Problem

Each repo's broker is fingerprinted from `git remote.origin.url` (12-hex sha256). Two pi sessions in two repos land in two different brokers and can't see each other in `c2c list` / `c2c send`.

Existing workarounds:
- **Option A** (shared `C2C_MCP_BROKER_ROOT`) — alias collision hell, all registrations merge
- **Option C** (local relay + connector) — connector is one-way out, doesn't mirror back; relay is for cross-machine, not cross-broker-on-host
- **`c2c list --global`** — read-only, doesn't help with sends

The c2c CLI **already has a second broker** — the "sessions broker" at `~/.c2c/sessions/broker` (or `$XDG_STATE_HOME/sessions/broker`). It's currently used for `enqueue_session_message` (when a target is a session_id, not an alias) so PostToolUse hooks and kimi notifier can deliver to sessions that haven't initialized c2c.

The sessions broker is **non-fingerprinted, fixed across repos on the host**. It's the natural cross-repo rendezvous.

## Proposal

**Add `C2C_CROSS_REPO` env var** (default `0` / off; opt-in). When set to `1`:

1. **`c2c register`** registers in both the per-repo broker AND the sessions broker
2. **`c2c list`** returns the union of both brokers (dedup by session_id, with a `[sessions]` tag showing which broker each entry came from)
3. **`c2c send <alias>`** tries per-repo broker first, falls back to sessions broker
4. **`c2c poll-inbox`** returns messages from both brokers
5. **`c2c list --global`** keeps its current behavior (scan all `~/.c2c/repos/*`); add `--include-sessions` flag for explicit opt-in to the cross-repo view

The pi-c2c extension sets `C2C_CCROSS_REPO=1` on every `c2c` invocation by default, so pi users get cross-repo coordination automatically without changing the per-repo broker's behavior for other clients.

## Alias collision handling

The sessions broker uses the same alias pool as the per-repo broker (16,384 ordered pairs, case-insensitive). When two sessions in two different repos both try to register the same alias, the second gets `alias_hijack_conflict` (existing protection).

In practice this is rare because:
- pi-c2c's aliases are `pi-<8hex>` derived from session_id, giving ~1-in-16M collision per session
- codex/kimi aliases have their own hash prefixes
- The session_id namespace is unique per process

If a collision does happen, the extension falls back to the per-repo broker only and surfaces a `cross_repo_alias_collision` warning in the bar state (yellow dot with reason).

## Implementation

**Files**:
- `ocaml/c2c_repo_fp.ml` — add `cross_repo_enabled ()` helper
- `ocaml/c2c_mcp.ml` — extend `Broker` to support dual-broker register/list/send/poll
- `ocaml/cli/c2c.ml` — wire up the env var in `register`, `list`, `send`, `poll-inbox`
- `pi-c2c/src/index.ts` — set `C2C_CROSS_REPO=1` in the `ExecFn` wrapper
- `pi-c2c/src/status.ts` — surface `cross_repo_alias_collision` as a reason

**Tests**:
- `ocaml/test/test_cross_repo.ml` — new test file
  - Register in repo A and repo B with the same alias
  - Verify both succeed (different sessions)
  - Send a DM from repo A's session to repo B's session via the sessions broker
  - Verify the message arrives in repo B's inbox
  - List from repo A shows both local and cross-repo sessions

## Rollout

- v0.8.x: ship the c2c-side change behind `C2C_CROSS_REPO=1` (default off)
- pi-c2c v0.2.0: enable by default in the extension
- Coordinate with coord1 before merging; this changes c2c semantics

## Relation to Slice D

Slice D (broker-to-broker forwarder) is the long-term answer. `C2C_CROSS_REPO` is a **pragmatic short-term** that uses the existing sessions broker. Slice D would replace it with proper broker-to-broker sync (no alias collision risk because each broker keeps its own namespace).

Until Slice D lands, this is the smoothest path.
