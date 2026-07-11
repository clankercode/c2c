# Codex app-server safe message delivery research

Date: 2026-07-11

## Result

Codex CLI 0.144.1 provides a viable non-PTY architecture for *new* interactive
sessions: run an app-server endpoint, then attach the stock terminal UI using
`codex --remote <ws-or-unix-endpoint>`. A separate c2c client can then use the
app-server JSON-RPC protocol against that server. The planned normal lifecycle
is one app-server per `c2c start codex` session: it exits with the TUI. A closed
session is therefore offline and receives durable queued mail rather than a
background turn.

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
2. For an active app-server-managed session, inject a validated message item.
   Local-broker mail may then start a Codex turn only when recipient DND is off
   and the normal TUI has no in-progress composer draft; either condition queues
   without starting a turn. Never use `turn/steer`,
   `turn/interrupt`, PTY writes, tmux `send-keys`, or Herdr submission.
3. Local c2c messages are trusted peer communication and may wake the recipient
   and start a Codex turn under that recipient's delivery policy. This is still
   not an approval channel: message content can never resolve an approval or
   write an approval verdict; `allow`/`deny` strings remain inert to
   `await-reply`.
4. When the normal TUI exits, stop its app-server and report later sends as
   successful `queued_offline` delivery. Unknown aliases remain errors.
5. Generate the default alias from the stable Codex/app-server identity;
   `--alias` is an optional human override. `--yolo` must visibly forward only
   to Codex `--dangerously-bypass-approvals-and-sandbox`.
6. Preserve the existing Codex hook delivery as the fallback.
7. Keep the existing hooks+wake implementation opt-in: its tmux/Herdr nudge
   writes text plus Enter and therefore cannot guarantee typed-draft safety.
8. Do not expose an app-server endpoint to peer processes without a proven
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
- `P1.M1.E1.T002`: internal app-server-backed session launcher primitive used by the canonical managed Codex path.
- `P1.M1.E1.T003`: passive c2c ingress adapter.
- `P1.M1.E1.T004`: real-tmux typed-draft preservation proof.
- `P1.M1.E1.T005`: safe profile, installer, doctor, and documentation.
- `P1.M1.E1.T006`: canonical `start`/`new`/`resume` commands, generated
  aliases, optional `--alias`, and explicit `--yolo` forwarding.
- `P1.M1.E1.T007`: start a turn for active local mail when recipient policy
  permits, while DND and a non-empty composer keep the message queued.
- `B127`: durable local-broker mail for a known alias while its managed session
  is offline, with `queued_offline` receipts and exact-once resume delivery.

The spike must explicitly prove the behavior with a non-empty composer before
the rest proceeds.

## Sources

- https://learn.chatgpt.com/docs/app-server
- https://learn.chatgpt.com/docs/hooks
