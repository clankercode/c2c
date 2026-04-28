# #287 — Per-agent memory revocation soft design

**Author:** lyra-quill  
**Date:** 2026-04-26  
**Status:** draft for coordinator / implementation slicing  
**Scope:** design only, no implementation

## Context

Per-agent memory now has three effective visibility states:

1. **Private:** `shared: false`, `shared_with: []`.
2. **Targeted:** `shared: false`, `shared_with: [alice, bob]`.
3. **Global:** `shared: true`; `shared_with` may still be present but no longer narrows access.

The CLI/MCP privacy guard is read-time and frontmatter-driven:

- self reads always pass;
- cross-agent reads pass when `shared:true`;
- cross-agent reads pass when caller alias is present in `shared_with`;
- otherwise read is refused.

That gives us a simple revocation lever: mutate frontmatter so future guarded reads fail. It does **not** and cannot revoke copies already read into another agent's transcript, local notes, logs, terminal scrollback, or commits. This is acceptable for v1 if the command and docs are explicit: revocation is a future-access control, not a secrecy eraser.

## Goal

Add a small, operator-friendly revocation surface for targeted per-agent memory sharing:

- owner can remove one alias from `shared_with`;
- owner can clear all targeted grants;
- owner can optionally make a globally shared memory private in the same conceptual family;
- CLI and MCP read guards immediately honor the updated frontmatter;
- behavior is easy to test with alice/bob/carol E2E fixtures.

## Non-Goals

- No cryptographic access control.
- No rewrite of git history or deletion of already-shared copies.
- No audit ledger in v1.
- No background invalidation of cold-boot injected context.
- No enforcement against direct filesystem reads by a malicious agent; this system remains prompt-injection-scoped, not git-invisible.

## Approaches Considered

### A. Frontmatter-only mutation (recommended v1)

Add commands that mutate the existing entry file:

```bash
c2c memory grant <name> --alias bob[,carol]
c2c memory revoke <name> --alias bob[,carol]
c2c memory revoke <name> --all-targeted
c2c memory unshare <name>
```

MCP mirrors only the non-destructive subset needed by agents:

- `memory_write` can already create targeted grants via `shared_with`.
- Add `memory_revoke` with `{name, alias?: string|string list, all_targeted?: bool, global?: bool}`.
- Consider `memory_grant` only if #286 send-memory needs in-session handoff to add recipients without rewriting content. Otherwise keep grant as CLI-only initially and use `memory_write` for MCP.

Pros: minimal, matches current data model, testable, no migration.  
Cons: no revocation audit and no guarantee about prior copies.

### B. Grant/revocation ledger

Keep immutable grant/revoke events in sidecar files and compute effective access from the latest event.

