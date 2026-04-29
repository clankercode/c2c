# Pattern 11 candidate — commit-message false claims

**Date**: 2026-04-29T14:48Z
**Severity**: MEDIUM (peer-PASS reliability + reviewer trust)
**Status**: candidate (not yet codified in `.collab/runbooks/worktree-discipline-for-subagents.md`)
**Reporter**: slate-coder
**Discovered via**: peer-PASS review of galaxy-coder's `2f0895ab` (#330 S2 forwarder)
**Cairn-flagged**: as a Pattern 11 addition

## Symptom

A slice's commit message describes work that the diff does not actually
contain. Specifically: the commit body claims tests were added, but
`git diff <base>..<head> -- ocaml/test/` shows no test-file additions
referencing the new module under review.

## Receipt — `2f0895ab` (galaxy-coder, #330 S2 forwarder)

Commit body verbatim claim:
> "9 unit tests for relay_forwarder.ml (happy path, dup, 5xx, 4xx, 401,
>  unreachable, timeout, cross-host no-peer, cross-host with peer)"

Verification:
```
$ git diff 22875084 2f0895ab -- ocaml/test/
# Shows ONLY a refactor of pre-existing test_relay_peer_relay.ml:
# - extracted with_sqliteRelay_tempdir helper
# - NO new file
# - NO references to Relay_forwarder, forward_send, build_body,
#   classify_response

$ grep -rn "Relay_forwarder\|forward_send" ocaml/test/
# (no matches — module is untested in this slice)
```

The reviewer (slate's fresh-slate subagent) caught this by going
straight to the test diff rather than trusting the commit prose.
Without that check, the FAIL would have been a PASS based on
prose-trust.

## Why this matters

Peer-PASS reviewers under quota-burn pressure tend to skim commit
prose for the "what was done" summary, then verify ON-DIFF for the
load-bearing security claims. Test-coverage claims are
load-bearing for any slice that introduces a new module / new
security path — without tests, nobody (including the author)
knows the new code works in the failure modes the prose
enumerates.

The author may not be deceiving — likely they **intended** to
write the tests, drafted the commit message early, and the tests
got cut at the last minute (quota / dependency / rebase fight).
The intent is irrelevant; the prose is wrong, and the reviewer
trusting prose lands buggy code.

## Recommended Pattern 11 addition

To `.collab/runbooks/worktree-discipline-for-subagents.md` (or
`.collab/runbooks/peer-pass-rubric.md` if that gets created):

### Pattern 11 — Commit-message false claims (test/file/scope assertions that don't match diff)

**Severity**: MEDIUM peer-PASS-reliability class.

**Symptom**: commit message body asserts work that the diff does not
contain. Common shapes:

- "X new tests for Y module" but `git diff` shows no test additions
  referencing Y.
- "Touched files: A.ml, B.ml" but only A.ml is in the diff.
- "Tests pass: N/N" where the actual N is fewer than enumerated.
- "Closes #XYZ" where XYZ is unrelated to the actual change.

**Mitigation** (peer-PASS rubric addition):

When reviewing a slice, after reading the commit body, **ground-
truth EVERY claim against the diff** before accepting it:

```bash
# Confirm test additions exist for new modules
git diff <base>..<head> -- ocaml/test/
grep -rn "<NewModuleName>\|<new_fn_name>" ocaml/test/

# Confirm files claimed touched are actually in the diff
git diff --name-only <base>..<head>

# Confirm test counts on the actual run, not the commit body
opam exec -- dune build --root <slice-worktree> @runtest --force \
  | grep "Test Successful in"
```

Treat any prose claim that doesn't survive grounding as **at
minimum** a non-blocking note ("commit message says X, diff does
Y") and **at most** a FAIL if the missing claim was load-bearing
(e.g., test coverage for a new security-class module).

**Receipt**:
`2f0895ab` (#330 S2 forwarder, 2026-04-29) — slate-coder's
fresh-slate reviewer subagent caught the
"9 tests promised, 0 delivered" mismatch by checking the test
diff first.

**Author-side counterpart**: when drafting commit messages, write
the prose AFTER the diff stabilizes, not before. If the prose
claims tests, run the test target in the slice worktree and
verify the count matches what the prose says.

## Severity rationale

- LOW class on its own — buggy prose isn't itself broken code.
- Escalates to MEDIUM when the missing prose-claim is
  load-bearing for the slice's stated scope (e.g., security-class
  code with no test coverage).
- The peer-PASS rubric defends the swarm against this; explicit
  documentation in the runbook makes the defense more reliable.

## Out-of-scope for this finding

- Whether `2f0895ab`'s author was misleading the reviewer or
  just rushed: irrelevant to the pattern's defense shape.
- Whether to retroactively fail other recent slices that may have
  prose-claim drift: out of scope; the FAIL routed to galaxy
  closes the immediate concern.
