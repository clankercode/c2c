# P9 and contact integration validation

Implementation candidate: `b8c42376ea8363891f7b2249e4056d7ebf4b53c8`.
Tree: `e7750255ed766aeb7b61a015c4c0c3576333642d`.
Merged and pushed to master on 2026-10-22. Later report/ledger commits do not
change the installed implementation or relabel its original receipts.

## Build and installation

Both x-p35 and x-tuf passed the following gates in clean, isolated checkouts
before guarded `just bi` installed the candidate:

1. `just build`
2. `just check`
3. `just test`
4. `scripts/dune-build-locked.sh build @runtest --force`
5. Explicit build of all eight installed artifacts and the native fault harness.
6. `scripts/test-contact-deliver-cli.py` with explicit CLI/MCP artifacts and
   source identity: 26 native TLS/HTTP checks.

Each forced repository run reported 225 suite summaries and 4,523 tests.
All eight installed artifact hashes match the host's original PASS manifest.
The running T3 connector and relay connector match the installed CLI; doctor
verified healthy supervision and the enabled 60-second recovery monitor.

| Host | Original manifest SHA-256 | Installed CLI SHA-256 |
|---|---|---|
| x-p35 | `74fb49d19b65b13252960a4d410a10a6bbb80cfbb2dfdb646afc738b6bd0bbd7` | `ee4cfc9a19deb9f3757fa412d8ba5824f0731784dd80be28856b0ee0f6a5a553` |
| x-tuf | `6d41049eb323c48e1559d1432f1651b91029e4f044401a0af3766d89ee515c82` | `fa4f7a728fc38c9fe430eb00a6b89d23935f2be0bebf9a10bc949311def13b91` |

Original manifests remain at
`/home/xertrov/src/c2c-p9-receipts-b8c42376.json` on each host. Gate roots are
`/home/xertrov/src/c2c-p9-contact-gate`; x-tuf resolves this to
`/srv/home-src/c2c-p9-contact-gate`.

## Installed T3 proofs

Native service/recovery, dispatcher fault, and local direct/reply/T3-restart
proofs passed on both hosts. Their hashes were checked against the original
manifests, and all accepted proofs report successful owned-fixture cleanup.

Evidence includes idle start and active steer with agent/MCP provenance and
provider nonce receipts; DATA/footer framing; observed in-place retry updates;
bounded per-thread hold diagnostics; default recovery cadence and shared
one-second admission spacing; duplicate/credential/response-loss fences;
permission, queued-work and approval holds; conservative repair and retirement;
stable aliases through restart; and direct local delivery with relay disabled
and configured, with no AF_INET connection for bare local routes.

T3 was unmodified stock 0.1.1. Provider failures were synthetic. A real model
outage and a different T3 release were not tested. Headless fixture repair
truthfully reports partial readiness while retaining pending mail/credentials;
actual installed systemd readiness passed.

Preserved metadata receipts on the coordinator are under
`/home/xertrov/.cache/c2c/p9/`, using the prefix
`b8c42376-{x-p35,x-tuf}-` and suffixes `pass.json`, `installed.json`,
`native-service-proof.json`, `dispatcher-fault-proof.json`,
`summary-proof.json`, and `restart-direct-proof.json`.

## Remaining live gates

Independent source reviews passed for the contact integration and final
monitor-fixture cleanup. Extra two-host contact validation and an isolated
NAS30435 Debian canary are still in progress. Intermediate proof-driver
failures are preserved and are not PASS receipts. Production NAS30434 and
machine-wide relay configuration remain outside these fixtures.

P9.M2.E1.T003 still requires the actual public-relay T3 proof through
`https://relay.c2c.im`; isolated/NAS contact proofs cannot replace it. At
11:11 UTC production still reported `a0b52e4`. Railway's live status page
reported the ongoing platform incident and deployment delays. The authorized
master push starts the automatic rollout; it does not prove rollout success.
P9.M2.E1.T004 remains dependent on T003 completion.

B369/B370 remain open until their required live canary and two-host evidence
complete. Hermes gateway delivery/wake remains separately scoped.
