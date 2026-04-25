# DRAFT: Generic `pty` / `tmux` client types

**Status:** draft / backlog
**Originator:** Max (2026-04-25)
**Coordinator:** coordinator1

## Motivation

We currently support 5 first-class clients (Claude Code, Codex, OpenCode,
Kimi, Crush) via dedicated launcher modules. Each new "supported" client
costs real maintenance (configurator, deliver-daemon glue, wake path, MCP
config). Some users (Max in particular) want to run c2c with Gemini CLI,
Cursor agent, or any other coding CLI **without** adding it as a
first-class client.

Goal: a generic delivery shim that uses **PTY injection** or **tmux
`send-keys`** to drive an arbitrary CLI as if it were a peer. Outgoing
c2c sends remain via the CLI (`c2c send …`) or, if the user wires it up,
MCP. Inbound delivery is the hard part — that's what this slice solves.

## Proposed CLI surface

```bash
# PTY-injection variant (driver opens a PTY, runs cmd inside, injects on inbox)
c2c start pty -- gemini --yolo --some-other-arg

# tmux-targeted variant (driver attaches to an existing tmux pane)
c2c start tmux --loc <tmux-SWP-address> -- cursor-agent --foo

# attach-only mode is valid: c2c registers + delivers to an existing pane
c2c start tmux --loc <tmux-SWP-address>

# helper to get the current pane's address
c2c get-tmux-location
# → e.g. "0:1.2"  (session:window.pane)  — exact format TBD
```

### Argument-passing convention

For **all** `c2c start <client>` invocations, anything after `--` is
passed verbatim as additional argv to the underlying exec. For supported
clients, this means extra flags onto the existing command. For `pty` /
`tmux` generic clients, the **first non-flag arg after `--` is the
command** to run, and the rest are its argv.

This is a small change to the existing `c2c start` parser — today it has
no `--` passthrough convention, so we should establish it consistently
across both supported and generic clients.

### `c2c get-tmux-location`

Prints an addressable string identifying the tmux pane the user runs it
in. Format: probably `<session>:<window>.<pane>` (matches `tmux
display-message -p '#S:#I.#P'`). This is the address to pass to
`c2c start tmux --loc <addr>`.

User flow:
1. User opens a tmux pane and starts their CLI manually (or just sits
   at a shell).
2. In another pane, they run `c2c get-tmux-location` from the target
   pane to print the address. Or have the start command print it.
3. They invoke `c2c start tmux --loc <addr> -- <their-cli> <args>` from
   wherever — c2c sends the optional startup command into the addressed
   pane. If no `-- <cmd>` is supplied, c2c attaches delivery to whatever
   is already running there. Inbound messages arrive via tmux paste /
   `send-keys` to that pane.

## Inbound delivery design

- **`pty` mode**: c2c forks a PTY pair, execs the user's command on the
  slave, drains the master, and writes inbound c2c messages to the
  master fd (with a brief delay + Enter, à la `pty_inject`). This is the
  same mechanism `claude_send_msg.py` uses for legacy PTY injection.
  Owns the lifecycle of the child process, like `c2c start <managed>`.
- **`tmux` mode**: c2c does NOT fork the user's CLI. It registers a
  session, validates the target with `tmux display-message`, and on each
  inbound message pastes the c2c XML envelope into the target pane and
  submits Enter. Lifecycle is decoupled from the user's CLI process:
  `c2c stop <name>` stops delivery/registration only and must not kill
  the process running in the tmux pane.

Both modes register an alias and run `c2c-deliver-inbox` in a delivery
mode appropriate to the transport.

## Outgoing

User handles outgoing themselves — either typing `c2c send <peer>
<msg>` in another shell, or wiring MCP into their CLI manually if it
supports it. We do not auto-wire MCP for these generic clients.

## Why this matters / north-star fit

- **Unblocks Gemini, Cursor, and the long tail of "small-share" CLIs**
  without committing us to maintain a configurator per CLI.
- **Reduces per-client maintenance cost** for genuinely-supported
  clients — the generic path is the fallback when a user just wants
  c2c to deliver inbound to their tool.
- **Decouples "run a CLI" from "deliver c2c messages to it"** — the
  tmux variant means the CLI process and the c2c delivery process can
  be lifecycle-managed independently. That's a healthier separation
  than today's "managed sessions" model where c2c owns the child.

## Open questions

1. **Submit delay / paste mode**: PTY injection has known reliability
   issues across CLIs (Kimi needed a longer submit delay; bracketed
   paste matters for some). Need a per-target tunable, probably with
   sensible defaults that work for "most" line-oriented REPLs.
2. **Tmux-mode authentication**: any tmux pane on the box that accepts
   `send-keys` is a target. We should validate that the user has
   permission for the target socket (default tmux socket per user is
   fine; other sockets require explicit `-S`).
3. **What happens if the target pane dies?**: tmux mode should detect
   pane gone and emit an alias drift warning.
4. **`c2c get-tmux-location` outside tmux**: should error clearly
   ("not in a tmux session — set $TMUX or run inside tmux").
5. **Does `c2c start pty` need the same poker / wake-daemon path as
   managed clients?**: probably yes — periodic poke to keep the CLI
   from idle-shutting-down.

### Slice 3 decisions

- **Attach-only mode is v1 behavior**: `c2c start tmux --loc <addr>` is
  valid with no `-- <cmd>`. This supports already-running CLIs and keeps
  c2c lifecycle-decoupled from the target process.
- **Optional startup command**: when `-- <cmd> ...` is provided, c2c
  sends the shell-quoted command to the target pane once, then runs the
  delivery loop.
- **Pane loss**: if the target can no longer be resolved by tmux, the
  delivery loop exits non-zero after printing a diagnostic. Existing
  inbox messages remain in the broker if paste/send fails.
- **Transport scope**: v1 uses tmux paste/send-keys only. It does not
  auto-wire outgoing MCP or inspect the target CLI process.

## Slicing suggestion

- **Slice 1**: `c2c start pty -- <cmd>`. Forks PTY, execs cmd, runs
  delivery daemon writing inbound to master fd. Simple end-to-end.
  Smoke test: `c2c start pty -- bash` and send it a message; verify it
  appears at the prompt.
- **Slice 2**: `c2c get-tmux-location`. Prints the SWP address from
  inside a tmux pane. Trivial wrapper around `tmux display-message`.
- **Slice 3**: `c2c start tmux --loc <addr> [-- <cmd>]`. Optionally
  sends the startup command into the addressed pane, then runs a
  lifecycle-decoupled delivery loop that pastes c2c envelopes into the
  pane for inbound messages. Smoke test with Gemini or a disposable
  shell pane.
- **Slice 4**: `--` passthrough convention for ALL `c2c start`
  variants. Documentation + tests that extra argv survives.

## References

- Existing PTY injection: `c2c_inject.py`, `claude_send_msg.py`
- Existing tmux scripts: `scripts/c2c_tmux.py`, `scripts/c2c-tmux-exec.sh`
- Submit delay tuning: see `c2c_kimi_wake_daemon.py --submit-delay`
- Current managed client launcher: `ocaml/cli/c2c_start.ml`
