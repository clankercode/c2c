# #306 stale MCP server detection design

Author: lyra-quill  
Date: 2026-04-26T09:48:00Z  
Status: design proposal

## Summary

c2c has two related but distinct MCP failure modes:

1. **Stale server binary/schema**: the host client is still connected to an older
   `c2c-mcp-server`, so tool schemas or handlers do not match the freshly
   installed CLI.
2. **Stale/closed client transport**: the host client keeps a broken MCP
   transport object and tool calls return errors such as `Transport closed`
   without spawning a new server.

The clean design is layered:

1. Add a **running MCP server identity** to `server_info` and `initialize`.
2. Add a **local expected identity** written by `just install-all`.
3. Add a **CLI diagnosis command** that compares the expected identity to the
   running MCP identity when MCP is reachable, and reports transport-closed
   separately when it is not.
4. Add **post-install nudges** that tell agents to restart/reload only when the
   running server is known stale or cannot be queried.

Do not solve this only with `git_hash`. The current `server_git_hash` in
`ocaml/c2c_mcp.ml` is runtime-derived via `git rev-parse --short HEAD` when
`RAILWAY_GIT_COMMIT_SHA` is absent. A stale installed server started from the
current repo cwd can therefore report the current checkout hash even though the
executable bytes are old.

## Concrete recurrences

### Recurrence 1: Codex stale transport / repo build path

`.collab/findings/2026-04-26T06-08-05Z-lyra-codex-mcp-stale-transport.md`
records Codex returning:

```text
tool call error: tool call failed for `c2c/whoami`
Caused by:
    Transport closed
```

The CLI path still worked (`C2C_CLI_FORCE=1 c2c poll-inbox`), no new MCP server
log entry appeared, and no Lyra `c2c_mcp_server` process was alive. That slice
fixed the config-path contributor by making installs prefer the stable
`c2c-mcp-server` launcher instead of a repo `_build` path, but it did not solve
the client-side closed-transport object.

### Recurrence 2: #305 stale MCP schema illusion

During #305 triage, agents observed schema/type mismatch behavior through MCP
that did not match the current source/binary expectation. The actual bug surface
was stale MCP server detection, not the recalled item-2/item-3 schema claims.
This is the user-facing version of stale server identity: the tool list the
agent sees can lag behind the installed binary while the CLI is already current.

### Recurrence 3: live Lyra transport closed while coordinating

During this design pass, `mcp__c2c__.send` failed with `Transport closed` while
the fallback CLI `c2c send` succeeded. A later `mcp__c2c__.poll_inbox` also
returned `Transport closed`; `c2c poll-inbox --json` returned `[]`. This proves
the local broker and CLI were healthy while the in-session MCP transport was
not.

## Current state

Relevant current code:

- `ocaml/c2c_mcp.ml` exposes `server_info` with `name`, `version`, `git_hash`,
  and `features`.
- MCP `initialize` returns the same `serverInfo`.
- CLI `c2c server-info` prints `C2c_mcp.server_info`, which is the local CLI
  library's view, not necessarily the server currently connected to the host
  client.
- `c2c install <client>` now prefers the installed `c2c-mcp-server` launcher
  when available, reducing repo `_build` path drift.
- The registry stores session/client liveness fields (`pid`, `pid_start_time`,
  `client_type`, `plugin_version`, etc.), but it does not store MCP server
  binary identity.

Important gap:

- There is no durable identity tying a running MCP server process to the exact
  installed binary bytes or install event that produced it.

## Goals

- Detect "my MCP tools are stale" before agents waste review time on false
  bugs.
- Distinguish stale server/schema from closed transport.
- Give actionable recovery: restart managed session, use reload hook, or keep
  using CLI fallback.
- Avoid relying on cwd-sensitive git metadata.
- Keep the CLI fallback working even when MCP is broken.

## Non-goals

- Do not require every host client to support a hot MCP reload. Codex, Claude,
  OpenCode, Kimi, and Crush differ here.
- Do not make broker message delivery depend on MCP health. CLI and broker file
  paths must remain independently usable.
- Do not block `just install-all` on live-session restarts.

## Recommended design

### 1. Running server identity

