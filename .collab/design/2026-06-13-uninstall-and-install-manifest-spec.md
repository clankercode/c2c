# Spec — Install transparency + `c2c uninstall <component>` (install manifest)

**Status:** Max-approved design (decisions below). Worktree `.worktrees/wt-uninstall`,
branch `feat/uninstall-manifest`, base `origin/master` @ 16064f0f.
**Goal:** every `c2c install …` prints exactly what it installed and how to remove it;
`c2c uninstall <component>` cleanly removes a specific component (its inverse), using a
recorded **install manifest** with a deterministic **recompute fallback** for installs that
predate the manifest.

## Decisions (Max, 2026-06-13)
1. **Granularity** = per-client + self + git pieces + all:
   `c2c uninstall claude|codex|kimi|opencode|self|git-hook|git-shim|all`.
2. **Tracking** = an **install receipt/manifest** file; install writes it, uninstall reads it.
3. **Uninstall default** = **execute immediately + print exactly what was removed**;
   `--dry-run` previews without changing anything (symmetry with `c2c install`). `--json` supported.
4. **Legacy installs** = **manifest-primary with recompute fallback**: when the manifest is
   absent or an artifact isn't listed, fall back to the deterministic known paths/keys from the
   surface inventory so the entire already-deployed swarm is still cleanly removable.

## Surface inventory (authoritative basis)
Full map: `.collab/research/2026-06-13-install-surface-inventory.md` (committed alongside).
Key facts that shape the design:
- **No backups are made today; no uninstall/cleanup logic exists** — greenfield.
- Every client setup already strips the prior `c2c` key before re-adding it, so the surgical
  removal target is uniformly the `c2c` stanza (`mcpServers.c2c` / `mcp.c2c` /
  `[mcp_servers.c2c*]`). This is the inverse operation we implement.
- **OWNED** artifacts (c2c is sole writer) → delete on uninstall.
  **SHARED** artifacts (c2c injected a key/stanza/block into a user-owned file) → surgically
  remove ONLY the c2c key/block; NEVER delete the whole user file.

### Component → artifacts (disposition)
- **self**: OWNED `~/.local/bin/{c2c,c2c-mcp-server,c2c-mcp-inner,c2c-inbox-hook-ocaml,
  c2c-cold-boot-hook,c2c-post-compact-hook,cc-quota,c2c-deliver-inbox,c2c-gui}`,
  `~/.local/bin/.c2c-version`. (Guard: removing the running `c2c` is allowed but WARNED.)
- **git-shim**: OWNED `$XDG_STATE_HOME/c2c/bin/{git,git-pre-reset}` +
  `~/.local/share/c2c/instances/*/bin/{git,git-pre-reset}`.
- **git-hook**: `.git/hooks/{pre-commit,pre-push}` — remove ONLY if it is the c2c copy/symlink
  (symlink into `scripts/git-hooks/`, or byte-equal to `.c2c/hooks/pre-commit.sh`); else leave.
- **claude**: OWNED `~/.claude/hooks/{c2c-inbox-check.sh,c2c-stop-deliver.sh}`. SHARED
  `mcpServers.c2c` in project `.mcp.json` AND/OR global `~/.claude.json`; SHARED
  `~/.claude/settings.json` → drop `hooks.PostToolUse[]`/`hooks.Stop[]` entries whose command
  points at the two c2c scripts + the `__C2C_PREAUTH_DISABLED__` PreToolUse sentinel entry.
- **codex**: SHARED `~/.codex/config.toml` → strip every `[mcp_servers.c2c*]` section. OWNED
  `~/.c2c/clients/codex/{deliver-watch.sh,start-hooks/pre-deliver.sh}` (+ runtime pid/log/session-id).
- **kimi**: SHARED `~/.kimi/mcp.json` → `mcpServers.c2c`; SHARED `~/.kimi/config.toml` → remove the
  `# c2c-managed:BEGIN/END preuse-approval-hook-142` block (+ legacy marker). OWNED
  `~/.local/bin/c2c-kimi-approval-hook.sh`, `~/.c2c/clients/kimi/{…}`.
- **opencode**: SHARED `<target>/.opencode/opencode.json` → `mcp.c2c`. OWNED
  `<target>/.opencode/{c2c-plugin.json, plugins/c2c.ts}` (unlink symlink-or-file),
  `~/.c2c/clients/opencode/{…}`.
- **cross-client schedule**: OWNED `<schedule_root>/<alias>/wake.toml` (needs install-time alias).
- (crush/gemini: deprecated; uninstall MUST still surgically remove a legacy `mcpServers.c2c` +
  `~/.c2c/clients/{crush,gemini}/` if present, for completeness — recompute path only.)
- **all** = self + git-shim + git-hook + every client that has a manifest record or a detectable
  install (recompute), in a safe order (clients → schedules → git pieces → self last).

## Manifest
- Path: `$XDG_STATE_HOME/c2c/install-manifest.json` (else `~/.local/state/c2c/…`). Single file,
  flock-guarded atomic write (reuse the broker atomic-write idiom).
- Shape:
  ```json
  { "version": 1,
    "installs": [
      { "component": "opencode", "alias": "codex-ember-frost",
        "target_dir": "/abs/project", "c2c_version": "<stamp>", "ts": 1781280000.0,
        "artifacts": [
          {"kind":"owned-file","path":"/abs/project/.opencode/plugins/c2c.ts"},
          {"kind":"owned-file","path":"/abs/project/.opencode/c2c-plugin.json"},
          {"kind":"shared-key","path":"/abs/project/.opencode/opencode.json","key":"mcp.c2c","format":"json"},
          {"kind":"schedule","path":"<schedule_root>/codex-ember-frost/wake.toml"}
        ] } ] }
  ```
