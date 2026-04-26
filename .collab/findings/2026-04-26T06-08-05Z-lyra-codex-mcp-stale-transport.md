# Codex MCP stale transport and repo-build config path

## Symptom

Lyra's Codex session repeatedly returned `Transport closed` for MCP tool calls:

```text
tool call error: tool call failed for `c2c/whoami`
Caused by:
    Transport closed
```

The CLI path still worked:

```text
C2C_CLI_FORCE=1 c2c poll-inbox
```

returned normally, so the broker and installed CLI were reachable.

## Evidence

The live Codex process was a managed session:

```text
c2c start codex --agent Lyra-Quill -n Lyra-Quill-X --bin /home/xertrov/.local/bin/codex
/home/xertrov/.local/bin/codex --xml-input-fd 3 --server-request-events-fd 6 --server-request-responses-fd 7 resume ...
```

The last Lyra-like MCP server log entry was under `no-session.log`:

```text
2026-04-26T05:12:58Z [2552374] starting pid=2552374
2026-04-26T05:17:04Z [2552374] method: tools/call
2026-04-26T05:17:04Z [2552374] send: ... "[]"
```

After the transport started returning `Transport closed`, another MCP tool call did not append a new log entry and no Lyra MCP server process was present in `pgrep -a -f c2c_mcp_server`.

Codex config also pointed at a repo build artifact:

```toml
[mcp_servers.c2c]
command = "opam"
args = ["exec", "--", "/home/xertrov/src/c2c/_build/default/ocaml/server/c2c_mcp_server.exe"]
```

That path changes under rebuilds and worktree/cherry-pick activity. It is weaker than the installed stable launcher `c2c-mcp-server`, which `just install-all` already deploys.

## Root-cause hypothesis

There are two layers:

1. The immediate stale-transport behavior is in Codex's MCP client: once the stdio transport is closed, the harness can keep returning `Transport closed` without spawning a fresh server. Max's new MCP reload hook did not revive this session in this repro.
2. c2c made recurrence more likely because `c2c install codex` ignored the installed `c2c-mcp-server` launcher and wrote a repo `_build` path into `~/.codex/config.toml`.

## Fix status

This slice fixes layer 2:

- `resolve_mcp_server_paths` now prefers `c2c-mcp-server` before requiring a repo `_build` server.
- `setup_codex` writes `command = "c2c-mcp-server"` and `args = []` when the installed launcher is available.
- A regression test verifies Codex install no longer writes `opam` or `_build/default/ocaml/server/c2c_mcp_server.exe` when `c2c-mcp-server` is on PATH.

Layer 1 still needs an upstream/Codex-side recovery path or a reliable user-facing command that forces Codex to discard and recreate the stale MCP transport. Current workaround remains a full managed Codex restart.

## Severity

High for dogfooding. CLI fallback works, but MCP failure removes the preferred tool path and silently shifts agents back to CLI.
