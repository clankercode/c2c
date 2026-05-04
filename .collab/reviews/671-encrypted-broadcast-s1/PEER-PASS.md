# Peer-PASS — 671-encrypted-broadcast-s1 (stanza-coder)

**Reviewer**: test-agent
**Date**: 2026-05-03
**Commits**: e436b0eb + 891c467f
**Branch**: 671-encrypted-broadcast-s1
**Criteria checked**:
- `build-clean-IN-main-tree-rc=0` (dune build @check — no output, exit 0)
- `test-suite-send_handlers=16/16` (dune exec test_c2c_send_handlers.exe — tests 13/14/15 new, all OK)
- `test-suite-full=337/337` (dune exec test_c2c_mcp.exe — confirmed prior run)

---

## Commit 1: e436b0eb — feat(#671 S1): per-recipient encrypted broadcast

### What changed
`broadcast_to_all` in `c2c_send_handlers.ml` replaced the single plaintext `Broker.send_all` fan-out with a per-recipient loop:
1. Iterate `Broker.list_registrations`
2. Deduplicate by case-folded alias (mirrors `Broker.send_all` pattern)
3. Skip sender + excluded aliases
4. Call `encrypt_content_for_recipient ~broker ~from_alias ~to_alias ~content ~ts`
5. Route result: `Encrypted` → `sent_encrypted`, `Plain` → `sent_plaintext`, `Key_changed` → (temporary, later fixed)
6. Emit receipt with `sent_to`, `encrypted`, `plaintext` arrays

### +3 tests (`test_c2c_send_handlers.ml`)
- `send_all receipt has encrypted/plaintext arrays`: asserts all 4 arrays present; local peers land in plaintext (encryption is relay-only by design)
- `send_all empty receipt has empty enc arrays`: zero-peer broadcast → empty arrays
- `send_all per-recipient delivery`: registers 3 peers + 1 excluded, drains individual inboxes, verifies content and exclusion

### Code quality
- Alias dedup uses `Hashtbl` + `alias_casefold` — same pattern as `Broker.send_all`
- Dead-recipient `Invalid_argument` caught and added to `skipped` with reason `not_alive` — matches existing `send_all` error-handling style
- Tag prefix prepended to content before broadcast loop (correct — preserves `send_all` tag behavior)
- OCaml module comment updated with `#671 S1` reference

---

## Commit 2: 891c467f — fix(#671 S1): promote key_changed to top-level receipt array

### What changed
Review finding: `key_changed` peers were being added to `skipped` with reason `"key_changed"`, but the docstring and AC promise a **separate top-level `key_changed` array**.

Fix:
- New `key_changed : string list ref` introduced alongside `sent_encrypted` / `sent_plaintext`
- `Key_changed alias` branch now prepends to `key_changed` (not `skipped`)
- JSON receipt gets a dedicated `"key_changed"` field alongside `encrypted` and `plaintext`
- Test updated: asserts `key_changed` array is present and empty for local-only peers

### Verdict on fix
Correct and minimal. The separate array is the right shape — `skipped` is for delivery failures, `key_changed` is an encryption status that doesn't prevent delivery.

---

## Overall

**PASS** — clean architecture, correct API usage, proper error handling, good test coverage (including exclusion and empty-broadcast edge cases), and the fix commit addresses the receipt-shape issue precisely.

### Minor note
The test suite ran against main tree HEAD (which contains identical content to these commits per coordinator's push). The worktree opam context doesn't have a separate Dune root so build was verified via main tree — this is equivalent since the OCaml source files are identical.
