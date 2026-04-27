# Documentation hygiene

Canonical home for the doc-discipline rules called out from
`CLAUDE.md`. Lessons distilled from the 2026-04-26 parallel doc-fix
sweep + subsequent enforcement (#324 docs-up-to-date as a peer-PASS
criterion). Apply on every slice that touches docs or changes a
documented surface.

## Where things go

- **Jekyll publishes every `.md` under `docs/` as a public URL** at
  `https://c2c.im/<path>/`, even files that aren't nav-linked.
  Internal-only artifacts (planning docs, handovers, in-flight specs,
  research notes) leak the moment they land in `docs/`. Default home
  for those is `.collab/`: `.collab/findings-archive/`,
  `.collab/runbooks/`, `.collab/research/`. If a file MUST sit in
  `docs/` but stay unpublished, add it to `docs/_config.yml`
  `exclude:`.
- **Public site = polished landing + clear `docs/` subsection.**
  Internal scratchpads belong under `.collab/`, not `docs/`. When
  uncertain whether something should be public, default to
  `.collab/` and promote later.
- **The relay landing page in `ocaml/relay.ml`** (HTML heredoc,
  search `landing_html`) is a public-facing doc surface — the literal
  first thing a fresh visitor sees at `https://relay.c2c.im/`. Treat
  edits to it with the same discipline as `docs/`.

Per-directory companion: `docs/CLAUDE.md` covers Jekyll-specific
gotchas and front-door pages.

## Common drift patterns

- **`c2c_*.py` references → OCaml subcommands.** The OCaml binary at
  `~/.local/bin/c2c` is canonical; Python `scripts/c2c_*.py` are
  mostly deprecated (see
  `.collab/runbooks/python-scripts-deprecated.md` for the mapping).
  Run a search/replace pass during periodic audits.
- **Stale OCaml `file.ml:NN` line numbers drift fast.** Prefer file
  paths or function names; drop line numbers unless they're
  load-bearing for a specific finding.
- **Wrong GitHub org URLs accumulate.** Canonical is
  `github.com/XertroV/c2c-msg`. Drift spotted in the 2026-04 audit:
  `clankercode/c2c` (×2 in `ocaml/relay.ml` HTML),
  `anomalyco/c2c` (×1 in `docs/remote-relay-transport.md`). A
  periodic `git grep "github.com/" -- ':!.git'` pass catches these.
- **Verify command/flag wording against `~/.local/bin/c2c <subcommand>
  --help` before committing.** Don't trust memory; flag surfaces
  drift.

## Slice discipline

- **One worktree per doc slice**, same as code: branch off
  `origin/master`, `.worktrees/<slice-name>/`, one commit, no
  `--amend`, coord gates pushes. Full reference:
  `.collab/runbooks/git-workflow.md`.
- **Periodic doc-drift audits**: parallel review subagents split by
  surface area (front-door, relay, deep-tech, repo-root, Jekyll
  config, subdirs) catch drift fast. Common findings collapse into
  single fixer-per-cluster commits.

## Peer-PASS docs-up-to-date check

Per coord directive 2026-04-26 (`git-workflow.md` §3), peer-PASS
includes a docs-up-to-date check. FAIL any slice where a documented
surface changed but docs didn't move with it: `CLAUDE.md`,
`README.md`, `.collab/runbooks/*`, `--help` text, MCP tool schemas,
design specs, landing pages, `ocaml/relay.ml` HTML. Tool:
`c2c doctor docs-drift` against the worktree. Slice author either
expands scope or splits a follow-up doc-only slice referenced by SHA
before coord-PASS. PASS-while-stale = signing off on a docs-drift
bug.