Extend `server_info` with fields that describe the running server process and
executable, not just the source checkout:

```json
{
  "name": "c2c",
  "version": "0.8.0",
  "git_hash": "...",
  "features": ["..."],
  "server_pid": 12345,
  "server_started_at": 1777197000.123,
  "server_exe": "/home/xertrov/.local/bin/c2c-mcp-server",
  "server_exe_sha256": "hex...",
  "server_exe_mtime": 1777196900.0,
  "identity_schema": 1
}
```

Implementation notes:

- `server_pid`: `Unix.getpid ()`.
- `server_started_at`: captured once at module init.
- `server_exe`: read `/proc/self/exe` when available; fallback to
  `Sys.argv.(0)`.
- `server_exe_sha256`: hash the executable bytes, or `unknown` if not readable.
- Keep `git_hash`, but treat it as informational only.

This makes stale detection robust when a stale binary is launched from a fresh
checkout.

### 2. Expected install identity

After `just install-all` copies `c2c-mcp-server`, write an install identity
stamp to a stable user-local path, for example:

```text
~/.local/share/c2c/install-stamp.json
```

Suggested shape:

```json
{
  "schema": 1,
  "installed_at": 1777197000.456,
  "source_repo": "/home/xertrov/src/c2c",
  "source_head": "024b0925",
  "binaries": {
    "c2c": {
      "path": "/home/xertrov/.local/bin/c2c",
      "sha256": "hex...",
      "mtime": 1777197000.0
    },
    "c2c-mcp-server": {
      "path": "/home/xertrov/.local/bin/c2c-mcp-server",
      "sha256": "hex...",
      "mtime": 1777197000.0
    }
  }
}
```

If #302's install guard/stamp is already on local master when this is
implemented, reuse that stamp instead of adding a second file. The core
requirement is that the expected identity be generated after copy, from the
actual installed target bytes.

### 3. CLI diagnostic command

Add a CLI command:

```bash
c2c doctor mcp-stale
```

It should report three states:

| State | Meaning | Exit |
|---|---|---|
| `ok` | MCP reachable and running server identity matches expected install identity | 0 |
| `stale` | MCP reachable, but running `server_exe_sha256` differs from expected `c2c-mcp-server.sha256` | 1 |
| `unreachable` | CLI works but MCP tool call cannot complete / returns transport error | 2 |
| `unknown` | Missing install stamp or server too old to report identity | 3 |

The command should be useful from both sides:

- From CLI-only context: show expected installed identity and explain that MCP
  must be checked from the host client session.
- From an MCP-capable session: call `server_info` through MCP if the host
  exposes a local bridge for that, otherwise rely on agents calling
  `mcp__c2c__server_info` and comparing with `c2c doctor mcp-stale --expected`.

Because a CLI process cannot directly query the already-connected MCP server
inside Codex/Claude/OpenCode, the minimal first slice can provide:

```bash
c2c doctor mcp-stale --expected-json
```

and the MCP `server_info` output provides the actual JSON. Agents or future
client hooks can compare the two.

### 4. MCP-side self-check tool

Add an MCP tool:

```text
mcp__c2c__stale_status
```

It reads the install stamp and compares it to the running server identity from
inside the actual MCP server. This is the most reliable stale-server check:

- It runs in the same process as the tool schema/handlers the agent is using.
- It can report `stale` even when CLI and MCP disagree.
- It can include a recovery hint tailored by `C2C_MCP_CLIENT_TYPE`.

Suggested response:

```json
{
  "status": "stale",
  "running": {"path": "...", "sha256": "...", "pid": 12345},
  "expected": {"path": "...", "sha256": "...", "installed_at": 1777197000.456},
  "recovery": "Restart this managed session or use the host MCP reload command, then call server_info again."
}
```

If the transport is already closed, this tool cannot run. That is still useful:
`Transport closed` + CLI healthy means `transport_unreachable`, not
`server_schema_stale`.

### 5. Post-install nudge

After `just install-all`, print a short warning if likely live MCP sessions
exist:

```text
c2c install-all updated c2c-mcp-server.
Existing MCP sessions may still be using old server processes.
Run mcp__c2c__stale_status in each active agent, or restart/reload the session.
CLI fallback: C2C_CLI_FORCE=1 c2c poll-inbox
```

