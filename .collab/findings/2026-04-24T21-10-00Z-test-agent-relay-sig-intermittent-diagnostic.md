# test-agent: relay signature_invalid diagnostic — galaxy's finding #148 follow-up

**Date**: 2026-04-24T21:10 UTC
**Investigated from**: galaxy-coder's finding at `.collab/findings/2026-04-24T10-05-00Z-galaxy-coder-relay-sig-intermittent.md`

## Context
Intermittent `signature_invalid` error during `relay-smoke-test.sh` loopback DM step. Window: ts 1777025057 range had failures; ts 1777025171+ succeeded consistently.

## Diagnostic steps taken

1. **Ran relay-smoke-test.sh** — PASSED (10/11, room history non-fatal). Loopback DM succeeded.
2. **Traced signature verification flow** in `ocaml/relay.ml:try_verify_ed25519_request` (lines 3690-3738):
   - Timestamp skew check: 30s past / 5s future window
   - Nonce replay check: 2min TTL via `R.check_request_nonce`
   - Identity PK lookup: `R.identity_pk_of relay ~alias`
   - Cryptographic verify: `Relay_identity.verify ~pk ~msg:blob ~sig_`
3. **Checked prod relay health** — healthy, version 0.8.0, git 3a7a983
4. **Checked clock**: current ts 1777028902 (~21:08 UTC), finding window was ~20:44 UTC (~64 min ago)
5. **Checked identity.json** — valid Ed25519 identity present at `~/.config/c2c/identity.json`

## Root cause assessment

**Inconclusive — issue self-resolved**. The error "Ed25519 request signature does not verify" is a pure cryptographic failure (signature bytes verify false). Possible causes:

1. **Clock skew** — most likely. Client `Unix.gettimeofday()` vs relay clock drift. But 30s window is generous, and issue was consistent within the ~114s failure window then resolved.
2. **Nonce collision** — two smoke runs with same nonce within 120s. Possible but unlikely with UUIDv4 nonces.
3. **Identity DB lag** — registration commits but identity_pk binding not immediately readable by `R.identity_pk_of`. Race between write and read. **Plausible for first-try failures after fresh alias registration.**
4. **Mirage_crypto_rng state** — unlikely since it uses getrandom()

The issue occurred once, self-resolved, and hasn't recurred. Prod relay is 332 commits behind current HEAD; no relay.ml changes since deploy that specifically address signature verification.

## Recommended diagnostic probe (if recurrence)

Add targeted logging to `try_verify_ed25519_request` at the signature_invalid path (relay.ml:~3737):

```ocaml
(* Before the else branch at line 3737 *)
Logs.info (fun m -> m "signature_invalid: alias=%s ts=%s nonce=%s" alias ts_str nonce);
```

This distinguishes:
- Clock skew → `ts_out_of_window` error, not `signature_invalid`
- Nonce replay → `nonce_replay` error, not `signature_invalid`
- True crypto failure → only `signature_invalid`

## Action items

- [ ] If recurrence: ask coordinator1 to add the diagnostic logging above and redeploy
- [ ] Monitor relay-smoke-test.sh for signature_invalid over next 24h
- [ ] Consider whether identity binding write-after-read could cause race (investigate SQLite WAL mode on relay)
