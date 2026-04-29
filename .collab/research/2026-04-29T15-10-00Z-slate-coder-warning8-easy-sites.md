# Warning 8 (partial-match) — Easy-Site Audit

**Author:** slate-coder
**Date:** 2026-04-29T15:10:00Z
**Scope:** `/home/xertrov/src/c2c/ocaml/` (excluding `.worktrees/`)
**Target:** identify low-risk Warning 8 sites slate could bundle into a small slice
without colliding with cedar-coder's larger sweep.
**Mode:** AUDIT-ONLY — no code modified.

## 1. Method

1. Worktree pwd: `/home/xertrov/src/c2c/.worktrees/435-warnings-21-5`
   (branch `435-warnings-21-5` — already cleaning Warnings 11/21/23/26).
2. Forced clean rebuild to surface warnings (incremental builds are cached
   and emit nothing):
   ```
   cd /home/xertrov/src/c2c
   opam exec -- dune clean
   opam exec -- dune build 2>/tmp/c2c-stderr.log
   grep -B 5 "Warning 8" /tmp/c2c-stderr.log
   ```
3. Suppression scan — no Warning 8 suppressions anywhere:
   ```
   grep -rn '\[@ocaml.warning "[-+]8' ocaml/   # → 0 hits
   ```
   No `(flags (:standard -w +a-something))` in the dune files we use either —
   so the warnings we see are the full set the compiler currently emits.
4. Cedar-claim scan:
   ```
   git log --all --since="3 days" --author=cedar --oneline
   git log --all --since="5 days" --oneline | grep -iE "warning ?8|partial.match|exhaustive"
   git branch -a | grep -iE "cedar|warning"
   ls .worktrees/                        # only 435-warnings-21-5
   grep -rln "partial-match" .collab/    # → only stanza's code-health-audit
   ```

## 2. Cedar's claimed scope

**Findings:** **no cedar-coder Warning-8 commits or branches are visible
in the tree.** Cedar's only active worktree is `407-s5-signing-keys-e2e-cedar`
(cross-host signing tests, unrelated). The single Warning-8-relevant commit
ever made (`2bae0b45 fix(stickers): … fix scope exhaustiveness …`) was authored
by jungle-coder on 2026-04-25 and only patched ONE of the three scope sites
in `c2c_stickers.ml` — line 379 is still warning today.

Adjacent #435 work in our current worktree has covered Warnings 11/21/26
(commits `435ca4cb`, `1c814bba`, `537cedf1`) but **has not touched Warning 8**.

**Conclusion:** the four Warning-8 call sites listed below appear to be
unowned. Slate can pick from them subject to coordinator approval; cedar's
"larger sweep" if scoped will likely come from outside committed state, so
suggest slate DM cedar before claiming to deconflict.

The single mention in `.collab/research/2026-04-29-stanza-coder-c2c-mcp-code-health.md`
flags `c2c_mcp.ml:3633–3673` Warning 8 — **the current build does NOT flag that
site.** It is either already fixed in a recent commit or stanza was reading a
stale build log. Out-of-scope here.

## 3. Easy sites (current build emits 4 distinct Warning 8 sites)

The build duplicates each (library + executable compile both fire), so
counting unique source spans:

### Site A — `ocaml/relay.ml:4254` — JSON ts-extract symmetric typo

**Snippet (lines 4252–4255):**
```ocaml
(List.sort (fun (a : Yojson.Safe.t) (b : Yojson.Safe.t) ->
  let ts_a = match a with `Assoc f -> (match List.assoc_opt "ts" f with Some (`Float t) -> t | Some (`Int i) -> float_of_int i | _ -> 0.0) | _ -> 0.0 in
  let ts_b = match b with `Assoc f -> (match List.assoc_opt "ts" f with Some (`Float t) -> t | Some (`Int i) -> float_of_int i | _ -> 0.0) in
  compare ts_a ts_b
) all_msgs, [("gap", `Bool true)])
```

**Compiler diag:** missing variants
`(`Bool _|`Intlit _|`Null|`List _|`Float _|`String _|`Int _)`

**Proposed fix:** copy `| _ -> 0.0` from `ts_a` to `ts_b`:
```ocaml
let ts_b = match b with `Assoc f -> (match List.assoc_opt "ts" f with Some (`Float t) -> t | Some (`Int i) -> float_of_int i | _ -> 0.0) | _ -> 0.0 in
```

**Est LoC:** 1 token (`| _ -> 0.0` insertion).
**Behavior risk:** zero. Symmetric to the `ts_a` line above; today the
unmatched cases would raise `Match_failure`, but only `` `Assoc `` ever
shows up in the message-list pipeline.
**Classification:** **EASY**.

### Site B — `ocaml/cli/c2c_stickers.ml:379` — JSON output of scope

**Snippet (lines 372–381):**
```ocaml
if json then
  let items = List.map (fun env ->
    `Assoc [
      ("from", `String env.from_);
      ("to", `String env.to_);
      ("sticker_id", `String env.sticker_id);
      ("note", `String (Option.value env.note ~default:""));
      ("scope", `String (match env.scope with `Public -> "public" | `Private -> "private"));
      ("ts", `String env.ts);
    ]) stickers in
