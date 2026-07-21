# B267 — private reachability attack matrix ledger

**Date:** 2026-07-22  
**Branch:** `feature/b264-private-discovery`  
**Worktree:** `.worktrees/b264-private-discovery`  
**Invariant:** G1–G9 from `.collab/design/2026-07-22-b262-contact-grant-protocol.md`

## Suite inventory (hermetic)

| Suite | Tests | Focus |
|---|---|---|
| `test_relay_contact_grants` | 28 | Issue/list/revoke/rotate/admit, concurrency, restart, redaction |
| `test_relay_contact_delivery_handlers` | 28 | Ingress attacks + HTTP tokenless/send/send_all/protocol |
| `test_relay_private_discovery` | 23 | list/pubkey oracles, rooms, stats, schema stamp |
| `test_relay_private_migration` | 5 | Fresh/legacy/interrupted migration + health ads |
| `test_relay_private_reachability_migration` | 4 | Marker idempotence / legacy private |
| `test_relay_private_reachability_matrix` | 14 | Consolidated B267 matrix rows |

**Measured green (this session):** all of the above exit 0.

## B262 §15 row → evidence

| Attack row | Verdict proven | Primary tests |
|---|---|---|
| Anonymous list/send/pubkey on token relay | Deny | matrix HTTP; discovery anonymous list; auth matrix |
| Auth peer `/list` omits private | Absent | discovery list_peers both backends + HTTP |
| Auth peer `/send` to private | No side effects; uniform error | delivery_handlers + matrix guessed-alias |
| `/send_all` skips private | Excluded | delivery_handlers backend + HTTP |
| `/forward` path to private | No private delivery / no content DLQ | delivery_handlers forward-path |
| Wrong Ed25519 signer | Reject | delivery_handlers wrong sender; grants wrong sender |
| Leaked secret + wrong key | Reject | delivery_handlers leaked secret |
| Unknown/malformed/expired/revoked | Reject; zero inbox | grants + delivery_handlers |
| Duplicate message_id | At most one delivery | grants + delivery_handlers replay |
| Revoke vs admit race | Linearised | grants concurrent revoke/admit |
| Rotate old secret | Old rejected, new accepted | grants rotate |
| Wrong recipient identity after rebind | Reject | delivery_handlers wrong recipient |
| Restart preserves grant + mid | Yes (Sqlite) | grants restart; matrix authorised admit restart |
| Room membership ≠ DM route | Yes | discovery + delivery_handlers + matrix |
| Tokenless contact deliver | Refused | delivery_handlers HTTP |
| Protocol downgrade `c2c-contact/0` | Refused | delivery_handlers HTTP |
| Public legacy send still works | Yes | matrix public legacy send |
| Stats not bumped on private reject | Yes | matrix private reject no stats |
| Secret redacted from list meta / disk | Yes | grants list meta + sqlite secret-at-rest |
| Health ads contact_protocol + private_reachability | Yes | migration + matrix health |
| Migration fail-closed private default | Yes | migration suites |
| Doctor fails auth_mode=dev | Implemented | `c2c_doctor_relay.ml` checks |

## Canonical symbols

- Discovery: `list_peers`, `list_peers_admin`, `peer_discovery_visibility_of`, `set_peer_discovery_visibility`, `peer_identity_pk_of` (+ enc/signed/sig)
- Grants: `issue_contact_grant`, `list_contact_grants`, `revoke_contact_grant`, `rotate_contact_grant`, `admit_contact_delivery`
- HTTP: `handle_list`, `handle_pubkey`, `handle_send`, `handle_send_all`, `handle_forward`, `handle_contact_deliver`, `handle_health`
- Migration: `relay_features`, `discovery_visibility` ALTER, `schema_version=2`, contact_grants required
- Doctor: `check_auth_mode`, `check_contact_protocol`, `check_private_reachability`, `check_transport_security`
- CLI: `c2c relay contact {issue,list,revoke}`

## Still outside this hermetic matrix (explicit)

1. **Live tmux dogfood** against isolated local relay (B267 dogfood item).
2. **Independent security review** disposition (human/reviewer).
3. **Full repo-wide `@runtest --force`** count under AGENTS.md anti-false-green procedure (B267 acceptance evidence).
4. **WebSocket subscribe push spies** for rejected private first-contact (partially covered via no-inbox; push counters not instrumented here).
5. **Connector inbound policy** remains defence-in-depth only — not claimed as G1 proof.

## Commands

```bash
cd .worktrees/b264-private-discovery
eval $(opam env)
scripts/dune-build-locked.sh build \
  ./ocaml/test/test_relay_private_reachability_matrix.exe \
  ./ocaml/test/test_relay_contact_delivery_handlers.exe \
  ./ocaml/test/test_relay_contact_grants.exe \
  ./ocaml/test/test_relay_private_discovery.exe \
  ./ocaml/test/test_relay_private_migration.exe
# then run each .exe; all must exit 0
```
