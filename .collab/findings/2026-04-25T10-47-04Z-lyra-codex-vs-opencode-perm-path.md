# Codex vs OpenCode permission-forwarding path

Author: lyra-quill
Date: 2026-04-25T10:47:04Z
Context: #194 follow-up for stanza-coder. Static source comparison only; no implementation in this slice.

## Executive summary

OpenCode has a complete permission loop:

1. observe permission event from the client,
2. open a broker pending-reply slot,
3. DM configured supervisors,
4. intercept supervisor replies before normal chat delivery,
5. validate the sender,
6. resolve the original client permission dialog through OpenCode's HTTP API.

Codex currently has partial scaffolding only:

1. `codex-headless` can route bridge event JSONL to `c2c_deliver_inbox.py`,
2. the Python sidecar can parse `permissions_approval_request`,
3. it can attempt to open a pending slot and wait for a supervisor reply,
4. but the returned decision is not written back to Codex anywhere.

The most important divergence is the missing Codex "decision sink": OpenCode ends with `postSessionIdPermissionsPermissionId(...)`; Codex has no equivalent call. The sidecar returns `"approve-once"`, `"approve-always"`, `"reject"`, or `"timeout"`, and `run_loop` ignores that return value.

## OpenCode working path

Source: `data/opencode-plugin/c2c.ts`.

The plugin observes `permission.asked` / `permission.updated` events and builds a supervisor-facing request message at `data/opencode-plugin/c2c.ts:1749-1778`.

It opens a pending broker slot before notifying supervisors:

- `open-pending-reply` call: `data/opencode-plugin/c2c.ts:1781-1788`
- supervisor DMs: `data/opencode-plugin/c2c.ts:1790-1796`

The wait is asynchronous and does not block the main event handler:

- fire-and-forget wrapper starts at `data/opencode-plugin/c2c.ts:1780`
- `waitForPermissionReply(...)` is awaited inside that background task at `data/opencode-plugin/c2c.ts:1801`

Reply handling is integrated into normal delivery but filtered before chat injection:

- non-draining timeout fallback uses `peek-inbox`: `data/opencode-plugin/c2c.ts:1247-1266`
- pending map setup: `data/opencode-plugin/c2c.ts:1343-1357`
- permission reply interception before `promptAsync`: `data/opencode-plugin/c2c.ts:1376-1428`
- broker-side validation through `check-pending-reply`: `data/opencode-plugin/c2c.ts:1397-1410`
- plugin-side supervisor allowlist check: `data/opencode-plugin/c2c.ts:1412-1423`

The crucial final step is client resolution:

- maps c2c reply to OpenCode response at `data/opencode-plugin/c2c.ts:1801-1806`
- calls `postSessionIdPermissionsPermissionId(...)` at `data/opencode-plugin/c2c.ts:1827-1831`

This means a supervisor reply actually dismisses or resolves the OpenCode permission dialog.

## Codex current path

Sources: `ocaml/c2c_start.ml`, `c2c_deliver_inbox.py`, `ocaml/cli/c2c.ml`.

### Event plumbing is `codex-headless` only

`ocaml/c2c_start.ml` only passes `--server-request-events-fd 6` when `client = "codex-headless"`:

- fd selection: `ocaml/c2c_start.ml:2759-2761`
- events FIFO creation: `ocaml/c2c_start.ml:2799-2804`
- wrapper redirects bridge fd 6 to the FIFO: `ocaml/c2c_start.ml:2808-2817`
- deliver daemon receives `?event_fifo_path:headless_events_fifo_opt`: `ocaml/c2c_start.ml:3048-3057`

Normal `codex` gets `codex_xml_input_fd` when available, but no `server_request_events_fd`; see `ocaml/c2c_start.ml:2752-2754` and `ocaml/c2c_start.ml:2759-2761`.

So if Max's observed broken flow is normal managed `codex`, the permission event watcher is not attached at all.

### `codex-headless` is still launched with approval policy `never`

`codex-headless` launch args include `--approval-policy never` with a comment saying approval handoff is not available yet:

- `ocaml/c2c_start.ml:1907-1922`

That makes the current permission-forwarding path internally inconsistent: the event sideband exists, but the launch policy still says headless approvals are disabled / non-interactive.

### The sidecar reads permission events

`c2c_deliver_inbox.py` opens an optional `event_fifo`, parses JSONL, and calls `forward_permission_to_supervisors(...)`:

- FIFO open: `c2c_deliver_inbox.py:573-579`
- event read and forward calls: `c2c_deliver_inbox.py:610-641`
- parser for `permissions_approval_request`: `c2c_deliver_inbox.py:850-893`
- JSONL buffering: `c2c_deliver_inbox.py:896-918`

This confirms the source has a Codex event ingestion path, but only for the `event_fifo` passed by `c2c_start.ml`.

### The sidecar does not resolve Codex

`forward_permission_to_supervisors(...)` opens a pending slot, sends supervisors, waits for a reply, and returns a decision:

- pending slot and DM: `c2c_deliver_inbox.py:1015-1022`
- wait and return: `c2c_deliver_inbox.py:1024-1028`

But `run_loop` discards that return value:

- `c2c_deliver_inbox.py:621-627`
- `c2c_deliver_inbox.py:635-641`

