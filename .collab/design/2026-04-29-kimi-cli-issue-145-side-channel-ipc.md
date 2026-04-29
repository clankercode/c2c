# Upstream issue draft — kimi-cli: expose approval IPC as side-channel alongside shell mode

**Status:** DRAFT — for Max sign-off via coordinator1 before filing.
**Repo target:** `kimi-cli` (whichever upstream repo hosts it; needs confirmation —
the source on disk lives under `~/.local/share/uv/tools/kimi-cli/` from `uv tool install`).
**Author:** stanza-coder (c2c swarm)
**Date drafted:** 2026-04-29

---

## Issue title

Feature request: expose approval-runtime IPC as a side-channel alongside
shell-UI mode (not as a replacement)

## Issue body

### Summary

`kimi-cli` already has a complete, well-structured permission IPC: the
`approval_runtime` (`kimi_cli/approval_runtime/runtime.py`) backed by
`wire/server.py`'s JSON-RPC 2.0 stdio protocol. Today this IPC is only
reachable when kimi runs in `--wire` mode, which is mutually exclusive with
the interactive shell-UI mode. We'd like to use the IPC from external
supervisors (think: a coordinator process forwarding tool-approval requests
to a remote reviewer for sign-off) **while** kimi is rendering its
interactive TUI for an operator at the keyboard.

The ask: a flag (e.g. `--expose-approval-ipc <socket-or-fd>`,
`--wire-side-channel`, or similar) that runs the approval IPC server
**alongside** the shell-UI render loop on the same `ApprovalRuntime`
instance, rather than as a UI-mode swap.

### Motivation / use case

We're building a peer-to-peer agent communication system ("c2c") where
multiple agentic CLIs (Claude Code, OpenCode, Codex, kimi-cli) collaborate.
For unattended swarm operation, when an agent's tool-call requires
approval, we want a designated reviewer (another agent or human peer) to
see the request, sign off remotely, and have the verdict round-trip back —
without anyone needing to physically navigate to the agent's TTY pane.

For OpenCode and Codex this is straightforward — they expose programmatic
permission interception via their plugin / hook systems. For kimi-cli, we
mapped the source and found the IPC infrastructure already exists in
`wire/server.py`; it just isn't reachable from shell-UI mode today.

We don't want to use `--wire` standalone because:
- The operator at the keyboard still wants the rich interactive TUI.
- Spawning a second `kimi --wire` process per session doesn't help — each
  process has its own `ApprovalRuntime`, sees its own (different) agent's
  tool calls, and has zero visibility into the TUI process's pending
  approvals.

### Source pointers (current behavior)

Reading `kimi_cli/cli/__init__.py`:

- **Line 50**: `UIMode = Literal["shell", "print", "acp", "wire"]` —
  UI modes are mutually exclusive by enum.
- **Lines 244-249**: `--wire` is a bool that sets `wire_mode`.
- **Lines 435-460**: explicit conflict-set check enforces at-most-one of
  `{--print, --acp, --wire}`.
- **Lines 469-475**: `ui` is single-valued.
- **Lines 674-677**: `case "wire": await instance.run_wire_stdio()` is a
  separate code path entirely, not a side-channel.

The `ApprovalRuntime` itself is per-process state; the wire-server reads
from and writes to it. Decoupling "expose the IPC" from "swap the UI"
should be a small, internal refactor — the data structures already match.

### Proposed flag shape (open to bikeshed)

Two reasonable shapes:

**Shape A — additive flag, fd-based (recommended for Unix supervisors):**
```
kimi --expose-approval-ipc <fd|"-"|"@socket-path">
```
- `<fd>` — a numeric file descriptor inherited from the parent process.
  The supervisor opens the JSON-RPC pipe, passes the fd to kimi.
- `-` — stdin/stdout (reasonable when kimi is run as a subprocess of the
  supervisor with stdio pipes).
- `@socket-path` — abstract or filesystem unix socket.

Composes cleanly with `--shell` (the default), allowing the side-channel to
run while the TUI renders.

**Shape B — boolean flag, defaulting to a known socket path:**
```
kimi --wire-side-channel
```
- Opens a unix socket at e.g. `~/.kimi/sessions/<wh>/<sid>/wire.sock` and
  serves the JSON-RPC there.
- Easier to spawn (no fd-passing dance for the supervisor), but locks in
  a path convention.

We have a slight preference for Shape A (more compositional, harder to
abuse), but either would unblock our use case.

### Backward compatibility

This is purely additive:
- `--wire` continues to work as today (UI-mode swap).
- The new flag is opt-in; default behavior unchanged.
- Existing wire JSON-RPC clients already speak the protocol; they'd just
  point at the new socket/fd instead of stdio.

### Security considerations

- The side-channel exposes tool-approval power. Filesystem socket should
  be `0600` and owned by the kimi process owner; fd-passing inherits parent
  trust.
- Auth: the IPC has no auth today (relies on stdio access). For
  side-channel mode, an `--ipc-token <token>` companion flag would let
  supervisors gate access; nice-to-have, not load-bearing for v1.

### Alternatives we considered

1. **Tmux-scrape** — poll `tmux capture-pane` for approval-prompt UI,
   send `1`/`Enter` keystrokes to approve. Brittle to UI changes, no
   structured prompt-id, no audit trail. (See c2c finding
   `2026-04-29T12-40-00Z-stanza-coder-kimi-wire-tui-mutually-exclusive.md`.)
2. **Local kimi-cli fork** — patch the conflict-set to allow `wire +
   shell`. Maintainable in the short term but ties us to per-release
   re-applying. We'd rather upstream the change.
3. **Stay on `--afk`** — auto-approve everything. Acceptable for
   swarm-internal trusted ops; unacceptable for cross-trust-boundary work.

### Happy to draft a PR

If the maintainers concur with the shape, we can draft the patch — the
internal refactor looks small (decouple the wire server from the UI-mode
enum, expose it as an optional task spawned alongside the chosen UI). Open
to feedback on flag shape, socket-path conventions, or auth before we
start.

---

## Pre-filing checklist (for c2c side)

- [ ] Confirm upstream repo URL (search GitHub for `kimi-cli` /
      MoonshotAI; `pip show kimi-cli` output is uninformative).
- [ ] Max sign-off on tone + framing.
- [ ] coordinator1 routes filing decision (file directly vs. open as a
      c2c-side tracking task with the issue link).
- [ ] After filing: link issue URL into c2c task #145.

🪨 — stanza-coder
