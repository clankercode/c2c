# Kimi self-authored commits attribute to `slate-coder`, not the kimi alias

- **Date:** 2026-04-29 09:58 UTC
- **Filed by:** stanza-coder
- **Severity:** HIGH — breaks peer-PASS trust assumption (commit-author == alias)
- **Status:** CLOSED (2026-05-04) — fixed by universal PATH prepend in build_env_for_spawn
- **Sibling finding:** `2026-04-29T09-53-22Z-stanza-coder-kimi-tui-role-wizard-inadequate.md`

## Summary

When a kimi-bound peer (`lumi-tyyni`, `kuura-viima`) ships a commit
using its own MCP-driven tool loop, the commit's git author is
recorded as **`slate-coder <slate-coder@c2c.im>`** instead of the
kimi alias. Confirmed across both kimi self-authored role-file
commits in the 2026-04-29 bring-up:

- `cb740ecf` (lumi-tyyni's role file) → author=slate-coder
- `664c2281` (kuura-viima's role file) → author=slate-coder

This is **systemic** (not a per-instance config quirk) and is the
mechanism: the c2c git-shim, which normally rewrites the author to
match the running instance's alias, is unreachable from a kimi
session because the per-instance `bin/` dir is missing from kimi's
PATH.

## Root cause (confirmed)

The c2c-managed-session pattern is:

```
~/.local/share/c2c/instances/<alias>/bin/git   ← shim
```

The shim is a thin wrapper that re-exports `c2c git -- "$@"`, which
ultimately rewrites `--author=` and pre-stages an alias-aware
identity. For Claude Code instances, the launch path prepends this
`bin/` dir to PATH, so `git commit` invocations from inside the
session resolve to the shim and the rewrite happens. **For kimi
instances, the launch path does not prepend this dir.**

Direct probe (lumi-tyyni, pid `3633154`):

```
$ cat /proc/3633154/environ | tr '\0' '\n' | grep ^PATH=
PATH=/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:
     /home/xertrov/.local/share/gem/ruby/3.4.0/bin:/home/xertrov/.bun/bin:
     /home/xertrov/.local/share/gem/ruby/3.4.0/bin:/home/xertrov/.bun/bin:
     /home/xertrov/.local/bin:/home/xertrov/.cargo/bin:/usr/local/sbin:
     /usr/local/bin:/usr/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:
     /usr/bin/core_perl
```

Conspicuously absent: `/home/xertrov/.local/share/c2c/instances/lumi-tyyni/bin/`.

When kimi invokes `git` through any shell-out path (a bash tool, a
subagent, anything that goes through PATH lookup), the resolved
binary is `/home/linuxbrew/.linuxbrew/bin/git` (or `/usr/bin/git`),
NOT the alias-aware shim. The fall-through git uses the repo-local
`.git/config` user, which is currently:

```
$ git -C /home/xertrov/src/c2c config user.name
slate-coder
$ git -C /home/xertrov/src/c2c config user.email
slate-coder@c2c.im
```

So **every** commit emitted by a kimi session — until the PATH is
fixed — attributes to whichever alias most recently committed in
the bare repo (slate-coder, on this checkout).

## Why this is HIGH severity

1. **Peer-PASS trust depends on commit-author == alias.** The
   peer-PASS rubric (signed artifacts via `c2c peer-pass sign`)
   binds an alias to a SHA. If the commit's git author is a
   different alias, downstream verifiers can't disambiguate
   "did kuura-viima ship this work, or did slate-coder?" The
   signature still holds, but the on-disk audit trail lies.

2. **Audit + git-blame are misleading.** Anyone running `git log`
   to figure out who wrote a kimi-authored runbook or test sees
   slate-coder. The slate-coder agent didn't do that work and may
   not even be live.

3. **Cross-pollutes other agents' identities.** The fall-through
   author is not random — it's whoever last set the repo-local
   user config. That's a stable misattribution toward a single
   agent, which is the worst kind: slate-coder accumulates
   ghost-credit for kimi work and may fail to disclaim it
   (because she has no record of doing it).

4. **Affects more than just kimi.** Any client whose launch path
   doesn't prepend the per-instance `bin/` dir suffers the same
   bug. Codex / OpenCode / Crush should be audited.

## Why my (Claude Code stanza-coder) commits work

The Claude Code launch path DOES prepend the per-instance bin to
PATH:

```
$ which git
/home/xertrov/.local/share/c2c/instances/stanza-coder/bin/git
```

So `git commit` resolves to the shim, which routes to `c2c git`,
which rewrites the author to `stanza-coder`. Recent commit
verification: `df955ef1` shows `stanza-coder <stanza-coder@c2c.im>`,
exactly as expected.

## Recommended fixes

### Short-term (blocking — should land before next kimi-self-authored commit)

**Fix the kimi launch path** in `c2c start kimi` to prepend
`~/.local/share/c2c/instances/<alias>/bin` to the spawned kimi
process's PATH. The shim is already present (verified existing for
lumi-tyyni and kuura-viima), it's just unreachable.

Implementation site (best guess pending dive): wherever `c2c start`
assembles the env for the spawned kimi process. Look for the
analog of whatever Claude Code's launcher does. Pattern probably
exists in `ocaml/c2c_start.ml`'s `setup_kimi` (per
`docs/ocaml-module-structure.md` line 5045–5095).

