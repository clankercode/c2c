# B267 — private reachability attack matrix ledger (clean master base)

**Date:** 2026-07-22  
**Branch:** `feature/b266-from-master`  
**Worktree:** `.worktrees/b266-from-master`  
**Tip (pre-matrix commit base):** `6b808931dbc0b7d8876d6f152ea28a568014ce0e`  
**Invariant:** G1–G9 from `.collab/design/2026-07-22-b262-contact-grant-protocol.md`

## Suite inventory (hermetic)

| Suite | Tests | Focus |
|---|---|---|
| `test_relay_contact_grants` | 36 | Issue/list/revoke/rotate/admit, concurrency, restart, redaction |
| `test_relay_contact_delivery_handlers` | 37 | Ingress attacks + HTTP tokenless/send/send_all/protocol/forward |
| `test_relay_private_discovery` | 24 | list/pubkey oracles, rooms, stats |
| `test_relay_private_migration` | 5 | Fresh/legacy/interrupted migration + health ads |
| `test_relay_doctor_private_reachability` | 12 | Doctor auth/contact/private/transport |
| `test_relay_private_reachability_matrix` | 19 | Consolidated B267 dual-backend + HTTP matrix |

**Measured green (this session):** all of the above exit 0 on clean post-B265 base.

## B262 §15 row → evidence

| Attack row | Verdict proven | Primary tests |
|---|---|---|
| Anonymous list/send/pubkey on token relay | Deny | matrix HTTP; discovery anonymous list |
| Auth peer `/list` omits private | Absent | discovery list_peers both backends + HTTP |
| Auth peer `/send` to private | No side effects; uniform error | delivery_handlers + matrix guessed-alias |
| `/send_all` skips private | Excluded from delivered+skipped | delivery_handlers + matrix send_all |
| `/forward` path to private | No private delivery / content redacted DLQ | delivery_handlers forward-path |
| Wrong Ed25519 signer / leaked secret | Reject | delivery_handlers |
| Unknown/malformed/expired/revoked | Reject; zero inbox | grants + delivery_handlers |
| Duplicate message_id | At most one delivery | grants + delivery_handlers + matrix restart |
| Revoke vs admit race | Linearised; no content DLQ | grants concurrent + matrix concurrent |
| Rotate old secret | Old rejected, new accepted | grants rotate |
| Wrong recipient identity | Reject | delivery_handlers |
| Restart preserves grant + mid | Yes (Sqlite) | grants restart; matrix authorised admit restart |
| Room membership ≠ DM route | Yes | matrix room + discovery |
| Tokenless contact deliver | Refused | delivery_handlers HTTP |
| Protocol downgrade | Refused | delivery_handlers HTTP |
| Public legacy send still works | Yes | matrix public legacy send |
| Stats not bumped on private reject | Yes | matrix private reject no stats |
| Secret redacted from list meta | Yes | matrix list redacts + grants |
| WS push not invoked on private reject | Yes | matrix push_dm spy |
| Health ads contact + private_reachability | Yes | migration + matrix health process_local |
| Migration fail-closed private default | Yes | migration suite |
| Doctor fails auth_mode=dev / process_local prod | Yes | doctor_private suite |

## Canonical symbols

- Discovery: `list_peers`, `list_peers_admin`, `peer_discovery_visibility_of`, `set_peer_discovery_visibility`, `peer_*_of`
- Grants: `issue_contact_grant`, `list_contact_grants`, `revoke_contact_grant`, `rotate_contact_grant`, `admit_contact_delivery`
- HTTP: `handle_list`, `handle_pubkey`, `handle_send`, `handle_send_all`, `handle_forward`, `handle_contact_deliver`, `handle_health`
- Migration: `relay_features`, `discovery_visibility` ALTER, `schema_version=2`
- Doctor: `check_auth_mode`, `check_contact_protocol`, `check_private_reachability`, `check_transport_security`
- CLI: `c2c contact {issue,list,revoke,rotate}`
- WS spy: `Relay_ws_server.push_dm_invocations` / `reset_push_dm_count`

## Still outside this hermetic matrix (explicit next checklist)

1. **Live tmux dogfood** against isolated local relay.
2. **Independent security review** disposition on this clean branch.
3. **Full repo-wide `@runtest --force`** under AGENTS.md anti-false-green.
4. Connector inbound policy remains defence-in-depth only — not G1 proof.
5. Pre-B266 binary + migrated DB (M1 ops residual).

## Commands

```bash
cd .worktrees/b266-from-master
export DUNE_THROTTLE_BYPASS=1 C2C_DUNE_SKIP_GLOBAL_LOCK=1
scripts/dune-build-locked.sh build -j 2 \
  ./ocaml/test/test_relay_private_reachability_matrix.exe \
  ./ocaml/test/test_relay_contact_delivery_handlers.exe \
  ./ocaml/test/test_relay_contact_grants.exe \
  ./ocaml/test/test_relay_private_discovery.exe \
  ./ocaml/test/test_relay_private_migration.exe \
  ./ocaml/test/test_relay_doctor_private_reachability.exe
# run each .exe; all must exit 0
```


## Status (clean master tip)

Closed on local master tip `6f313eea`:

- Full `@runtest --force` exit 0 (0 FAIL)
- Matrix suite green (`test_relay_private_reachability_matrix`)
- Dogfood AUTH-OK + unauth artefacts under goal evidence `dogfood-final/`
- Independent review PASS-WITH-NOTES + clean-tip reaffirmation

Next-checklist items that were residual (optional WS push on Accepted, public opt-in CLI product follow-up, old-binary ops constraint) are **not** blockers for B267 close.
