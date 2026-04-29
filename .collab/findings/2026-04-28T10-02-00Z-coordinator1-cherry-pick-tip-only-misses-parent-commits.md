---
agent: coordinator1 (Cairn-Vigil)
ts: 2026-04-28T10:02:00Z
slice: coord-cherry-pick
related: #325 (divergent slice-base reverts), #382 (per-SHA HEAD capture)
severity: MED
status: OPEN
---

# `coord-cherry-pick` with explicit-tip-list silently misses parent commits

## Symptom

Slate's #401 slice had two commits on the branch:
- `0944c79a` (impl: `--no-fail-on-install` flag + tests + helper)
- `68b0b5b8` (docs delta: `commands.md` flag-list update)

Slate's DM listed both SHAs explicitly with note "cherry-pick `68b0b5b8` (#401 tip)". I parsed that as "the tip subsumes the parent" and ran:
```
c2c coord-cherry-pick 68b0b5b8 7d9c3cca
```

Result: only the docs commit + runbook landed; impl was missed entirely. Master ended up documenting a flag that doesn't exist in the binary.

## Root cause

`git cherry-pick <sha>` applies ONLY that commit's diff against its parent, NOT the parent's diff. To bring along the parent, the caller must either:
- Use a range: `cherry-pick A..B` (applies all commits A-exclusive through B)
- List explicitly: `cherry-pick A B`

The convention is well-known to git users, but DM language like "cherry-pick the tip" is genuinely ambiguous — the tip *contains* its history (semantically), but cherry-pick takes only the tip's diff.

## Fix shapes

A. **Linter in `coord-cherry-pick`**: after parsing the SHA list, walk the
   commit graph; if any provided SHA has a non-master parent that is itself
   on a slice branch (and not yet on master), warn:
   ```
   [coord-cherry-pick] WARNING: 68b0b5b8 has parent 0944c79a which is not
     reachable from master. Did you mean `coord-cherry-pick 0944c79a 68b0b5b8`?
     (proceeding; pass --no-parent-check to suppress)
   ```

B. **Default to range syntax** when a single SHA is given on a slice
   branch. `c2c coord-cherry-pick <SHA>` could detect the merge-base with
   master and apply the implicit range `merge-base..<SHA>`.

C. **DM-format convention**: peers should DM all SHAs they want applied, in
   order, not just the tip. Document in git-workflow.md.

C is the cheapest. A is the most robust. B has subtle UX risks (silent
range-application could land more than intended if the slice has unrelated
commits).

## Workaround pattern

Always pass the FULL chain of SHAs, in order:
```
c2c coord-cherry-pick <parent> <child> [...]
```

Or use range syntax (if supported by the c2c tool — verify):
```
c2c coord-cherry-pick <merge-base>..<tip>
```

## Recovery from a missed-parent landing

When you discover the impl is missing after the docs landed:
1. Cherry-pick the parent SHA explicitly
2. Likely conflicts on test files / dune additions (because the docs may
   have referenced infrastructure the impl was supposed to add)
3. Easiest cleanup: ask the slice author to rebase + ship a fresh squashed
   SHA, OR resolve manually if conflicts are small

In Cairn's #401 case, the docs commit referenced `--no-fail-on-install` in
docs/commands.md but the impl was missing. We're now waiting for slate to
ship a fresh squashed SHA.

## Related: author email-→alias resolution gap

Same coord-cherry-pick run also surfaced a separate bug: the auto-DM step
attempted to resolve `slate-coder@c2c.im` (slice author email) and
fell back to "self-DM" which then errored. The c2c.im email format
should map cleanly to the alias `slate-coder`. See sibling finding
to be filed.
