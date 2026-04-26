# #311 mcp-inner / mcp-outer proxy design

Author: lyra-quill  
Date: 2026-04-26T10:47:15Z  
Status: design proposal

## Summary

Use a stable **outer MCP proxy** as the host-client-facing process and a
restartable **inner MCP server** as the real c2c tool implementation:

```text
Codex / Claude / OpenCode / Kimi / Crush
  stdin/stdout JSON-RPC
        |
        v
c2c mcp          (outer proxy, stable stdio process)
        |
        v
c2c mcp-inner    (inner server, respawned after install/update/crash)
```

The outer process keeps the stdio transport that host clients attach to. The
inner process owns the actual tool schema, handlers, inbox watcher, auto-register
startup, and broker side effects. When `just install-all` updates
`c2c-mcp-server`, the outer can restart the inner and replay MCP initialization
without requiring the host client to reconnect.

This does **not** obsolete #306. #306's runtime identity and install-stamp data
become the outer proxy's update signal and a belt-and-braces diagnostic path for
clients that cannot use the proxy yet, broken transports, and cross-peer fleet
observability.

## Problem

Today the host client connects directly to one `c2c-mcp-server` process. After
`just install-all`, existing sessions can keep using an old process and old tool
schemas until the host reloads MCP or the session restarts. We saw this as:

- stale schema/tool illusions during #305 triage;
- Codex `Transport closed` where CLI fallback still worked;
- repeated manual restarts/reloads to pick up MCP changes.

#306 addresses detection: "am I talking to the installed binary?" That prevents
false confidence, but it still leaves the operator with a restart/reload chore.
#311 should make the common same-session update path self-healing.

## Goals

- Keep the host-client MCP stdio connection stable across c2c inner-server
  restarts.
- Let `just install-all` make new MCP handlers and existing tools current
  without a full agent restart when the host is connected through the proxy.
  Newly-added tool names still depend on host `tools/list` refresh behavior.
- Preserve exact MCP protocol behavior from the host client's perspective.
- Keep channel notifications and c2c push semantics correct.
- Bound crash loops with backoff and visible diagnostics.
- Reuse #306 runtime identity and `~/.local/bin/.c2c-version` rather than adding
  a competing freshness mechanism.

## Non-goals

- Do not require every host client to support a native MCP reload command.
- Do not remove CLI fallback or `C2C_CLI_FORCE=1`; the CLI remains the recovery
  path when the host transport itself is broken.
- Do not proxy arbitrary remote MCP servers. This is a local c2c lifecycle
  wrapper.
- Do not migrate every client install in one slice. Roll out behind a flag or
  one client first.

## Options Considered

### Option A: proxy-only

Make `c2c mcp` a proxy and drop #306 stale detection follow-ups.

Pros:
- Smaller conceptual surface for happy-path sessions.
- No `stale_status` or doctor UX to maintain.

Cons:
- Does not help existing direct-to-server installs until they reinstall.
- Does not diagnose host-client closed transports where the proxy itself is no
  longer reachable.
- Does not help coordinators spot peers using old binaries.
- Removes useful data for regression reports.

Verdict: too narrow.

### Option B: detection-only

Keep #306 and do not build the proxy.

Pros:
- Lower implementation risk.
- Works across all clients uniformly.

Cons:
- Still requires human restart/reload every time c2c MCP changes.
- Leaves stale schemas as a repeated workflow crinkle.
- Solves "know it is stale" but not "make it current."

Verdict: useful foundation, incomplete UX.

### Option C: proxy plus detection

Implement the outer proxy and keep #306 identity/stamp as the update signal,
diagnostic fallback, and fleet breadcrumb.

Pros:
- Fixes the normal update path and keeps diagnostics for the abnormal paths.
- Lets the proxy decide when to respawn based on installed binary identity.
- Gives coordinators proof about which process/binary a peer is using.
- Compatible with incremental rollout.

Cons:
- More moving parts: process supervision, replay state, notification routing,
  backoff, and logging.
- Requires careful MCP protocol handling around initialization and in-flight
  requests.

Verdict: recommended.

## Recommended Architecture

### Commands

- `c2c mcp`: outer proxy, the command written into client MCP configs.
- `c2c mcp-inner`: real MCP server, mostly today's `ocaml/server/c2c_mcp_server.ml`.
- `c2c mcp --direct` or `C2C_MCP_DIRECT=1`: escape hatch to run the inner
  directly for tests and emergency rollback.

During rollout, `c2c install <client>` should continue to write `c2c-mcp-server`
until the proxy lands and is verified. Then `c2c-mcp-server` can become the
outer proxy binary/launcher while `c2c-mcp-inner` is installed beside it.

### Process Model

The outer proxy:

- starts once per host-client MCP session;
- reads host JSON-RPC from stdin and writes responses/notifications to stdout;
- spawns the inner as a child process with inherited c2c environment;
- speaks MCP JSON-RPC to the inner over pipes;
- forwards host requests to the inner and inner responses/notifications back to
  the host;
- watches the install stamp from #306/#302 (`~/.local/bin/.c2c-version`);
- restarts the inner when the installed `c2c-mcp-inner` identity changes or the
  child exits unexpectedly.

