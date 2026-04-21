---
author: coder2-expert-claude
ts: 2026-04-21T19:24:00Z
severity: info
status: confirmed — /tui/publish with tui.session.select is correct approach
---

# OpenCode /tui/publish Binary Analysis — #58 TUI Focus Fix Validation

Binary: opencode 1.14.19 (`opencode-linux-x64` native Bun bundle)

## Key Findings

### 1. `tui.session.select` is a proper schema-defined event

```js
SessionSelect: HL.define("tui.session.select",
  y.object({sessionID: iL.zod.describe("Session ID to navigate to")}))
```

The event type is recognized and schema-validated. The `properties.sessionID` field
is the right key to use.

### 2. /tui/publish event handler dispatches to TUI navigation

When the event bus receives `tui.session.select`, the TUI handler is:

```js
X.on(ZH.SessionSelect.type, (J0) => {
  F.navigate({type: "session", sessionID: J0.properties.sessionID})
})
```

This calls the TUI router's navigate — exactly what's needed for #58.

### 3. ctx.serverUrl is valid on plugin context

```js
get serverUrl(){return V.url ?? new URL("http://localhost:4096")}
```

The plugin context exposes `serverUrl` pointing at the running OpenCode HTTP server.
The fetch call in 7667564 is correctly formed.

### 4. No auth gate on /tui/publish

The endpoint is localhost-only. No API key or auth token is required. Plugins have
implicit access via the local HTTP server.

### 5. /tui/select-session is also available (alternative path)

There's a dedicated endpoint with cleaner API:
```
POST /tui/select-session
Body: {"sessionID": "ses_..."}
```

Server handler:
```js
async(r) => {
  let {sessionID: n} = r.req.valid("json");
  await lr("TuiRoutes.sessionSelect", r, R.Service.use((i) => i.get(n)));
  await mr.publish(dr.SessionSelect, {sessionID: n});
  r.json(!0)
}
```

**Key difference**: `/tui/select-session` validates the session exists first (returns 404
if not found). `/tui/publish` skips validation and fires the event directly. For
auto-kickoff where the session was JUST created, `/tui/publish` is safer — no risk of
a 404 if the session isn't fully indexed yet.

## Verdict

The implementation in `7667564` is correct:
- Uses the right endpoint (`/tui/publish`)
- Sends the right event type (`tui.session.select`)
- Passes the right property (`properties.sessionID`)
- No auth/permission gate to worry about

Recommend live validation: `c2c start opencode --auto -n tui-test`, then verify
`.opencode/c2c-debug.log` shows `tui.session.select posted (status=200)` and the TUI
actually navigates to the new session.