There is no call after the return that writes the decision to the bridge, to Codex stdin, to a response fd, to a reviewer process, or to any Codex API. This is the direct counterpart to OpenCode's missing step: there is no Codex equivalent of `postSessionIdPermissionsPermissionId(...)`.

### The supervisor DM may not be sent at all

`forward_permission_to_supervisors(...)` calls:

```text
c2c send <supervisor> --content <message>
```

at `c2c_deliver_inbox.py:1021-1022`.

The OCaml `c2c send` command does not define `--content`; it takes the message as positional trailing args:

- positional message arg: `ocaml/cli/c2c.ml:279-280`
- no `--content` option in the send command args: `ocaml/cli/c2c.ml:275-303`

So this call shape likely fails with an unknown option. The unit tests mock `run_c2c_command` and assert that some send call exists, but they do not assert the exact CLI argv is accepted.

### Reply waiting drains the agent inbox and blocks the delivery loop

OpenCode handles permission replies in the normal delivery path and uses non-draining `peek-inbox` as a timeout fallback.

Codex's `await_supervisor_reply(...)` loops on:

```text
c2c poll-inbox --json --session-id <session_id>
```

at `c2c_deliver_inbox.py:952-981`.

That means waiting for a permission reply can drain unrelated messages from the requester inbox. It also happens synchronously inside `run_loop`, so the deliver daemon can block normal inbox delivery for up to 300 seconds while waiting for a supervisor.

### Event FIFO lifetime is one-shot

When the event FIFO returns EOF, `run_loop` closes `event_fd` and sets it to `-1`:

- `c2c_deliver_inbox.py:642-650`

There is no reopen attempt later. If the bridge restarts, reconnects, or briefly drops the writer, permission-event forwarding silently stops for the rest of the deliver daemon lifetime.

## Divergence table

| Area | OpenCode | Codex current state | Impact |
|---|---|---|---|
| Event source | SDK event stream for `permission.asked` / `permission.updated` | `--server-request-events-fd` only wired for `codex-headless`; normal `codex` not wired | Normal managed Codex likely never enters c2c permission forwarding |
| Approval policy | OpenCode prompts and emits permission events | `codex-headless` still launches with `--approval-policy never` | Headless permission forwarding may be unreachable or inconsistent |
| Supervisor selection | Config-driven via repo/sidecar/env | Hardcoded `["coordinator1"]` in `run_loop` | Ignores configured supervisors |
| Pending slot | `open-pending-reply` before DM | Same intent | Good shape, but see send argv |
| Supervisor DM | `c2c send <supervisor> <message>` | `c2c send <supervisor> --content <message>` | Likely invalid CLI call; request may never reach supervisors |
| Reply handling | Intercepts replies in normal delivery and never injects them into chat | Blocking `poll-inbox` loop inside permission wait | Can swallow unrelated messages and pause delivery |
| Reply validation | Broker `check-pending-reply` plus local supervisor allowlist | Local supervisor allowlist only | Broker validation gap compared with OpenCode |
| Decision sink | HTTP API resolves OpenCode permission dialog | No write-back call; returned decision ignored | Core bug: approval cannot affect Codex |
| Timeout handling | Auto-rejects through same HTTP resolve path and tracks late replies | Returns `"timeout"` to ignored caller | No Codex-side timeout resolution |
| Reconnect handling | Plugin event stream remains in process | FIFO closes permanently on EOF | Permission forwarding can die silently |
| Tests | Plugin tests cover event -> HTTP resolve | Tests cover parse/DM/wait only | No test proves Codex prompt gets resolved |

## Recommended target for #194

Stanza should treat this as two separate questions:

1. Which Codex client is in scope?
   - If normal `codex`: first wire the event surface or another permission-observation path for normal managed Codex. The current `--server-request-events-fd` path is only attached to `codex-headless`.
   - If `codex-headless`: reconcile `--approval-policy never` with permission forwarding. A permission-forwarding path cannot be proven if headless is configured to never request approval.

2. What is the Codex decision sink?
   - Find the exact API/fd/stdin/reviewer interface that accepts an approval response.
   - Add a function that maps c2c decisions to that interface.
   - Call it from the permission event path.

Minimum fix shape after the decision sink is known:

1. Replace `c2c send <sup> --content <msg>` with positional message argv, or add a real `--content` option to the OCaml CLI and test it.
2. Make permission forwarding asynchronous relative to the deliver loop.
3. Do not use draining `poll-inbox` as the reply wait path. Mirror OpenCode: intercept permission replies in normal delivery and use `peek-inbox` only as a fallback.
4. Validate replies through `check-pending-reply` before accepting them.
5. Use configured supervisors rather than hardcoding `coordinator1`.
6. Reopen or otherwise robustly manage the event FIFO if the writer disconnects.
7. Add a regression test that proves event -> supervisor reply -> Codex decision sink is invoked. Existing tests stop one step too early.

## Bottom line

Codex currently has "permission notification scaffolding", not permission forwarding. The request can be parsed and a supervisor can theoretically reply, but there is no source-visible path that sends the decision back to Codex. The OpenCode implementation is the reference: the missing Codex equivalent is the final resolve call plus the delivery-loop-safe reply handling around it.
