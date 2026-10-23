# P9 final public T3 proof

The remaining public-relay slice passed on 2026-10-23. This supplements the
historical exact-source build/install/native proofs; their source identities
and receipts have not been regenerated or relabeled.

- Installed product: `b8c42376ea8363891f7b2249e4056d7ebf4b53c8`.
- Installed tree: `e7750255ed766aeb7b61a015c4c0c3576333642d`.
- Public Railway deployment: `80c7f35a42cbdd90164acbbd8bdad9f8a7840069`, a descendant
  of that implementation, serving `https://relay.c2c.im`.
- Receipt: [2026-10-23-p9-public-t3-proof.json](2026-10-23-p9-public-t3-proof.json).
- Receipt SHA-256: `ad879af26072408e646dc2a2ef1199c6ce1478f03f3102fabf6ff84eb4329b3d`.
- Preserved final drivers and original receipt:
  `/home/xertrov/.cache/c2c/p9/public-proof-b8-20261023/`.
- Coordinator SHA-256: `74542a1a6adba25aa4893eaa0c120226efb80fe63ebf8e665ce24e0268f78361`.
- Actor SHA-256: `5f14890a7ddd67f665654d81a573977dfcb5ed0b1770e269a0346e1a0bd09f01`.

Execution (completed with exit 0):

```sh
python3 /tmp/p9-public-t3-proof.py \
  --execute \
  --public-url https://relay.c2c.im \
  --rollout-commit 80c7f35a42cbdd90164acbbd8bdad9f8a7840069
```

## Requirement-to-evidence audit

| Requirement | Authoritative evidence |
|---|---|
| Exact candidate passes before installation | Original per-host six-command PASS manifests, hashes and eight built/installed artifact identities are checked by the new public receipt before either host mutates fixtures. Full gate details remain in the [contact integration report](2026-10-22-p9-contact-integration-validation.md). |
| Public idle and active delivery both directions | Eight legs in the new receipt: two idle, two active, two after service restart, two after T3 restart. Agent/MCP provenance, exact remote footer, accepted native IDs and provider nonce hashes agree. Active delivery retains its run and uses provider `turn/steer`; idle delivery uses `turn/start`. |
| Canonical replies and duplicates | Eight driver-executed canonical replies through independent owned sender bindings, with sixteen duplicate ACKs in total. Replays retain the original message ID; final audit exhausts both target histories, checks every owned nonce and provider receipt, and requires empty queues. |
| Restart and ownership | Each host restarts its owned foreground service and stock T3 fixture once; aliases and credential generations stay stable. Live user unit identities, source, original manifests and all eight binaries remain unchanged. |
| Recovery, response loss and rotation | Original `b8c42376-{x-p35,x-tuf}-native-service-proof.json` and `dispatcher-fault-proof.json` identify the same installed CLI hashes: retry-in-place, per-thread holds, positive/negative recovery guards, nominal 60-second sweeps, shared one-second spacing, explicit disable, response-loss dedupe, credential-generation uncertainty and concurrent-start queue behavior. |
| Permission, retirement and repair | Original native-service receipts show permission holds, tombstone/mail/credential preservation and conservative partial repair. Installed systemd readiness is separately recorded by the install receipts. |
| Direct local delivery | Original `restart-direct-proof.json` on each host proves normal alias and thread-locator delivery/replies with relay disabled and configured, no AF_INET connection, stable aliases and T3 restart reconnect. |
| Operator setup and limitations | `docs/clients/t3-code.md` describes the native service for unmodified T3; bridge research remains historical. |
| NAS/contact coordination | B369/B370 landed before b8. Their actual LAN/NAS proofs supplement contact validation and are not substituted for this public T3 run. See the contact integration report and subsequent T004 review. |

## Independent review

T3 delegated review `p9-t003-final-evidence-review-20261023-r1` returned PASS
for the connector validation evidence. It checked the full current T003/design,
source/build/install linkage, driver assertions and final public receipt. No
false-PASS path or unmet connector requirement was found. It ran no new tests.
The final duplicate check accepts the actual frozen `/send` ACK
`result: "duplicate"` as well as `duplicate: true`, pins the requested ID, and
rejects an echoed different ID. Public-key audits sign each exact owned lookup.

## Failed attempts and cleanup

Earlier proof attempts remain FAIL and are not completion evidence. They
exposed scratch quota and driver compatibility issues (unsigned public-key
lookup and legacy duplicate ACK shape). A mistyped rollout SHA was rejected
before remote setup. The successful run uses a fresh ID and fresh owned state.
No installed product code was changed to obtain this proof.

Successful final cleanup withdrew every owned public alias, confirmed owned
service/fixture termination, removed private roots/keys, and checked foreign
services and exact source/artifact stability. This does not erase public relay
storage: leases expire by TTL and reservations/metadata can persist.
An older failed-run x-p35 root remains private and process-free; recursive
removal was denied by the command guard, so it was not retried through another
path. It is not part of final-run cleanup success.

## Explicit limits

Stock T3 0.1.1 uses the offline synthetic provider. Provider receipt proves
native input; it does not prove model comprehension or autonomous replies.
Replies were executed by the driver. A real model-availability outage and a
failed root retaining a live approval were not reproduced. Headless repair
truthfully retains two readiness holds. Public service intervals were two
seconds with recovery disabled; the nominal cadence/recovery/fault requirements
come from the preserved exact-binary native proofs. No unlimited exactly-once,
power-loss, live-user-daemon uptime or new T3-release guarantee is claimed.

T003 completion uses this combined evidence. T004 remains a subsequent,
independent review of the appended NAS/contact coordination requirements.
