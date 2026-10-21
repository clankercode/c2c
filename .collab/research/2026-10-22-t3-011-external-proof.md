# T3 0.1.1 external contract verification

The unmodified installed T3 0.1.1 runtime was copied with unchanged bytes into
an isolated fixture path on x-tuf and x-p35. Dependencies are read from the
installed runtime. Fixture homes contain only synthetic provider configuration;
no user T3 instance, thread, provider configuration, or credential was changed.

On both hosts `scripts/t3-connector-matrix.mjs` completed with exit 0 against
fresh external read/operate OAuth clients on 2026-10-21 UTC (2026-10-22 Sydney).
Evidence is in `/tmp/c2c-p9-native-20261022/probe/matrix-state.json` and
`/tmp/p9-external-011.log` on each host. Cases cover availability and text-only
failures, code-only/auth/usage negatives, child and mixed failures, active auto
steering and queued continuation, in-place retry updates, active interruption,
terminal interruption rejection, full-access denial, reconnect and fixture
restart. Error projection shape and root-error observations remain compatible
with the conservative c2c matcher. This permits adding 0.1.1 to the explicit
recovery version allowlist.

This matrix exercises the external contract and sends its own continuations.
It is not evidence that the production c2c service recovered a thread. The
separate native service proof must exercise the installed OCaml worker.
No real model outage was reproduced: the provider is synthetic/offline.

T3 0.1.1 exits a desktop backend when its launcher dies. A fixture driver must
remain alive for the whole proof; calling the fixture `start` CLI in a short
lived parent and then starting a separate probe loses the backend. In-process
fixture APIs keep the launcher alive without changing T3.

## Native worker follow-up

The strengthened native proof passed on both hosts using the `dcc7bc77` engine
and final proof driver at `/tmp/c2c-p9-native-worker-r2`. It observed recovery
without sending Continue from the driver, negative cases including Stop and
snooze, idle start and active steering by provider nonce hashes, actual default
sweep timestamps, broker/state alias reuse and delivery after restart, durable
disable, permission holds, retirement preserving pending mail, and permission
repair preserving credentials and state. Both roots were cleaned up successfully.
Receipts are `native-service-proof.json` inside each private fixture root.

Later review found a real spacing issue before awaited recovery preflight. The
final engine refreshes the submission clock and persists a conservative send
completion boundary. A controlled-clock regression models 1.2s preflight plus
0.4s send and verifies a full second still remains afterward. Provider receipt
timestamps remain independent delivery evidence; asynchronous startup means
they cannot establish spacing at MCP admission. Final-source gates and installed
build proofs remain required; the earlier worker proof is not an install receipt.
