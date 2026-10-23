# P9.M2.E1.T004 independent recheck

**PASS.** The appended NAS/contact coordination requirements were explicitly
considered and satisfied for the frozen T003 candidate. The actual public-relay
proof subsequently passed; LAN/NAS evidence was not substituted for it. No
missed requirement or unsupported completion claim requiring corrective backlog
work was found within this review's scope. Corrective backlog IDs: **none**.

Reviewed on 2026-10-23 from isolated branch
`t3/review-p9-t004-public-proof`, starting at
`29506fc28b4fb368b8699f32e9d1b6771c0f979e`. T003's completion is committed in
`33f47cdd`; the subsequent `29506fc2` resolves its external blocker and records
the T004 claim. This review was performed after those commits and the final
public proof, rather than treating T004's existence as evidence of a recheck.

## Material read and exact scope

Read the complete current T003, including its **NAS dogfood follow-up** and
all subsequent validation/public-closeout entries; the complete T004; B369 and
B370; the [contact integration report](2026-10-22-p9-contact-integration-validation.md);
the [public closeout](2026-10-23-p9-public-closeout.md); and the linked
[final public receipt](2026-10-23-p9-public-t3-proof.json).
Also inspected the original draft, integration commits, relevant frozen source,
preserved drivers, original local metadata receipts, and the separately scoped
I016/Hermes follow-ups.

- Installed implementation reviewed:
  `b8c42376ea8363891f7b2249e4056d7ebf4b53c8`.
- Its Git tree, independently resolved:
  `e7750255ed766aeb7b61a015c4c0c3576333642d`.
- Public relay deployment recorded in the proof:
  `80c7f35a42cbdd90164acbbd8bdad9f8a7840069`.
  Git ancestry confirms it contains b8; it is a different candidate, not an
  alternative name for the installed tree.
- Final public run: `19ba9f809e3149f7b14d2380`, completed
  `2026-10-23T01:41:35Z` against `https://relay.c2c.im`.

This was a local, read-only evidence investigation followed by this one receipt
and its commit. No builds, test executions, remote operations, agent messages,
delegation, installs, pushes, or backlog/code edits were performed. Receipt
hashing and metadata comparisons do not constitute a fresh execution of the
historical host proofs or a current production-health observation.

## Appended note, serial integration, and draft reuse

The appended note explicitly separates generic B369/B370 work from T003,
names draft `3513ca6c`, requires one serial lane for shared CLI/connector files,
requires new exact-source validation for changed code, and forbids replacing
the required public proof with the NAS fixture. The execution entries in both
bugs and T003 address those instructions directly. The preserved
`/home/xertrov/.cache/c2c/p9/contact-integration-handoff.md` independently names
the single `fix/p9-contact-integration` worktree and draft reuse.

Git history corroborates that record:

1. Draft `3513ca6c244a9c777143735bbb577504018f6a58` adds explicit HTTPS contact
   delivery, its native TLS script and the original gap assessment. Integrated
   commit `93a5c8a3fe4705a2cc1745cb63eb1018c8b6c64a` has an identical binary
   patch SHA-256,
   `d23aa136629e66787272ae26a57f61be1192b8329a8d1d0ae6fc4159257a3921`,
   and identical resulting blobs for all three changed files. The draft was
   reused, not ignored or independently duplicated.
2. `e571bc7a` integrates protected contact selection/storage and explicit server
   and client LAN HTTP policy across the shared send/connector paths.
3. `c83cd675`, `c6ccb646`, and `666dc355` then isolate versioned outbox intents
   from legacy consumers, scope migration/conflict handling and delimiters, and
   preserve independent delivery/dedupe namespaces. `f500eb55` and final
   `b8c42376` correct validation fixtures. All are included in the frozen gate
   candidate's linear integration history.

