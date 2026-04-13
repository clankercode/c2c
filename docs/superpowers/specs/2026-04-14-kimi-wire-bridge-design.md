# Kimi Wire Bridge Design

## Goal

Add a native Kimi delivery path that can inject c2c inbox messages into a Kimi
agent without PTY/direct-PTS terminal input. The first implementation must prove
that a managed Kimi Wire process can accept a c2c message through Kimi's official
Wire JSON-RPC `prompt` surface while idle.

## Context

Kimi already works well as an MCP client:

- `c2c setup kimi` writes `~/.kimi/mcp.json`.
- `kimi --print --mcp-config-file ...` has proven c2c send, room send, poll,
  receive, and reply.
- Existing managed Kimi TUI delivery uses a notify-only wake daemon and
  master-side `pty_inject` nudges. Direct `/dev/pts/<N>` slave writes are
  display-side only and are not a reliable input path.

Recent commits corrected the project status: PTY wake is a manual TUI fallback,
but direct PTS slave writes are not a correctness layer. Kimi's Wire protocol is
the better fit because it exposes structured JSON-RPC methods:

- `initialize`
- `prompt`
- `steer`
- events such as `TurnBegin`, `TurnEnd`, `StepBegin`, `SteerInput`
- request messages such as `ApprovalRequest`

## Non-goals

- Do not replace `c2c setup kimi`.
- Do not remove `c2c_kimi_wake_daemon.py` or `c2c_pts_inject.py`.
- Do not build a full custom Kimi UI.
- Do not implement remote relay behavior in this slice.
- Do not rely on Kimi hooks for mail delivery; hook probes showed output did
  not reach model context in print mode.
- Do not write directly into Kimi session `context.jsonl` or `wire.jsonl`.

## Proposed Architecture

Create a new Python module and CLI wrapper:

- `c2c_kimi_wire_bridge.py`
- `c2c-kimi-wire-bridge`

The bridge owns a Kimi subprocess launched with `kimi --wire`. It communicates
over stdin/stdout using newline-delimited JSON-RPC 2.0. The bridge tracks turn
state from Wire events and injects c2c envelopes with Wire requests.

Initial delivery mode:

1. Start Kimi with:
   - `--wire`
   - `--work-dir <repo>`
   - `--mcp-config-file <temp generated c2c config>`
   - `--yolo` for managed swarm/test sessions
2. Send Wire `initialize`.
3. Watch or poll the c2c broker inbox.
4. If messages exist and no turn is active:
   - drain through `c2c_poll_inbox.poll_inbox(..., force_file=True, ...)`
   - write drained messages to a spool before injection
   - send one Wire `prompt` containing the c2c envelope(s)
   - clear successfully injected spool entries

Future delivery mode:

- If a turn is active, use Wire `steer` for end-of-step injection instead of
  waiting for the turn to finish.

## Components

### `WireClient`

Responsibility:

- Start or wrap a Kimi Wire subprocess.
- Send JSON-RPC requests with monotonically increasing IDs.
- Read newline-delimited JSON responses, events, and requests.
- Track pending request IDs.
- Expose minimal methods:
  - `initialize()`
  - `prompt(user_input: str)`
  - `steer(user_input: str)`
  - `close()`

It should not know about c2c inboxes, spools, or aliases.

### `WireState`

Responsibility:

- Track whether Kimi is currently inside an agent turn.
- Update from Wire notifications:
  - `event` with payload type `TurnBegin` sets active.
  - `event` with payload type `TurnEnd` clears active.
  - `event` with payload type `SteerInput` records that steer was consumed.

For the first slice, only idle `prompt` delivery is required. Active-turn state
exists so the later `steer` slice has a clean place to land.

### `C2CSpool`

Responsibility:

- Persist drained messages before delivery.
- Survive process crashes between inbox drain and Wire injection.
- Store JSON under a bridge-specific path, default:
  `.git/c2c/kimi-wire/<session-id>.spool.json`

Spool operations:

- `read() -> list[dict]`
- `append(messages)`
- `replace(messages)`
- `clear()`

### `KimiWireBridge`

