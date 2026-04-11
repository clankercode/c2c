# Findings Review: current C2C messaging work

## Bottom line
The directory contains one genuinely useful result and several dead-end experiments.

- Useful result: the work proved that Claude team inbox JSON files can be used as a relay surface, and it also proved that a relay can sustain a long back-and-forth.
- But: this is not normal Claude-to-Claude messaging between two ordinary interactive CLI sessions.
- The successful conversation was effectively puppeted by a relay process/session, not by two autonomous top-level Claude sessions talking directly.

For a non-Teams solution, the best path is to stop trying to inject into arbitrary already-running interactive CLI sessions and instead use a supported transport from process start (stream-json or a per-session socket/bridge), with a broker in the middle.

## What is useful

### 1. The notes correctly identify the one thing that actually worked
Evidence:
- `/home/xertrov/src/c2c-msg/SOLUTION.md`
- `/home/xertrov/src/c2c-msg/NOTES.md`
- `/home/xertrov/.claude-p/teams/default/inboxes/C2C-test-agent2.json`
- `/home/xertrov/.claude-p/teams/default/inboxes/team-lead.json`

What this proves:
- `SendMessage(...)` writes to inbox JSON files under `~/.claude-p/teams/default/inboxes/`.
- Those inbox files are readable and mutable.
- A polling relay can move messages across that surface.

This is useful as a reverse-engineering result about Claude's local storage and relay shape, even if Teams itself is not the target solution.

### 2. The research correctly narrows the likely real input surfaces
Evidence:
- `/home/xertrov/src/c2c-msg/meta-agent-research.md`

Most credible transport options identified there:
- `stream-json` stdin
- per-session Unix socket when available
- PTY/tmux paste style injection only if the target runtime is actually reading from that path in a supported way

The key value here is architectural: direct supported input channels are more promising than transcript/history mutation.

### 3. The failure notes are valuable because they eliminate several tempting but bad approaches
Evidence:
- `/home/xertrov/src/c2c-msg/research-notes.md`

Likely-correct eliminations:
- PTY writes to existing interactive sessions do not meaningfully enter Claude's message loop.
- Appending to history does not cause a live interactive session to consume a new message.
- The shared IPC socket investigation never established a usable address or protocol.
- `SendMessage` is scoped to teammates/subagents, not arbitrary top-level sessions.

## What is dead-end or misleading

### 1. The "working conversation" is not true direct Claude-to-Claude messaging
Evidence:
- `/home/xertrov/src/c2c-msg/NOTES.md` explicitly says the relay session is acting as `C2C-test-agent2`.
- `/home/xertrov/src/c2c-msg/c2c_auto_relay.py` generates canned responses itself.
- `/home/xertrov/.claude-p/teams/default/inboxes/team-lead.json` and `/home/xertrov/.claude-p/teams/default/inboxes/C2C-test-agent2.json` show the relay writing/marking messages directly.

Why this matters:
- It demonstrates relay mechanics, not autonomous session-to-session messaging.
- So it should not be treated as proof that two normal Claude CLI sessions can talk directly today.

### 2. `c2c_auto_relay.py` is a demo stub, not a path to real C2C
Evidence:
- `/home/xertrov/src/c2c-msg/c2c_auto_relay.py`

Problems:
- It watches `team-lead` inbox, not the target agent's actual prompt-processing loop.
- It fabricates a response string itself.
- It appends the response back into `team-lead` inbox.

This is useful only as a mock relay skeleton.

### 3. PTY delivery attempts look like a dead end for existing interactive sessions
Evidence:
- `/home/xertrov/src/c2c-msg/relay.py`
- `/home/xertrov/src/c2c-msg/c2c_relay.py`
- `/home/xertrov/src/c2c-msg/research-notes.md`

Reason:
- The notes already conclude PTY input hit the terminal layer rather than Claude's internal message handler.
- So polishing PTY/bracketed-paste injection is likely wasted effort unless the session is launched under a runtime known to consume that input as messages.

### 4. The Unix-socket probing scripts are not close to a usable implementation
Evidence:
- `/home/xertrov/src/c2c-msg/connect_ipc.py`
- `/home/xertrov/src/c2c-msg/connect_abstract.py`
- `/home/xertrov/src/c2c-msg/investigate_socket.py`

Problems:
- They do not identify a stable connectable address.
- They do not know the framing/handshake/protocol.
- They mostly guess at abstract-socket addressing and payload shape.

This is currently exploratory, not implementation-ready.

### 5. History injection is both conceptually weak and implementation-inconsistent
Evidence:
- `/home/xertrov/src/c2c-msg/send_to_session.py`
- `/home/xertrov/src/c2c-msg/research-notes.md`
- `/home/xertrov/.claude-p/history.jsonl`

Problems:
- Notes already say live sessions do not poll history.
- The script writes to `~/.claude/history.jsonl`, while the researched sessions are in profile `p` and the visible history file is `/home/xertrov/.claude-p/history.jsonl`.

So this is a dead end twice over: wrong mechanism, and likely wrong profile path.

### 6. `claude-send-to-c2c` is only a reminder wrapper
Evidence:
- `/home/xertrov/src/c2c-msg/claude-send-to-c2c`

It does not send anything; it only prints instructions.

## Best next implementation path for non-Teams Claude-to-Claude messaging

## Recommended path
Build a brokered messaging prototype around supported session input surfaces from session creation time, not by injecting into arbitrary already-running interactive CLI sessions.

Concretely:
1. Start each Claude participant in a controllable mode that has a real input channel:
   - best candidate: `claude --input-format stream-json`
   - second candidate: a runtime like `claude-commander` that exposes a per-session Unix socket
2. Put a tiny broker in the middle that:
   - assigns agent/session IDs
   - persists message envelopes
   - forwards user/agent messages to the correct session transport
   - records responses and delivery status
3. Treat ordinary interactive CLI sessions as human-facing shells only, not as the wire protocol endpoint.

Why this is the best path:
- It matches the most credible findings in `meta-agent-research.md`.
- It avoids the already-failed PTY/history approaches.
- It removes dependence on Teams.
- It gives you something deterministic and testable.

## Important secondary insight
Before building too much, re-test `cc-p --resume` on the current Claude version.

Evidence:
- `/home/xertrov/src/c2c-msg/research-notes.md` recorded earlier `--resume` failure.
- `/home/xertrov/.claude-p/cache/changelog.md` contains many later `--resume` fixes and improvements.

This may still fail for interactive top-level session injection, but it is the cleanest native path and deserves one fresh validation pass before more custom transport work.

## Practical recommendation
Do not spend more time on:
- PTY paste injection into existing sessions
- history/transcript mutation
- blind probing of the shared abstract socket without protocol knowledge

Do spend time on:
- supported transport from launch time
- explicit broker/message schema
- fresh `--resume` validation on the current CLI build

## Prioritized next steps

1. Re-test native resume/injection on the current CLI.
   - Goal: verify whether `cc-p --resume <name-or-session-id>` can now deliver a prompt to one of these renamed interactive sessions on today's build.
   - If this works, it becomes the simplest non-Teams path.

2. If resume still fails, build a broker around `stream-json` sessions.
   - This is the highest-confidence implementation path for normal non-Teams C2C messaging.
   - Start new bridgeable sessions instead of targeting arbitrary existing interactive ones.

3. Only if you need richer interactive control, evaluate a per-session socket runtime such as `claude-commander`.
   - This is likely stronger than PTY hacks, but only worth it if stream-json is insufficient.
