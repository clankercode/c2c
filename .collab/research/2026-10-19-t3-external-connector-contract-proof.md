# P9 external T3 connector compatibility proof

Task: P9.M1.E1.T001. Status: in progress; not a completion receipt.
Implementation worktree: `.worktrees/t3-connector-contract`.

## Verified hosts and API

On 2026-10-19 both x-p35 and x-tuf run unmodified T3 0.1.0 at
`http://127.0.0.1:3773`, using
`/home/xertrov/.t3/runtime/versions/0.1.0/t3` with SHA-256
`4baaddb56353e7fe0e356ec587e2546082933b6b1c0445756d4a02ef5e0f1929`.
The server PID is a child of the systemd MainPID; x-tuf's launcher pathname
names an older version and must not be used as runtime-version evidence.

The development-only Node probe at source `9660254a` passed eight focused tests
on each box (8 pass, 0 fail, 0 skip). Tests cover strict JSON/SSE envelopes,
scope/type checks, atomic credential publication, runtime incarnation/socket
ownership including wrong address families, private Unix groups, authenticated
session headers, redaction and redirect refusal. An earlier runtime fixture
failed under the hosts' group-writable umask; explicit fixture modes fixed it.
That failure was not reported as PASS.

Using the supported T3 CLI pairing flow, the probe issued its own independent
OAuth client on each host with exactly `orchestration:read orchestration:operate`.
Authenticated capabilities verified runtime access `auto`. No provider or
t3-bridge credentials were read. Probe credentials remain mode 0600 in a 0700
probe directory outside this repository and are never included in evidence.

Live inspection at approximately 09:00 UTC returned protocol `2025-06-18` and
83 tools on each box. Tool names/input-schema digest on both:
`433913f723444f7b776b84d36ec66b3c1b26eb2b6620ee54e96ba16cd4e0d3ae`.
The required capabilities/project-list/thread-list/read/send tools exist;
send supports `auto`, `queue`, `steer`, `restart`. Project counts were zero on
x-p35 and one on x-tuf; no existing thread transcript was read or mutated by
this initial inspection. Both expose Codex in their provider catalog.

The probe pins credentials to the verified process incarnation/listener;
automatic restart trust is deliberately not claimed for this development
tool. Native client reconnect remains T002 work. T3 writes 0664 runtime files
under 0775 directories on these hosts; the probe permits group writes only
after verifying a user-private primary group with no other observed primary
or supplemental members. This assumes complete Unix account/group enumeration;
non-enumerable/shared groups fail closed. T3 permissions were not changed.

At `92171adf`, all 37 focused protocol/lifecycle tests passed on each box,
zero failures/skips. Independent review additionally caught a mock handshake
bug (ID-less notifications incorrectly emitted id-null errors); a request-order
barrier regression was added and the corrected source rerun before stock-T3 use.
Probe, fake-provider and isolated lifecycle source reviews passed.

The first isolated stock-T3 launch failed safely: its bootstrap schema rejects
port 0 (positive 1..65535 required), unlike the initial fixture assumption.
Only the owned test process groups were stopped, with private evidence retained.
The harness now reserves a positive loopback port and verifies the published
owned runtime matches it. Git checkout made the synthetic executable 0775 under
the hosts' umask; only that test-owned file was normalized to 0755 before use.
No T3 executable or user runtime permissions/configuration were changed.

## Buildbox setup and checks

Both hosts are x86_64, Node 22.22.1, npm 9.2.0, Python 3.14.4, pytest 9.0.2,
Git 2.53.0, just 1.45.0 and opam 2.5.0. x-p35's selected switch is clawq-5.1
(OCaml 5.1.1, Dune 3.23.1); x-tuf's is c2c (OCaml 5.4.0, Dune 3.24.2).
The current c2c dependencies are installed. Neither host has c2c/t3/dune on its
ordinary PATH. Existing old c2c build artifacts do not constitute installation.

Candidates are transferred by Git bundle into isolated clones under
`/home/xertrov/src/c2c-t3-buildgate/.worktrees/`, with exact pinned source.
At `8afdae06`, x-p35 completed the repository Dune wrapper's full build with
`-j2`, then `just check`, exit 0, no tracked generator drift. Logs:
`/tmp/c2c-t3-build-8afdae06.log` and `/tmp/c2c-t3-check-8afdae06.log`.
This earlier check is not the final latest-source gate. No `just bi`, c2c
installation, T3 restart or full all-tests PASS has occurred.

## Frozen broker and relay integration decisions

Source: c2c at the claimed task's base `4b03b6fd`, direct source inspection.

1. Use `C2c_repo_fp.resolve_sessions_broker_root` for shared registrations.
   Reuse the fenced `C2c_host_mailbox` OCaml library directly (no subprocess
   bridge and no T3 changes), with explicit stable environment/thread/alias,
   persisted owner identity and `owner_pid=Unix.getpid()`. The helper defaults
   to parent PID for subprocess use; that default is wrong in this service.
