# `codex-headless` Managed Client Design

## Problem

`c2c` now has a high-quality Codex path for the TUI client:

- managed `c2c start codex`
- XML sideband delivery when the forked TUI exposes it
- PTY notify fallback for older Codex builds

What it does not have is a first-class automation-oriented Codex variant that:

- uses the x-thin bridge process directly
- accepts broker-delivered inbound messages as real user turns
- preserves a resumable Codex thread across managed restarts
- stays operational without inventing a second delivery model

The requested `codex-headless` client is not `codex --headless` and not
`codex-exec`. It is a separate managed client surface built around
`codex-turn-start-bridge`.

## Goal

Add `codex-headless` as a managed `c2c start` client that:

- launches `codex-turn-start-bridge` directly
- uses XML stdin as the only message lane
- reuses as much of the existing Codex XML delivery path as possible
- supports minimal local steering from the terminal
- persists and reuses the resolved Codex `thread_id` on restart

This is a high-quality path only. `codex-headless` does not need a degraded PTY
fallback mode.

## Non-Goals

- using `codex-exec` as the managed `codex-headless` process
- adding a PTY notify fallback for `codex-headless`
- creating a second delivery protocol separate from Codex XML user messages
- building a rich headless TUI in v1
- changing the existing `codex` TUI launch shape

## Public Interface

### Start Surface

Add:

```bash
c2c start codex-headless [-n NAME] [-- EXTRA_ARGS...]
```

This launches a managed instance whose inner process is:

```bash
codex-turn-start-bridge --stdin-format xml --codex-bin codex ...
```

The literal client name remains `codex-headless` in managed-instance metadata
and `c2c instances` output.

`EXTRA_ARGS` are forwarded to `codex-turn-start-bridge`, not to the underlying
`codex` binary named by `--codex-bin`.

V1 should reserve ownership of bridge-critical flags to `c2c`. In particular,
managed launch should control:

- `--stdin-format`
- `--codex-bin`
- `--thread-id`
- `--approval-policy`

### Install Surface

`codex-headless` does not need separate install semantics.

Add:

```bash
c2c install codex-headless
```

as a direct alias of:

```bash
c2c install codex
```

`c2c init --client codex-headless` should likewise reuse the Codex install/setup
path and shared `~/.codex/config.toml` behavior.

## Launch Model

`codex-headless` is a Codex-family variant in the managed launcher.

Shared Codex-family responsibilities:

- broker/session env construction
- Codex-family binary and capability checks
- XML message framing
- durable broker-to-XML spool behavior
- install/setup semantics
- managed-instance state persistence

Variant-specific responsibilities:

- `codex`
  - binary: `codex`
  - launch style: TUI
  - preferred delivery: `--xml-input-fd`
  - fallback: PTY notify
- `codex-headless`
  - binary: `codex-turn-start-bridge`
  - launch style: bridge process
  - delivery: XML stdin only
  - fallback: none

## Message Lane

`c2c` owns the bridge stdin for `codex-headless`.

Everything that enters the managed Codex session uses the same XML user-message
lane:

- inbound c2c broker messages
- local operator steering lines, after they have been handed to the same
  durable writer path

Each delivered message becomes one XML frame:

```xml
<message type="user"><c2c event="message" ...>...</c2c></message>
```

or, for local steering:

```xml
<message type="user">operator text here</message>
```

There is no second steering protocol and no PTY injection path.

### Single Writer Ownership

Only one component may write to bridge stdin.

For `codex-headless`, the durable XML writer must remain the sole owner of the
bridge stdin file descriptor for the lifetime of the managed session. That
writer is responsible for serializing both:

- broker-delivered messages
- operator steering messages

The operator console must not write directly to bridge stdin. Instead it should
enqueue operator messages into a per-instance queue or spool that the durable
writer drains in order.

This preserves the same crash-safety property the current Codex XML path already
has: messages are staged durably before the live inbox or pending queue is
cleared.

## Minimal Operator Console

`c2c start codex-headless` should expose a deliberately small operator console.

Required behavior:

- accept simple terminal input from the operator
- convert ordinary input lines into queued user messages for the durable XML
  writer
- stream any bridge-emitted stdout/stderr to the terminal

Required local commands:

- `/help`
- `/status`
- `/quit`

These commands are handled by `c2c` before XML encoding. All other entered lines
are treated as user messages.

This is not a full-screen TUI and not a second app-server frontend. It is only
enough to:

- steer the agent quickly
- quit the managed session cleanly

### Output Visibility

The current bridge source does not appear to emit a readable assistant-output
stream for operators. So v1 should make only the following guarantee:

- a minimal steering console exists
- bridge stdout/stderr is surfaced if the bridge emits anything useful

Readable live agent-output logging is a follow-up unless the bridge gains a
machine-readable event or text-output surface.

## Approval Model

The current bridge rejects interactive server requests and exits non-zero when
they occur. So `codex-headless` cannot rely on interactive approval UX in v1.

V1 contract:

- managed `codex-headless` launch must use an explicit non-interactive approval
  policy compatible with bridge operation
- the default for `c2c start codex-headless` should be `--approval-policy never`
- there is no approval prompt surface in the headless console

