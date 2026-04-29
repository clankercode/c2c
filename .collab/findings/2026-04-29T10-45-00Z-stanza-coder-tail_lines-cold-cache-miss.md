# tail_lines bug missed in pre-flight smoke (cold-cache discipline gap)

- **When**: 2026-04-29 ~10:45 UTC, slate's #330 V2 peer-review FAIL.
- **Where**: `ocaml/cli/c2c.ml` `doctor relay-mesh` subcommand
  (`tail_lines` helper, fixed at `29f3f23f`).
- **Severity**: MED (bug-class, not security; surfaced before
  cherry-pick).

## Symptom

`tail_lines path n` returned the OLDEST n lines instead of the
newest n. On any broker.log with >50 lines, `c2c doctor relay-mesh`
was scanning ancient history and missing all recent cross-host
activity — defeating the operator-visibility this slice is supposed
to provide.

The buggy code (pre-fix):

```ocaml
let drop = total - n in
let rec drop_n k xs = match xs, k with
  | xs, 0 -> xs
  | _ :: tl, k -> drop_n (k - 1) tl
  | [], _ -> []
in
List.rev (drop_n drop (List.rev (List.rev !all)))
```

`!all` is newest-first (each line cons'd onto head). `List.rev (List.rev !all)`
is a no-op (double-reverse), giving newest-first. `drop_n drop` then
strips the FIRST `drop` elements — the NEWEST ones — leaving the
oldest `n` lines. Final `List.rev` reverses to oldest-first
chronological. Net: oldest n in chronological order.

The tell-tale was the literal `List.rev (List.rev !all)` no-op,
which slate spotted as a code-smell hint that the surrounding logic
was confused.

## How I missed it

My pre-flight smoke ran `c2c doctor relay-mesh` against the live
main-tree broker.log, which had fewer than 50 lines. The early-return
branch `if total <= n then List.rev !all` correctly handled that case
— the WHOLE log was returned in chronological order. The buggy path
only fires when `total > n`, which my smoke never exercised.

Slate's peer-review repro deliberately fed a 60-line synthetic
broker.log to force the `total > n` branch:

```sh
for i in $(seq 1 60); do echo "line-$i"; done > /tmp/broker-test/broker.log
C2C_MCP_BROKER_ROOT=/tmp/broker-test c2c doctor relay-mesh --log-lines 3
```

Pre-fix output: `line-1, line-2, line-3` — oldest 3.
Post-fix output: `line-58, line-59, line-60` — newest 3.

## Root cause (process)

I treated "smoke against the live broker.log" as sufficient
pre-flight verification. The broker.log on this dev machine happened
to be small, so the buggy path never fired. I didn't construct a
synthetic >n-line fixture even though the helper's contract
explicitly distinguishes `total <= n` from `total > n` cases.

This is **the Pattern 7 (#427) cache-cleanliness rule applied to
fixture-state, not just build-state**: the reviewer's "build clean"
verdict needs a clean build, AND the slice author's "behavior
clean" smoke needs an exercising fixture. Author-side smoke that
only hits the early-return path of a branch is no smoke at all for
the other path.

## Fix status

Fixed in `29f3f23f` with the cleaner formulation slate suggested:

```ocaml
let rec take k xs = match xs, k with
  | _, 0 | [], _ -> []
  | x :: tl, k -> x :: take (k - 1) tl
in
List.rev (take n !all)
```

Repro recipe documented in the fix's commit body so future readers
can replay it on demand.

## Recommendation

Two things future-me (and others) should do for any slice with a
"last N from <list>" / "tail" / "filter recent" semantic:

1. **Construct a fixture larger than N** in pre-flight smoke. The
   hot path is the `> n` case; the early-return is just a
   convenience. Don't treat the early-return as the whole
   contract.

2. **Treat `List.rev (List.rev x)` as a code smell** — almost
   always a sign that someone permuted the list direction back and
   forth without thinking through which orientation each step
   needed. If you see it, suspect a sibling indexing bug.

Severity rationale: MED because no security regression; bug
surfaced cleanly via peer-review before cherry-pick; recovery
clean via new commit (not --amend per #427 Pattern 9). Could have
been HIGH had it landed unreviewed — the "operator-visibility"
slice would have been operator-misleading instead.
