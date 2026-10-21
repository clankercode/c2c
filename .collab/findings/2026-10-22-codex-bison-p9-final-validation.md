# P9 final native connector validation — 2026-10-22

Status: local implementation and two-host installed validation passed. Production
relay validation remains blocked; P9.M2.E1.T003 is not complete.

Validated source: `45573733fb49b52881397f534f79f1a54766580f`.
Tree: `64d4c79c2df61b0772e31485fe99abacf1ebe34d`.
Later ledger/report-only commits do not change the installed implementation.

## Corrected findings

- Never-submitted recovery intents can refresh or re-arm from fresh eligible
  observations; superseded unsent runs retain cancellation acknowledgments.
  Attempted or uncertain submissions stay fenced, including when a new OAuth
  pairing repeats numeric generation 1. The private credential fingerprint is
  hashed; credentials are not logged.
- Doctor distinguishes configured API readiness from a fresh, verified live
  monitor. Unsupported recovery, malformed config and failed reads degrade
  readiness. Bounded per-thread diagnostics preserve each observation's age,
  next due time and redacted hold reason.
- Systemd install/stop/uninstall serialize mutations and fence them to the
  configured T3 home, config and state. Install verifies executable/process
  generation, environment, completed sweep and authenticated MCP readiness.
  Repair preserves credentials/mail, fixes only owned metadata and truthfully
  reports incomplete readiness.
- Native proof now observes a retrying error through a completed worker sweep,
  then verifies its terminal update retains the same item ID and position and
  receives exactly one service-generated Continue on a later sweep.

Focused independent source rereview passed at the validated commit. No known
source-review findings remain from those rounds.

## Exact gates and installation

Both isolated buildbox roots were clean and pinned to the source/tree above.
The gate driver ran under `opam exec` with `DUNE_JOBS=2`; x-tuf used its explicit
Node 24 binary. All five steps exited zero on each host:

1. `just build`
2. `just check`
3. `just test`
4. `scripts/dune-build-locked.sh build @runtest --force`
5. Explicit build of all eight install artifacts plus the native fault harness.

| Host | Forced suites / tests | Installed artifacts matched | Running c2c SHA-256 | Minimum observed submission spacing |
|---|---:|---:|---|---:|
| x-p35 | 223 / 4409 | 8 / 8 | `21f86b46fc1127756c9f2aae77c3666dbb43ee32484fc8c6e8ce0ea88888be86` | 1.033s |
| x-tuf | 223 / 4409 | 8 / 8 | `d75f74097fe180c47f230f8c329314f2b101b82660315ec8d8e799df81b51470` | 1.042s |

Each host then ran guarded `just bi` with its original
`C2C_VALIDATION_RECEIPT`, after the gate completed. No force bypass was used.
All eight installed hashes match that host's original manifest. Both
`c2c-t3.service` and `c2c-relay-connect.service` running executable hashes match
its c2c artifact. Doctor verified healthy supervision and enabled recovery at
the default 60-second cadence. Only these related c2c services were restarted;
T3 restarts in proofs targeted owned fixture instances.

Original manifests, install verification and sanitized proof artifacts are
preserved under `/home/xertrov/.cache/c2c/p9/` as:

- `45573733-{x-p35,x-tuf}-pass.json`
- `45573733-{x-p35,x-tuf}-installed.json`
- `45573733-{x-p35,x-tuf}-native-service-proof.json`
- `45573733-{x-p35,x-tuf}-dispatcher-fault-proof.json`
- `45573733-{x-p35,x-tuf}-restart-direct-proof.json`

The original build roots remain at
`/home/xertrov/src/c2c-p9-gate-72280fb2` on both hosts; the directory name is
historical. Per-step logs are `/tmp/p9-45573733-gate-{0..4}.log` and `.exit`.

## Installed native evidence

All following cases passed on both hosts with matching binary hashes and
successful owned-fixture cleanup:

- Stock T3 0.1.1 accepts idle start and active steer, with agent/MCP attribution,
  DATA/footer framing and nonce hashes recorded by the synthetic provider.
- Worker-generated availability recovery, narrow negative cases, visible holds,
  observed in-place retry update, 60-second checks and shared serial submission
  spacing. Provider arrival times are delivery evidence; controlled-clock tests
  and actual submission timestamps verify the rate cap.
- A live pending approval suppresses Continue. After the fixture explicitly
  declines its inert approval and later fails, recovery resumes. Failed roots
  with queued work remain held. Snooze/interruption negatives remain suppressed.
- Service restart preserves aliases and broker routes; captured aliases still
  deliver. Explicit disable, unsupported-version metadata and malformed config
  holds are verified. Retirement and conservative partial repair retain mail
  and credentials.
- Native MCP response-loss replay returns one DATA receipt. Accepted recovery
  followed by activity change retains uncertainty without replay. Lost/re-paired
  credentials with the same numeric generation are fenced before preflight.
  A user start after preflight queues recovery without steering that active run.
- Real CLI normal aliases and local `t3.<thread-id>` locators work with relay
  disabled and configured. Strace records no AF_INET connection for these bare
  local routes. The canonical footer reply recipe delivers through c2c. An
  owned T3 fixture restart retains alias, credential generation and one delivery.

Failures were produced by an offline synthetic provider; no real model outage
was reproduced. Held-unsent refresh/cancellation also has durable controlled-seam
coverage. Unknown-version checks manipulate only owned runtime metadata and do
not claim execution against a different T3 release. Headless fixture repair
correctly reports partial readiness; actual installed systemd readiness passed.

## Rejected intermediate evidence

The d7 gate commands passed but metadata collection failed without the opam
PATH, so no d7 PASS manifest or installation was issued. Superseded 79ce gates
later completed genuinely on both hosts but were not installed. On x-tuf, the
first final proof launcher used a symlinked checkout path: Node exited zero
without running its entrypoint. Requiring a proof artifact caught the no-op;
that attempt was not accepted. The launcher used the physical checkout path for
the successful r2 proof. Failure records remain preserved.

## Production blocker and exact continuation

The public relay health check still reports `git_hash: a0b52e4`. Railway's
[active incident](https://status.railway.com/incident/QH8L8B3E) reports paused
builds. The public relay still lacks the compatible signed T3 peer-publication
surface needed for this rollout. Master pushes are authorized and deploy
through Railway automatically.

Unblock: Railway resumes the automatic master deployment and the production
relay exposes the compatible publication capability. Then run owned x-p35 to
x-tuf and x-tuf to x-p35 sends through `https://relay.c2c.im`, with unique nonces,
canonical replies, duplicate checks and owned lease cleanup. Preserve the
production evidence before closing P9.M2.E1.T003. No manual Railway deployment
or new user credential is needed for the existing deployment path.
