# Codex app-server safe message delivery research

Date: 2026-07-11

## Result

Codex CLI 0.144.1 provides a viable non-PTY architecture for *new* interactive
sessions: run an app-server endpoint, then attach the stock terminal UI using
`codex --remote <ws-or-unix-endpoint>`. A separate c2c client can then use the
app-server JSON-RPC protocol against that server.

The candidate passive-delivery primitive is `thread/inject_items`. Official
documentation says it appends raw Responses API items to a loaded thread's
model-visible history without starting a user turn. This is much safer than
`turn/steer`, which appends user input to an in-flight turn, or a terminal
injector, which can modify an operator's composer.

This is not yet a completed solution. The documented protocol does not promise
that an injected item becomes visible in the stock remote TUI, and no documented
path attaches app-server control to an already-running ordinary `codex` TUI.
Use the current hook-based path for ordinary sessions.

There is also a security gate: the app-server exposes powerful control methods,
not only item injection. A Unix socket path is not a sufficient boundary among
same-UID swarm processes. The prototype must prove an authenticated transport
with protected credentials or an OS/container identity boundary; otherwise this
architecture is a no-go even if injection preserves the composer.

## Safe contract

1. Persist every inbound c2c message in its broker inbox first.
2. For app-server-managed remote sessions, inject only a validated passive
   message item. Never use `turn/start`, `turn/steer`, `turn/interrupt`,
   PTY writes, tmux `send-keys`, or Herdr submission for passive delivery.
3. An incoming peer message remains data, not an instruction, approval, or
   command. It must never execute or authorize anything by itself.
4. Preserve the existing Codex hook delivery as the fallback.
5. Keep the existing hooks+wake implementation opt-in: its tmux/Herdr nudge
   writes text plus Enter and therefore cannot guarantee typed-draft safety.
6. Do not expose an app-server endpoint to peer processes without a proven
   control boundary. A peer must be unable to start, steer, interrupt, or
   otherwise control the thread.

## Evidence

- `codex --version` reported `codex-cli 0.144.1`.
- `codex --help` exposes `--remote <ws|wss|unix endpoint>`.
- `codex app-server --help` exposes WebSocket and Unix transports.
- Official app-server documentation describes remote terminal UI mode:
  `codex app-server --listen ws://127.0.0.1:4500` followed by
  `codex --remote ws://127.0.0.1:4500`.
- Official app-server documentation describes `thread/inject_items` as
  model-visible history insertion without a user turn.
- The shared c2c checkout's `c2c hook codex` currently drains at
  `UserPromptSubmit` and emits `additionalContext`; it supports ordinary
  interactive Codex safely, but only at a natural hook boundary.

## Implementation backlog

The work is in backlog phase `P1`, derived from idea `I001`:

- `P1.M1.E1.T001`: protocol and remote-TUI spike.
- `P1.M1.E1.T002`: opt-in app-server-backed session launcher.
- `P1.M1.E1.T003`: passive c2c ingress adapter.
- `P1.M1.E1.T004`: real-tmux typed-draft preservation proof.
- `P1.M1.E1.T005`: safe profile, installer, doctor, and documentation.

The spike must explicitly prove the behavior with a non-empty composer before
the rest proceeds.

## Sources

- https://learn.chatgpt.com/docs/app-server
- https://learn.chatgpt.com/docs/hooks
