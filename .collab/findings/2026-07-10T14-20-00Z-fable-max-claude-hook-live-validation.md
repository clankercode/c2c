# claude S3/S4 live validation: SessionStart onboard works; two real bugs found

- **When**: 2026-07-11T00:05–00:20 local (2026-07-10T14:05Z–14:20Z), vanilla claude in tmux session `c2ctest`
- **Who**: Max-driven Fable session (claude-tavi-lumi-lz83)
- **Status**: S3 VALIDATED; S4 hook delivery has a critical gap (fix slice `hook-repo-broker` in flight); identity-overwrite bug OPEN.

## What worked (S3)

Fresh vanilla `claude` in tmux, after `c2c install claude` (which now writes
`c2c-session-hook.sh` under SessionStart + SessionEnd): the session
self-onboarded — cold-boot context block injected, auto-registered
`claude-koru-yarrow-c7j4`, the model could correctly describe its onboarding.
Codex-parity achieved for claude session hooks.

Note for operators: `just install-all` only installs BINARIES. Settings-level
hook wiring requires `c2c install claude` — S3's hooks were dormant until that
ran. (Same class as the "restart yourself after MCP updates" rule: new install
surfaces need an explicit install step.)

## BUG 1 (OPEN, tracked as B119): MCP registration overwrites the hook registration's alias

Sequence in one session (sid `18e4322c…`):
1. SessionStart hook auto-registers alias `claude-koru-yarrow-c7j4`
   (repo broker), and bakes that alias into the injected cold-boot context.
2. The c2c MCP server connects moments later and re-registers the SAME
   session_id with a FRESH alias `claude-palo-saima-8fh1` — last writer wins;
   `koru-yarrow` ceases to exist.
3. Result: the model believes it is `koru-yarrow` (transcript context) but is
   addressable only as `palo-saima`. DMs to the alias the agent announces
   bounce ("not registered"); the agent never learns its real alias.

Same identity-split family as the codex managed-resume bug
(2026-07-10T14-05-00Z finding, §OPEN BUG) and B102. Fix direction: MCP
register should PRESERVE an existing alive alias for the same session_id
(adopt, not replace) — or the hook should be the identity authority and the
MCP server a joiner.

## BUG 2 (FIXED + live-validated 2026-07-11T00:44Z): delivery hooks never drained the repo broker for vanilla sessions

`c2c_inbox_hook.ml` / `c2c_stop_hook.ml` took the repo broker root ONLY from
`C2C_MCP_BROKER_ROOT` (managed-session env). Vanilla sessions have it unset →
hooks drained only the global sessions broker → peer DMs (repo broker inboxes,
where `c2c send` puts them) were NEVER hook-delivered. Live evidence: DM sat in
`18e4322c….inbox.json` through a PostToolUse fire that reported "no messages".
S4's "full delivery by default" therefore only ever applied to global-broker
messages on vanilla claude.

**Fix (slice `hook-repo-broker`, merged to local master `b04adbd2`):**
`C2c_hook_lib.resolve_hook_broker_root` — env override wins verbatim; else
falls back to the canonical repo-fp broker (`C2c_repo_fp.resolve_broker_root`),
existence-gated on `registry.json` so hooks never create broker dirs for
non-c2c repos. Wired into `c2c_inbox_hook`, `c2c_stop_hook`, and the CLI
`hook post-tool`/`hook stop` fallbacks. 4 commits (3c45bcce fix, f73669e6
tests+hermeticity, 457997eb docs, 78cc41ac Warning-10 cleanup). Opus peer-PASS,
build-clean-IN-slice-worktree-rc=0, full `@ocaml/test/runtest` rc=0, `just
check` rc=0. Hermetic tests pin `HOME`+`C2C_STATE_HOME` to a temp tree so the
new fp fallback can't touch the developer's live `~/.c2c`.

**Live validation (in the wild):** after `just install-all`, sent a fresh DM
to vanilla `claude-palo-saima-8fh1` (sid `18e4322c`, cwd = repo → fp
`8fef2c369975`), then drove a Bash-tool turn in tmux session `c2ctest`. The
repo inbox drained to 0 and the model reported verbatim: "two `<c2c
event=\"message\">` blocks arrived in my context this turn — both via a
PostToolUse:Bash hook after the echo ran, both from claude-tavi-lumi-lz83",
including full message bodies. The identical turn returned "No c2c messages
this turn" on the OLD binary. S4 mid-turn full-body hook delivery for vanilla
claude now works. NOT pushed (local hook-binary fix; deploy is coord/Max's
call).

## Collateral note: tmux server death ~00:05 — RESOLVED, operator action

The default tmux server (`/tmp/tmux-1000/default`) disappeared mid-test:
Max closed it deliberately (old, unneeded). No c2c involvement. The railmap
vite dev server survived independently. Validation continued on a fresh tmux
server (session `c2ctest`).