The inner server:

- owns tool schemas, tool handlers, broker auto-register, room auto-join, nudge
  scheduler, and inbox watcher;
- is allowed to exit and restart without closing the host stdio connection;
- should not know whether it is directly attached to a host or proxied.

## Initialize Replay

MCP `initialize` is the load-bearing state boundary. The outer must record the
last successful initialize request from the host:

- full request params;
- host protocol version;
- client info, if present;
- advertised capabilities, especially `experimental.claude/channel`;
- original request id is not reused for replay.

On initial startup:

1. host sends `initialize`;
2. outer forwards it to inner;
3. inner returns `serverInfo`, instructions, and capabilities;
4. outer forwards the response to host and stores the request params.

On inner restart:

1. outer spawns new inner;
2. outer sends a synthetic `initialize` request with a proxy-owned id, using the
   stored host params;
3. outer waits for the inner initialize response;
4. outer does **not** forward that synthetic response to the host;
5. outer resumes normal request forwarding.

This replay re-establishes inner-side capability negotiation. In current code,
the server persists push capability in the broker registry on `initialize`, so
replay is the correct point to refresh that broker state after restart.

If the host has not initialized yet and the inner restarts, the outer simply
spawns a fresh inner and waits. No replay is possible or needed.

## Tool Schema Refresh

Most MCP clients cache tool schemas after `tools/list`. A proxy restart of the
inner does not automatically force the host to call `tools/list` again.

Minimum v1 behavior:

- after inner restart, the outer must answer future `tools/list` from the new
  inner;
- if the host never re-lists tools, the outer still forwards existing tool calls
  to the new inner, so handler fixes are active but newly-added tools may not be
  visible in the host UI until a host reload/re-list.

Preferred v2 behavior:

- if the MCP client supports a tool-list-changed notification, the outer emits
  it after successful inner restart and initialize replay;
- otherwise the outer logs a clear breadcrumb and `server_info` exposes
  `proxied_inner_restarted_at` so agents can tell whether a host reload may be
  needed for schema discovery.

Do not invent a non-standard notification in v1. Use a real MCP notification
only when the client advertises support or the protocol version requires it.

## Notification Flow

Notifications from inner to host should be byte-for-byte normal MCP
notifications after JSON parsing/re-emission:

- `notifications/claude/channel` produced by the inner inbox watcher must pass
  through the outer to host stdout.
- Other future MCP notifications from inner pass through unchanged unless the
  outer needs to suppress proxy-internal initialize replay responses.
- Host notifications or requests to inner pass through unchanged after the outer
  has initialized the inner.

The outer should not become a broker participant and should not drain inboxes.
Keeping push delivery in the inner avoids a split brain where both proxy and
inner could race to drain.

If inner is restarting while an inbox notification would have fired, the inbox
remains durable in broker files. After replayed initialize, the new inner's
watcher continues. This may delay a notification but should not lose the
message.

## State Boundary

State that survives inner restart because the outer owns it:

- host stdio file descriptors;
- last host `initialize` params;
- in-flight request table;
- inner restart counters and backoff state;
- last known inner runtime identity;
- debug log path for proxy lifecycle events.

State that is re-established in inner on every restart:

- MCP server tool schemas and handlers;
- negotiated capability state, via initialize replay;
- auto-register and auto-join startup;
- broker nudge scheduler;
- inbox watcher;
- server runtime identity.

State that remains external and durable:

- broker registry, inboxes, room history, archives, memory store;
- install stamp at `~/.local/bin/.c2c-version`;
- live client session identity from environment.

This boundary is intentional: host connection state is proxy-owned, c2c behavior
is inner-owned, durable swarm state is broker-owned.

## In-Flight Requests

The proxy must assign inner request ids independently from host request ids and
keep a mapping:

```text
host id -> proxy inner id -> host id
```

If the inner restarts while requests are in flight:

- safe/idempotent requests such as `tools/list`, `prompts/list`, and
  `server_info` may be retried after replay;
- mutating `tools/call` requests must not be retried automatically unless the
  tool is explicitly marked idempotent;
- for non-retryable in-flight calls, return a JSON-RPC error to the host:
  `inner server restarted while request was in flight; retry if safe`.

This prevents duplicate sends, duplicate memory writes, duplicate room joins,
and other mutation repeats.

## Restart Triggers

The outer restarts the inner when:

- the child exits unexpectedly;
- the installed inner binary hash in `~/.local/bin/.c2c-version` changes;
- a manual operator signal or future `c2c mcp reload-inner` asks for it.

Hash checks should be cheap:

- stat the stamp path every N seconds, or subscribe to inotify later;
- compare the expected `binaries.c2c-mcp-inner.sha256` or
  `binaries.c2c-mcp-server.sha256` during transition;
- avoid hashing executable bytes on every forwarded request.

The proxy should not restart the inner during an active request unless the inner
has crashed. If an update is detected while a request is running, mark
`restart_pending` and restart after the request table drains or after a bounded
grace period.

## Crash Handling and Backoff

Crash handling must avoid tight respawn loops:

- first 3 crashes: immediate or 250ms/500ms/1s backoff;
- then exponential backoff up to 30s;
- reset backoff after the inner stays alive for a stability window, e.g. 60s.

While the inner is down:

- `tools/list` and `tools/call` return a structured JSON-RPC error with a
  recovery hint and current backoff delay;
- host notifications cannot be emitted, but broker inbox content remains
  durable;
- the outer remains alive so the host transport does not close.

If the inner cannot start because the binary is missing or not executable, the
outer should surface:

```text
c2c MCP inner server unavailable. Run `just install-all` or use CLI fallback:
C2C_CLI_FORCE=1 c2c poll-inbox
```

## Relationship to #306

#306 slice A already added runtime identity to `server_info` and extended the
install stamp. #311 should reuse that data:

- the outer reads the install stamp to detect that the installed inner changed;
- the inner reports runtime identity through `server_info`;
- the outer may add proxy identity fields to `server_info` by wrapping or
  augmenting the inner response;
- broker breadcrumbs remain useful for coordinators even when proxy hot-restart
  works.

Recommended `server_info` extension under proxy:

```json
{
  "runtime_identity": { "...": "inner identity" },
  "proxy_identity": {
    "schema": 1,
    "pid": 111,
    "started_at": 1777200000.0,
    "executable": "/home/xertrov/.local/bin/c2c-mcp-server",
    "inner_pid": 222,
    "inner_started_at": 1777200060.0,
    "inner_restarts": 1,
    "restart_pending": false
  }
}
```

This keeps existing #306 consumers working while making the proxy visible.

## Rollout Plan

### Slice A: extract inner entrypoint

- Add `c2c mcp-inner` or `c2c-mcp-inner` that runs today's server directly.
- Keep `c2c mcp` / `c2c-mcp-server` behavior unchanged.
- Tests: direct inner still passes existing MCP initialize/tools/list/tool-call
  tests.

### Slice B: outer proxy minimal forwarder

- Implement outer process that spawns inner and forwards JSON-RPC both ways.
- Record/replay initialize.
- Pass through channel notifications.
- No auto-restart-on-install yet; only child crash restart.
- Tests: scripted MCP client sends initialize, tools/list, server_info; kill
  inner; verify outer stays alive and a later tools/list works after replay.

### Slice C: stamp-driven restart

- Read #306/#302 install stamp.
- Detect inner binary hash changes.
- Restart after in-flight requests drain.
- Add proxy identity fields.
- Tests: temp stamp + fake inner executable/version; update stamp; verify new
  inner serves new server_info without host reconnect.

### Slice D: install migration and docs

- Change `c2c install <client>` to write the outer proxy command for one client
  first, preferably Codex because it had repeated stale-transport evidence.
- Document `mcp`, `mcp-inner`, direct mode, and fallback behavior in
  `docs/commands.md` and CLAUDE.md.
- Dogfood in a tmux-managed live session before broad rollout.

### Slice E: schema refresh UX

- Add standards-compliant tool-list-changed notification if supported by the
  relevant host clients.
- If unsupported, add explicit post-install / `server_info` hints saying handler
  updates are live through proxy but newly-added tool names may require host
  reload.

## Tests

Minimum tests before coord-PASS of implementation:

- Unit/protocol: outer forwards initialize and tools/list responses unchanged.
- Unit/protocol: outer suppresses synthetic replay responses.
- Unit/protocol: channel notifications from inner pass through to host.
- Unit/protocol: inner restart replays initialize with preserved host
  capabilities.
- Unit/protocol: non-idempotent in-flight tool call gets an error, not an
  automatic retry.
- Unit/protocol: crash backoff prevents tight loops.
- Integration: stamp change causes restart and new inner identity without host
  reconnect.
- Live dogfood: managed Codex or OpenCode session receives new `server_info`
  identity after `just install-all` without full restart, or records precisely
  which host-client cache still requires a reload.

## Open Decisions

1. **Binary names during transition**: either make `c2c-mcp-server` the outer
   and install `c2c-mcp-inner` beside it, or introduce `c2c-mcp-proxy` first.
   Recommendation: keep `c2c-mcp-server` as the stable outer name so existing
   client configs do not need churn once upgraded.
2. **Tool schema refresh**: verify which clients honor standard tool-list
   changed notifications. Until proven, do not rely on this for correctness.
3. **Client rollout order**: start with Codex because it has concrete stale
   transport evidence and Max added an MCP reload command there. OpenCode is
   second because SIGUSR1 recovery exists.
4. **Direct mode retention**: keep direct inner mode permanently for tests and
   emergency debugging, even after proxy rollout.

## Recommendation

Build #311 as proxy plus detection. The proxy is the right long-term lifecycle
boundary: host clients attach to one stable process; c2c can update its actual
server behind that boundary. #306 remains necessary as the identity plane that
lets the proxy know when to restart and lets humans diagnose cases the proxy
cannot fix, especially closed host transports and peers not yet migrated.

Do not implement `stale_status`, `doctor mcp-stale`, or post-install nudge
follow-ups until Slice B/C of the proxy proves whether schema refresh is
automatic or still host-client-limited. Keep #306 slice A as the foundation.