Do not auto-restart sessions in `install-all`; that is too disruptive. The
existing `just bii`/`./restart-self` path remains the explicit opt-in.

### 6. Broker-visible breadcrumbs

On startup/auto-register, include MCP server identity in the registration row:

```json
{
  "mcp_server_pid": 12345,
  "mcp_server_sha256": "hex...",
  "mcp_server_started_at": 1777197000.123,
  "mcp_server_path": "/home/xertrov/.local/bin/c2c-mcp-server"
}
```

This enables `c2c list --json`, `c2c stats`, or coordinator diagnostics to spot
which peers are likely stale after an install. It is not sufficient alone
because a transport can be closed before the registration refreshes, but it is
useful fleet observability.

## Recovery hints by failure class

| Detection | Likely class | Recommended hint |
|---|---|---|
| MCP tool returns `Transport closed`; CLI works | host-client stale/closed transport | Use CLI fallback now; restart managed session or host MCP reload; record as #306 evidence |
| `stale_status.status=stale` | old running MCP server binary | Restart/reload this session; re-run `server_info` |
| `server_info` missing identity fields | pre-#306 server | Restart after install; if persists, install path is stale |
| CLI expected stamp missing | install not stamped / old install | run `just install-all` from current worktree |
| broker registration has old `mcp_server_sha256` | peer likely stale | DM peer with restart/reload request, do not assume their tool schemas are current |

## Implementation slices

### Slice A: identity fields

- Add runtime identity fields to `server_info`.
- Add tests that `initialize` and `tools/call server_info` include
  `server_pid`, `server_exe_sha256`, and `identity_schema`.
- Keep old fields for compatibility.

### Slice B: install stamp

- Write install stamp from `just install-all` after all binary copies succeed.
- Include `c2c`, `c2c-mcp-server`, inbox hook, and cold-boot hook hashes.
- Add shell or pytest coverage that stamp hashes match installed files.
- Reuse #302 stamp if already present; do not create competing stamp formats.

### Slice C: MCP stale-status tool

- Add `stale_status` MCP tool.
- Compare running identity to install stamp.
- Return `ok`, `stale`, or `unknown` with recovery hints.
- Test stale by writing a fake expected hash in a temp `HOME`/stamp path.

### Slice D: CLI doctor + docs

- Add `c2c doctor mcp-stale`.
- Document in `docs/commands.md`, CLAUDE.md, and relevant failover/MCP runbooks.
- Include examples for:
  - MCP reachable/current;
  - MCP reachable/stale;
  - MCP transport closed, CLI fallback works.

### Slice E: registration breadcrumbs

- Persist MCP server identity on auto-register and explicit register.
- Surface in `c2c list --json` and maybe `c2c stats`.
- Add coordinator-facing warning when many live peers are on old hashes.

## Tests

Minimum tests before coord-PASS:

- Unit: `server_info` identity fields are present in initialize and tool call.
- Unit: stale-status returns `ok` when stamp hash matches current executable.
- Unit: stale-status returns `stale` when stamp hash differs.
- Unit: stale-status returns `unknown` with a useful hint when stamp is absent.
- CLI: `c2c doctor mcp-stale --expected-json` prints parseable expected data.
- E2E/manual: after `just install-all`, call MCP `stale_status` in a live
  session; then rebuild/install and verify the old session reports `stale`
  before restart.

## Open decisions

1. **Stamp location**: prefer reusing #302's install stamp if present on the
   implementation base; otherwise use `~/.local/share/c2c/install-stamp.json`.
2. **Hash cost**: hashing a small OCaml executable on every `server_info` call
   is acceptable, but cache the result at process start to avoid repeated I/O.
3. **Client reload hooks**: Codex has an MCP reload command in progress; OpenCode
   has SIGUSR1 recovery; Claude may require full restart. Keep recovery hints
   client-specific but do not block detection on reload availability.

## Recommendation

Start with slices A-C. They solve the core false-confidence problem: the agent
can ask the actual MCP server, "are you the binary I just installed?" Slices D
and E turn that into better operator UX and coordinator observability, but they
depend on the identity/stamp contract.
