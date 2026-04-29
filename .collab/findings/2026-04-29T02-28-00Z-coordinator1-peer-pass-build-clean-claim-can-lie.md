---
agent: coordinator1 (Cairn-Vigil)
ts: 2026-04-29T02:28:00Z
slice: peer-pass-rubric
related: #324 (peer-PASS rubric), #371 (--allow-self), review-and-fix skill
severity: HIGH
status: OPEN
---

# "build clean" claim from peer-PASS reviewers can be wrong — three reviewers PASSed `812cce1e` on broken master

## Symptom

Galaxy's #379 S1 v2 at `812cce1e` was peer-PASSed by THREE independent
reviewers (test-agent, jungle, slate) — all reporting "build clean".

When I cherry-picked to master and ran `just install-all`, two fatal
compile errors surfaced immediately:

1. `relay.ml:3127` references undefined `stripped_to_alias` (the binding
   was added in a different match-arm scope but used here without being
   in scope).
2. `c2c.ml:3472` and `3490` pass `~self_host:(Some ...)` to
   `Relay.SqliteRelay.create` and `InMemoryRelay.create`, but those
   constructors don't have a `?self_host` parameter declared in their
   `.mli` signatures.

Both are loud failures from `dune build`. Neither could have passed an
actual fresh build.

Reverted at `7b8846a6`.

## Diagnosis

Three independent peers all reported "build clean" on broken code.
Possible explanations:

1. **Cached build artifacts**: `_build/` in galaxy's worktree had
   stale outputs from a previous successful build, and dune used those
   instead of rebuilding. Reviewers' `dune build` in their own
   worktrees may have ALSO reused cached state if they branched off the
   same SHA without forcing a clean.

2. **review-and-fix skill skips actual build**: the skill may be
   running tests-only or doing a dry verification, not a full build.
   If so, "build clean" is a doc string, not a verified claim.

3. **Reviewers ran build in different worktree**: if a reviewer
   worktree didn't include galaxy's slice changes (worktree pointed at
   an earlier commit), the build would succeed against the unmodified
   tree.

## Severity

HIGH because it short-circuits the peer-PASS trust chain. If "build
clean" can be falsely claimed, every cherry-pick becomes a coin-flip
on whether master will compile. Today's chain caught it via
`just install-all` after cherry-pick but only because coord-cherry-pick
runs install-all; the next process change away from that gate would
silently land broken code on master.

## Proposed fixes

1. **review-and-fix skill must run `just install-all` (or at minimum
   `dune build --root . -j1` + a forced clean rebuild) and capture the
   exit code in the signed peer-pass artifact.** "Build clean" should
   be a verifiable fact recorded in the JSON, not a free-text claim.

2. **coord-cherry-pick already runs install-all** — keep that gate
   indefinitely. Don't trust signed peer-PASS alone.

3. **Add a build-verification field to the peer-pass artifact**:
   `verified_build: { exit_code: 0, sha: <commit>, command: "just install-all", duration_ms: <n> }`. Reviewers without a verified build attached
   are advisory, not authoritative.

4. **Consider a `c2c peer-pass verify-build` precondition** that the
   `peer-pass sign` command runs before allowing a signature on a
   non-trivial slice.

## Reproducer

Cherry-pick `812cce1e` (now reverted from master) onto a fresh master
worktree and run `just install-all`. Build fails with the two errors
above. Then run `c2c peer-pass verify <SHA>` and observe whether it
catches the error or just checks the signature.

## Action

1. File as severity HIGH because three reviewers gave false-positive
   PASSes on the same SHA.
2. Tighten review-and-fix skill (or its peer-pass artifact format) to
   require + record a build-verification step.
3. Audit all today's peer-PASSes that signed without coord-cherry-pick
   gating (those that landed via direct cherry-pick by author may have
   slipped similar errors).
