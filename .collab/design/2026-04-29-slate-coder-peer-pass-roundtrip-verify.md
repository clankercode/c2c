# DESIGN: `c2c peer-pass roundtrip-verify` — chain-of-custody across cherry-pick (#427-followup)

**Author**: slate-coder
**Date**: 2026-04-29
**Status**: draft / proposal
**Related**: SPEC-signed-peer-pass.md, #427b (`build_exit_code`), #172 (signed artifact),
H1/H2/H2b broker enforcement (already shipped — see SPEC §"Broker-side enforcement")
**References**: `ocaml/peer_review.ml:17-46` (record), `:82-104` (canonical JSON),
`:109-112` (canonical-for-signing), `:153-158` (sign), `:180-194` (verify),
`:284-308` (artifact_path)

---

## 1. Problem

The signed peer-PASS artifact (#172) binds a reviewer's Ed25519 signature to
`(reviewer, reviewer_pk, sha, verdict, criteria_checked, skill_version,
commit_range, targets_built, notes, ts [, build_exit_code])` — see
`peer_review.ml:82-104`. The `sha` field (`peer_review.ml:20`, `:87`) is the
**commit SHA** of the slice-branch commit the reviewer built and inspected.

The c2c git workflow (CLAUDE.md §"Git workflow") routes every slice through
**coordinator-driven cherry-pick** onto `origin/master`. When the coord runs
`git cherry-pick X`, git replays the patch onto a different parent than the
slice branch had — so the resulting commit's SHA is **Y ≠ X**, even when the
patch applies cleanly. The signed artifact at
`<broker_root>/peer-passes/<X>-<reviewer>.json` (`peer_review.ml:284-308`)
references `X`, not `Y`.

After cherry-pick, three observable states exist:

1. The slice branch (ephemeral, GC'd by `c2c worktree gc` once landed) — SHA `X`.
2. The peer-pass artifact on disk — references `X`, signed bytes locked to `X`.
3. `origin/master` HEAD — SHA `Y`, no peer-pass artifact.

A later auditor running `c2c peer-pass verify Y` finds **no artifact**. They
can find the `X` artifact (via reflog, the worktree, or a coord ledger), but
its `sha` field doesn't match `Y`. The signature verifies for `X`, but does
that say anything about `Y`'s safety?

The threat surface a roundtrip-verify path needs to close:

- **Rubber-stamp**: coord cherry-picks an unreviewed commit and claims it was
  reviewed because "we have artifacts in the directory".
- **Cherry-pick mutation**: coord cherry-picks `X` but resolves a conflict in
  a way that introduces a malicious diff into `Y` — the patch genuinely
  changed during replay.
- **Stale-evidence drift**: months later, an auditor wants to know which
  `origin/master` commits had real peer review. With no link `Y → X`, they
  can't tell.

## 2. Options for chain-of-custody

### (a) Tree-hash artifact

Sign over the **git tree hash** (the SHA-1 of the staged tree the commit
points to) instead of the commit SHA. Cherry-pick of a clean patch onto a
parent that already contains the upstream changes produces the *same tree
hash* — `git ls-tree X` and `git ls-tree Y` are bytewise identical.

Pros: artifact verifies against `Y` for free; no new wire format beyond
adding a `tree_sha` field. Composes with the existing v2 schema as another
additive bump.

Cons: tree hash is **invariant only when there's no conflict**. Any
non-trivial cherry-pick (semantic merge of two parallel slices touching the
same file) produces a different tree, and tree-hash equivalence collapses to
"identical patch + identical base", which the coord's `git diff X..Y` already
proves more cheaply. Worse, a malicious coord could cherry-pick `X` into a
branch with a *crafted parent* whose pre-existing diff makes `Y`'s tree
match `X`'s tree while smuggling unwanted semantics. Tree-hash equivalence
is necessary but **not sufficient** for "Y is the patch the reviewer
approved".

### (b) Coord-side counter-signature

When the coord cherry-picks `X` and the result is `Y`, they emit a
**counter-signature** artifact: their own signed claim that "I, coord, took
artifact-for-`X` (signed by reviewer R), cherry-picked it onto master, and
the result is `Y`. The patch from `Y^..Y` matches the patch from `X^..X`
modulo conflict resolution, which I attest to."

The counter-signature is a separate, smaller artifact:

```json
{
  "version": 1,
  "kind": "peer-pass-cherry-pick",
  "coord": "<alias>",
  "coord_pk": "<base64url-ed25519-pk>",
  "source_sha": "X",
  "landed_sha": "Y",
  "patch_id_source": "<git patch-id of X>",
  "patch_id_landed": "<git patch-id of Y>",
  "patch_match": "exact" | "conflict-resolved",
  "underlying_artifact_sha256": "<sha256 of X-artifact JSON bytes>",
  "underlying_reviewer": "<R alias>",
  "underlying_reviewer_pk": "<base64url-ed25519-pk>",
  "ts": <epoch>,
  "signature": "<base64url-ed25519>"
}
```

Stored at `<broker_root>/peer-passes/<Y>-<coord>.cherry-pick.json` (the
distinct `.cherry-pick.json` suffix keeps it from colliding with a peer-pass
on the same SHA the coord may also have signed for review).

`c2c peer-pass roundtrip-verify Y` then:

1. Loads `<Y>-*.cherry-pick.json` (any coord may have signed; pick the most
   recent or the one whose `coord` matches the swarm's coord-alias config).
2. Verifies its signature against `coord_pk`, and verifies `coord_pk` against
   the broker pin store (same H2b mechanism used for peer-pass DMs —
   `verify_claim_with_pin`).
3. Reads `underlying_artifact_sha256`, locates the `X` artifact under that
   hash (or by `(source_sha, underlying_reviewer)`), verifies *its*
   signature with `underlying_reviewer_pk` (also TOFU-pinned).
4. Recomputes `git patch-id` for `Y` and `X`; checks `patch_id_landed`
   matches the recomputed value. If `patch_match = "exact"`, also checks
   `patch_id_source == patch_id_landed`.
5. Returns OK only if both signatures verify and patch-ids match the claim.

Pros: explicit chain. Two-key-compromise required to forge (reviewer R *and*
coord). Conflict-resolved cherry-picks remain expressible — the coord
acknowledges in `patch_match` that they had to do work. Auditors see exactly
who signed for what.

Cons: more wire surface, second pin store entry per coord, requires coord
infrastructure (`c2c peer-pass cosign Y --from X`) that doesn't exist yet.

### (c) Status quo — artifact is informational

Keep `X`'s artifact as the single source of truth for "review happened".
After cherry-pick, the coord's responsibility is to verify `git diff X..Y`
is empty (or sign off on the conflict) before pushing. Any post-hoc
`c2c peer-pass verify Y` is just a re-build — re-run the build, re-run the
review checklist on `Y` directly, ignore `X`'s artifact entirely.

Pros: zero wire-format change. Matches what the swarm actually does today.

Cons: the audit trail is verbal ("coordinator1 said the cherry-pick was
clean"). Doesn't survive coord rotation. Doesn't help a future reader of
master-history understand which commits had review.

## 3. Recommendation

**Adopt (b) — coord counter-signature** with **(a)'s `tree_sha` field added
to the underlying artifact as a free defence-in-depth check**.

Justification against the threat model:

- **Rubber-stamp**: (a) alone doesn't help — a tree-hash check passes
  trivially if the coord re-applies the same patch. (b) forces the coord to
  produce a signed statement; rubber-stamping is now a **signed lie**,
  attributable, and pinnable. (c) leaves rubber-stamping invisible.
- **Cherry-pick mutation**: (a) catches *some* cases (tree changed) but
  can be fooled by parent-crafting. (b) catches all cases that change the
  patch-id, which is the closest cheap proxy for "is this still the same
  patch" git provides. (c) catches nothing post-hoc.
- **Fragility / cost**: (a) is cheapest but insufficient. (b) is one extra
  signed file per landed slice — same order as the artifact itself, well
  under the 64 KiB cap (SPEC §"Artifact Size Cap"). (c) is free but
  forecloses future audit work.

The threat-model cost-benefit favours (b). (a) becomes a sub-feature: add
`tree_sha` to v3 of the underlying artifact so the counter-signature can
*also* assert tree-equivalence cheaply when no conflict was resolved.

## 4. Wire shape (option b, formal)

**File**: `<broker_root>/peer-passes/<Y>-<coord>.cherry-pick.json`
(new path-component: the validator at `peer_review.ml:215-272` extends with
a `kind` discriminator instead of a separate filename, OR — preferred — a
new `validate_cosign_path_components` mirroring the existing one with the
`.cherry-pick.json` suffix encoded in the writer, never the alias).

**Schema**: as in §2(b).

**When emitted**: `c2c peer-pass cosign --source X --landed Y` invoked by
the coord *after* the cherry-pick lands locally and *before* the push to
`origin/master`. Wired into the `c2c doctor` push-readiness check (CLAUDE.md
§"Push only when you actually need to deploy") so a missing cosign for an
about-to-push commit FAILs the gate.

**When verified**: `c2c peer-pass roundtrip-verify Y` (new subcommand);
called by the pre-merge git hook (#171) after the existing per-commit
artifact lookup; called by `c2c doctor` for the last N commits on master.

**Signing target**: canonical JSON with the same field-sort + UTF-8 bytes
discipline as the underlying artifact (`peer_review.ml:109-112`); reuse
`Relay_identity.sign` / `verify`.

**Pin enforcement**: identical to H2b for peer-pass — `verify_claim_with_pin`
is generalised (or a sibling `verify_cosign_with_pin` is added) to TOFU-pin
`coord_pk` under the coord's alias. A `Pin_mismatch` rejects with the same
broker-log discipline as today (SPEC §"Broker-side enforcement").

## 5. Backward-compat / schema versioning

- The **underlying** peer-pass artifact stays at v2 unless we add `tree_sha`
  — in which case bump to **v3**, additive: v3 canonical adds `tree_sha`
  between `commit_range` and `targets_built` (sorted lexically by the
  existing `sort_assoc` at `peer_review.ml:104`). v2 readers who don't know
  about `tree_sha` still verify v2 artifacts; v3 readers reproduce the
  matching canonical (with or without the field) before verifying — same
  pattern as v1→v2 (SPEC §"Schema versioning").
- The **counter-signature** is a new artifact `kind`; it carries its own
  `version: 1` and is independent of the underlying artifact's version.
  Coord using cosign v1 can sign over a v2 *or* v3 underlying artifact;
  the `underlying_artifact_sha256` field locks them together cryptographically
  regardless of underlying version.
- CLI default stays v1/v2-emit for `c2c peer-pass sign` (no behaviour
  change for current reviewers). `c2c peer-pass cosign` is a new opt-in
  surface; `roundtrip-verify` falls back to "verify just the underlying
  artifact, warn that no cosign exists" when the cosign file is absent —
  preserving the current workflow during rollout.

## 6. Out of scope

- Full Merkle-tree-of-cherry-picks (chains of cosigns when a slice is
  rebased multiple times before landing). The single source→landed pair
  is the v1 wire shape; chains can be modelled as multiple cosigns later.
- Multi-coord co-signing (M-of-N coord approval). Today there's one
  coord-of-record (CLAUDE.md §"Coordinator failover protocol"); multi-coord
  is a v2 feature.
- Push-to-remote signing / signed git tags. The cosign lives in
  `<broker_root>/peer-passes/`, not in git history. A future SPEC can
  promote cosigns into signed-tag form once the broker→git bridge exists.
- Time-window / freshness checks beyond the existing `ts` (SPEC §
  "Verification" item 5 — still NOT YET IMPLEMENTED).

---

## Summary checklist

- [ ] add `tree_sha` to v3 underlying artifact (additive, optional)
- [ ] new `peer_pass_cosign` record + canonical JSON in `peer_review.ml`
- [ ] `c2c peer-pass cosign --source X --landed Y` CLI
- [ ] `c2c peer-pass roundtrip-verify Y` CLI
- [ ] `c2c doctor` integration: missing cosign on push-ready commit → FAIL
- [ ] pre-merge hook (#171) consults cosign before allowing push
- [ ] cosign TOFU pin enforcement at broker boundary (mirror H2b)
- [ ] runbook update: coord workflow gains a `cosign` step before push
