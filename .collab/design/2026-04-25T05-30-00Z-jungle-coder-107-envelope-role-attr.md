# #107: sender role attribute on c2c XML envelope

## Spec
Goal: Add `role="<role>"` attribute to outbound c2c XML envelope so recipients can style/filter by sender role.

## Registry story (confirmed 2026-04-25)
- **OCaml broker** writes `registry.json` in broker_root (`.git/c2c/mcp/registry.json`)
- **Python legacy** reads `<git-common-dir>/c2c_registry.yaml` (YAML, hand-rolled, read-only for OCaml)
- OCaml does NOT write YAML — it writes JSON. Python reads both formats.
- `role` field lives in the OCaml JSON registry and is set explicitly via `register` tool.

## Chain of changes

### Slice 1 — Registry field + register tool (THIS SLICE)
**Files: `c2c_mcp.ml`**

1. **`type registration`** — Add `role : string option` field
2. **`registration_to_json`** — Serialize `role` (omit if None, like `dnd`)
3. **`registration_of_json`** — Parse `role` (default None)
4. **`Broker.register`** — Add `?role` optional param, preserve across re-registration like `client_type`
5. **`register` tool definition** — Add optional `role` string property
6. **Register handler** — Extract `role` from tool arguments, pass to `Broker.register`

**Backward compat**: `role` is `None` by default. When None, field is omitted from JSON (same pattern as `dnd` when false). Existing registrations without `role` parse as None.

### Slice 2 — XML envelope emitter
**Files: `c2c_mcp.ml` (`channel_notification`), `c2c_inbox_hook.ml`**
- Add `role=<role>` to `<c2c event=... from=... alias=...>` XML tag when role is set
- When role is None: omit attribute entirely (not `role=""` or `role="null"`)
- Add role to `meta` in `notifications/claude/channel` params

### Slice 3 — Python tooling parity
**Files: `c2c_verify.py`, `c2c_cli.py`**
- `role=` in XML tags
- Python already reads OCaml's JSON registry — no registry format changes needed

## Role values
Role is set explicitly via `register` tool param. Valid values:
- `"coordinator"` — swarm coordinators
- `"reviewer"` — code/plan reviewers
- `"agent"` — general agents (default when unspecified)
- `"user"` — human operators
- `null` — unregistered / no role (attribute omitted)

No prefix-matching or auto-derivation. The field describes what the registration holds, not how it gets populated.

## Out of scope
- Enforcement (hard auth) — lives in sticker/permission system
- YAML registry writes from OCaml

## Status
Slice 1: COMPLETE (commit ready)
Slice 2: pending — XML envelope emitter
Slice 3: pending — Python tooling parity