- `kind ∈ owned-file | symlink | binary | schedule | shared-key | shared-block`.
  `shared-key` carries `{path,key,format:json|toml}`; `shared-block` carries
  `{path,begin_marker,end_marker,legacy_marker?}`; `shared-toml-section` carries
  `{path,section_prefix:"mcp_servers.c2c"}`.
- **Re-install replaces** the prior record for the same `(component, target_dir)` (no dup growth).
- Manifest write is **best-effort**: a manifest-write failure MUST NOT fail the install (log a
  warning). The recompute fallback covers any gap.

## Install-time output (every `install …`, both Human + `--json`)
After a successful component install, print a consolidated block:
```
Installed c2c for <component>:
  owned:
    + ~/.local/bin/c2c-inbox-check.sh           (file)
    + ~/.claude/hooks/c2c-stop-deliver.sh        (file)
  shared (c2c stanza added to your files):
    ~ ~/.claude/settings.json                    (hooks.PostToolUse[], hooks.Stop[])
    ~ .mcp.json                                  (mcpServers.c2c)
To remove: c2c uninstall <component>   (preview: c2c uninstall <component> --dry-run)
```
`--json` adds an `installed` array mirroring the manifest artifacts. Honor existing `--dry-run`
(prints the same block prefixed "Would install").

## `c2c uninstall <component>` CLI
- Components: `claude codex kimi opencode self git-hook git-shim all`.
- Flags: `--dry-run` (preview only), `--json`, `--target-dir DIR` (for opencode/claude project
  scope, default cwd), `--alias A` (to locate the wake schedule when not in the manifest).
- Behavior: resolve artifacts = manifest record for the component (+ recompute fallback for
  anything not in the manifest / when no manifest). For each artifact: OWNED → unlink (report);
  SHARED-key → load file, remove key, atomic-rewrite (report; if file becomes empty of meaningful
  content, still leave the file); SHARED-block → strip marker-delimited block; SHARED-toml-section
  → strip `[mcp_servers.c2c*]` sections. NEVER delete a shared file wholesale. Report a summary;
  `--dry-run` prints what WOULD be removed and changes nothing. Exit 0 even if nothing found
  (idempotent), print "nothing to remove for <component>".
- Safety rails: never touch a path outside the known set; `self` prints a warning that it removes
  the running binary; `git-hook` only removes verified-c2c hooks; remove the manifest record on
  success (so re-running is a clean no-op).

## Tests (MANDATORY — Max requirement; good coverage is a peer-PASS gate)
Fixture-gated, no real HOME mutation (use temp HOME / temp dirs, the existing test idiom):
- manifest round-trip (write → read → schema); re-install replaces same-component record.
- install writes a manifest record for each of claude/codex/kimi/opencode/self with the expected
  artifacts (use the existing setup_* tests' temp-HOME harness).
- uninstall OWNED: creates temp owned files + manifest, `uninstall <c>` deletes them; `--dry-run`
  leaves them.
- uninstall SHARED-key: a user `opencode.json`/`.mcp.json`/`mcp.json` with BOTH a user key and
  `c2c` → after uninstall the user key SURVIVES and only `c2c` is gone (the critical safety test).
- uninstall SHARED-block: kimi `config.toml` with the BEGIN/END block + surrounding user content →
  block removed, user content intact; legacy-marker variant.
- uninstall codex `[mcp_servers.c2c*]` sections stripped, other `[mcp_servers.*]` intact.
- **recompute fallback**: with NO manifest, a hand-placed install is still removed.
- git-hook: removes c2c copy/symlink, LEAVES a non-c2c pre-commit.
- idempotent: uninstall twice → second run reports nothing, exit 0.
- install-time output: asserts the "Installed … To remove: c2c uninstall" block appears (Human +
  `--json` `installed` array present).

## Out of scope (v1)
- Restoring a pre-c2c backup (none is taken today; uninstall is removal, not restore).
- Uninstalling the broker data / registry / per-agent memory (that's `sweep`/data, not install).
- Touching shell rc files (PATH prepend is process-env only — nothing to undo).

## Slices
- **U1** manifest module (`c2c_install_manifest.ml` + `.mli`): schema, atomic read/write/append,
  `replace_record`, path resolution; unit tests. No behavior change yet.
- **U2** wire manifest writes + consolidated install-output into each install path
  (`do_install_client`, `do_install_self`, git-shim/git-hook) + `--dry-run`/`--json`; tests.
- **U3** `c2c uninstall` command (manifest-driven removal + recompute fallback + per-component
  removers + `--dry-run`/`--json`/safety rails); the SHARED-key/block/section surgical removers
  reuse install's JSON/TOML helpers; full uninstall test matrix.
- **U4** docs: `docs/commands.md` (install output note + `uninstall` rows), install runbook,
  `CLAUDE.md` pointer; docs-up-to-date gate.

## Final step — REVIEW-AND-FIX LOOP (required)
Each slice: commit → `review-and-fix` until PASS → DIFFERENT-model ccc peer-PASS with
`build-clean-IN-slice-worktree-rc=0` AND explicit **test-coverage** verification (esp. the
SHARED-file safety test: user keys survive). Do NOT push; lands after Max review.
