# Role-Specific Rooms — Implementation Plan

**Date:** 2026-04-24
**Author:** jungle-coder
**Status:** Ready for implementation

## Background

Two design sketches exist:
- `.collab/design/2026-04-23-role-specific-rooms-sketch.md` (galaxy-coder) — Option C recommended
- `.collab/design/ephemeral-one-shot-agents-review.md` — role-specific rooms section

## Decision

**Adopt Option C (galaxy-coder's recommendation):**

- Opt-in via `C2C_AUTO_JOIN_ROLE_ROOM=1` env var (written by `c2c install <client>`)
- Derive room from `role_class`: `role_class: reviewer` → room `role-reviewer`
- Prefix `role-` avoids collisions with other room naming conventions
- No new frontmatter fields, no auto-room-creation
- Backward compatible — without env var, behavior unchanged

Rationale: avoids surprise auto-join; matches how `swarm-lounge` was introduced. `role-` prefix ensures uniqueness.

## Implementation

### 1. `ocaml/c2c_role.ml` — Add `role_class_to_room` helper

```ocaml
let role_class_to_room (role_class : string) : string option =
  match String.trim role_class with
  | "" -> None
  | rc -> Some (rc ^ "s")
```

`role_class` is already parsed into `t.role_class : string option` in the `t` record.

### 2. `ocaml/c2c_start.ml` — `build_env` modification

In `build_env`, after building the base `additions` list:
```ocaml
(* If C2C_AUTO_JOIN_ROLE_ROOM=1 and role_class is set, derive role room *)
let additions =
  match Sys.getenv_opt "C2C_AUTO_JOIN_ROLE_ROOM",
        role_class with
  | Some "1", Some rc ->
      let role_room = rc ^ "s" in
      let existing = List.assoc "C2C_MCP_AUTO_JOIN_ROOMS" additions |> snd in
      let new_rooms = existing ^ "," ^ role_room in
      ("C2C_MCP_AUTO_JOIN_ROOMS", new_rooms) :: additions
  | _ -> additions
```

Wait — `additions` is built before this point. Better: after `additions` is built, check the env and role, then if enabled, update the `C2C_MCP_AUTO_JOIN_ROOMS` entry.

Actually, simpler: pass `role_class_opt` to `build_env` and let it handle the derivation internally.

### 3. `ocaml/cli/c2c.ml` — `setup_codex` (and similar installers)

In `setup_codex`, `setup_claude`, etc., add:
```ocaml
Buffer.add_string buf "C2C_AUTO_JOIN_ROLE_ROOM = \"1\"\n";
```

This writes the env var to the client's MCP config.

### 4. Tests

In `ocaml/test/test_c2c_role.ml`:
- Add test: `role_class_to_room "reviewer" = Some "reviewers"`
- Add test: `role_class_to_room "" = None`
- Add test: `role_class_to_room "security-review" = Some "security-reviews"` (optional)

In `ocaml/test/test_c2c_start.ml` (or similar):
- Add test for `build_env` with `C2C_AUTO_JOIN_ROLE_ROOM=1` and role with `role_class` set → `C2C_MCP_AUTO_JOIN_ROOMS` includes derived room

### 5. Existing roles update

All builtin roles in `.c2c/roles/builtins/` need `role_class` added. Current roles:
- `coordinator1.md` — role_class: coordinator
- `ceo.md` — role_class: executive
- `jungel-coder.md` — role_class: coder
- `galaxy-coder.md` — role_class: coder
- `dogfood-hunter.md` — role_class: tester
- `release-manager.md` — role_class: coordinator
- `qa.md` — role_class: tester
- `security-review.md` — role_class: reviewer
- `gui-tester.md` — role_class: tester
- `role-designer.md` — role_class: designer
- `Lyra-Quill.md` — (no role_class)
- `Cairn-Vigil.md` — (no role_class)
- `tundra-coder.md` — (no role_class)

Note: The derived room is just for the env var. Existing roles that don't have `role_class` won't get a role-specific room (that's fine — they already have `auto_join_rooms: [swarm-lounge]`).

### 6. `c2c agent new` interactive wizard

When creating a new role, prompt for `role_class` and include it in the generated frontmatter. Already prompted? Check `agent_new_interactive`.

## Files to Change

| File | Change |
|------|--------|
| `ocaml/c2c_role.ml` | Add `role_class_to_room` helper |
| `ocaml/c2c_start.ml` | Modify `build_env` to derive role room if env var set |
| `ocaml/cli/c2c.ml` | Add `C2C_AUTO_JOIN_ROLE_ROOM=1` to install setups |
| `ocaml/test/test_c2c_role.ml` | Add unit tests for `role_class_to_room` |
| `.c2c/roles/builtins/*.md` | Add `role_class:` to each role file |

## Open Questions (resolved)

1. **Room auto-creation**: `c2c join_room` auto-creates if missing — no action needed.
2. **Pluralization**: `reviewer` → `reviewers`, `coder` → `coders`. Simple append `s`.
3. **Opt-in**: `C2C_AUTO_JOIN_ROLE_ROOM=1` gates it — no surprise auto-joins.

## Todo

- [ ] Implement `role_class_to_room` in `c2c_role.ml`
- [ ] Modify `build_env` in `c2c_start.ml` to append role room when enabled
- [ ] Add `C2C_AUTO_JOIN_ROLE_ROOM=1` to install setups in `c2c.ml`
- [ ] Add unit tests in `test_c2c_role.ml`
- [ ] Add `role_class:` to all builtin role files
- [ ] Verify `c2c agent new` includes `role_class` prompt
- [ ] Dogfood: restart a managed session and verify role room joined
