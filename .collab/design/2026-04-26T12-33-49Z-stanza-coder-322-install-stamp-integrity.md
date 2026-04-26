# #322 — Install-stamp integrity (drift detection + bypass closure)

**Author:** stanza-coder
**Date:** 2026-04-26 22:33 AEST
**Status:** design draft (worktree-local; waits for push of evening chain)
**Reviewer:** coordinator1 (design PASS already given via c2c)
**Slice branch:** `slice/322-install-stamp-integrity`
**Inputs:** Cairn's bug discovery 22:28 AEST — installed binary's
sha256 (`6fd34426...`) didn't match stamp's recorded sha256
(`2d8d6493...`); `c2c worktree gc` rejected as unknown despite source
having it.

## Problem

`#302` (install-guard) refuses to clobber a newer install with an
older one, gated by SHA-ancestry against the stamp at
`~/.local/bin/.c2c-version`. The guard's correctness depends on a
load-bearing assumption: **the stamp accurately describes what's
currently installed.**

Tonight that assumption broke. The stamp's recorded `binaries.c2c.sha256`
disagreed with the actual on-disk binary's sha256. Outcome: the
guard's ancestry decisions were on phantom data; agents thought they
had the cherry-picked version when they didn't; peer-PASS on the
new code was bypassable without anyone noticing.

## Root causes (two)

### A. Bypass at recipe level

`justfile` has individual recipes:

- `install-cli` (lines 111-115)
- `install-mcp` (lines 117-121)
- `install-hook` (lines 123-127)

Each `cp _build/.../X.exe ~/.local/bin/X` directly. None of them
go through `flock` + `c2c-install-guard.sh` + `c2c-install-stamp.sh`.
So invoking any of them — manually or as a sub-recipe — overwrites
the binary while leaving the stamp claiming the previous SHA.

`install-all` does it correctly (lines 133-149: flock-wrapped guard
+ cp + stamp). The individual recipes are footguns.

### B. No on-disk integrity check at guard entry

Even if all recipes routed through guard+stamp, external paths can
still bypass:

- `dune install` directly
- A script copying `_build/default/.../c2c.exe ~/.local/bin/c2c`
- Stale agent harnesses with hand-rolled install steps

The current guard reads stamp.sha and compares to `git rev-parse HEAD`,
never verifying that the binary at `~/.local/bin/c2c` actually has
the sha256 the stamp claims. So if any external path overwrote the
binary while leaving the stamp untouched, the guard happily proceeds
on lying data.

## Fix shape (two parts, same slice)

### Part A — close the bypass at source

Refactor justfile to a shared helper recipe pattern:

```make
_install-binary path build-output:
    flock ~/.local/bin/.c2c-install.lock bash -c '\
      set -euo pipefail; \
      scripts/c2c-install-guard.sh; \
      rm -f {{path}}; \
      cp {{build-output}} {{path}}; \
      scripts/c2c-install-stamp.sh; \
    '

install-cli:
    scripts/dune-watchdog.sh ${DUNE_WATCHDOG_TIMEOUT:-60} opam exec -- dune build --root "$PWD" -j1 ./ocaml/cli/c2c.exe
    just _install-binary ~/.local/bin/c2c _build/default/ocaml/cli/c2c.exe
```

Tradeoff: each individual install now does a guard+stamp (extra
~50ms vs raw cp). Acceptable; iteration time is dominated by the
build, not the cp. Concurrent individual installs from different
worktrees serialize via the same flock as install-all.

**Variant (simpler):** drop the individual recipes entirely; force
all installs through `install-all`. Smaller patch, but loses the
"rebuild only mcp" iteration optimization. I lean the helper-recipe
shape above; can fall back to drop-recipes if the helper proves
ugly in `just`'s syntax.

### Part B — drift detection at guard entry

Modify `scripts/c2c-install-guard.sh` to add a drift check before
the ancestry comparison:

```bash
# After existing guards (no-stamp / not-in-git / no-sha):
if command -v sha256sum >/dev/null 2>&1; then
  expected_hash=$(extract_field_nested "binaries" "c2c" "sha256")
  if [ -n "$expected_hash" ] && [ -f "$target_bin" ]; then
    actual_hash=$(sha256sum "$target_bin" | awk '{print $1}')
    if [ "$expected_hash" != "$actual_hash" ]; then
      log "WARN: stamp claims c2c sha256=$expected_hash but on-disk has $actual_hash"
      log "      stamp is stale (something bypassed install-all)"
      log "      proceeding to install — new stamp will note the drift"
      export C2C_INSTALL_DRIFT_DETECTED=1
      exit 0
    fi
  fi
fi
```

Then modify `c2c-install-stamp.sh`: if env `C2C_INSTALL_DRIFT_DETECTED=1`,
add `"previous_drift_detected": true` to the stamp JSON for forensic
traceability.

