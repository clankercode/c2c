# c2c install / uninstall runbook

Operational reference for installing and removing c2c client integrations.

## Install

```bash
# Interactive TUI — detects clients, installs binary + configures each
c2c install

# Binary only (also the default for `c2c install all` unless --with-clients)
c2c install self
c2c install all                 # binary only
c2c install all --with-clients  # binary + configure detected clients

# One client (replaces legacy configure-* scripts)
c2c install codex --alias my-alias
c2c install claude --alias my-alias
c2c install opencode --alias my-alias --target-dir ./my-project --force
c2c install grok --alias my-alias   # CLI-first: skill + SessionStart hooks (no MCP)
c2c install kimi --alias my-alias   # writes ~/.kimi-code/mcp.json + config.toml + skill

# Git hooks in the current repo (explicit opt-in only)
c2c install git-hook
```

**Grok** is a first-class **CLI-first** peer: `c2c install grok` writes the
embedded skill + SessionStart/SessionEnd hooks under `~/.grok/` (no MCP).
Managed `c2c start grok` remains deferred — use the Grok CLI skill path.

Every successful component install prints a consolidated summary:

```
Installed c2c for <component>:
  owned:
    + /path/to/c2c-owned-file           (file)
  shared (c2c stanza added to your files):
    ~ /path/to/user-config-file         (mcpServers.c2c)
To remove: c2c uninstall <component>   (preview: c2c uninstall <component> --dry-run)
```

Use `--dry-run` to preview and `--json` for machine-readable output.

### Git hooks are disabled by default

As of 2026-06-18, the repo-local `.git/hooks/pre-commit` and
`.git/hooks/pre-push` symlinks are not installed automatically by
`just install-all` / `just bi`, and the c2c main checkout has those hooks
removed unless an operator explicitly reinstalls them.

The hook scripts remain available under `scripts/git-hooks/` for operators who
want them:

- `pre-commit` checks staged `.opencode/plugins/*.ts` changes with
  `bun build .opencode/plugins/c2c.ts --target=bun`.
- `pre-push` rejects non-coordinator pushes to `origin/master` for remotes that
  look like the c2c repo; `C2C_COORDINATOR=1` bypasses it.

Install them only when that repo-local policy is desired:

```bash
just install-git-hooks
```

## Uninstall

```bash
# Per-component (uses install manifest, falls back to deterministic known paths)
c2c uninstall codex
c2c uninstall claude --target-dir ./my-project
c2c uninstall opencode --target-dir ./my-project
c2c uninstall grok
c2c uninstall kimi --alias my-alias
c2c uninstall git-hook
c2c uninstall git-shim
c2c uninstall self     # warns: removes the running c2c binary

# Everything: clients → git pieces → self last
c2c uninstall all
```

Safety rules:

- **Shared files are stripped, never deleted.** `mcpServers.c2c`, `mcp.c2c`,
  `[mcp_servers.c2c*]` sections, and kimi's BEGIN/END block are removed; any
  user-owned keys/sections survive.
- **Owned files are deleted.** These are files c2c is the sole writer of
  (binaries, deliver-watch scripts, schedules, hooks).
- **Git hooks are verified.** `c2c uninstall git-hook` only removes hooks that
  are byte-equal to the c2c source or are symlinks into `scripts/git-hooks/`.
- `--dry-run` previews changes; `--json` emits machine-readable output.
- Running uninstall twice is idempotent: the second run reports
  "nothing to remove for <component>" and exits 0.

## Install manifest

Installs write a receipt to `$XDG_STATE_HOME/c2c/install-manifest.json`
(falling back to `~/.local/state/c2c/install-manifest.json`). The manifest is
updated atomically with a file lock. A manifest-write failure does **not** fail
the install; the uninstall recompute fallback covers any gap.
