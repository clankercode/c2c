# SPEC: Signed Peer-PASS Artifact (#172)

## Status
implemented
**Shipped (in landing order on master):** a4eb88b (broker verify), 9983943 (anti-cheat), dacc2b7 (--warn-only), a5c05ad (self-pass detector), `2a6ad11a` (H1 TOFU pubkey pin, originally `73f31614` on slice branch), `d2c8ec38` (H2 broker invalid-sig reject, originally `52a44a0e` on slice branch — superseded by H2b after slate's FAIL surfaced the pin-not-enforced gap; landed as the base layer for the H2b fix to apply on top of), `0c57b839` (H2b broker TOFU pin enforcement, originally `c26ee37d` on slice branch), `2af9def4` (M1 co-author trailer in reviewer_is_author, originally `98f7479b` on slice branch), `ef09077c` (S1 pin-save flock).

## Broker-side enforcement (H2 + H2b, 2026-04-28)

The broker verifies peer-pass DMs at the boundary, not just the CLI:

- **Pre-H2 (legacy)**: `verify_claim` was advisory — `Claim_invalid` set
  the `peer_pass_verification` field on the receipt but the DM still
  enqueued. A forged peer-pass DM reached the recipient.
- **H2 (`d2c8ec38`)**: strict-mode rejects on `Claim_invalid` —
  signature failure, sha mismatch, or reviewer-field mismatch.
  **Slate's peer-PASS review of H2 surfaced a gap**: H2 only checked
  the artifact-embedded `reviewer_pk` against its own signature, never
  consulting the H1 TOFU pin store. An attacker minting a fresh ed25519
  keypair could sign an artifact under any victim alias, drop it at
  the well-known path, and DM "peer-PASS by victim, SHA=…" — H2 returned
  `Claim_valid` and the broker enqueued. H2 was kept in the chain (not
  reverted) because H2b applies on top of it; H2 alone is not safe.
- **H2b (`0c57b839`)**: `verify_claim_with_pin` consulted at the broker.
  `Pin_mismatch` → `Claim_invalid` (rejected). `Pin_first_seen` and
  `Pin_match` → `Claim_valid` (accepted, TOFU preserved). Closes the
  fresh-keypair forgery vector that walked through H2 alone.

**User-visible reject text on H2/H2b rejection** (verbatim from
`c2c_mcp.ml:4471-4473`):

```
send rejected: peer-pass verification failed (H2b: forged or pin-mismatched peer-pass DM not enqueued; see broker.log for details)
```

The string deliberately does NOT echo attacker-placed file contents
(claim_alias, claim_sha, reviewer_pk, signature bytes, underlying parse
errors) back to the sender — those would let an attacker probe what
their forged artifact looked like to the broker. The string DOES name
the failing check class ("H2b: forged or pin-mismatched") so an
operator reading their own send error knows where to look. Detailed
reason (claim_alias, claim_sha, underlying error) is logged to
broker.log under `event:"peer_pass_reject"` via
`c2c_mcp.ml:log_peer_pass_reject`.

**Pin store**: `<broker_root>/peer-pass-trust.json` (broker-side) and
`<repo>/.c2c/peer-pass-trust.json` (CLI-side); same schema. The broker
loads it via `verify_claim_with_pin ?path` so all worktrees share one
TOFU view. Save serialized via `Unix.lockf` on `<store>.lock` (per
S1, `ef09077c`); `Trust_pin.with_pin_lock` exposed for callers needing
read-modify-write atomicity across the load→check→save sequence.

**Rotation**: only the operator-driven `c2c peer-pass verify --rotate-pin`
path can replace an existing pin; the broker never auto-rotates.

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

## Path-traversal defence (#57)

The artifact path is composed as `<base>/peer-passes/<sha>-<alias>.json`
from caller-supplied `alias` and `sha`. Today the production callers
feed these via `claim_of_content`, which already restricts alias to
`[a-z0-9_-]` and sha to lowercase hex — so traversal is closed *de
facto* — but `verify_claim`, `verify_claim_with_pin`, and `artifact_path`
are public functions; any future caller (e.g., one that reads alias
straight from `Broker.list_registrations`, which does not enforce these
character restrictions at registration time) would reopen the traversal
vector.

`Peer_review.validate_artifact_path_components ~alias ~sha` is the
defence-in-depth choke point. It rejects (returning `Error reason`):

- **alias**: empty; contains `/`, `\`, `..`, NUL, leading `.`; or any
  byte outside printable ASCII excluding space (i.e. only `0x21..0x7e`
  allowed).
- **sha**: empty; not matching `^[0-9a-f]{4,64}$` (lowercase hex,
  4..64 chars). Uppercase hex is rejected because the production write
  path always emits lowercase, so a request for an upper-cased SHA
  cannot match a legitimate artifact and is more likely a smuggle
  attempt.

Integration points:

- `Peer_review.artifact_path` raises `Invalid_argument` on a validator
  failure — fail-fast for direct callers.
- `Peer_review.verify_claim` and `Peer_review.verify_claim_with_pin`
  short-circuit to `Claim_invalid "alias/sha rejected by
  path-validator: <reason>"` so the broker's
  `log_peer_pass_reject` machinery captures the rejection in
  `broker.log` exactly like other invalid-claim paths.
- `c2c peer-pass`'s CLI artifact-path builder (`cli/c2c_peer_pass.ml`)
  re-runs the same validator before composing the path; the CLI
  exits with a clear error rather than relying on the lib check
  downstream.

The validator lives in `peer_review.ml` so it is testable in isolation
(`test_peer_review.ml` group `path_traversal_57`) and is reused
identically by all callers.

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
