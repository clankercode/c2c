# #160 Close-Out — Deliver-Inbox Is Python-Only

**Author**: galaxy-coder
**Date**: 2026-04-29
**Branch**: slice/406-e2e-docker-mesh-s2
**Status**: Close-out research — #160 to be closed, #162 to be filed

---

## Summary

The premise of #160 ("migrate test harness to OCaml `c2c deliver-inbox`") was that there exists an OCaml `c2c-deliver-inbox` binary that could replace the Python deliver daemon. **This premise is false.** The `c2c-deliver-inbox` binary is a **bash shim that execs `python3 c2c_deliver_inbox.py`**. There is no OCaml deliver daemon.

---

## What Exists vs. What We Assumed

| What we assumed | What actually exists |
|---|---|
| OCaml `c2c deliver-inbox` binary | Bash shim: `#!/usr/bin/env bash; exec python3 c2c_deliver_inbox.py "$@"` |
| OCaml deliver has parity with Python | N/A — no OCaml deliver exists |
| Migration = swap binary | Migration = build OCaml daemon from scratch |

### OCaml Binary Inventory

The OCaml build produces:
- `c2c.exe` — main CLI
- `c2c_mcp_server.exe` — MCP server
- `c2c_mcp_server_inner_bin.exe` — inner MCP binary
- `c2c_inbox_hook.exe` — Claude Code PostToolUse hook
- `c2c_cold_boot_hook.exe` — cold boot hook

There is **no `c2c_deliver_inbox.exe`** in the OCaml build. The `c2c-deliver-inbox` binary on the host is the Python bash shim.

### What `c2c_deliver_inbox.py` Actually Does

The Python deliver daemon is a substantial piece of infrastructure:

1. **Persistent poll loop** — polls broker inbox at configurable interval
2. **PTY injection** — injects messages into live terminal sessions via `c2c_poker`
3. **XML FD delivery** — writes to file descriptor for codex-headless (`codex-turn-start-bridge`)
4. **Kimi notification-store delivery** — writes to Kimi's disk notification store
5. **Permission TTL handling** — waits for permission replies with timeout
6. **Daemons**: `--daemon` mode + foreground mode
7. **Deliver modes**: PTY, XML FD, Kimi store, history

None of this is implemented in OCaml. Building it would require implementing the full deliver logic in OCaml from scratch.

---

## `c2c start codex-headless` — What Actually Happens

From `c2c_start.ml:2779-2782`:
```ocaml
let deliver_command ~(broker_root : string) : (string * string list) option =
  (* OCaml c2c-deliver-inbox is the only supported delivery daemon. *)
  Option.map (fun path -> (path, [])) (find_binary "c2c-deliver-inbox")
```

`find_binary "c2c-deliver-inbox"` resolves via `PATH` search, finds the bash shim at `~/.local/bin/c2c-deliver-inbox`, and returns its path. `c2c start` then execs the Python script.

---

## Implications for Docker Agent Testing

**Option A (host-side Python daemon)** is the **correct permanent solution** for Docker-based testing:
- The deliver daemon must run on the **host** alongside the Docker container
- The container runs `codex-turn-start-bridge` (which is dynamically linked to host libraries — already handled via volume mount)
- The host-side Python deliver daemon connects to the same broker volume mount

There is no Docker-native deliver daemon path in the near term. The OCaml implementation (#162) would need to be built first.

---

## Decision

| Item | Action |
|---|---|
| #160 (#406 S4) | Close — deliver-inbox-is-Python-only; Option A accepted |
| #162 | File separately — "Build OCaml c2c-deliver-inbox daemon from scratch"; multi-week scope |

---

## Option A Acceptance — Docker Agent Test Harness

The accepted state for Docker-based agent testing:

```
Host shell:              docker compose up -d
                         docker exec codex-a1 c2c start codex-headless
Host deliver daemon:     python3 c2c_deliver_inbox.py --daemon --alias codex-a1
```

The host-side deliver daemon (`c2c_deliver_inbox.py`) requires:
- Python 3 with the full OCaml-adjacent Python stack (c2c_registry, c2c_mcp, etc.)
- Access to the same broker volume mount as the container

For the Docker compose setup, the deliver daemon runs on the host with the repo Python stack available. The container only needs `c2c` binary + `codex-turn-start-bridge` (host-mounted).

---

## Open Questions (for #162)

1. Should the OCaml deliver daemon be a separate binary or integrated into `c2c.exe`?
2. Should it use the same PTY injection approach (`c2c_poker`) or a different mechanism?
3. XML FD delivery for codex-headless — is there an OCaml equivalent to the Python's fd-writing approach?
4. Kimi notification-store delivery — does OCaml have access to the Kimi disk store path?
5. Should `c2c start` be updated to start the OCaml deliver daemon (when it exists) instead of spawning a bash shim?
