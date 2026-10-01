# Codex 0.159 daemon protocol + MCP inject (IGC ? cells)

Date: 2026-10-01. Scope: read-only (source + Codex 0.159.3 binary strings + help). No live inject, no `c2c start`.

Open cells this note targets: I4/I5 **G1** (MCP can wake), I4/I6 **G5** (owner), plan items **A–G**.

## A. Protocol

The machine daemon listens on a **Unix-domain WebSocket**, not raw NDJSON.

Evidence:

- Binary: `app-server-transport/src/transport/unix_socket.rs`, `failed to upgrade control socket websocket connection`, `invalid UDS websocket handshake URL`.
- `--remote` accepted forms: `ws://host:port`, `wss://host:port`, `unix://`, `unix://PATH` plus `--remote-auth-token-env` for a bearer on a remote WS.
- `codex app-server proxy --sock` is documented as “Proxy stdio bytes to the running app-server control socket”.
- Same binary exports JSON-RPC methods already used by c2c: `thread/inject_items`, `thread/list`, `thread/read`, `thread/resume`, `turn/start`.

c2c today (`C2c_codex_ingress.ws_connect`) is **TCP loopback + HTTP Upgrade + `Authorization: Bearer`**. It cannot open `PF_UNIX`. The missing piece is a UDS WS transport (handshake, likely no bearer on the local daemon), or exec’ing `codex app-server proxy` and speaking JSON-RPC on that stdio.

This is a transport adapter spike, not a new RPC surface.

## B. `CODEX_THREAD_ID`

c2c already treats it as harness-native (`c2c_mcp_helpers_post_broker.ml` client-type table; changelog 0.9.1 “`$CODEX_THREAD_ID` natively”). `c2c start` **does not seed** it (`test_c2c_start.ml` “does not seed CODEX_THREAD_ID”).

This host’s `~/.codex-shared/config.toml` has other MCP servers and **no** `[mcp_servers.c2c]` block. Vanilla MCP inject is off until `c2c install codex --with-mcp` (and the entry lands `enabled = false` unless already on — B290).

Live vanilla probe of the MCP child env is still required (Codex’s B).

## C. Socket reachability

Control sock: `~/.codex/app-server-control/app-server-control.sock` → `/tmp/codex-daemon-1000/<hash>`, directory `0700`. Same-UID connect should work. Codex MCP sandbox (feature-matrix: “Codex gates MCP binary execution”) is the remaining probe: a sandboxed MCP child might not see `/tmp/codex-daemon-*`.

## D. MCP background loop

The c2c MCP server **already** runs `Lwt.async` inbox + schedule watchers (`c2c_mcp_server_inner.ml` ~149–208, ~553–567). The inbox watcher only **drains** when `experimental.claude/channel` is negotiated — Codex MCP does not, so the thread exists and no-ops on drain.

So “can MCP run a timer” is already yes. Remaining G1 risk: **does Codex keep the MCP stdio child alive for the whole TUI session, or spawn per tool call?** If per-call, a timer is not a wake. Unproven here. Sidecar (I6) does not depend on that.

## E. Auto-turn

`turn/start` exists on the app-server RPC (binary method list). c2c’s gated client is the same JSON-RPC over the private WS. After a UDS WS adapter, the same gated local-mail policy can target the daemon. B098 unchanged.

## F. Owner

One owner per thread. If MCP is the owner, `c2c start` must not also run `run_delivery_loop`. If sidecar is the owner, MCP watcher must not drain/inject the same thread.

## G. Fallback

Keep private WS `c2c start` path + hook `--no-daemon` until UDS attach is proven. Uncommitted tactical diff is that bandage.

## IGC update (after this note)

| Idea | All | change |
|---|---|---|
| I4 MCP inject+turn | ? | G1 still ? (lifetime). G5 ? until owner pick. Protocol is adapter, not unknown RPC. |
| I5 MCP sole owner | ? | Same G1 ?. G5 would be ✔ by construction. |
| I6 sidecar sole owner | ? | G1 ✔ if sidecar talks UDS WS. G5 ✔ if it is the only owner. Remaining ?: live UDS handshake + sandbox. |

Conservative survivor if we refuse to ship a `?` G1: **I6**, with I1/I2 as daemon-down fallback. I5 becomes the default if a vanilla Codex session keeps MCP alive (one probe).