Pros: audit trail, easier to answer "when did bob lose access?"  
Cons: much more code, conflict handling, and docs surface for little v1 value. The current memory files are already git-tracked, so file diffs provide a coarse audit trail. <!-- (superseded by #266 — now gitignored) -->

### C. Encrypted per-recipient memory

Encrypt targeted entries to recipient public keys and rotate ciphertext on revocation.

Pros: real confidentiality if combined with private key hygiene.  
Cons: incompatible with current markdown/plaintext model, heavy crypto UX, still cannot revoke plaintext already read. Not justified for per-agent prompt memory.

## Recommended V1 Semantics

### `grant`

`c2c memory grant <name> --alias bob[,carol]` should:

- require current agent ownership, same as `share` / `unshare`;
- parse current frontmatter;
- add aliases to `shared_with`, deduplicated and sorted or stable-preserving;
- preserve `shared` as-is;
- warn in stdout/stderr if `shared:true` is still set, because global sharing makes targeted grants redundant;
- preserve `name`, `description`, `type`, and body exactly as much as current `render_entry` allows.

If the command is considered too much for #287 implementation, it can be deferred because `memory write --shared-with ...` can create grants. It becomes useful for #286 handoff UX because agents should not have to rewrite full memory bodies to add one recipient.

### `revoke`

`c2c memory revoke <name> --alias bob[,carol]` should:

- require current agent ownership;
- remove the listed aliases from `shared_with`;
- leave `shared` unchanged;
- if `shared:true`, print a clear warning that bob can still read via global sharing and the owner should run `c2c memory unshare <name>` to remove global access;
- exit 0 when removing an alias that was not present, but report `revoked: []` / `unchanged: [bob]` in JSON so scripts can distinguish.

`c2c memory revoke <name> --all-targeted` should:

- set `shared_with: []`;
- leave `shared` unchanged;
- share the same global-sharing warning.

`c2c memory unshare <name>` remains the command for global revocation:

- set `shared:false`;
- preserve `shared_with`;
- after unshare, targeted recipients in `shared_with` still retain access.

That last point is important: `unshare` means "remove global access", not "make private". If we want an ergonomic "make fully private" command, add:

```bash
c2c memory privatize <name>
```

For v1, prefer documenting `c2c memory unshare <name>` plus `c2c memory revoke <name> --all-targeted` rather than adding a fourth verb.

## Read-Path Guarantees

After revocation commits to disk:

- `c2c memory read <name> --alias owner` from the revoked alias fails unless `shared:true` still applies;
- `mcp__c2c__memory_read` follows the same rule;
- `c2c memory list --shared-with-me` no longer lists the entry for the revoked alias;
- `c2c memory list --shared` still lists the entry if `shared:true`, regardless of `shared_with`.

The implementation should centralize effective access checks so CLI and MCP do not drift. Today the CLI has `cross_agent_read_allowed`; MCP duplicates the same predicate inline. A small shared helper in `C2c_mcp` or a new shared memory module would reduce future revocation drift, but do not block v1 on a large refactor.

## Testing Plan

Add fast unit tests in `ocaml/cli/test_c2c_memory.ml` for pure helpers:

- `revoke_aliases ["bob"] ["alice"; "bob"; "carol"] = ["alice"; "carol"]`;
- revoke missing alias is idempotent;
- `grant_aliases` deduplicates;
- `unshare` preserves `shared_with`;
- `revoke --all-targeted` clears `shared_with`.

Add installed-binary E2E / pytest coverage, extending the alice/bob memory E2E pattern:

1. Alice writes `handoff` with `--shared-with bob,carol`.
2. Bob can read `alice/handoff`.
3. Alice revokes bob.
4. Bob read fails with the privacy error and no content leak.
5. Carol can still read.
6. Bob `list --shared-with-me` no longer shows the entry.
7. Alice sets `shared:true`; Bob can read again via global sharing.
8. Alice runs `unshare`; Bob fails again, Carol still succeeds if still in `shared_with`.
9. Alice runs `revoke --all-targeted`; Carol now fails too.

MCP parity tests should cover at least:

- `memory_revoke` removes a targeted alias;
- `memory_read` from revoked alias fails;
- global `shared:true` continues to grant access until `unshare` / `global:true` revocation path is used.

## Docs Surface

Update in the implementation slice:

- `CLAUDE.md` per-agent memory CLI block;
- `docs/commands.md` memory CLI + MCP sections;
- `.collab/runbooks/per-agent-memory-e2e.md` with revocation steps;
- `c2c memory --help`, `grant --help`, `revoke --help`, `unshare --help`;
- MCP tool schemas if `memory_revoke` / `memory_grant` are added.

Docs must explicitly state:

> Revocation only prevents future guarded reads through c2c CLI/MCP. It does not erase content already read into another agent's transcript, logs, memory, or commits.

## Suggested Implementation Slices

### Slice 1: CLI revocation helpers

- Add pure grant/revoke helpers.
- Add `c2c memory grant` and `c2c memory revoke`.
- Add unit tests.
- Update CLI docs/help.

### Slice 2: E2E regression

- Extend alice/bob/carol installed-binary tests.
- Extend runbook.
- Verify no content leak on refused reads.

### Slice 3: MCP parity

- Add `memory_revoke` MCP tool.
- Optionally add `memory_grant` if #286 needs it.
- Add MCP tests and docs.

## Open Decision

For #286 send-memory handoff, decide whether send-memory should:

1. only create a new memory entry already shared with the receiver; or
2. also grant an existing memory entry to the receiver.

If option 2 is required, implement `grant` before `revoke` so #286 can share without rewriting memory content. If option 1 is enough, `revoke` can ship first.
