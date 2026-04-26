---
# Per-directory guide for agents editing pages under `docs/`.
# Not published itself — listed in `_config.yml` exclude.
---

# `docs/` — agent guide

Quick rules for anything edited under this directory. Companion to the
root `CLAUDE.md`'s "Documentation hygiene" section; read both.

## Scope

- This directory is the public Jekyll site, served at <https://c2c.im/>.
- Every `.md` here publishes as `https://c2c.im/<path>/`, whether or not
  it appears in nav.
- Build config: `docs/_config.yml`. Theme + plugins live in the same
  file; `exclude:` is the escape hatch for files that must live here
  but stay unpublished.

## Public-by-default — what belongs here vs. `.collab/`

- `docs/` = polished, public-facing reference: landing, get-started,
  architecture, command reference, design specs that have stabilised.
- `.collab/` = internal artifacts: findings, runbooks, research notes,
  in-flight specs, handover docs.
- When in doubt, **default to `.collab/`**. Promotion later is cheap;
  unpublishing a leaked URL is not.
- Moving a file out of `docs/`? See "Cross-doc link discipline" below.

## Source-of-truth: don't paraphrase from memory

- CLI surface: `~/.local/bin/c2c <subcommand> --help` is canonical.
  Don't write commands or flags from memory — run the help and check.
- MCP tool surface: `ocaml/c2c_mcp.ml` defines tools and schemas.
- Python scripts: see the root `CLAUDE.md` "Python Scripts" mapping;
  most are deprecated in favour of OCaml subcommands.

## Cross-doc link discipline

When you move or rename a file out of `docs/`:

1. `git grep -l <oldpath>` to find inbound references.
2. Update each reference in the same commit as the move.
3. Prefer repointing to the new path with an "(internal/archived)"
   annotation; drop the link only if it was tangential and replace
   with a one-sentence inline summary.
4. Internal references from `docs/` should generally point to
   `.collab/...` (which won't render as a public URL but is the
   correct provenance trail for agents reading the source).

## Common drift hotspots (carryover from 2026-04 audit)

- **Python script citations** (`c2c_*.py`) where the OCaml subcommand
  has long since taken over. Replace with `c2c <subcommand>`.
- **Stale OCaml line numbers** (`foo.ml:42`). Prefer file path +
  function name; drop the line number unless load-bearing.
- **Wrong GitHub org URLs**. Canonical is
  `github.com/XertroV/c2c-msg`. Periodic `git grep "github.com/"`
  catches drift.
- **`c2c register` shown without flags** when current usage requires
  one. Check `--help` before pasting examples.

## Front-door pages — extra care

These are the highest-traffic pages; double-check structure, links,
and accuracy before committing:

- `README.md` (repo root, also the GitHub landing)
- `docs/index.md`
- `docs/get-started.md`
- `docs/overview.md`

`docs/commands.md` is a hand-written mirror of `c2c --help`. When you
add or change a CLI subcommand, update this page in the same slice.

## Embedded landing HTML in `ocaml/relay.ml`

The relay landing page (search `landing_html` in `ocaml/relay.ml`) is
a public doc surface served at <https://relay.c2c.im/>. Same hygiene
rules apply — treat HTML edits there with the discipline you'd use
on a `docs/*.md` change.

## Test before commit

- For structural changes (new layouts, nav changes, front-matter):
  render locally — `cd docs && bundle exec jekyll build` if Ruby is
  set up — and eyeball the output.
- For text-only edits: review the diff for broken Markdown
  (mismatched `]()`, unclosed code fences, list breaks).
- Cross-link to runbook: peer-PASS includes a docs-up-to-date
  criterion. See `.collab/runbooks/git-workflow.md` §3 and the
  root `CLAUDE.md` "Documentation hygiene" section.