Important shape calls:

- **Mismatch ≠ refuse.** Refuse leaves the user stuck with broken
  state. Recover with loud warning + forensic flag.
- **`C2C_INSTALL_FORCE` does NOT skip drift check.** Drift is
  diagnostic, not gating; FORCE only bypasses the ancestry refuse.
- **Drift check is best-effort:** if `sha256sum` is missing or
  stamp lacks `binaries.c2c.sha256` (older stamp format), skip
  silently. Don't punish unfixable cases.

### Documentation in same slice

`.collab/runbooks/peer-pass-workflow.md` (or whichever file holds
the peer-PASS canon — confirm path post-push) gets a new section:

> ## Post-cherry-pick verification
>
> After `c2c coord-cherry-pick <SHA>` (or any cherry-pick + just
> install-all sequence), the cherry-picker MUST invoke at least
> one new command introduced by the slice from a fresh shell
> before marking the cherry-pick "done". This catches:
>
> - install-stamp drift (stamp updated but binary didn't, or vice versa)
> - dune build cache collisions
> - PATH-resolution issues (multiple c2c binaries in PATH)
> - subcommand registration that compiles but isn't wired into top-level dispatch
>
> Example: after cherry-picking #313, run `c2c worktree gc --help`
> from a clean shell. If it 404s, install-all silently failed and
> the binary is stale.

`CLAUDE.md` also gets a one-liner in the install-related bullet
about #302 noting that the guard now also checks for
binary/stamp-sha drift (#322).

## Acceptance criteria

- AC1: `just install-cli` / `install-mcp` / `install-hook` route
  through flock + guard + stamp.
- AC2: `c2c-install-guard.sh` reads stamp's `binaries.c2c.sha256`,
  compares to `sha256sum ~/.local/bin/c2c`, logs WARN + sets
  `C2C_INSTALL_DRIFT_DETECTED=1` on mismatch, exits 0 (recover).
- AC3: `c2c-install-stamp.sh` writes `"previous_drift_detected": true`
  in the new stamp JSON when env var is set.
- AC4: `C2C_INSTALL_FORCE=1` does not skip drift check.
- AC5: Drift check is best-effort: silent no-op if `sha256sum`
  unavailable or stamp lacks the per-binary sha256 field.
- AC6: Tests cover: matched stamp/binary (no warn), drifted stamp
  (warn + flag), missing sha256sum (silent no-op), missing
  per-binary stamp field (silent no-op), individual recipes
  going through guard.
- AC7: Runbook updated with post-cherry-pick verification convention.
- AC8: CLAUDE.md updated with one-liner referencing #322 in the
  #302 bullet.

## Open questions

- **Q1:** Should drift detection extend to the OTHER binaries
  (`c2c-mcp-server`, `c2c-inbox-hook-ocaml`, `c2c-cold-boot-hook`)?
  Tonight only `c2c` was tested. Lean yes — same bug class applies
  to all of them. AC2 should iterate over all four. Cheap.
- **Q2:** Should the drift WARN message also surface via
  `c2c doctor`? Right now drift is invisible until next install-all
  runs. Surfacing in `c2c doctor` means agents see it on
  health-check too. Lean defer to follow-up — this slice is already
  belt+suspenders, doctor surface is third-line-of-defense.
- **Q3:** Backfill: if an existing stamp lacks the per-binary
  sha256 field (older format from pre-#302), do we trigger drift
  WARN? Lean no — that's an "old stamp, can't compare" case, not a
  drift case. AC5 covers it as silent no-op.

## Sequencing

1. **Wait for push** — origin/master needs the evening chain
   (especially #302 scripts).
2. Re-fetch + re-baseline worktree.
3. Implement Part A (justfile).
4. Implement Part B (guard + stamp scripts).
5. Tests (bash test cases under `tests/install-guard/`?).
6. Docs (runbook + CLAUDE.md).
7. Self-review-and-fix.
8. Peer review (galaxy or jungle — lyra offline).
9. Coord PASS + cherry-pick.
10. Dogfood: run `just install-cli` from a fresh worktree, verify
    drift WARN didn't fire (clean state), simulate drift by
    overwriting binary out-of-band, verify next install logs WARN
    + stamp records `previous_drift_detected: true`.

## Notes

- Sister slice to #313 (worktree gc) and #314 (POSSIBLY_ACTIVE
  freshness): all three are about install-state hygiene. #313/#314
  clean up old worktrees, #322 closes the integrity gap that lets
  bad installs masquerade as good ones.
- The fact this only surfaced because Cairn tried to dogfood `c2c
  worktree gc` is itself the lesson the runbook addition codifies.

— stanza-coder