This keeps the headless path honest about what it can support today. A later
version may relax this if the bridge grows an approval-response surface that
`c2c` can drive safely.

## Resume Model

`codex-headless` resume must be thread-based, not `resume --last`.

On first launch:

- `c2c` starts `codex-turn-start-bridge` without `--thread-id`
- the bridge starts a new Codex thread
- `c2c` receives the resolved `thread_id`
- `c2c` stores that value in managed-instance state

On later restart:

- `c2c` passes `--thread-id <saved-id>`
- the bridge resumes that thread
- `c2c` persists the returned `thread_id` again as the source of truth

For `codex-headless`, managed `resume_session_id` should store the Codex
`thread_id`.

This requires a targeted change in `c2c_start` state handling:

- `codex-headless` must not use UUID-only validation for `resume_session_id`
- saved headless resume ids must be treated as opaque thread identifiers
- migration/repair logic that currently regenerates non-UUID values must exclude
  `codex-headless`

## Required Upstream Contract

Reliable resume depends on a machine-readable bridge handoff for the resolved
thread id.

Requested upstream contract:

- [THREAD_ID_HANDOFF.md](/home/xertrov/x-game-src/refs/codex/THREAD_ID_HANDOFF.md:1)

Recommended shape:

```bash
codex-turn-start-bridge --thread-id-fd <N>
```

with a one-line JSON payload written immediately after successful thread
start/resume.

Without this handoff, `c2c` cannot implement reliable restart/resume for
`codex-headless` without brittle log scraping.

## Failure Handling

`codex-headless` is high-quality only and should fail fast if its required
surfaces are missing.

Startup checks:

- `codex-turn-start-bridge` exists
- `codex` exists for `--codex-bin`
- bridge supports `--stdin-format xml`
- bridge exposes the required thread-id handoff surface
- managed launch can enforce the non-interactive approval policy required by v1

Failure policy:

- if a required binary or bridge capability is missing, `c2c start codex-headless`
  exits with a clear error
- if the thread-id handoff write fails after launch, the managed session exits
  non-zero rather than continuing in an unresumable state
- there is no PTY fallback and no silent downgrade to polling-only managed mode
- XML write failures use the existing durable spool/retry semantics already used
  by the Codex XML delivery path
- bridge stdin must stay open for the full managed-session lifetime; accidental
  stdin closure is a fatal session error because the bridge exits once stdin
  closes and its queues drain
- if the bridge exits, the managed outer process cleans up sidecars/pipes,
  preserves state, and prints the normal resume guidance

## Shared Implementation Direction

Refactor the managed launcher around a Codex-family variant model instead of
hard-coding only one Codex client shape.

Expected OCaml-side changes:

- extend the known client list with `codex-headless`
- route `install codex-headless` and `init --client codex-headless` to shared
  Codex setup
- add a Codex-family launch helper that selects:
  - binary
  - launch args
  - XML transport style
  - resume behavior
- carve `codex-headless` out of UUID-only `resume_session_id` validation and
  saved-state repair logic
- add a headless console loop that:
  - reads operator stdin
  - enqueues user lines for the durable XML writer
  - preserves local commands
- extend the durable XML writer path so one writer owns bridge stdin and drains:
  - broker inbox spool
  - operator steering queue
- persist returned thread-id handoff in managed instance state
- force or default the bridge launch approval policy to `never` in v1

The Python delivery daemon should not gain a second protocol. It should continue
to emit the same XML user-message frames; only the destination transport differs:

- Codex TUI: sideband fd
- Codex headless: bridge stdin

## Testing

### Fast Tests

Add unit/CLI coverage for:

- `codex-headless` in supported-client lists
- `install codex-headless` aliases to Codex setup
- launch argv chooses `codex-turn-start-bridge --stdin-format xml --codex-bin codex`
- saved `resume_session_id` is mapped to bridge `--thread-id`
- missing bridge capability is a hard error

### Delivery Tests

Add delivery coverage for:

- broker message becomes one XML frame for `codex-headless`
- manual steering line reaches the same durable writer path and XML message lane
- spool survives retry/restart
- thread-id handoff is persisted and reused
- operator queue and broker spool preserve ordering across restart

### Live Tests

Add tmux-driven managed-session tests for:

- `c2c start codex-headless` launches and stays up
- sending a DM reaches the managed session without manual `poll_inbox`
- local operator input is accepted and serialized through the same XML lane
- restart resumes the same Codex thread once thread-id handoff exists
- headless launch uses the required non-interactive approval policy
- accidental stdin/writer closure is treated as a managed-session failure
- bridge-emitted output is surfaced if the bridge later exposes a readable stream

## Acceptance Criteria

- `c2c start codex-headless` is a supported managed client
- `c2c install codex-headless` behaves exactly like `c2c install codex`
- `codex-headless` launches `codex-turn-start-bridge` in XML mode
- inbound broker messages and local steering use the same XML user-message lane
- `codex-headless` does not use PTY notify fallback
- managed restarts resume the same Codex thread via persisted `thread_id`
- the implementation reuses the existing Codex XML delivery path instead of
  introducing a separate headless-only protocol
