# Doc-drift audit 2026-04-28

**Author:** stanza-coder
**Date:** 2026-04-28 14:22 AEST

Read-only audit. Methodology: ran `c2c --help` + each subcommand --help, ran
`c2c doctor docs-drift`, then grep-cross-checked front-door docs (`docs/index.md`,
`docs/overview.md`, `docs/architecture.md`, `docs/MSG_IO_METHODS.md`,
`docs/client-delivery.md`, root `CLAUDE.md`) and the `.collab/runbooks/` set
against the OCaml source of truth (`ocaml/cli/c2c.ml`, `ocaml/c2c_mcp.ml`,
`ocaml/server/c2c_mcp_server.ml`, `ocaml/cli/c2c_setup.ml`).

## Summary

- 12 drifted items found: **4 high / 5 med / 3 low**
- 1 high item is the broker-root migration (2026-04-26, coord1) — front-door
  docs still describe `.git/c2c/mcp/` everywhere; this is the single biggest
  carryover.
- `c2c doctor docs-drift` flags 1 finding by itself (`c2c_verify.py` in
  CLAUDE.md:322); the other 11 are below its current rule set.
- #334 (project-scoped `.mcp.json`) is on a slice branch not yet on master,
  so today's binary still writes `~/.claude.json` and matches the live docs —
  **not filed as drift**, but the update will need to land in the same slice
  as the merge.
- `c2c install claude --global` is documented in `docs/clients/feature-matrix.md`
  but `c2c install claude --help` shows no `--global` flag in the installed
  binary. Same gating: lands with #334.

## High-severity (user actively misled)

- `docs/architecture.md:29` and `:50` — claims broker root is
  `.git/c2c/mcp/` (the **git common dir**). Code: `c2c_mcp_server.ml:17,26`
  and `c2c_mcp.ml:908` resolve in priority `C2C_MCP_BROKER_ROOT` →
  `$XDG_STATE_HOME/c2c/repos/<fp>/broker` → `$HOME/.c2c/repos/<fp>/broker`.
  Verified live: `~/.c2c/repos/8fef2c369975/` exists and is the active
  broker; `.git/c2c/mcp/` only retains stale lockfiles. **Fix:** rewrite
  the "Broker root" subsection to match `CLAUDE.md` line 318; add a
  pointer to `c2c migrate-broker --dry-run`.

- `docs/overview.md:33` (ASCII diagram) and `:45` ("git common dir") and
  `:129` (rooms path `.git/c2c/mcp/rooms/`) — same drift as architecture.md.
  Front-door page; high traffic. **Fix:** redraw the diagram with the
  per-repo path; reword §"Storage Layout" / §"Group Rooms".

- `docs/MSG_IO_METHODS.md:561` — env-var table claims default for
  `C2C_MCP_BROKER_ROOT` is `.git/c2c/mcp`. **Fix:** change default column to
  `$HOME/.c2c/repos/<fp>/broker` (or note "see `c2c_mcp_server.ml`
  resolution chain"). Already partially flagged as stale in `#334`
  follow-ups; broker-root row was missed.

- `docs/known-issues.md:73` — "The broker root lives in `.git/c2c/mcp/`."
  Same factual error; user-facing troubleshooting context. **Fix:** one-line
  rewrite to match the canonical path.

## Med (stale but not actively misleading)

- `docs/cross-machine-broker.md:10,80,81` — broker-root narrative still
  built around `.git/c2c/mcp/`. Doc is mostly historical/design framing,
  but the very first paragraph sets the wrong mental model. **Fix:** add
  a "Path moved 2026-04-26" callout near top.

- `docs/relay-quickstart.md:10` — "stores broker state under
  `.git/c2c/mcp/`". Not load-bearing for the relay procedure (the rest
  of the page parameterises via `C2C_MCP_BROKER_ROOT`). **Fix:** one-line
  rewrite of the orienting sentence.

- `CLAUDE.md:319` — "Session discovery scans `~/.claude-p/sessions/`,
  `~/.claude-w/sessions/`, `~/.claude/sessions/`". Verified live: only
  `~/.claude/sessions/` exists; the `-p` and `-w` variants are gone.
  Code that depends on those paths (if still present) is best-effort.
  **Fix:** trim to the single existing path or note the others as
  legacy.

- `CLAUDE.md:317,322` — references hand-rolled YAML registry in
  `c2c_registry.py` and `c2c_verify.py` envelope counter. Both files
  still exist at the repo root, but the OCaml registry
  (`c2c_registry.ml`) is the live source; line 322 is what
  `c2c doctor docs-drift` already flags. Severity = med because the
  OCaml side is canonical and the Python is shim/diagnostic. **Fix:**
  rewrite both bullets to lead with the OCaml module and note the
  Python as fallback.

- `docs/MSG_IO_METHODS.md:158,199,211` and `docs/overview.md:86` — the
  PTY-injection table cites `claude_send_msg.py` as the legacy entry
  point. The script *does* still exist at the repo root, so this isn't
  factually wrong, but the surrounding text in MSG_IO_METHODS already
  marks the path "Deprecated". The drift is conceptual: today's
  Claude-Code delivery is the OCaml `c2c-deliver-inbox` binary +
  PostToolUse hook (mentioned in row 208 of the same doc). **Fix:**
  collapse the legacy row to a footnote; remove `claude_send_msg.py`
  from the headline path.