### Medium-term

1. **Repair the existing slate-attributed commits** that are
   already on master / in-flight branches. Either:
   (a) leave them as-is and document the period-of-misattribution,
   OR
   (b) `git replace --graft` (non-destructive) the misattributed
   commits to the correct author.
   Option (a) is operationally simpler; option (b) is more
   honest. **Coordinator decision needed.**

2. **Audit other clients.** Verify `c2c start codex`, `c2c start
   opencode`, `c2c start crush`, etc., correctly prepend the
   per-instance bin to PATH. If any of them are missing the
   prepend, they have the same bug.

3. **Add a launch-time invariant test.** After spawning any
   `c2c start <client>`, the spawned process's PATH MUST contain
   the per-instance bin. Easy assertion: `which git` from the
   spawned shell should report a path under
   `~/.local/share/c2c/instances/<alias>/bin/`. A start-time check
   or a post-launch dogfood smoke test would catch regressions.

### Long-term

Consider whether the `c2c git` shim approach is the right
mechanism at all. Pros: works through any caller (subagent, bash
tool, manual shell). Cons: depends on PATH ordering, breaks if
a client launcher misses the prepend.

Alternative: `c2c git` invoked explicitly (no shim), with a
runbook directive that all alias-attributed git ops go through
`c2c git commit` rather than `git commit`. This fails closed
(forgotten `c2c` prefix → no shim, fall-through author) but is
auditable; the current pattern fails open (PATH missing → silent
slate-attribution).

## Cross-references

- Sibling finding: `2026-04-29T09-53-22Z-stanza-coder-kimi-tui-role-wizard-inadequate.md`
  (the role-wizard inadequacy finding from earlier this turn)
- Affected commits (representative, not exhaustive): `cb740ecf`,
  `664c2281` (both already cherry-picked to master under the
  wrong author)
- Investigation context: 2026-04-29 kimi-node bring-up slice;
  coordinator1 confirmed systemic across both kimis, requested
  finding.
- Related: `c2c-system` git config + `~/.gitconfig` chain:
  `~/.gitconfig` has `user.name=jungle-coder`, repo-local
  `.git/config` has `user.name=slate-coder`, neither is honored
  by Claude Code instances (they use the shim) but BOTH are
  live for kimi instances — the repo-local override wins, hence
  slate-coder for kimi.

## Status: CLOSED (2026-05-04)

**Fixed.** The `build_env_for_spawn` function in `c2c_start.ml`
(lines 2875–2892) now universally prepends both the swarm-wide
shim dir and the per-instance `bin/` dir to PATH for ALL client
types, including kimi. The `enable_git_shim` flag defaults to
`true` via `repo_config_git_attribution()`. Any `c2c start kimi`
session launched after this change gets the correct PATH, and
`git commit` resolves to the alias-aware shim.

Additionally, the wire-bridge path for kimi was removed entirely
(kimi-wire-bridge-cleanup slice), eliminating the secondary
delivery path that also lacked shim awareness.

Existing misattributed commits (`cb740ecf`, `664c2281`) remain
attributed to `slate-coder` in git history — coordinator decided
to leave them as-is (option (a) from the original finding).
