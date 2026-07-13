# c2c Git Workflow

**Status:** Canonical reference (post swarm-era, 2026-07-14)
**Audience:** Anyone working on the c2c repo (human or agent)

Historical multi-agent process (peer-PASS, coordinator cherry-pick, branch-per-slice
swarm rules) lives under `.collab/runbooks/deprecated/` — do not follow those as
current process.

---

## TL;DR

```
1. Prefer a feature branch or worktree for non-trivial work
2. Branch from origin/master when integrating with upstream
3. Commit often; never --amend published/shared SHAs
4. just build / just check before merge
5. Push only when something needs to be live (deploy cost)
```

---

## Worktrees (optional, still useful)

For larger changes, isolate under `.worktrees/<name>/`:

```bash
git fetch origin
git worktree add -b feat/<desc> .worktrees/<desc> origin/master
cd .worktrees/<desc>
```

- `c2c dev worktree gc` cleans landed/stale worktrees (dry-run by default;
  `--clean` to remove). Full mechanics: `worktree-per-feature.md`.
- Avoid `git stash` when multiple worktrees share one `.git` (stash list is
  shared) — prefer a WIP commit or a patch file.

---

## Build / check / install

Full `just` recipes are below and in this file's historical sections if
present. Day-to-day:

| Goal | Command |
|------|---------|
| Compile-check | `just build` |
| Pre-merge gate | `just check` |
| Install local binary | `just install-all` or `just bi` |
| Skill embed regen | `just codegen-c2c-skills` then `just sync-skills` |

OCaml changes need rebuild + install before they are live in your session.

### `just`-recipes (common)

```bash
just build          # dune build
just check          # broader local gate (see justfile)
just install-all    # install c2c + related
just bi             # build + install shortcut when defined
just test-ocaml     # OCaml test suite
```

---

## Push / deploy

Pushing `origin/master` triggers Railway Docker (~10–15 min, real $) and
GitHub Pages. Prefer local commits + install to validate.

- Push when something needs to be **live** (relay, site, production hotfix).
- "Feature finished + tests green" alone is not a reason to push.
- Assess with `c2c doctor` (relay-critical vs local-only).
- After deploy: `./scripts/relay-smoke-test.sh`.

---

## Reviews

Optional. `review-and-fix` / `/ccc-review-cx` when useful. Fix in new commits;
never `--amend` shared SHAs.

---

## See also

- Root `AGENTS.md` / `CLAUDE.md` — agent-facing product rules
- `worktree-per-feature.md` — worktree GC and mechanics
- `.collab/runbooks/deprecated/` — swarm-era peer-PASS / coordinator process
