# SPEC: Signed Peer-PASS Artifact (#172)

## Status
implemented
**Shipped:** SHAs a4eb88b (broker verify), 9983943 (anti-cheat), dacc2b7 (--warn-only), a5c05ad (self-pass detector)

## Background
Peer review currently produces an unsigned verdict (PASS/FAIL) with no cryptographic
binding to the reviewer's identity or the commit under review. We need a signed artifact
so that:
- Coordinators can verify a PASS came from a real peer with a valid c2c identity
- Pre-merge git hooks can validate peer review before accepting
- Audit trail is self-contained and replayable

## Design Decision
Reuse existing per-alias Ed25519 identity infrastructure (`Relay_identity` module) rather
than minting new keys. The same keys used for relay end-to-end encryption sign review
artifacts.

## Artifact Schema

```json
{
  "version": 1,
  "reviewer": "<alias>",
  "reviewer_pk": "<base64url-ed25519-public-key>",
  "sha": "<git-sha-of-reviewed-commit>",
  "verdict": "PASS" | "FAIL",
  "criteria_checked": [
    "<criterion-1>",
    "<criterion-2>"
  ],
  "skill_version": "<semver-of-review-skill-used>",
  "commit_range": "<base-sha>..<head-sha>",
  "targets_built": {
    "c2c": true,
    "c2c_mcp_server": true,
    "c2c_inbox_hook": false
  },
  "notes": "<free-text>",
  "signature": "<base64url-ed25519-signature>",
  "ts": "<unix-epoch-float>"
}
```

### Field Semantics

| Field | Required | Description |
|-------|----------|-------------|
| `version` | yes | Schema version; currently 1 |
| `reviewer` | yes | Alias of reviewing agent |
| `reviewer_pk` | yes | base64url-encoded 32-byte Ed25519 public key (self-contained, no registry lookup needed) |
| `sha` | yes | The specific commit SHA under review |
| `verdict` | yes | `PASS` or `FAIL` |
| `criteria_checked` | yes | Structured list of acceptance criteria evaluated |
| `skill_version` | yes | Version of `review-and-fix` skill used (from skill file) |
| `commit_range` | yes | `base..head` range the review covered |
| `targets_built` | yes | Which of the 3 binaries were compiled successfully |
| `notes` | no | Free-text summary (may be empty string) |
| `signature` | yes | base64url-encoded 64-byte Ed25519 signature over canonical JSON |
| `ts` | yes | Unix epoch timestamp at time of signing |

## Signature Computation

1. Embed `reviewer_pk` (base64url of the reviewer's Ed25519 public key) in the artifact
2. Serialize artifact to JSON **without** the `signature` field (canonical field order: version, reviewer, reviewer_pk, sha, verdict, criteria_checked, skill_version, commit_range, targets_built, notes, ts)
3. Sign the UTF-8 bytes of that JSON string using `Relay_identity.sign` with the reviewer's private key
4. Base64url-encode the 64-byte raw signature and embed as `signature`

## Verification

1. Parse JSON, extract `signature` and `reviewer_pk`
2. Base64url-decode both `signature` (must be 64 bytes) and `reviewer_pk` (must be 32 bytes)
3. Re-serialize WITHOUT `signature` field in canonical field order
4. Call `Relay_identity.verify ~pk:pk_bytes ~msg:canonical ~sig_:sig_bytes`
5. Check `ts` is not too old (e.g., not older than 30 days) — NOT YET IMPLEMENTED

## Artifact Size Cap (#56)

Peer-pass artifacts on disk MUST NOT exceed `peer_pass_max_artifact_bytes`
(64 KiB = 65536 bytes). Real artifacts are well under 2 KB; the cap is
purely a defense against an OOM/DoS where a malicious or accidentally
huge file lives at `<repo>/.c2c/peer-passes/<sha>-<alias>.json` and a
reader (broker `verify_claim` or CLI `c2c peer-pass verify`) tries to
slurp it whole.

Both code paths funnel through `Peer_review.read_artifact_capped : path ->
(string, [> \`Too_large of int | \`Read_error of string]) result`, which
stats the file first and refuses if `st_size >
peer_pass_max_artifact_bytes`. On the broker path, an oversized artifact
surfaces as `Claim_invalid` with reason text `"artifact exceeds size cap
(<sz> bytes > <cap>)"` so it flows through the existing peer-pass reject
machinery. On the CLI verify path, oversize prints to stderr and exits 1.

If a future legitimate artifact ever needs more than 64 KiB, bump the
constant in `ocaml/peer_review.ml` and update this section.

## Git Hook Integration (#171)

A pre-merge hook at `githooks/pre-commit` (installed by `c2c install`) verifies that for
each commit in the push, there exists a signed PASS artifact signed by a known peer,
OR the commit is flagged as `no-review-needed` (e.g., docs-only, rollback).

Hook checks:
1. List commits in push range
2. For each commit, look for `.<sha>.peer-pass.json` in a `.peer-reviews/` directory at repo root
3. If found, verify signature using the reviewer's public key from relay identity registry
4. If no artifact found, fail the push unless `no-review-needed` label present

The `.peer-reviews/` directory is local to the worktree (not committed to the repo).

## Skill Version Acquisition

The `review-and-fix` skill version is read from the skill file header at:
```
~/.claude/skills/review-and-fix/SKILL.md
```
or the equivalent path for Codex/OpenCode. The version is the first H1 comment e.g.:
```markdown
# review-and-fix v1.2.3
```

Parsed via regex `^# review-and-fix v(\d+\.\d+\.\d+)` at load time.

## Implementation Tasks

- [x] `Relay_identity` already provides sign/verify — no new crypto needed ✓
- [x] New module `ocaml/peer_review.ml` — serialize/deserialize/sign/verify ✓
- [x] Test suite in `ocaml/test/test_peer_review.ml` — 4 tests passing ✓
- [ ] `review-and-fix` skill updated to emit signed artifact instead of plain text PASS/FAIL
- [ ] Git hook script `githooks/pre-commit` to verify artifacts on push
- [ ] `c2c install` to install hook into `.git/hooks/`
- [ ] `ts` age check on verification (30-day expiry) — NOT YET IMPLEMENTED

## Open Questions

1. Where is `.peer-reviews/` physically stored? Per-worktree or per-repo-common-dir?
   - Decision: per-worktree (`.git/peer-reviews/`) so each agent worktree has its own audit trail
2. Should the artifact be committed to the worktree?
   - Decision: NO — artifact lives in `.git/peer-reviews/` which is .gitignored locally
3. What about FAIL artifacts?
   - Decision: FAIL artifacts are NOT signed by default (the author may not want to sign their failure).
   - Only PASS artifacts require a valid signature.