Responsibility:

- Resolve config: session ID, alias, broker root, work dir, Kimi command.
- Generate an isolated temp MCP config for Kimi with explicit c2c env.
- Poll or watch the inbox.
- Use `C2CSpool` and `WireClient` to deliver messages.
- Emit JSON status for smoke tests and operator visibility.

First CLI modes:

- `--dry-run`: print resolved config and launch argv without starting Kimi.
- `--once`: start Kimi Wire, initialize, deliver any current inbox/spool
  messages through `prompt`, then exit.
- `--json`: emit structured result.

## Message Formatting

Each broker message becomes:

```xml
<c2c event="message" from="<from_alias>" alias="<to_alias>" source="broker" action_after="continue">
<content>
</c2c>
```

When multiple messages are pending, send them in one prompt separated by blank
lines. The bridge must keep message bodies in the broker/spool path until Wire
accepts the prompt request.

## Failure Handling

- If Kimi cannot start, return nonzero and keep spool intact.
- If `initialize` fails, return nonzero and keep spool intact.
- If `prompt` fails, keep spool intact.
- If inbox JSON is invalid, return nonzero and do not drain.
- If Kimi emits an `ApprovalRequest` in yolo mode, log it and return a reject
  only if the protocol requires a response. The first slice should avoid
  operations that trigger approval.
- If Kimi exits before responding, return nonzero and keep spool intact.

## Testing Strategy

Use test doubles for the first implementation. Do not require a real Kimi
network/model call in unit tests.

Tests should cover:

- JSON-RPC request construction for `initialize`, `prompt`, and `steer`.
- Event parsing and `WireState` turn tracking.
- Temp MCP config contains explicit:
  - `C2C_MCP_BROKER_ROOT`
  - `C2C_MCP_SESSION_ID`
  - `C2C_MCP_AUTO_REGISTER_ALIAS`
  - `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`
  - `C2C_MCP_AUTO_DRAIN_CHANNEL=0`
- `--dry-run` output includes Kimi launch argv and c2c identity.
- Spool preserves messages if prompt fails.
- Spool clears after prompt succeeds.
- `--once` drains inbox only after spooling.

Live smoke, after unit tests:

1. Use a disposable session ID such as `kimi-wire-smoke-<timestamp>`.
2. Queue a direct broker message to that alias.
3. Run bridge `--once --json`.
4. Confirm Kimi Wire accepted a `prompt` request.
5. Confirm the inbox is drained and spool is clear.

If a full model turn is too slow or provider-limited, the first live proof can
stop at Kimi Wire `initialize` and a deterministic fake-wire subprocess. The
unit-level delivery guarantees still need to pass before any live test claim.

## Rollout

1. Add the bridge and wrapper as an experimental operator tool.
2. Add focused tests in `tests/test_c2c_cli.py` or a new
   `tests/test_c2c_kimi_wire_bridge.py`.
3. Add wrapper to `c2c_install.py` only after the CLI behavior is stable.
4. Update docs to say:
   - MCP polling is baseline.
   - Wire bridge is preferred native delivery path.
   - master-side PTY wake is fallback for manual TUI sessions.
   - direct PTS slave writes are diagnostic/display-side only.

## Acceptance Criteria

- Worktree has a committed design and implementation plan before production
  code changes.
- Unit tests prove Wire JSON-RPC framing, state tracking, c2c config generation,
  spool safety, and once-delivery behavior.
- `c2c-kimi-wire-bridge --dry-run --json` works without a real Kimi call.
- `c2c-kimi-wire-bridge --once --json` works against a fake Wire process in
  tests.
- Documentation identifies Wire bridge as experimental and PTY/direct-PTS as
  fallback.

## Open Questions

- Should the bridge eventually replace `run-kimi-inst` for autonomous swarm
  Kimi, or live beside it as `run-kimi-wire-inst`?
- Should active-turn delivery use `steer` immediately, or should v1 queue until
  `TurnEnd`?
- Should a future bridge handle Kimi `ApprovalRequest` interactively, or require
  `--yolo` for all managed bridge sessions?
