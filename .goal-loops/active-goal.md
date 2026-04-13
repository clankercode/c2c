# Primary Goal

Unify all agents via the c2c instant messaging system — make it so that
Claude Code, Codex, OpenCode, Kimi, and Crush agents can send and receive
messages in real time, across 1:1 DMs and N:N group rooms, on the local
machine and across machines via relay.

## Group Goal Context

The broader group goal is larger than any single iteration.
These are Max's target experiences, verbatim:

### Delivery surfaces
- **c2c via MCP**: auto-delivery of inbound messages into the agent's
  transcript plus tool-path sending. Real auto-delivery requires the
  experimental `notifications/claude/channel` extension; on binaries
  where that's gated, the MCP surface stays polling-based via `poll_inbox`.
- **c2c via CLI**: fallback path usable by any agent, with or without MCP.
- **c2c CLI self-configuration**: the CLI turns on auto-delivery for any
  host client that supports it (no hand-editing settings files).

### Reach
- Codex, Claude Code, OpenCode, Kimi, Crush as first-class peers.
- Cross-client parity: a message from Codex to Kimi Just Works.
- Local-only today; broker design does not foreclose remote transport.

### Topology
- 1:1 ✓, 1:N ✓ (send_all), N:N ✓ (rooms: join_room, send_room, etc.)
- `swarm-lounge` is the default social room; all clients auto-join.
- `c2c init` / `c2c join <room>`, discoverable peers, sensible defaults.

### Social layer
- Persistent social channel for agents to coordinate and reminisce.
  Room identity and history support this.

---

## Current Status (updated 2026-04-14, storm-ember)

### Satisfied (all AC met)

- **Claude Code** ↔ Codex ↔ OpenCode ↔ Kimi: 1:1 DM proven for all live pairs.
- **Claude Code**: PostToolUse hook auto-delivers broker inbox per tool call.
  Fast path ~3ms (bash builtin); stable alias via `C2C_MCP_AUTO_REGISTER_ALIAS`.
- **Codex**: managed harness (`run-codex-inst-outer`) + `c2c_deliver_inbox --notify-only`
  loop; `c2c setup codex` for one-command onboarding.
- **OpenCode**: native TypeScript plugin (`.opencode/plugins/c2c.ts`) PROVEN
  end-to-end (59c0909, 2026-04-14). Plugin background-polls broker, delivers via
  `client.session.promptAsync`. DM drain + promptAsync confirmed; opencode-local
  replied to Codex's probe. PTY wake daemon is fallback only. Spool file retries
  failed promptAsync; spool injected into managed restart prompt (9cc5663).
  JSON parse bug fixed (da78130): `parsePollResult()` unwraps CLI JSON envelope.
- **Kimi**: managed harness (`run-kimi-inst-outer`) + wake daemon.
  PTY wake proven; kimi-nova↔opencode-local DM roundtrip proven. All Kimi↔
  {Claude, Codex, OpenCode} pairs proven 2026-04-13.
- **Rooms** ✓: `join_room`, `send_room`, `room_history`, `my_rooms`,
  `list_rooms`, `leave_room`. `swarm-lounge` is active. Sweep evicts dead
  room members.
- **Dead-letter + auto-redelivery** ✓: swept sessions recover queued messages
  on re-register. Matched by session_id OR alias.
- **Broker-gc** ✓: daemon sweeps dead registrations; `c2c sweep` CLI;
  `c2c dead-letter` for orphan inspection and pruning.
- **Cross-machine relay** ✓: 6 phases complete (InMemoryRelay → SQLite backend,
  HTTP relay server, connector sync, rooms, GC daemon, exactly-once dedup).
  `c2c relay serve/connect/setup/status/list/gc/rooms`. Tested in-process.
- **Liveness hardening** ✓: `pid_start_time` defeats PID reuse. POSIX `fcntl.lockf`
  interlocks OCaml broker + Python writers. Alias-occupied guard prevents
  one-shot probes from evicting live peer registrations.
- **`C2C_MCP_CLIENT_PID`** ✓: all managed launchers (kimi, crush, codex,
  opencode) pin the broker's liveness target to the durable outer-loop PID.
- **OCaml broker** ✓: 97 tests; sweep, rooms, dead-letter, alias dedup,
  peer-renamed fan-out, session hijack guard, alias-occupied guard,
  dead-pid fallback in `current_client_pid()`.
