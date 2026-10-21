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
