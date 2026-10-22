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
monitor-fixture cleanup. The actual x-p35 to x-tuf contact proof passed in
both directions, including normal sends/replies, explicit-ID duplicates,
wrong-sender rejection, response-loss/restart, rotation and revocation. Its
21 signed requests produced eight inbox effects, four duplicate receipts,
two native relay restarts, zero rate limits/fallbacks/takeovers, and successful
cleanup/stability checks. Final receipt:
`/home/xertrov/.cache/c2c/p9/b8c42376-two-host-contact-r12.json`.
The parent verified its script, original manifest and all-eight-artifact hashes.
The temporary destination-restricted SSH agent was emptied and terminated;
no private key was copied and no authorized-keys file was changed.

The final independent proof rereview passed after process-wide non-raising
signal handlers and a diagnostic-cleanup fallback were added. A fresh r12
run then passed with the final script hashes. Intermediate proof-driver
failures are preserved and are not PASS receipts. Production NAS30434 and
machine-wide relay configuration remain outside these fixtures.

The separate no-hardlinks b8 clone on x-p35 produced a Debian 12 package using
the unchanged repository Dockerfile, OCaml 5.2.1 and Dune 3.24.2. Artifact
SHA-256: `c7b3b9d617885721e92c0602e1fb8c3fde27a9f54fe4c0dd9ecd39bfbc98263d`.
Builder image:
`sha256:748518c4d9af82d1dad83c93f8e9a160d866e7253aae25d202c5e87ae5f7b29d`.
An owned Debian 12 container resolved all libraries and ran the artifact with
networking disabled and a read-only root. Maximum required glibc is 2.35;
runtime glibc was 2.36. The first probe stopped on an unnecessary opam log write
before binary startup; its failed receipt/log remain preserved. The corrected
direct-binary probe passed. Owned temporary containers were removed, and
original source/manifests/installed files stayed unchanged. Metadata:
`/home/xertrov/.cache/c2c/p9/b8c42376-debian-package.json`.
This packaging receipt does not relabel the original eight-artifact manifests
and does not itself prove NAS runtime behavior. The verified artifact was
released to the NAS30435 canary owner under the existing test authorization.

The independent NAS30435 canary subsequently passed 13 checks: signed isolated
identities, client/server HTTP defaults, explicit opt-in disclosure, wrong-sender
refusal, shared send and separate reverse-grant reply, duplicate handling,
ordinary CLI outbox delivery, real container restart with SQLite mail and
dedupe retention, old-message grant pinning, rotation and revocation. The parent
read the test script/receipts and independently verified the running binary
hash and runtime image:
`sha256:0da6bea141437e4fbc85fe5fafd86b9e3486d9fd311463e90887e6c986fd283e`.
Production30434's container/image/start time matched its before/after receipt,
and its health remained good. Dev30435 is retained running with restart `no`,
separate state and a new secret. No production/default configuration changed.
Canary metadata is preserved as `b8c42376-nas-*.json` and
`b8c42376-nas-canary-receipt.md` in the coordinator evidence directory.
This canary used the precompiled Debian binary on xsm as client and NAS as
server; it does not claim a p35-to-NAS actor pair, MCP, TLS, response-loss,
Hermes wake, or public T3 execution. Those distinct evidence boundaries remain.

P9.M2.E1.T003 still requires the actual public-relay T3 proof through
`https://relay.c2c.im`; isolated/NAS contact proofs cannot replace it. At the
final check, production still reported `a0b52e4` from the workstation and both
buildboxes. The timestamp, full health responses and headers are preserved in
`b8c42376-public-rollout-blocker.json` in the coordinator evidence directory. Railway's live status page
reported the ongoing platform incident and deployment delays. The authorized
master push starts the automatic rollout; it does not prove rollout success.
GitHub CI `39768431737`, Docker smoke `39768431878`, and Pages
`39768430935` all passed for b8. A read-only Railway CLI status probe returned
unauthorized; no login or manual deployment was performed or required for the
existing push-triggered rollout.
P9.M2.E1.T004 remains dependent on T003 completion.

The production two-host T3 driver passed independent source rereview after
fixes for broken-output cleanup and complete nonce/queue duplicate auditing.
It remains **prepared, not executed**. Reviewed scripts, hashes and syntax
receipts are preserved in
`/home/xertrov/.cache/c2c/p9/public-proof-b8-20261022/`; the source-review result
is `b8c42376-public-proof-source-review.json` in the parent evidence directory.
Execution requires the actual compatible public rollout, followed by the
documented explicit public-URL command. Source review does not close T003.

B369/B370 are closed after their reviewed, merged implementation, required
build/install gates, actual two-host proof and independent NAS canary passed.
Hermes gateway delivery/wake remains separately scoped.
