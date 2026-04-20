# Shared working directory causes WIP-sweep across agents' commits

- **Date:** 2026-04-21T01:24Z
- **Alias:** coder2-expert
- **Severity:** medium — mis-attribution, no data loss; can confuse
  history and mask intent.
- **Fix status:** identified; mitigation options listed below.

## Symptom

Multiple swarm agents run as tmux panes in session `0`, all with cwd
`/home/xertrov/src/c2c/`. Consequences observed in a single ~30-minute
window:

1. I edited `ocaml/relay.ml` to add L2/1 TLS wiring
   (`?tls:[\`Cert_key of cert_path * key_path]` + server mode switch).
2. Before I committed, coder1 staged their own L3/3 work via
   `git add ocaml/relay.ml` and committed as `0bc08eb`. That commit's
   diff includes MY TLS changes alongside their Ed25519 header parser.
   The commit message says only "L3 slice 3 — per-request Ed25519 auth
   header" — no mention of TLS.
3. Inverse: minutes earlier I ran `git diff --cached` and saw
   coder1's L3/3 scaffolding queued as "my" stage, because I'd run
   `git add .` at some point in the session.
4. RELAY.md: I wrote `| (this commit) |` as a placeholder, expecting
   to replace it right before committing. Another agent's
   `git add docs/c2c-research/RELAY.md` captured the placeholder
   verbatim into `d3b9446`.

## Root cause

`git add <path>` (or `git commit -a`) at the pane level picks up every
uncommitted modification in the shared working tree, not just the
changes the committing agent made. There is no per-agent isolation.

## Why this matters

- **Attribution breaks.** Commit authorship becomes "whoever ran the
  `git commit` first," not who wrote the code. Reading git log lies.
- **Commit messages describe the wrong diff.** A reader sees "L3/3
  per-request Ed25519 auth" but the commit also contains TLS server
  wiring and a Layer-4 context constant.
- **Revert surface is dangerous.** `git revert <hash>` now backs out
  multiple unrelated features at once. If we ever need to roll back
  L3/3, TLS would go with it.
- **Agents lose track of their own progress.** I thought I was about
  to commit TLS; then `git diff HEAD` returned empty because my work
  was already in HEAD under someone else's name.

## Mitigations (not yet decided)

1. **Per-agent git worktrees.** `git worktree add ../c2c-coder2 HEAD`
   — each agent gets an isolated checkout, merges via PR/branch.
   Heaviest but cleanest. Works with the existing shared git-common
   dir per CLAUDE.md.
2. **Feature branches per slice.** Each agent creates a branch for
   each slice, rebases onto master before committing. Requires
   coordination but keeps all work in one working tree.
3. **Announce-before-commit.** Agent posts "committing FILE now, pls
   hold" in `swarm-lounge` + 5s pause. Lightweight but relies on
   cooperation; one forgetful agent breaks it.
4. **Per-path ownership.** CLAUDE.md-level rule that only the declared
   owner of a file stages it. Hard to enforce.
5. **Force `git add <specific files>`.** Rule: agents must name their
   own paths explicitly and never use `git add .` or `-A`. This is
   already the CLAUDE.md rule, but the sweep happens via
   `git add ocaml/relay.ml` — the hazard is that *any* file an agent
   has touched gets grabbed whole.

My gut: (1) worktrees is the real fix. (3) is the easy patch.

## How I discovered it

Running L2/1 TLS slice. My edits to `ocaml/relay.ml` vanished from
`git diff HEAD` before I committed them. Logged the history via
`git log --oneline` and noticed they were already in coder1's commit
from two minutes prior. Cross-referenced RELAY.md and saw the same
pattern with my `(this commit)` placeholder.

## Cross-refs

- CLAUDE.md dev rules already say "Do not delete or reset shared files
  without checking" — that's the read-side version of the same
  problem; this is the write-side corollary.
- Max's 2026-04-21 steering "finish the relay" — if we're about to
  sprint through Layer 4, this hazard will keep ambushing us. Worth
  deciding on a mitigation before we hit another simultaneous-edit
  conflict on the same file.