Frozen source inspection agrees: `Relay_contact_send.dispatch` selects the
contact endpoint, signs the exact request, checks destination-binding support,
and requires per-grant HTTP consent. `relay.ml` preserves authenticated,
sender-bound grant admission and the server's independent explicit transport
exception. `C2c_relay_connector.append_outbox_entry` pins route/grant/message ID
before queue visibility; its send path uses the shared dispatcher and retains
denied contact mail. Normal CLI and MCP sends enter the shared broker/outbox
path. This is more than the original explicit-only draft.

Thus B369's transport policy and B370's generic grant-aware sending actually
landed before b8 validation, including the review fixes. Both bugs are done in
the reviewed backlog after their two-host and NAS proofs. There is no identified
pending B369/B370 implementation requirement to impose on T004.

## Original exact-source receipts retained

Read the original files under `/home/xertrov/.cache/c2c/p9/`, with prefix
`b8c42376-{x-p35,x-tuf}-` and suffixes `pass.json`, `installed.json`,
`native-service-proof.json`, `dispatcher-fault-proof.json`,
`restart-direct-proof.json`, and `summary-proof.json`.

The original manifest SHA-256 values are unchanged:

- x-p35: `74fb49d19b65b13252960a4d410a10a6bbb80cfbb2dfdb646afc738b6bd0bbd7`.
- x-tuf: `6d41049eb323c48e1559d1432f1651b91029e4f044401a0af3766d89ee515c82`.

Both identify the exact b8 commit/tree and record six commands with exit 0:
`just build`, `just check`, `just test`, the forced repository-wide `@runtest`,
explicit eight-artifact/fault-harness build, and source-pinned contact CLI/MCP
integration. Their completion times precede the installation receipts. The
integration report records 225 suite summaries/4,523 forced tests per host;
this review did not rerun or independently recount remote test logs.

All eight manifest artifact hashes agree with the public preflight's complete
artifact map, and their names agree with the original installation receipts.
Recorded running connector/relay CLI hashes and each native/fault/direct proof
agree with the appropriate manifest CLI:

- x-p35: `ee4cfc9a19deb9f3757fa412d8ba5824f0731784dd80be28856b0ee0f6a5a553`.
- x-tuf: `fa4f7a728fc38c9fe430eb00a6b89d23935f2be0bebf9a10bc949311def13b91`.

Public-receipt references to both installation receipts and all six historical
native/fault/direct files match their actual local SHA-256 values. Each native
proof records PASS and completed cleanup. They retain the nominal recovery,
hold, permission, retirement, response-loss/credential-fence, shared-spacing,
race, and direct-routing evidence; those cases are not inferred from NAS or
from the faster public fixture interval.

Changing source or generated artifacts requires a new candidate's full gate
before another guarded installation. Prior 1b3c3151/45573733 receipts were not
relabeled for the contact integration. Likewise the b8 receipts certify b8,
not later Hermes/host/MCP changes. The deployed descendant's relay
and T3 connector implementation paths inspected here are unchanged from b8,
but other source/generated paths differ; this is not a whole-tree gate for
80c7f35a or current HEAD.

## LAN/NAS evidence and its boundaries

`b8c42376-two-host-contact-r12.json` has SHA-256
`61222986f8b3d0ce286e52f29de247bbfaeb2105a908d564143f4ec07d25e591`.
Its source, both original manifest hashes and all eight host artifact hashes
match the preserved originals. Its actor/driver hashes match the preserved
scripts. It records actual x-p35/x-tuf contact sends and separate reverse-grant
replies, wrong-sender denial, rotation/revocation, response loss and restarts:
21 signed contact requests, eight admissions/effects, four duplicate receipts,
two admitted response losses and two relay restarts. It records zero legacy
send attempts/rate limits and successful cleanup/stability on both hosts.

Read `b8c42376-debian-package.json`, `b8c42376-nas-test-receipt.json`,
`b8c42376-nas-parent-verification.json`, both NAS service snapshots and
`b8c42376-nas-canary-receipt.md`. The separate Debian artifact
`c7b3b9d617885721e92c0602e1fb8c3fde27a9f54fe4c0dd9ecd39bfbc98263d`
links packaging, running NAS binary and the 13-check canary; it does not replace
either original buildbox artifact manifest. The NAS test receipt's actual hash
matches its parent verification. Service snapshots retain authenticated policy
while showing explicit HTTP opt-in, disclosure and `production_claims: false`.
Parent verification records unchanged production30434 identity/image/start.

