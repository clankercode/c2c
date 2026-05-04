# Broker-root fallthrough → swarm split-brain

- **UTC:** 2026-04-30T10:29Z
- **Filed by:** stanza-coder (with diagnosis from coordinator1 / Cairn-Vigil)
- **Severity:** HIGH — silently splits the swarm into two non-communicating registries
- **Status:** CLOSED — fix at e7686142 (resolver rejects legacy env var, uses canonical path + warns on stderr). Prior partial fixes: #503 (MCP server delegated to canonical resolver), #504/#514 (instance config drift prevention). Self-review PASS; awaiting peer-PASS.

## Symptom

After a coordinated broker migration in which `broker_root` was scrubbed
(set to `""`) from all 1252 instance configs, two broker registries
ended up actively written to in parallel:

- `~/.c2c/repos/91816a939438/broker/` — canonical, post-migration target
- `.git/c2c/mcp/` — legacy, pre-migration path

Different processes routed to different registries depending on env, so
DMs intended for "coordinator1" went to whichever instance happened to
share the writer's registry. Receipt confirmation impossible by design,
so the split was invisible without `/proc/<pid>/environ` audit.

## Discovery

1. Stanza launched a fresh coordinator1 via
   `scripts/c2c_tmux.py launch claude -n coordinator1` from a shell that
   had `C2C_MCP_BROKER_ROOT=…/91816a939438/broker` exported.
2. Stanza's DM "Welcome back" was sent to that fresh coord (pid 3654611)
   but read by the *original* coord (pid 211434, surviving via MCP
   reconnect from a different tmux pane).
3. `/proc/<pid>/environ | tr '\0' '\n' | grep C2C_MCP` showed only
   stanza's pid 3649226 had `C2C_MCP_BROKER_ROOT` set. The fresh coord,
   the opencode trio (galaxy/jungle/test-agent-oc) Max launched, and
   the original coord all lacked it.
4. Both registries showed live writes (broker dir mtime + new
   `.inbox.json` files for the same aliases).

## Root cause hypothesis

CLAUDE.md documents the canonical resolver order as:

> `C2C_MCP_BROKER_ROOT` env → `$XDG_STATE_HOME/c2c/repos/<fp>/broker`
> → `$HOME/.c2c/repos/<fp>/broker` (canonical default).

But empirically, processes without `C2C_MCP_BROKER_ROOT` and without
`XDG_STATE_HOME` are landing on `.git/c2c/mcp/` — the legacy path.
That implies one of:

1. **Resolver still has a legacy fallback.** Some code path (possibly
   `c2c_start.ml` or `c2c_broker_root.ml` or wherever the OCaml
   resolver lives) prefers `.git/c2c/mcp/` when the directory already
   exists, before falling back to the canonical home. The migration
   left `.git/c2c/mcp/` intact (data preserved), so the existence
   check still passes.
2. **Saved-config override beats env default.** Cairn's recent fix
   (commit `e3b0d76b`, `fix(#501): c2c start crashes when instance
   config has no broker_root`) made empty `broker_root` fall through
   to `broker_root()` — but only for resume. New starts may pick up a
   different default.
3. **Outer-loop wrapper strips env.** `c2c-start/<name>` wrappers may
   build a clean child environment from the saved config rather than
   inheriting the launcher's env. The launcher had
   `C2C_MCP_BROKER_ROOT` set; the inner agent processes do not.

(1) seems most consistent with the observed selectivity — only stanza,
who explicitly passes the env, hits canonical. Everyone else hits
legacy regardless of how they were launched.

## Reproduction

```sh
# audit which alive c2c-start child processes have the env var
for pid in $(pgrep -f c2c-start); do
  printf "pid=%s env=%s\n" "$pid" \
    "$(tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep ^C2C_MCP_BROKER_ROOT= || echo 'UNSET')"
done

# check both registries are alive
ls -la ~/.c2c/repos/*/broker/*.inbox.json | tail
ls -la .git/c2c/mcp/*.inbox.json 2>/dev/null | tail
```

A swarm where the second `ls` returns ANY recently-written file is
split-brained. After the migration, `.git/c2c/mcp/` should be
read-only (or absent).

## Mitigations (interim, until resolver is fixed)

- **Launchers must export `C2C_MCP_BROKER_ROOT`** before spawning
  managed agents, OR `c2c_tmux.py launch` should inject it into the
  child's environment.
- **Don't trust `c2c list` / `c2c instances` to detect split-brain** —
  each tool reads only one registry. Compare `inbox.json` mtimes
  across both paths.
- **Don't `c2c sweep`** while split-brained — different views of
  liveness will drop registrations on whichever side runs.

## Suggested follow-ups

1. **Code audit:** `grep -rn "\.git/c2c\|broker_root\|c2c/mcp" ocaml/`
   to find every place the legacy path is referenced. Either delete
   the fallback or guard it behind an explicit migration flag.
2. **`c2c doctor` should detect split-brain:** add a check that walks
   both candidate broker roots, reports any with recent writes, and
   FAIL-loud if more than one is live.
3. **Migration completion gate:** after a migration, the legacy
   directory should be renamed (e.g. `.git/c2c/mcp.migrated-<ts>`) so
   any process still routing there fails-loud rather than silently
   continuing to write.
4. **Doc reconciliation:** if the resolver implementation diverges
   from CLAUDE.md's documented order, update one or the other so
   future migration plans reason from accurate ground truth.

## Cross-refs

- `c2c_start.ml` — `load_config_opt` strict-getter fix (Cairn,
  commit `e3b0d76b`).
- `CLAUDE.md` § Key Architecture Notes — broker-root resolution order.
- `scripts/c2c_tmux.py launch` — env propagation behaviour worth
  inspecting.

— stanza-coder, with thanks to coordinator1 for the diagnosis hand-off.
