# Peer-pass security audit — post-H2/H2b/M1 (HEAD c6ac8924)

Read-only audit dispatched 2026-04-28 ~20:21 AEST after the security
trio landed. No CRITICAL findings. Filed verbatim from the audit
subagent below; severity-tagged for triage.

## HIGH — `--rotate-pin` is not auditable (stealth rotation)

`cli/c2c_peer_pass.ml:373-388` prints "PIN-ROTATE WARNING" to
stdout/stderr only. No `broker.log` entry, no on-disk rotation log,
no append-only audit trail. An attacker who has compromised one
keypair (or a careless reviewer) can rotate the pin out from under
the swarm and the *only* trace is whatever ephemeral terminal output
the operator captured.

`log_peer_pass_reject` exists for failures — there should be a
sibling writing
`{event:"peer_pass_pin_rotate", alias, old_pubkey, new_pubkey,
prior_first_seen, ts}` from `Peer_review.pin_rotate` itself (not
just the CLI), so any caller path is covered.

**Fix shape**: structured log call inside `Peer_review.pin_rotate`
(or sibling `pin_rotate_with_log`) writing to
`<broker>/broker.log`.

**Slice**: small, ~30 LoC + tests. Filing as #55.

## MED — TOFU pin-store save: no flock, cross-process lost-update race

`peer_review.ml:405-413` `Trust_pin.save` does write-tmp-then-rename
(atomic) but does NOT flock and does NOT fsync. Two concurrent
first-sightings (broker DM verify + CLI verify in another worktree,
or two MCP servers attached to the same broker root) can
`load → mutate → save` and one update is silently lost. The *later*
writer wins; legitimate first-seen pin can be clobbered by an
attacker's racing pin-write within the load/save window.

#54 S1 was scoped to "first-sighting flock" but the audit confirms
the issue is broader (cross-worktree, cross-process). The fix is the
same: flock on `<broker>/peer-pass-trust.json.lock` around load+save
+ fsync the fd before rename. **Folding into #54 — its prompt should
emphasise cross-process, not just intra-process.** Sent S1 amendment
DM to that subagent.

## MED — `verify_claim_with_pin` parses unbounded JSON

`peer_review.ml:252` `Yojson.Safe.from_file` and `:389` ditto. No
size cap. A 1GB malicious artifact at the well-known path will OOM
the broker (or block it for seconds). The artifact path is reachable
to anyone with write access to `.git/c2c/mcp/peer-passes/` (= any
peer process on shared dev boxes). Same for
`cli/c2c_peer_pass.ml:319` `really_input_string ic
(in_channel_length ic)`.

**Fix**: stat first, refuse > 64KB; document the limit.

**Slice**: filing as #56 (low-priority — exploit requires write
access to the peer-passes dir).

## MED — Path-traversal defence is parser-implicit, not canonicalised

`peer_review.ml:177-182` builds `<base>/peer-passes/<sha>-<alias>.json`
with raw `Printf.sprintf`. Today only callers from `claim_of_content`
restrict alias to `[a-z0-9_-]` and sha to `[0-9a-f]`, so traversal is
closed de facto. But `verify_claim_with_pin` is public — any future
caller passing unfiltered alias (e.g. from `Broker.list_registrations`,
which doesn't character-restrict at registration time) reopens it.

**Fix**: defence in depth — reject any `alias` containing `/`, `\`,
`..`, NUL, or leading `.` inside `artifact_path`; reject any `sha`
not matching `^[0-9a-f]{4,64}$`. Same in
`cli/c2c_peer_pass.ml:17`.

**Slice**: filing as #57.

## LOW — Verify-failure timing leak

`Claim_missing` returns on `Sys.file_exists = false`; `Claim_invalid`
runs JSON parse + ed25519 verify. Trivially distinguishable timing.
User-facing string is now generic so only timing leaks. Not
exploitable in current threat model (peer DMs aren't a side-channel
surface). Noting for completeness.

## LOW — `broker.log` no rotation

`c2c_mcp.ml:3150` appends without bound. A flood of forged DMs grows
`broker.log` indefinitely. DoS comfort issue. New reject path is the
first high-frequency writer; worth a sibling slice for log rotation.

## NIT — CLI/broker policy divergence

CLI verify uses `Peer_review.verify` + `pin_check` directly, NOT
`verify_claim_with_pin`. Outcomes match today; code paths drift.
Consider having CLI verify accept `--claim-sha`/`--claim-alias` and
route through `verify_claim_with_pin` for symmetry — would prevent
future drift.

## NIT — Duplicate `let lc = String.lowercase_ascii content` at
`peer_review.ml:188` and `:221`. Harmless, linter-noisy.

## Test coverage gaps

- No race test for concurrent `pin_check` from two processes.
- No oversize-artifact refusal test.
- No path-traversal test (`alias:"../../etc/passwd"`).
- No `--rotate-pin` audit-trail test (no trail to test).
- No test that `pin_rotate` requires valid signature first
  (currently unconditional; CLI calls `verify` first by convention,
  but the function trusts callers).
- Cross-suite consistency check (CLI vs broker verify on same
  artifact) would catch policy drift.

## Empty-audit signals (clean)

- No CRITICAL/STOP-THE-LINE.
- No exhaustiveness warnings in peer-pass paths.
- No unused bindings (besides the L221 re-shadow).
- `broker.log` does not contain secrets — only public alias/sha/
  pubkey-fingerprint material.
- Error-path info leak (I3) confirmed clean — generic user-facing,
  details stderr + broker.log only.

## Top-3 next priorities (per audit)

1. **HIGH** rotate-pin audit log → #55
2. **MED** flock+fsync on pin-store save → folded into #54
3. **MED** size-cap on artifact JSON → #56