2. Peek -> durable connector journal -> selected durable broker ACK. Existing
   `read_inbox ~assign_ids:true ~strict:true` and
   `drain_inbox_matching ~strict:true ~durable:true` provide IDs/selection.
   Prefer the existing bounded/fenced host mailbox interface instead of
   duplicating ownership transitions. Unbind preserves identity and mail.
3. Add a target-registration consumer guard: existing raw CLI guards are
   environment-based and stock T3 must remain untouched. Explicit drains by
   alias must not consume service-owned inboxes before durable acceptance.
4. The existing machine relay connector alone owns relay registration/sync.
   Its `discover_machine_broker_roots` currently misses the shared sessions
   broker; include that configured root narrowly, with canonical deduplication.
   No per-thread relay process or competing registration loop.
5. Preserve full remote reply addresses. Existing ordinary outbox forwarding
   retains a bare sender and cannot reconstruct its host at the destination.
   Decorate c2c-originated sender claims in the existing transport with the
   canonical local opaque host ID, retaining its existing bare signing identity.
   Legacy bare remote senders require explicit resolution/degradation, not a
   fabricated receiving-host suffix.

Important relay compatibility limits (not yet a deployed-relay finding):

- This source defaults new leases private, and both ordinary `/send` and
  opaque `alias@host_id` delivery require public recipients. There is no exposed
  owner publication operation despite a backend visibility setter. T006 needs
  a narrow authenticated owner publication capability for these explicitly
  advertised aliases, with a measured compatibility/deployment gate. Do not
  globally make private peers public or use relay admin credentials.
- Normal machine connector TTL requests (300 seconds) are floored by current
  relay policy to 24 hours. Retiring an alias stops local advertisement/renewal;
  remote eligibility may persist up to 24 hours after the final renewal.
  The separate ownership reservation is 360 days. No owner lease-unregister
  endpoint exists; admin/mobile unbind is not a substitute.
- Existing remote outbox does not carry ephemeral/deferrable flags or a stable
  source message ID. Freeze reject/disclose semantics rather than claiming
  end-to-end exactly-once or silently promising missing remote flags.
- Legacy relay ingress can fall back to destructive poll after peek errors;
  the unconditional persist-first guarantee requires a verified compatible
  path. The connector's own local accept-before-ACK contract remains required.

Read-only preflight found no activated relay, connector or relay service on
either buildbox. No public health/registration/send call was made. The user
has been asked which relay to use for installed services; isolated relay
fixtures can be used while that is undecided. No implicit relay activation.

Subsequent user decisions: use `https://relay.c2c.im` for the installed
services, while keeping local delivery direct. The user confirmed acceptance
means local direct plus cross-host relay, not a new direct cross-host transport.
An authorized read-only `/health` call reported relay 0.18.2, git a0b52e4,
protocol 1, production auth, private reachability consent_gated. The matching
local source has the private-default/public-send restriction, so the older
public-default compatibility escape does not apply. No registration or message
was sent to that relay. T006's publication capability needs an explicit
reviewed/tested relay rollout; no deployment has happened.

The live 83-tool inventory also includes `t3_queue_list`; source verifies it is
external-read authorized and independently pages queued work. Use it as an
additional recovery hold guard instead of relying only on 50 recent runs.

## Live behavior matrix, T3 0.1.0

On 2026-10-19 the isolated stock-T3 fixture at
`/tmp/c2c-t3-compat-6d274fc8` completed `scripts/t3-connector-matrix.mjs` on
both x-p35 and x-tuf. Server version was 0.1.0. The provider was the bundled
offline Codex fixture. No real model ran, and no user T3 process or thread was
used. Private evidence stays in each host's fixture `probe/matrix-state.json`.

Both hosts agreed:

- Availability and text-only failures are recovery-eligible and a queued
  `Continue` starts a new turn. Code-only, auth, usage, and mixed-root
  failures are not. A native child failure leaves the root completed and
  ineligible. A mixed child-plus-root failure is ineligible.
- `auto` steers the active held run. `queue` does not steer it, and the queued
  `Continue` drains only after that run completes.
- A provider retry keeps one error item id, then updates that item from
  running to failed. While the retry is still active it is not
  recovery-eligible. After the update, queued `Continue` recovers it.
- `run.interrupt` during that active retry is accepted. The run ends
  `interrupted`, T3 records `run_interrupt_request`, and recovery stays
  ineligible because the run is not `failed` (`not-failed`).
- The same command after the run has already failed is rejected: the run is
  not interruptible. A stored rejection drops the original cause, so a later
  replay must confirm with one fresh command id rather than treating every
  "previously rejected" result as unknown.
- A read/operate credential with access `auto` cannot send to a full-access
  thread. The text payload code is `runtime_mode_escalation_denied`. No run
  is created. Structured content does not carry that code.

There is no `thread.stop` command. Stop is `orchestration.dispatchCommand`
with `type: run.interrupt`, `commandId`, `threadId`, and `runId`.

## Remaining proof before closing T001

- Replay across MCP reconnect and T3 process restart, including the
  re-pair hold rule for uncertain sends.
- Concrete relay publication and retirement compatibility contract.
- Independent review and latest-source buildbox checks. No `just bi` or
  service installation yet. A real model outage was not reproduced.
