# Independent review of the friction report reconciliation

Date: 2026-07-10  
Review range: `c8d5e7c9..788ab68b`  
Source snapshot: `/home/xertrov/src/c2c/friction-points-cn.md`, 2,836 lines,
SHA-256 `26ac721bc2740ff86d14f25e650ba3c9dc20c46e9d6a92b71988ab2ae18c3718`

## Verdict

**FAIL, with two decisive and one consistency correction required.**

The reconciliation gets the difficult authority decisions right: it preserves
the I003/I004/I007/I008 deferrals, splits stale I006, keeps cursor/ack work out
of B096/H0, and legitimately selects strict host-local approval for B098. T1
and T3 are acceptable inputs, and T2 becomes an acceptable input after the
reconciliation applies its cursor/ack correction and the recorded B098
decision.

The current artifact nevertheless does not yet satisfy its own promise that
every non-closed T0 row has bounded ownership or an explicit disposition. It
also sends independently parallel slices into a concrete shared test-manifest
ownership collision. These are handoff defects, not objections to the product
or security direction.

## Decisive criticisms

### R1 — seven non-closed inventory rows have no bounded owner or explicit disposition

The coarse “Complete 406-row coverage ledger” mechanically covers all 406 IDs,
but that ledger only assigns broad topic clusters. Comparing the T0 rows whose
closure is not `CLOSED`, `OBSERVATION`, `SUPERSEDED`, `CONSTRAINT`, or
`BOUNDARY` against the bounded-slice table plus authority-disposition table
leaves seven rows absent:

| Row | Missing reconciliation | Required correction |
|---|---|---|
| B071 | Working, honest bridge retains production/two-host live proof. | Attach to F5d or D1 with an explicit connector-mode two-host receipt. |
| B076 | CI command argument-parsing coverage remains partial. | Give a named slice the per-command parse matrix, or explicitly disposition it as an ongoing gate with an owner. |
| B077 | CI command exit-code coverage remains partial. | Give a named slice the success/failure exit matrix. |
| B183 | Every relay error must exit non-zero. | Expand F5b (or a separate relay-command audit slice) from selected P0 failures to an explicit command-wide exit matrix. |
| B184 | Every relay error needs a clear human message. | Pair the exit matrix with a failure-message snapshot/catalog owner. |
| B210 | Full connector failure regression remains partial. | Map explicitly to F5b/F5d and retain the full process-boundary regression. |
| C046 | ADR/decision sequencing remains partial. | Own a decision ledger/ADR-link gate before irreversible protocol slices; do not leave it only implicit in the dependency graph. |

F5b/F5d prose is close to covering B071/B210 and portions of B077/B183/B184,
but the current scope is a selected P0 adverse matrix, not the command-wide
parse/exit/message matrices those rows require. The omission is therefore not
just a missing row label: B076 and the global extent of B077/B183/B184 have no
clear acceptance owner.

Validator result: 285 non-closed/non-boundary T0 rows; 278 occur in the bounded
slice or explicit disposition sections; the seven above do not. The separate
coarse ledger covers 406/406, so source capture is intact while actionable
ownership is incomplete.

### R2 — the parallel start set has concrete overlapping test ownership

J1 and F5a are both declared independent and in the immediate parallel start
set. Their reviewed T3 file boundaries both require `ocaml/test/dune`: J1 adds
the schema test executable/module and F5a adds the reusable relay-test support.
The reconciliation shortens those boundaries but does not remove the manifest
work. H0's new signed HTTP ownership coverage may also need the same relay HTTP
test executable/manifest surface.

This violates the stated owned-file boundary and makes parallel cherry-pick
order, rather than the plan, decide the shared manifest result. Correct by one
of:

1. sequencing F5a after J1 (or vice versa);
2. assigning exclusive manifest ownership to one integration slice while the
   other commits source/test modules without manifest registration; or
3. naming disjoint existing executables and exact manifest hunks, with an
   explicit integration owner.

The same risk is under-specified for H4/H5/H6, whose “focused/new tests” are
likely to converge on `ocaml/test/test_c2c_cli.ml` unless exclusive new test
files are named. That secondary risk should be clarified while correcting the
proven J1/F5a collision.

### R3 — the B098 finding still reports a blocker that HEAD resolves

`.collab/findings/2026-07-10T03-55-57Z-remote-supervisor-approval-contract-mismatch.md`
says the fix is blocked on authority and that neither outcome may be selected.
The later decision record and reconciliation explicitly select strict local
approval and unblock H1. Preserve the discovery history, but add a dated status
note/link to `friction-cn-b098-decision.md` so the six current findings do not
contradict the handoff state.

## Attempted decisive criticisms that did not succeed

### 406-row source capture

Rejected. The source hash matches the inventory worktree copy. A/B/C sequences
are contiguous at A001-A099, B001-B250, and C001-C057. The reconciliation's
coarse ledger expands to exactly 406 unique IDs with no omission. R1 concerns
the stronger ownership/disposition gate, not source loss.

### B098 authority precedence

