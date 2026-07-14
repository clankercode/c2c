# RESULT — B184 relay auth intermittent Ed25519 signature_invalid

**Branch**: `fix/bl-b184`  
**Worktree**: `/home/xertrov/src/c2c/.worktrees/bl-b184`  
**Bug**: `.backlog/bugs/B184-relay-auth-intermittent-ed2551.todo`  
**Status**: fix committed on branch only (no merge, no `bl done`)

## Summary

Intermittent `Ed25519 request signature does not verify` after rename/register
was caused by a **sign/wire body mismatch on signed GET requests**, not by
Ed25519 key rebinding or clock skew.

| Side | Body used for hash |
|------|--------------------|
| Client sign (`whoami --relay`, `doctor --relay`, mesh, `relay list`) | `""` (empty) |
| Client wire (`Relay_client.request_raw` default) | `"{}"` |
| Server verify | hash of received body |

When a proxy stripped GET bodies, wire became empty → verify OK. When body
`{}` was preserved → `signature_invalid`. Felt intermittent and often showed
up in post-rename recovery flows that re-probed the relay via signed `/list`.

## Changes

1. **`ocaml/relay_client.ml`** — `body=None` → send `""`, not `"{}"` (B184).
2. **`ocaml/c2c_relay_connector.ml`** — same default for connector requests.
3. **`ocaml/relay.ml`** — `try_verify_ed25519_request` (and forward path)
   include `alias`, `bound_pk` fingerprint, meth/path/query, body_sha256
   token, and re-register remediation in the error string.
4. **`ocaml/relay_client_hints.ml`** — `is_signature_invalid` + actionable
   hint; `hint_for_response` covers it.
5. **`ocaml/cli/c2c_relay_state.ml`** — print hint on stderr when
   `whoami --relay` / status lease fetch fails auth/verify.
6. **Tests**:
   - `ocaml/test/test_relay_bindings.ml` — empty vs `{}` body hash regression
   - `ocaml/test/test_relay_client_hints.ml` — signature_invalid hint
7. **Finding**:
   `.collab/findings/2026-07-14T08-50-00Z-b184-relay-get-body-sign-mismatch.md`

## Validation

```text
opam exec -- dune build --root .                    # rc=0
opam exec -- dune exec --root . ocaml/test/test_relay_bindings.exe
  # b184_empty_vs_json_object_body_hash OK; 39 tests
opam exec -- dune exec --root . ocaml/test/test_relay_client_hints.exe
  # signature_invalid hint OK; 9 tests
opam exec -- dune exec --root . ocaml/test/test_c2c_relay_state.exe
  # 22 tests OK
opam exec -- dune exec --root . ocaml/cli/test_c2c_monitor_logic.exe
  # 43 tests OK
```

## Process notes

- **PIRFL**: planned against findings + verify path; implemented body fix +
  diagnostics + hints; self-review; no open correctness issues known for
  this root cause.
- **review-and-fix**: self-PASS (gpt55 peer not invoked from this agent
  session). Criteria: root cause matches crypto failure (not ts/nonce codes);
  wire body equals sign body; tests pin empty-vs-`{}`; whoami has next step.
- **Not done** (per instructions): merge to master, `bl done`, production
  relay deploy. Server-side error-string improvement only helps after
  relay redeploy; the **client body fix alone** stops intermittent whoami
  failures against current prod.

## Commit SHAs

| Ref | SHA |
|-----|-----|
| Fix commit | `bbbd69686ea3ae9c982be44ec3b3338c9d7fa192` (`bbbd6968`) |
| Branch tip | `bbbd69686ea3ae9c982be44ec3b3338c9d7fa192` (before RESULT SHA fill-in) |
| Claim base | `0e2559d7` |
