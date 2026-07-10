# Independent T0 review of the `friction-points-cn.md` inventory

Review target: `47c8f7081436d9dea994cdd732fbdb1b3a52a9e1`  
Source reviewed: `/home/xertrov/src/c2c/friction-points-cn.md` (untracked operator artifact, 2,836 lines at review time)  
Artifacts reviewed:

- `.collab/research/friction-cn-complete-inventory.md`
- `.collab/research/friction-cn-inventory-part-a.md`
- `.collab/research/friction-cn-inventory-part-b.md`
- `.collab/research/friction-cn-inventory-part-c.md`

## Verdict

**PASS.** I found no omitted source partition, broken stable-ID sequence, decisive
misclassification, or authority inversion. The artifacts are fit to serve as T0's
reviewed input to reconciliation. No inventory or code file was changed during this
review.

## IGC (independent goal check)

The T0 goal is a lossless, authority-aware source-to-evidence inventory, not an
implementation plan and not a claim that all 406 rows require distinct tasks. The
four artifacts satisfy that goal:

1. **Complete source partition:** A covers 1-966, B covers 967-1985, and C
   covers 1986-2836. These inclusive intervals are adjacent, non-overlapping,
   and total exactly 2,836 lines. Line 966 is deliberately retained as the next
   top-level heading boundary in A; B inventories its body beginning at line 967.
   The unheaded M2 tail at 1986-1990 is explicitly C001 before the next heading
   at 1994.
2. **Stable row integrity:** A001-A099 (99), B001-B250 (250), and C001-C057
   (57) are each unique and contiguous, for 406 rows total. Every A/B row has
   eight logical table columns. Every C entry has all seven named evidence
   fields.
3. **Source traceability:** I compared the report heading map and boundary text
   with all three heading self-checks, then sampled first/middle/last and
   decision-sensitive rows. Samples included A001, A039, A059, A073, A083,
   A086-A087, A099; B001, stable-row B089, stable-row B096, B173, B213, B250;
   and C001, C003, C036-C045, C047-C057. The cited headings and line regions
   matched the source.
4. **Authority discipline:** The inventory consistently applies later explicit
   Max/operator decisions over the earlier report proposal, implementation plus
   proof over historical observations, and explicit deferrals over aspirational
   roadmap wording. It does not treat a backlog `done` flag as proof that every
   clause in the original backlog body shipped.
5. **Open-work visibility:** A's six genuinely unowned open items are surfaced
   in the complete index (A039, A059, A073, A083, A086-A087); A003 is correctly
   excluded because B101 owns it. C's four `OPEN-UNCLASSIFIED` decisions are
   surfaced exactly (C040, C043, C044, C045). Part B preserves every open
   AC/test/doc/product row individually and its roll-up calls out the I002/I005
   hubs plus the source-only product/IA proposals requiring a product/coordinator
   decision. The complete index makes ownership/disposition of every partial/open
   row a mandatory reconciliation gate rather than silently declaring it closed.

## Attempted decisive criticisms

| Attempted criticism | Evidence checked | Result |
|---|---|---|
| A/B seam omits or double-counts the heading at line 966 | Source lines 956-981; A heading self-check; B scope statement and first heading row | Rejected. A records line 966 as a boundary with no normative body; B starts at 967 under that enclosing heading. No body line is omitted or overlapped. |
| B/C seam loses the M2 tail before the M3 heading | Source lines 1972-2005; B250 and B heading self-check; C001 | Rejected. B ends at 1985 and C001 owns 1986-1990; separator lines 1991-1993 lead to the M3 heading at 1994. |
| The report's repeated per-agent-key recommendation improperly outranks the later operator decision | Source lines 2013-2017, 2602-2620, and 2801-2803; I008; A061-A063; C003, C036, C041, C051, C057; complete-index authority rule | Rejected. Every sampled occurrence makes the machine Ed25519 key the trust anchor and treats optional machine-attested agent identity as the only permitted future refinement. The source mechanism is explicitly `SUPERSEDED`; the replacement remains ADR/open-deferred where appropriate. |
| Completed backlog B089 is used to claim canonical JSON is complete | B089 backlog body/status, I002, monitor implementation/docs, A029-A041, B213-B250, C001/C037/C049/C053, complete-index gate 1 | Rejected. Unified relay-aware monitoring is closed, while versioned send/monitor/poll JSON remains open under I002. The artifacts preserve both truths. |
| Completed backlog B096 is used to claim cursor/ack/delivery tracking is complete | B096 backlog body/status, `Relay_client.peek_inbox`, monitor/docs peek behavior, I004, A021/A035-A037, C019/C039, complete-index gate 2 | Rejected. Only non-destructive peek is closed. Durable server-side cursors, at-least-once semantics, delivery tracking, waits, and receipts remain explicitly deferred under I004. |
| Unowned open items disappear in aggregation | All A `OPEN` rows, all C `OPEN-UNCLASSIFIED` rows, all 96 B `OPEN` rows, per-part roll-ups, complete-index open-items section and reconciliation gates | Rejected. The six A items and four C decisions are enumerated; B's granular rows remain the canonical list and are all forced through the reconciliation ownership gate. |
| Status totals conceal row loss or table corruption | Mechanical sequence, column, field, and closure-count validators | Rejected. Counts reproduce the complete index exactly for A and B, and all 57 C entries carry all required fields. |

## Validators and receipts

The following checks ran from the slice worktree against the reviewed tip:

- `wc -l /home/xertrov/src/c2c/friction-points-cn.md` -> `2836`.
- Partition arithmetic -> `[1,966]` (966 lines), `[967,1985]` (1,019),
  `[1986,2836]` (851), sum 2,836; adjacent boundaries differ by exactly one.
- Source heading scan (`^#{1,6} `) -> 77 body headings through line 965,
  boundary heading at 966, 93 headings in B's body, and 82 headings in C's
  body. The self-checks account for those heading groups and C001 accounts for
  the unheaded tail.
- A row validator -> 99 contiguous IDs; closure totals `CLOSED 44`,
  `PARTIAL 33`, `OPEN 7`, `DEFERRED 11`, `SUPERSEDED 2`, `OBSERVATION 2`.
- B row validator -> 250 contiguous IDs; closure totals `CLOSED 62`,
  `PARTIAL 65`, `OPEN 96`, `DEFERRED 27`.
- C validator -> 57 contiguous IDs and seven required fields in every entry.
- A/B Markdown-table validator -> eight logical columns in every stable row.
- Commit provenance -> integrated A/B/C commits are ancestors of the reviewed
  tip. The B author/integrated commits have identical file blobs, as do the C
  author/integrated commits.
- `git diff --check 47c8f708^ 47c8f708` -> clean.

This is a documentation/research-only slice. No compile target changed, so a
fresh code build would not add evidence about the inventory's correctness.

## Remaining uncertainty

- The source report is intentionally untracked and the inventory does not record
  a content digest. The line-count and heading evidence above bind this PASS to
  the 2,836-line source snapshot read on 2026-07-10; a later edit to the operator
  artifact would require rerunning the inventory validators. This is an
  auditability improvement, not a current-content failure.
- Stable IDs in Part B (`B001-B250`) share the `B` prefix with backlog bug IDs
  such as backlog B089/B096. Part B's `E06 B089`/evidence-catalog convention and
  context disambiguate them, but reconciliation should preserve an explicit
  `stable row` versus `backlog item` label when referencing either namespace.
- T0 verifies capture and disposition, not the eventual deduplication quality of
  TR. The complete index correctly makes row-to-acceptance-criterion traceability
  a gate for that next phase.
