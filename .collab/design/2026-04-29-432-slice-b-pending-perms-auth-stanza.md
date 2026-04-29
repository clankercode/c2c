# #432 Slice B — pending-permissions auth-binding fixes (design)

**Source**: pending-permissions audit Finding 4 (MED). See
`.collab/research/2026-04-29-stanza-coder-pending-permissions-audit.md`.

**Status**: design only — code lands after #432 Slice A peer-PASS to
avoid same-file conflict on `ocaml/c2c_mcp.ml`.

## Two related issues

### B1 — `open_pending_reply` accepts unregistered callers

**Where**: `c2c_mcp.ml:5774-5781` (handler for the `open_pending_reply`
MCP tool).

**Symptom**: when the calling session is unregistered, the handler
resolves `requester_alias` to `""` (empty string) and writes the
entry anyway. A subsequent register of any alias whose value matches
`""` after some normalization (none today, but the fragility is real)
could collide with the M4 guard's lookup. The CLI already rejects
unregistered callers from this surface — the MCP path should mirror.

**Fix**: in the `open_pending_reply` MCP handler, after resolving the
calling session's registration, return `tool_result ~is_error:true`
with text `"open_pending_reply requires the calling session to be
registered first"` if the registration is `None` (or alias is empty).

**Test**: `test_open_pending_reply_rejects_unregistered_caller` —
calls the tool from a session_id that has no registration row in the
broker, asserts `isError: true` and that no entry was written to
`pending_permissions.json`.

**Effort**: ~12 LoC change + ~25 LoC test. Single function.

### B2 — `check_pending_reply` trusts caller-supplied `reply_from_alias`

**Where**: `c2c_mcp.ml:5806-5840` (handler for the `check_pending_reply`
MCP tool).

**Symptom**: `reply_from_alias` is read from the request `arguments`,
NOT derived from the calling session's registration. This means any
agent who knows a `perm_id` (UUID, but discoverable on broker.log)
plus any supervisor's alias can call `check_pending_reply` and get
back the requester's `session_id` — an information disclosure on
otherwise-private state.

**Fix**: in the `check_pending_reply` MCP handler, compute
`reply_from_alias` from `session_id_override` resolved against
`Broker.list_registrations` (the same pattern already used in many
peer handlers). If the calling session is unregistered, return
`isError: true`. Then verify `reply_from_alias ∈ pending.supervisors`
as today.

The `reply_from_alias` request argument can be retained as a backstop
(operator/test surface) but only if the caller also passes a
specific `--unsafe-derive-from-arg` flag that's NOT exposed via the
default MCP tool schema. Better: drop the argument from the schema
entirely and let the broker derive it.

**Schema change consideration**: dropping `reply_from_alias` from
the `check_pending_reply` schema is a breaking change for any client
calling it with the argument set. Audit all callers (likely just the
in-tree plugins) and migrate. Schema file:
`ocaml/c2c_mcp.ml` — search for `tool: "check_pending_reply"` JSON
descriptor near the handler.

**Test**: two tests:
1. `test_check_pending_reply_derives_from_calling_session` — call
   from session-A registered with alias `"a-alias"`, verify the
   handler treats `reply_from_alias = "a-alias"` regardless of any
   request arg.
2. `test_check_pending_reply_rejects_unregistered_caller` — same
   shape as B1's test.

**Effort**: ~25 LoC change + ~50 LoC tests + schema update + caller
migration. Could be ~100 LoC total depending on caller surface.

## Slicing recommendation

**Option 1 (single slice)**: B1 + B2 together, ~150 LoC including
tests and schema migration. Both touch the same auth-binding pattern
in adjacent handlers; coherent diff.

**Option 2 (split)**: B1 first (smaller, no schema migration), B2
second (after B1 lands).

Recommend Option 1 unless the schema migration surfaces unforeseen
caller surface — then split.

## Acceptance criteria

- [ ] `open_pending_reply` rejects unregistered callers with clear
  error text + `isError: true`.
- [ ] No entry is written to `pending_permissions.json` on the
  reject path.
- [ ] `check_pending_reply` derives `reply_from_alias` from the
  calling session, not from request args.
- [ ] Existing pending-permissions tests still pass (M2 + M4 paths
  unchanged in behavior for registered callers).
- [ ] Two new tests cover the rejection paths.
- [ ] Schema for `check_pending_reply` updated if `reply_from_alias`
  is dropped; CHANGELOG / runbook note for any caller migration.
- [ ] Build IN-slice-worktree rc=0; full ocaml/test runtest 254+/254+
  pass.

## Out of scope

- Findings 2 (capacity bound), 3 (TTL gaps), 5 (decision audit log)
  from the audit — separate slices C and D.
- Any new "operator-staged approval" feature — that's a new design,
  not a hardening of this one.

## Open questions for Cairn / Max

1. **Schema migration**: drop `reply_from_alias` from
   `check_pending_reply` schema entirely, or keep as compat-arg with
   warning? Breaking change vs gentle deprecation.
2. **B1 + B2 bundling**: ship together or split?
3. **Caller surface**: are there OpenCode/Codex plugins that call
   `check_pending_reply` with `reply_from_alias`? If yes, those need
   coordinated update.
