# install-all removed c2c-stop-hook-ocaml on every run and never reinstalled it

- **When**: 2026-07-10T13:25Z (discovered during S4/S2 live-validation install)
- **Who**: Max-driven Fable session
- **Severity**: HIGH (silent delivery outage for vanilla claude turn-boundary drain)
- **Status**: FIXED (`14aed4b3`)

## Symptom

After `just install-all`, `~/.local/bin/c2c-stop-hook-ocaml` was gone. The
recipe's `rm -f` list included the stop hook but the `cp` block did not —
every install deleted the binary and never put it back. The `install-quick`
recipe (line ~466) *did* have the cp, so anyone using `just bi` got it back,
masking the bug intermittently depending on which recipe last ran.

## Impact

Claude settings register a Stop hook pointing at that path. With the binary
missing, the Stop hook fails silently (Claude Code ignores failing hooks), so
the turn-boundary drain never ran for vanilla claude sessions. As of S4
(claude-full-delivery, merged 2026-07-10) the Stop hook is the ONLY path that
delivers **deferrable** messages to vanilla claude mid-session — so this
one-line omission silently reintroduced the exact gap S4 closed.

## Root cause

`d3974c2d` (B035) added the stop-hook install to one recipe but the
`install-all` copy block was missed; the `rm -f` list was updated in both.
Classic paired-list drift — the rm list and cp list live 10 lines apart with
no check that they match.

## Fix

`14aed4b3` adds the missing
`cp _build/default/ocaml/tools/c2c_stop_hook.exe ~/.local/bin/c2c-stop-hook-ocaml`
to `install-all`. Verified: binary present after reinstall.

## Follow-up idea (not done)

A tiny guard in the install recipe (or `c2c doctor`): every path in the
`rm -f` list must be recreated by the end of the recipe — diff the two lists
or stat the paths in `c2c-install-stamp.sh` and fail loudly on a missing one.
`c2c health` could also check that every hook command referenced in claude
settings resolves to an existing executable (it already has a dangling-hook
check — extend it to stat the target).
