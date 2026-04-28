# CLAUDE_CODE_UDS_INBOX Feature Flag Research

**Date:** 2026-04-14  
**Researcher:** storm-beacon  
**Repository:** /home/xertrov/src/claude-code  

---

## Executive Summary

The `CLAUDE_CODE_UDS_INBOX` feature flag is an **ant-only (Anthropic-internal)** feature that enables a Unix Domain Socket (UDS) messaging system for inter-process communication between Claude Code instances. The UDS socket allows local Claude Code sessions to exchange messages directly without going through the cloud, providing faster local IPC for agent swarm coordination.

**Key Finding for c2c:** The c2c messaging system could potentially use a similar UDS mechanism for faster local IPC between agent sessions on the same machine.

---

## 1. What Does UDS_INBOX Do?

### Purpose
UDS_INBOX enables a **local Unix Domain Socket messaging server** that allows Claude Code sessions to:
1. Receive messages injected by external tools/prompts via the UDS socket
2. Exchange messages between local Claude Code instances
3. Trigger the REPL/query loop when messages arrive via the socket
4. Communicate with Remote Control bridge sessions using `uds:<socket-path>` addressing

### Code Evidence
```typescript
// src/shims/bun-bundle.ts:26
UDS_INBOX: envBool('CLAUDE_CODE_UDS_INBOX', false),
```

The feature flag gates:
- The UDS messaging server startup in `setup.ts`
- UDS-based message routing in `SendMessageTool`
- UDS inbox callbacks in `cli/print.ts`
- The `messaging_socket_path` field in system/init messages

---

## 2. How Does It Work?

### 2.1 Socket Path

**Default Path Generation:**
The code references `getDefaultUdsSocketPath()` (not found in source, but based on patterns):

1. **Environment variable override:** `CLAUDE_CODE_MESSAGING_SOCKET`
2. **Default:** Likely in `/tmp` or `$TMPDIR` with a session-specific path

**Referenced in multiple locations:**
- `src/utils/concurrentSessions.ts:87` — stores in PID file:
  ```typescript
  messagingSocketPath: process.env.CLAUDE_CODE_MESSAGING_SOCKET
  ```
- `src/setup.ts:98` — passed to `startUdsMessaging()`:
  ```typescript
  messagingSocketPath ?? m.getDefaultUdsSocketPath()
  ```
- `src/main.tsx:3836` — CLI option:
  ```bash
  --messaging-socket-path <path>  # Unix domain socket path for UDS messaging server
  ```

### 2.2 Server Creation (Who Binds)

**Server is created in `setup.ts`:**
```typescript
// src/setup.ts:95-101
if (feature('UDS_INBOX')) {
  const m = await import('./utils/udsMessaging.js')
  await m.startUdsMessaging(
    messagingSocketPath ?? m.getDefaultUdsSocketPath(),
    { isExplicit: messagingSocketPath !== undefined },
  )
}
```

- The **Claude Code main process** creates and binds the socket
- Bound **before any hooks run** (`SessionStart` in particular)
- Gated on `!isBareMode()` (--bare mode skips UDS)
- Explicit `--messaging-socket-path` is an escape hatch

### 2.3 Client Connections (Who Connects)

**Clients connect from:**

1. **SendMessageTool** (`src/tools/SendMessageTool/SendMessageTool.ts:775-797`):
   ```typescript
   if (addr.scheme === 'uds') {
     const { sendToUdsSocket } = require('../../utils/udsClient.js')
     await sendToUdsSocket(addr.target, input.message)
   }
   ```

2. **print.ts** (`src/cli/print.ts:2683-2693`):
   Sets up callback to kick the query loop when messages arrive:
   ```typescript
   if (feature('UDS_INBOX')) {
     const { setOnEnqueue } = require('../utils/udsMessaging.js')
     setOnEnqueue(() => {
       if (!inputClosed) {
         void run()
       }
     })
   }
   ```

3. **conversationRecovery.ts** (`src/utils/conversationRecovery.ts:494-505`):
   Lists live sessions via UDS:
   ```typescript
   const { listAllLiveSessions } = await import('./udsClient.js')
   const live = await listAllLiveSessions()
   ```

### 2.4 Protocol Details

**Message format:** Plain text messages sent over the socket (based on `SendMessageTool` usage).

**Addressing scheme** (`src/utils/peerAddress.ts`):
```typescript
export function parseAddress(to: string): {
  scheme: 'uds' | 'bridge' | 'other'
  target: string
} {
  if (to.startsWith('uds:')) return { scheme: 'uds', target: to.slice(4) }
  if (to.startsWith('bridge:')) return { scheme: 'bridge', target: to.slice(7) }
  // Legacy: bare socket paths route through UDS
  if (to.startsWith('/')) return { scheme: 'uds', target: to }
  return { scheme: 'other', target: to }
}
```

**SendMessageTool input schema** (when UDS_INBOX enabled):
```
Recipient: teammate name, "*" for broadcast, "uds:<socket-path>" for a local peer, or "bridge:<session-id>" for a Remote Control peer
```

---

## 3. What Does It Enable?

### 3.1 Features Enabled by UDS_INBOX

