# Finding: Claude PostToolUse hook errors after profile-share migration (dangling `c2c-inbox-check.sh`)

- **UTC**: 2026-06-13
- **Reporter**: orchestrator-claude (dogfooding, surfaced by Max)
- **Severity**: medium (non-blocking noise on every Bash tool call; PostToolUse c2c
  auto-delivery silently dead for affected sessions — messages fall back to polling)
- **Status**: FIXED (ops remediation done; preventive `c2c doctor` check in progress)

## Symptom

In a live Claude session (CLAUDE_CONFIG_DIR = `~/.claude-w`), **every** Bash tool call
emitted two non-blocking PostToolUse hook errors:

```
PostToolUse:Bash hook error — /bin/sh: line 1:
  /home/xertrov/.claude-w/hooks/c2c-inbox-check.sh: No such file or directory
PostToolUse:Bash hook error — /bin/sh: line 1:
  /home/xertrov/.claude-p/hooks/c2c-inbox-check.sh: No such file or directory
```

`settings.json` referenced the hook scripts but the files did not exist on disk.

## Root cause

NOT a c2c bug. On **2026-05-31 00:54** a profile-sharing migration (Max's dotfiles
tooling, external to this repo) converted `~/.claude`, `~/.claude-p`, `~/.claude-w`
into shared profiles: each per-profile subdir was renamed to `<dir>.pre-share.<ts>/`
and replaced with a symlink into a single `~/.claude-shared/<dir>`. This was applied
to `agents`, `plans`, `sessions`, `hooks`, etc.

For `hooks/` specifically, the migration created the symlink
`~/.claude-{,p,w}/hooks -> ~/.claude-shared/hooks` but **never copied the existing
`c2c-inbox-check.sh`** from the per-profile `hooks.pre-share.*/` into the new shared
target. So `~/.claude-shared/hooks/` stayed empty and every symlinked reference
`~/.claude-*/hooks/c2c-inbox-check.sh` dangled.

Aggravating factor: `~/.claude-w/settings.json` carried **two** PostToolUse groups
(same matcher `^(?!mcp__).*`) — one pointing at `.claude-p/hooks/...` and one at
`.claude-w/hooks/...` — i.e. a stale cross-profile duplicate that would have
double-fired even once restored.

The c2c install code is correct: the live `do_install_client` path
(`ocaml/cli/c2c_setup.ml`, ~line 1193) resolves the hooks dir from `claude_dir`
(= `CLAUDE_CONFIG_DIR` else `~/.claude`) and writes the script through whatever that
path is (symlink-transparent). The hardcoded `~/.claude/hooks` at
`configure_claude_hook` (~line 1006) is the **dead** alt-copy and is not on the
install path (and would now resolve through the symlink anyway).

## Fix (ops remediation, applied 2026-06-13)

1. Regenerated the **canonical current** `c2c-inbox-check.sh` + `c2c-stop-deliver.sh`
   (via a throwaway `HOME`/`CLAUDE_CONFIG_DIR` `c2c install claude`) — confirmed the
   April backup was stale (used legacy `c2c hook`; current uses `c2c-inbox-hook-ocaml`).
2. Copied both into `~/.claude-shared/hooks/` (chmod +x). All three profiles
   (`.claude`, `.claude-p`, `.claude-w`) symlink to it, so this fixed every profile at once.
3. De-duped `~/.claude-w/settings.json` PostToolUse — removed the stale `.claude-p`
   cross-ref group, kept the single own-profile `.claude-w/hooks/...` entry
   (backup: `~/.claude-w/settings.json.bak-20260613-c2c-hookdedup`).
4. Verified: scripts resolve through all symlinks, hook runs clean (exit 0), and a
   full sweep of every `settings*.json` + codex/kimi configs shows **zero** remaining
   dangling c2c script refs.

## Remediation runbook (if it recurs after any profile re-share)

Re-run `c2c install claude` once per active `CLAUDE_CONFIG_DIR` (it writes the hook
script through the symlink into `~/.claude-shared/hooks/` and refreshes the settings
entry idempotently). Or copy a freshly-generated `c2c-inbox-check.sh` into
`~/.claude-shared/hooks/` directly.

## Preventive (in progress)

Adding a check to `c2c doctor` that scans the resolved Claude `settings.json` hook
`command` paths and flags any that don't exist on disk, with a one-line remediation
hint — so this drift surfaces immediately instead of as per-Bash-call noise.
