## Goal

Add a minimal, repeatable two-session Claude harness that can launch fresh MCP-enabled sessions, observe their state, inject short prompts or keys, and drive the existing C2C chat verification flow.

## Scope

This harness is for test orchestration, not for replacing the existing Python or OCaml C2C transport implementations.

It should reuse the existing repo tools wherever possible:

- `claude_list_sessions.py` for discovering live session metadata
- `claude_send_msg.py` for PTY-backed prompt injection
- transcript files under `~/.claude/projects/...` for progress verification
- existing C2C commands for registration, listing, and send verification

## Recommended Approach

Implement the harness in Python.

Reasoning:

- The existing session metadata and PTY injection tooling is already in Python.
- The harness is primarily orchestration logic, so minimizing integration work matters more than runtime characteristics.
- Reusing the current Python utilities keeps the change surface small and reduces new failure modes.

## Behavior

The harness should support the following workflow:

1. Launch two fresh Claude sessions with the desired MCP and channel flags.
2. Detect the two new sessions and capture their:
   - session IDs
   - PIDs
   - TTYs
   - transcript paths
3. Handle simple startup interaction:
   - send `Enter` or another short key sequence if the channel warning must be accepted
   - inject very short prompts when needed
   - retry that initial PTY interaction if the session has not registered yet
4. Observe state by reading:
   - current live session metadata
   - transcript tails
   - optional terminal snapshots suitable for debugging
5. Drive the C2C flow:
   - register the two sessions with fixed aliases
   - seed the first message
   - verify the autonomous exchange reaches the target count

Fresh PTY-launched sessions are not reliably discoverable immediately after process spawn. In practice, Claude often does not expose session metadata until the PTY receives an initial interaction. The harness should prime each fresh session with `Enter`, wait about 1 second, and retry once before declaring launch discovery failed.

## Interface

Add a new Python script, tentatively `claude_pty_harness.py`.

It should provide a small command surface instead of a large framework. Initial subcommands:

- `launch-two`
  - launch two fresh sessions
  - return discovered metadata as JSON
- `snapshot`
  - return a short recent terminal snapshot for a session
- `send-prompt`
  - inject a short prompt into a session
- `send-key`
  - inject a simple key like `Enter`
- `await-condition`
  - poll transcripts or metadata until a condition is met or times out

The JSON shape should stay simple and match the existing session metadata style where possible.

## Reuse Strategy

The harness should call existing modules directly when practical rather than reimplementing them.

- Use `claude_list_sessions.load_sessions(with_terminal_owner=True)` for live discovery.
- Use `claude_send_msg.send_message_to_session(...)` for prompt injection.
- Reuse transcript path metadata already exposed by `claude_list_sessions.py`.

If a missing primitive is required, add the smallest possible helper to an existing Python module instead of duplicating logic inside the harness.

## Verification Plan

After the harness exists, use it to build a repeatable two-session verification flow:

1. Launch two sessions.
2. Confirm they are channel-enabled and responsive.
3. Register fixed aliases `c2c-s1` and `c2c-s2`.
4. Inject one short seed message.
5. Verify both sessions send at least 5 messages through the real channel/broker path.

## Non-Goals

- Rewriting session discovery in OCaml
- Replacing the current PTY injector
- Replacing the MCP server implementation
- Building a generic terminal automation framework beyond what this test flow needs

## Risks

- Claude startup dialogs may vary slightly across launches.
- Transcript timing may lag behind visible PTY state.
- Duplicate stale sessions with reused names can confuse naive discovery.
- Fresh launches may not register until after an initial PTY interaction.
- Channel delivery can enqueue and drain correctly while still failing to appear in the receiver transcript.

The harness should prefer exact session IDs and newly launched PIDs over session names.