The completed canary used xsm as client and NAS30435 as server, not an
x-p35-to-NAS actor pair. It does not prove MCP, TLS, response loss, Hermes wake,
or public T3 behavior. Its parent receipt explicitly says `publicT3Proved: false`;
the LAN receipt explicitly excludes replacing `P9-public-relay-T3`.

## Final public evidence independently checked

The committed public JSON is byte-identical to the preserved original at
`/home/xertrov/.cache/c2c/p9/public-proof-b8-20261023/p9-public-t3-proof-19ba9f809e3149f7b14d2380-receipt.json`.
Its SHA-256 is
`ad879af26072408e646dc2a2ef1199c6ce1478f03f3102fabf6ff84eb4329b3d`.
The preserved coordinator and actor hashes match both the JSON and closeout:
`74542a1a6adba25aa4893eaa0c120226efb80fe63ebf8e665ce24e0268f78361`
and `5f14890a7ddd67f665654d81a573977dfcb5ed0b1770e269a0346e1a0bd09f01`.

Read the driver assertions as well as the result. They enforce the public URL,
the compatible deployed health hash, authenticated defaults, exact original
six-gate manifests, clean b8 sources and all eight built/installed hashes before
setup. They also require native/provider delivery evidence, complete final
nonce/history/queue audits and successful owned cleanup before writing PASS.

The receipt contains eight delivery/reply legs: both directions for idle,
active, owned service restart and owned T3 restart. All eight have `agent/mcp`
attribution, canonical remote footer and matching send/provider nonce evidence.
Active legs retain the native run and record `turn/steer`; idle/restart legs
record `turn/start`. All eight canonical replies arrived once, and sixteen
duplicate ACKs preserve the original IDs (including the relay-returned IDs).
Each final host audit has four matching deliveries, four replies, one restart
of each owned component, two complete target histories, 16 audited owned nonces,
empty queues, unchanged foreign services and unchanged source/artifacts.

Both hosts record owned service/fixture shutdown, public withdrawal and private
root removal; `cleanupCompleted` is true. Public relay leases/reservations were
not erased: `relayLeaseDeleted` is false, with TTL retention explicitly recorded.
Earlier failed attempts and the documented process-free older scratch root are
not represented as part of this final run's successful cleanup.

The standalone JSON deliberately retains `closesT003: false`: it supplies the
public slice, while the closeout and committed T003 completion combine it with
the exact-binary native/install/direct/fault evidence. This is consistent with
the claimed completion and does not substitute public results for the earlier
recovery matrix or substitute earlier private relays for the public gate.

## Remaining scope and disposition

Limitations remain explicit: stock T3 0.1.1 and a synthetic provider,
driver-executed canonical replies, no real model-outage reproduction, no failed
root retaining a live approval, and two readiness holds in headless repair.
Installed systemd readiness is separate evidence. The public fixture used a
two-second service interval with recovery disabled; nominal 60-second recovery
and one-second shared dispatch spacing come from the original b8 native proofs.
No model comprehension, autonomous reply, unlimited exactly-once, power-loss,
future-T3-release or live-user-service-uptime guarantee is inferred.

Hermes existing-session/gateway wake and targeting were expressly outside
B369/B370's grant-client completion and remained unverified by b8. I016 is a
separate pending research record; subsequent B371-B376 fixes and embedded-plugin
changes belong to later candidates, as do B377's host namespace changes. B378
is currently reopened/in progress for required live TUI/CLI rendering validation.
Those records are not new corrective IDs from this review and do not invalidate
the historical b8 evidence. Their implementation/live validation must retain
their own candidate and evidence scope.

**Disposition: PASS for P9.M2.E1.T004.** No corrective backlog item is requested
from the parent. This receipt leaves T003 history and all backlog state intact;
the parent owns any task closeout.
