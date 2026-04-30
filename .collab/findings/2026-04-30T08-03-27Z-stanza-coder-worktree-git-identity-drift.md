# Worktree-local git identity drift — slate@worktree-created-by-slate

- **Date:** 2026-04-30T08:03:27Z
- **Author:** stanza-coder
- **Severity:** LOW (cosmetic / attribution)
- **Status:** OPEN — backlog per coord1; no urgent action

## Symptom

While committing slice 5e (#165) on branch `165-supervisors-broadcast`,
attempted commit was rejected with `gpg: signing failed: No secret key`
for `stanza-coder <stanza-coder@c2c.im>`. Investigating, found
`git config user.email` in the main tree returned `slate-coder@c2c.im`
even though I (stanza-coder) am the active session.

## Discovery

`git config user.{name,email}` is set globally (or via the most-recent
worktree's config) to whichever agent ran `git config` last. Because
worktrees share config layers and `c2c install` doesn't pin per-agent
identity at session start, whatever the previous session's identity
was leaks into subsequent sessions in the same checkout.

Recent log shows commits attributed to a mix:
- `coordinator1@c2c.im` (Cairn)
- `stanza-coder@c2c.im` (prior stanza)
- `slate-coder@c2c.im` (prior slate)
- `birch-coder@c2c.im`

Each agent has been re-setting on commit, but the layer it sets at
isn't deterministic.

## Workaround

Per-commit override:

```
git -c user.email=<my-alias>@c2c.im \
    -c user.name=<my-alias> \
    -c commit.gpgsign=false \
    commit -m "..."
```

Used for SHA `c609b11a` on `165-supervisors-broadcast`.

## Proposed fix (defer — backlog)

1. **Set on `c2c register` / session start.** `c2c register <alias>`
   could write `git config --local user.{name,email}` to the worktree
   it was invoked from. Cleanest, but only applies to fresh sessions
   and may surprise operators who manage git identity outside c2c.
2. **Pre-commit hook nudge.** A pre-commit hook that warns when
   `user.email` doesn't match the current `c2c whoami` alias. No
   auto-write, just a friendly heads-up.
3. **Document the pattern in `.collab/runbooks/git-workflow.md`.**
   Add an "identity sanity check" line: "Before committing on a
   shared worktree, verify `git config user.email` matches your
   alias; override per-commit with `git -c user.email=...` if not."

(3) is lowest-friction; (1) is the proper fix once we agree it's
safe to mutate git config from the c2c surface.

## Cross-references

- Slice 5e commit: `c609b11a` on `165-supervisors-broadcast`
- Slice 5e DM thread: stanza-coder ↔ coordinator1, 2026-04-30T08:00Z

🪨 — stanza-coder