Rejected. The direct operator request is to make this report completely
addressed. The report repeatedly requires local-operator-only approval and
calls relay-reachable approval a critical escalation; backlog B098 repeats that
contract at critical priority. The configured-supervisor inbox fallback is a
later implementation that failed the accepted contract, not authority to
weaken it. Selecting strict host-local verdict-file/CLI resolution is therefore
legitimate. The coordinator should be described as recording/applying the
operator-backed contract, not as independently creating authority.

H1's required proof is appropriately strong: configured and unconfigured peer
DMs, exact token/verdict text, relay-form senders, empty/no binding, and the
host-local success path. F5b retains the process-level regression.

### Accidental activation of I003/I004/I007/I008

Rejected.

- H0 closes only the peek authorization defect; cursor, ack, independent
  progress, waits, receipts, and push remain I004-deferred.
- H2a-H2c finish the already accepted B099 safety-framing subset. They do not
  add trust tiers, schema-generated cross-harness tools, `c2c env --json`, or a
  unified hook contract, so they do not activate I003 or I007.
- H6 distinguishes current identity kinds and tests relay merging without
  inventing attestation or verified-agent semantics, so I008 remains deferred.
- J1 explicitly reserves trust/identity/receipt fields for later schema
  versions.

### Stale I006 handling

Rejected. Authenticated `list --relay` contradicts I006's original
unknown-peer-discovery premise. The reconciliation correctly supersedes that
premise, leaves bare-alias uniqueness/ambiguity deferred, moves address cards
behind I008/I003, and requires a product/abuse ADR for broader directory and
federation behavior. It does not dispatch an I006-labelled implementation.

### T1/T2/T3 input acceptance

Accepted with the following precise interpretation:

- **T1:** acceptable as-is; its 4 PASS / 3 PARTIAL / 1 FAIL result is supported
  by current source and recorded focused/live evidence.
- **T2:** the original audit is not independently authoritative. Its factual
  peek, B099, discovery, and B100 findings are acceptable only through the TR
  transform: H0 isolates peek authorization; durable cursors/acks remain I004;
  the separate B098 decision selects strict local approval. With those two
  corrections applied, T2 is fit as reconciliation input.
- **T3:** acceptable after the same B098 decision and the explicit I006 split;
  its B101/I002/I005 start set and deferrals remain sound.

The historical `friction-cn-audits-review.md` can retain “T2 FAIL pending
reconciliation” because the pending corrections now exist outside it. A short
cross-link would improve navigation but is not itself decisive.

### Six finding documents

Their technical findings were corroborated against current source:

- signed poll enforces session ownership while signed peek discards verified
  identity;
- the approval inbox fallback accepts configured supervisors, including remote
  peers;
- monitor defaults connector-incompatible keys and converts error-shaped
  responses to empty message batches;
- doctor equates generic reachability with subscribe capability and uses
  machine-global process discovery;
- status labels the local alias `registered` without relay truth;
- common/client renderers do not enforce one hostile-content-safe authority
  boundary.

Only R3's fix-status drift needs correction.

## Tests, docs, and live-proof assessment

The named H/F/J/D slices generally specify proportionate focused tests, docs,
and live proof. In particular, the security slices include victim/attacker and
hostile-content vectors; adapter activation includes tmux proof; monitor and
doctor include public-HTTPS evidence; D1 requires a current two-host receipt;
and the completion gate requires peer-PASS plus in-worktree build receipts.

The missing proof is concentrated in R1: no named owner currently guarantees
the command-wide parse/exit/message matrices or explicitly preserves B071 and
B210's full connector live/process receipts. F5d also remains correctly blocked
on a named live-test owner and secrets/flakiness policy; the report cannot be
called completely addressed until that blocker is resolved and the retained
receipt exists.

## Validators and receipts

- `sha256sum` on the main and T0 copies of `friction-points-cn.md` produced the
  same digest shown above; `wc -l` is 2,836.
- Mechanical range expansion: coarse reconciliation ledger = 406/406 unique
stable IDs; bounded slices + dispositions miss the seven non-closed rows in
  R1.
- Direct review of all three T0 inventory parts, their independent review, T1,
  T2, T3, the TR audits review, the reconciliation, the B098 decision, and all
  six findings.
- Direct source checks of relay poll/peek routing, approval trust/await paths,
  monitor extraction/key selection, doctor capability/process checks,
  relay-state rendering, and common envelope rendering.
- Full backlog bodies for B098 and I003/I004/I006/I007/I008.
- `git diff --check c8d5e7c9..788ab68b` passed.

No code changed in this range, so a build would not validate the research
mapping. Recorded T1-T3 builds/focused/live receipts were assessed as evidence;
this review did not rerun production-relay or tmux scenarios.

## Remaining uncertainty

- The source report is outside this review branch at the reviewed tip. The
  operator has since allowed it to be committed; adding the exact hashed
  snapshot will make the evidence chain durable and remove reliance on an
  absolute path.
- The security severity labels are advisory as the reconciliation says; this
  review validates the defects and ordering, not a formal threat-model score.
- H2c and F5d still need named cross-repo/live owners before dispatch. That is
  explicitly visible and is not an additional hidden failure.

After R1, R2, and R3 are corrected, this reconciliation is otherwise suitable
for implementation dispatch and re-review.