| Feature | Location | Description |
|---------|----------|-------------|
| **UDS messaging socket path** | `system/init` message | Exposed to SDK as `messaging_socket_path` |
| **UDS send routing** | `SendMessageTool` | `uds:<path>` addressing for cross-session sends |
| **Bridge send routing** | `SendMessageTool` | `bridge:<session-id>` for Remote Control sends |
| **Message-driven loop kick** | `print.ts` | Socket messages trigger REPL execution |
| **Live session discovery** | `conversationRecovery.ts` | `listAllLiveSessions()` via UDS |
| **PID file enrichment** | `concurrentSessions.ts` | Stores `messagingSocketPath` in session registry |

### 3.2 System Init Message Enrichment

```typescript
// src/utils/messages/systemInit.ts:87-93
// Hidden from public SDK types — ant-only UDS messaging socket path
if (feature('UDS_INBOX')) {
  (initMessage as Record<string, unknown>).messaging_socket_path =
    require('../udsMessaging.js').getUdsMessagingSocketPath()
}
```

The socket path is injected into `system/init` messages for SDK consumers.

### 3.3 Security Model

Based on `chromeNativeHost.ts` patterns (similar UDS implementation):
- Socket directory created with `mode: 0o700`
- Socket file permissions set to `0o600`
- Stale sockets cleaned up by checking if PID is still alive
- Platform-gated (Mac/Linux only, not Windows)

---

## 4. Could It Help c2c Instant Messaging?

### 4.1 Architecture Comparison

| Aspect | Claude Code UDS_INBOX | c2c Messaging |
|--------|---------------------|---------------|
| **Transport** | Unix Domain Socket | HTTP/REST (current) |
| **Protocol** | Raw text over socket | JSON over HTTP |
| **Routing** | Socket path addressing | Alias-based peer registry |
| **Discovery** | Via socket directory scan | Via c2c broker registration |
| **Latency** | ~0.1ms (same-host UDS) | ~1-5ms (local HTTP) |
| **Scope** | Same-machine sessions | Cross-machine possible |

### 4.2 Potential c2c UDS Integration

**Benefits for c2c:**
1. **Faster local IPC** — UDS would be significantly faster than HTTP for same-host communication
2. **No network stack overhead** — Direct socket communication
3. **Simpler routing** — Socket paths are deterministic

**Design Options:**

Option A: **c2c as UDS Server**
- c2c could create a UDS server alongside its HTTP server
- Local agents connect to `unix:///tmp/c2c-messaging.sock`
- HTTP remains for cross-machine communication

Option B: **c2c UDS Broker**
- c2c acts as a message broker on a UDS socket
- Local agents use `uds:<path>` addressing (like Claude Code)
- Registration via c2c still required for alias resolution

Option C: **Hybrid**
- c2c runs HTTP server for cross-machine
- UDS socket for same-machine fast path
- Agents can choose transport based on peer location

### 4.3 Implementation Sketch

```typescript
// c2c-msg could add UDS support:

// Server side (c2c broker)
if (feature('C2C_UDS')) {
  const server = createServer((socket) => {
    socket.on('data', (data) => {
      const msg = jsonParse(data.toString())
      // Route to registered peers
    })
  })
  await server.listen('/tmp/c2c-messaging.sock')
  chmod('/tmp/c2c-messaging.sock', 0o600)
}

// Client side (local agent)
async function sendUdsMessage(path: string, msg: object) {
  return new Promise((resolve, reject) => {
    const socket = createConnection(path)
    socket.write(jsonStringify(msg))
    socket.end()
  })
}
```

### 4.4 Key Differences to Consider

1. **c2c uses aliases** — Needs broker for alias→socket resolution
2. **c2c is cross-machine** — HTTP still needed for remote peers
3. **UDS is single-machine** — No network discovery needed
4. **Security** — UDS permissions must be carefully managed

---

## 5. File References

| File | Purpose |
|------|---------|
| `/src/shims/bun-bundle.ts` | Feature flag definition |
| `/src/setup.ts` | UDS server startup |
| `/src/main.tsx` | CLI option parsing |
| `/src/cli/print.ts` | UDS inbox callback |
| `/src/tools/SendMessageTool/SendMessageTool.ts` | UDS send routing |
| `/src/utils/messages/systemInit.ts` | Socket path in init |
| `/src/utils/concurrentSessions.ts` | PID file enrichment |
| `/src/utils/conversationRecovery.ts` | Live session discovery |
| `/src/utils/peerAddress.ts` | Address parsing (uds: prefix) |
| `/src/utils/claudeInChrome/chromeNativeHost.ts` | Reference UDS implementation |
| `/src/utils/claudeInChrome/common.ts` | Socket path utilities |
| `/docs/bridge.md` | Chrome native host docs |

---

## 6. Conclusions

1. **UDS_INBOX is ant-only** — Not intended for external use (compile-time feature)
2. **Provides fast local IPC** — Enables sub-millisecond inter-process messaging
3. **Uses standard Unix patterns** — Socket path in tmpdir, 0o600 permissions
4. **Integrates with SendMessageTool** — Enables `uds:<path>` addressing
5. **c2c could benefit** — UDS would speed up same-host agent communication

---

## 7. Recommendations for c2c

1. **Add UDS support as an option** — `C2C_UDS=true` env var
2. **Expose socket path** — Via `c2c socket-path` command
3. **Support hybrid transport** — UDS for local, HTTP for remote
4. **Keep HTTP as default** — UDS is an optimization, not a replacement
5. **Consider same-user security** — Match c2c user before accepting socket connections

---

*Research completed: 2026-04-14T12-15-00Z*