```

**Compiler diag:** missing case `` `Both ``. The scope ADT is
`type scope = [ \`Public | \`Private | \`Both ]` (line 62), and the
sibling sites (lines 100 and 142) already encode `` `Both -> "both"``.

**Proposed fix:**
```ocaml
("scope", `String (match env.scope with `Public -> "public" | `Private -> "private" | `Both -> "both"));
```

**Est LoC:** 1 token (`| `Both -> "both"` insertion).
**Behavior risk:** very low. The 2026-04-25 sticker exhaustiveness fix
(`2bae0b45`) already converted lines 100/142 to the same shape; this is
the third sibling that was overlooked. Line 379 is the JSON-output path
of `sticker list --json`, which today would raise `Match_failure` if a
`` `Both `` envelope ever reached it (likely unreachable with current
default `scope=`Both` in `load_stickers`, but still load-bearing).
**Classification:** **EASY**.

### Site C — `ocaml/cli/c2c.ml:3970–4165` — `match subcmd with` (rooms group)

**Snippet (lines 3970–4165, abbreviated):**
```ocaml
match subcmd with
| "join" | "leave" -> ...
| "send" -> ...
| "history" -> ...
| "list" -> ...
| "invite" | "uninvite" -> ...
| "set-visibility" ->
    ... (match result with
         | `Assoc fields ->
             (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
         | _ -> exit 1))
```

**Compiler diag:** missing case `""` (any other string).

**Proposed fix:** add a final catch-all branch at the end of the outer
match (just before the closing paren of the let-expression):
```ocaml
| _ ->
    Printf.eprintf "error: unknown rooms subcommand: %s\n%!" subcmd;
    exit 1
```

**Est LoC:** 3 lines.
**Behavior risk:** very low. cmdliner already constrains `subcmd` to a
positional string; an unknown subcommand currently raises `Match_failure`
which prints an unfriendly stack trace. The fix replaces that with a
clean error message + non-zero exit. No behavior change for the 6
recognized subcommands.
**Classification:** **EASY**.

### Site D — `ocaml/relay.ml:1429–1432` — binding_state inner match

**Snippet (lines 1424–1433):**
```ocaml
match binding_state with
| `Mismatch ->
  let dummy = RegistrationLease.make … in
  (relay_err_alias_identity_mismatch, dummy)
| _ ->
  let effective_pk = match binding_state with
    | `Preserve -> !existing_pk
    | `Matches -> identity_pk
    | `NoPkNoBinding -> ""
  in
  …
```

**Compiler diag:** missing `` `Mismatch `` in the inner match (which is
structurally unreachable because the outer `_` excludes it).

**Proposed fix:** the inner match could be replaced with a flat
`if/else` or the missing arm could be `| `Mismatch -> assert false`:
```ocaml
| `Mismatch -> assert false  (* unreachable: outer match handled it *)
```

**Est LoC:** 1 line.
**Behavior risk:** **MEDIUM**. The site is in the relay's alias→identity
binding logic (`register_alias`), which is a security-sensitive path
(TOFU pin enforcement, #432 lineage). `assert false` is correct today
but couples the inner match's correctness to the outer match's coverage;
a future refactor that drops the outer `Mismatch` arm would silently
explode. Cleaner refactor: lift the inner `match` out into a helper or
switch the outer match to be exhaustive too. **Defer to cedar's larger
sweep** rather than slate's small slice.

## 4. Medium / Hard sites (just for awareness)

| Site | Reason to defer |
|------|-----------------|
| `ocaml/relay.ml:1429–1432` (binding_state) | Auth/identity-binding path. `assert false` works but couples to outer match; merits the larger refactor cedar may already be planning. |

No other Warning 8 sites currently fire in the tree.

## 5. Recommendation

**Top 3 easy sites for slate's bundled slice (Sites A + B + C):**

| Site | File:line | LoC | Tests already covering |
|------|-----------|-----|------------------------|
| A | `ocaml/relay.ml:4254` | +1 token | `ocaml/test/test_relay.ml` (history sort path); `test_relay_observer.ml` exercises the replay sort branch indirectly. |
| B | `ocaml/cli/c2c_stickers.ml:379` | +1 token | `ocaml/cli/test_c2c_stickers.ml` covers create/load + roundtrip; the `--json` list path is exercised. |
| C | `ocaml/cli/c2c.ml:3970–4165` | +3 lines | No direct test. cmdliner enforces positional subcmd at parse time, so the new branch is a defensive guard rather than a new code path; manual smoke `c2c rooms bogus` would suffice. |

**Total:** ~5 LoC across 3 files, all in distinct modules so no merge-base
conflict with #435-warnings-21-5 work. Build-clean verifiable in
`.worktrees/<slice>/` after fix; the existing `just test` run already
exercises Sites A and B paths.

**Suggested slice name:** `435-warning8-easy-three`
**Suggested commit message:**
> fix(#435): exhaust three Warning 8 sites — relay.ml:4254 ts_b symmetric, c2c_stickers.ml:379 scope `Both, c2c.ml:3970 unknown-subcmd guard

**Pre-claim DM:** before slate opens the worktree, Cairn or slate should
DM cedar-coder to confirm her wider sweep has not already queued these
three so we don't double-commit.

**NOT recommended for this slice:** Site D (relay.ml:1429 binding_state).
Defer to cedar's larger refactor or treat as a separate medium-risk slice
with peer-PASS attention on the auth path.