## Low (cosmetic/cross-reference)

- `docs/MSG_IO_METHODS.md:80,81,158,314` — file paths
  `ocaml/c2c_mcp.ml`, `ocaml/server/c2c_mcp_server.ml`, `ocaml/cli/c2c_setup.ml`
  all verified to exist; no line numbers cited; clean. Listed here so
  future audits know these specific cells are GOOD as of today.

- `CLAUDE.md:333` — "`filter_commands` in `c2c.ml`" — function is
  actually defined in `ocaml/cli/c2c_commands.ml:119` and only *called*
  from `c2c.ml:8586`. Trivial mis-citation; not actionable on its own
  but worth correcting on next pass.

- `docs/index.md:93` and `docs/overview.md:169,191,199` describe
  `c2c install <client>` writing to `~/.claude.json` / `~/.codex/config.toml`
  / `~/.kimi/mcp.json`. These match the **currently installed binary**
  (#334 not yet on master). Listed as low-risk *known-pending* drift —
  must land docs in the same slice when #334 merges. The `--global`
  flag mentioned in `docs/clients/feature-matrix.md` (per the #334 diff)
  similarly gates on that merge. Already tracked by #334; do not
  double-file.

## Already-clean (verified, do not touch)

- `c2c --help` output and `docs/commands.md` Tier-1/Tier-2 lists are
  consistent; every top-level subcommand from `c2c --help` appears in
  `docs/commands.md` (spot-checked: `worktree gc`, `doctor delivery-mode`,
  `doctor docs-drift`, `doctor opencode-plugin-drift`,
  `coord-cherry-pick --no-dm`, `install ... --dry-run`).
- `docs/commands.md:711` — `worktree gc` flags (`--clean`,
  `--ignore-active`, `--json`, `--path-prefix`, `--active-window-hours`)
  match `c2c worktree gc --help` exactly.
- `docs/commands.md:619-622` — `doctor` subcommand list matches
  `c2c doctor --help` (delivery-mode, docs-drift, monitor-leak,
  opencode-plugin-drift). `nudge-flood` from #335 v0 is correctly
  ABSENT — the slice has not landed.
- `docs/commands.md` § Memory CLI matches the binary surface (list/read/
  write/delete/grant/revoke/share/unshare).
- Env var inventory in `CLAUDE.md` § Key Architecture Notes — all 9 vars
  spot-checked are still read by the OCaml binary
  (`C2C_MCP_BROKER_ROOT`, `C2C_MCP_AUTO_REGISTER_ALIAS`,
  `C2C_MCP_AUTO_JOIN_ROOMS`, `C2C_MCP_SESSION_ID`,
  `C2C_MCP_INBOX_WATCHER_DELAY`, `C2C_CLI_FORCE`,
  `C2C_NUDGE_CADENCE_MINUTES`, `C2C_NUDGE_IDLE_MINUTES`,
  `C2C_INSTALL_FORCE`).
- GitHub-org URLs in `docs/*.md` are uniformly `XertroV/c2c-msg`. The
  one `anomalyco/c2c` reference in the binary's `c2c --help` exit-code
  text (`ocaml/cli/c2c.ml:8604`) was previously flagged in
  `.collab/runbooks/documentation-hygiene.md:44` and is still present
  in the binary; out of scope for a *docs* drift audit but worth a
  follow-up at the source level. Worktree copies (`.c2c/worktrees/*`)
  carry stale copies of the same string — read-only artifact, ignore.
- `scripts/c2c-swarm.sh` and `scripts/c2c_tmux.py` referenced from
  `CLAUDE.md` lines 66/69/97 both exist on disk.
- `c2c install codex-headless`, `install opencode`, `install kimi`,
  `install crush`, and `install git-hook` subcommands all enumerated in
  the CLI; `docs/commands.md:566` enumerates them too.

## Recommended fix-slice shape

A single doc slice can land items 1–4 (high) and 5–6 (med, broker-root
narrative): one find/replace pass on `.git/c2c/mcp/` →
`$HOME/.c2c/repos/<fp>/broker` across `architecture.md`, `overview.md`,
`MSG_IO_METHODS.md`, `known-issues.md`, `cross-machine-broker.md`,
`relay-quickstart.md`. Re-render the ASCII diagram in `overview.md:33`.
Item 7 (`CLAUDE.md:319` claude-p/-w paths) is one-line. Items 8–9 are a
small CLAUDE.md re-pass that should bundle with the other CLAUDE.md
hygiene edits the swarm has been deferring.

Estimate: 1 worktree, ~30-45 min, single commit, peer-PASS via
`review-and-fix` (uses #324 docs-up-to-date criterion).

The `c2c doctor docs-drift` rule set could grow to catch the
broker-root drift class — currently it only flags the
deprecated-Python-script pattern. Filing as a follow-up, not part of
this audit's fix.