- **Python suite** ✓: 718 tests across all subsystems.
- **Kimi Wire bridge** ✓: `c2c_kimi_wire_bridge.py` + `c2c-kimi-wire-bridge` wrapper;
  42 tests pass; `run_once_live` subprocess path implemented and **live-proven
  2026-04-14** by codex with a real `kimi --wire` subprocess (delivered 1 broker
  message, cleared spool, rc=0; see finding
  `2026-04-13T16-10-03Z-codex-kimi-wire-live-once-proof.md`). Native JSON-RPC
  delivery via `kimi --wire` without PTY injection. `run_loop_live` + `--daemon`
  polls cheaply and starts Wire only when inbox/spool work exists, with pidfile
  and log support for detached operation.
- **Kimi wake daemon** ✓: basic and idle-at-prompt TUI wake proven via the
  master-side `pty_inject` backend. Kimi uses a longer default submit delay
  (1.5s) so prompt_toolkit accepts and submits the notify-only poll prompt.
  Direct `/dev/pts/<N>` slave writes are display-side only and must not be used
  as an interactive input path (see finding
  2026-04-13T16-12-18Z-codex-kimi-pts-slave-write-not-input.md).
- **Kimi Wire Bridge** ✓: native JSON-RPC delivery via `kimi --wire` implemented
  and **live-proven 2026-04-14** by `kimi-nova`. Auto-registration, inbox drain,
  Wire `prompt` delivery, and spool clearing all confirmed working end-to-end
  (see finding 2026-04-14T02-27-00Z-kimi-nova-kimi-wire-bridge-live-proof.md).
  Persistent `--loop` and detached `--daemon` modes are implemented for daemon
  use. `c2c wire-daemon` lifecycle management subcommand added (start/stop/status/
  restart/list) with standard pidfile support (2026-04-14, storm-ember).
  This is Kimi's preferred native path; master-side PTY wake remains the
  manual TUI fallback.

### Satisfied (continued)

- **Cross-machine relay live test** ✓: localhost multi-broker test passed
  2026-04-14 (see finding 2026-04-14T02-06-00Z-kimi-nova-relay-localhost-
  multi-broker-test.md). Docker cross-machine equivalent test passed 2026-04-14
  (see finding 2026-04-14T02-16-00Z-kimi-nova-relay-docker-cross-machine-
  test.md). True two-machine Tailscale test passed 2026-04-14 with `x-game` ↔
  `xsm` over real network (see finding 2026-04-14T02-37-00Z-kimi-nova-relay-
  tailscale-two-machine-test.md).
- **Site visual redesign** ✓: Max approved without sign-off gate. Redesign
  shipped with deep-space dark theme, electric cyan + magenta accents,
  glass-morphism cards, mesh-gradient hero, pulse animations, card-grid
  features, and Inter typography (2026-04-14).

### Active Work

- **Crush DM proof** — `c2c_crush_wake_daemon.py` written, Crush MCP config
  ready. Max is configuring Crush; will unblock when ready.

### Remaining Product Polish

- **Inbox drain progress indicator** ✓ — `c2c poll-inbox` text mode now prints
  `[c2c-poll-inbox] N message(s) for <session> (<source>)` before message bodies;
  JSON output gains a top-level `count` field. 3 new tests; 718 Python total
  (a01ce40, 2026-04-14).
- Room access control (invite-only, message visibility scopes) — future work.
- Native MCP push delivery — revisit `notifications/claude/channel` on future
  Claude builds.

---

## For Autonomous Agents Resuming This Session

When you resume, start by:
1. `mcp__c2c__poll_inbox` — drain your inbox
2. `mcp__c2c__whoami` — re-register if missing
3. Check `tmp_collab_lock.md` for active peer locks
4. Check `swarm-lounge` for recent swarm activity
5. Arm the inotifywait broker monitor (see CLAUDE.md Recommended Monitor setup)
6. Pick the highest-leverage unblocked work

**Do NOT call `mcp__c2c__sweep` while outer loops are running.**
Check: `pgrep -a -f "run-(kimi|codex|opencode|crush|claude)-inst-outer"`

Empty inbox is NOT a stop signal. Send a message to swarm-lounge with what
you're working on, pick up a slice, and keep going. The swarm lives as long
as at least one agent is active.

---

## Blockers / Notes

- **Crush**: needs `ANTHROPIC_API_KEY` in the Claude Code shell to launch.
- **OpenCode plugin promptAsync**: codex is patching the session target selection.
  Do not edit `.opencode/plugins/c2c.ts` or `run-opencode-inst` while codex
  holds the lock (check `tmp_collab_lock.md`).
- **Channel delivery**: `notifications/claude/channel` requires `experimental.claude/channel`
  in the client's `initialize` handshake. Standard Claude Code does not declare
  this; polling is the production delivery path. `C2C_MCP_AUTO_DRAIN_CHANNEL=0`
  is the correct setting (see findings).
