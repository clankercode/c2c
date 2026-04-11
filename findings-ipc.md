# Claude Code live-session IPC / injection research (2026-04-11)

## Executive summary
There is **no documented general-purpose local IPC/socket/pipe API** for injecting a prompt into an already-running normal Claude Code terminal session. The two real built-in non-teams mechanisms I found are:

1. **Remote Control** — lets you send messages into the *same running local session* from claude.ai/code or the Claude mobile app.
2. **Channels** — lets an MCP server push external events/messages/webhooks directly into a *running local session*.

`--resume`, SDK `resume`, `continue`, `fork`, `--session-id`, and `claude mcp serve` are **not** live-session injection mechanisms. PTY/tmux input injection is a community workaround, not a Claude-built API, and is brittle.

---

## What exists

### 1) Remote Control: built-in session messaging into the same running session
**Status:** real, documented, built-in  
**Best for:** human remote steering from browser/phone  
**Confidence:** **high**

Anthropic docs explicitly say Remote Control connects claude.ai/code or the mobile app to a Claude Code session already running on your machine, and that:

- the conversation stays in sync across terminal/browser/phone
- you can send messages from those surfaces interchangeably
- `/remote-control` can be started from an existing session and carries over current conversation history
- the local process keeps running, with web/mobile acting as a window into that local session

Important implementation detail:
- docs say Remote Control uses **outbound HTTPS only** and **never opens inbound ports** on your machine
- so this is not a local socket/inbox API; it is an Anthropic-mediated remote bridge

Relevant docs also mention `--remote-control-session-name-prefix`, but that is only a **naming/discovery aid** for remote sessions, not an injection primitive.

**Evidence**
- Remote Control docs: “Work from both surfaces at once” and send messages from terminal/browser/phone interchangeably.
- CLI docs: `claude --remote-control`, `/remote-control`, and `--remote-control-session-name-prefix`.

**Limitations / caveats**
- Remote Control is tied to claude.ai/app auth and surfaces, not a general programmable local API.
- Multiple open bugs show that **interactive dialogs / AskUserQuestion / resume/history** are unreliable in Remote Control:
  - AskUserQuestion UI missing on mobile
  - AskUserQuestion answers submitted remotely not reaching CLI
  - remote resume/history persistence bugs

So: **yes for live messaging into the same session; no for a documented generic automation IPC API.**

### 2) Channels: built-in external event/message injection into a running session
**Status:** real, documented, built-in, preview  
**Best for:** machine-to-session push (webhooks, bots, alerts, CI, chat bridges)  
**Confidence:** **high**

Anthropic docs explicitly say Channels push messages/alerts/webhooks into an already-running Claude Code session from an MCP server.

Key points:
- channels are MCP servers that push `notifications/claude/channel` into a running session
- docs explicitly frame them as the answer for “push events into a running session”
- they are for Telegram/Discord/iMessage or your own custom channel server
- custom channels can be built locally and tested with `--dangerously-load-development-channels`
- the channel server communicates with Claude Code over **stdio MCP**, not a documented Claude-local socket

This is the strongest built-in answer to “can something external send a message into an already-running session?”

**But:** channels are not a full replacement for terminal-local interaction.
Open issues show that with `--channels` enabled, some interactive tools/modal flows are currently broken or suppressed:
- `AskUserQuestion` not available when channels are active
- plan-mode tools (`ExitPlanMode`, `AskUserQuestion`, `EnterPlanMode`) suppressed under `--channels`
- feature request open to extend channel relay to AskUserQuestion / plan approvals / dialogs
- feature request open for runtime `/channels pause` / `/channels resume`

So: **yes for external message injection into a live session; currently weaker for sessions that need blocking interactive UI.**

### 3) PTY / tmux / send-keys: viable workaround, but not built-in Claude IPC
**Status:** unofficial workaround  
**Best for:** local automation if you control the terminal multiplexer/PTY  
**Confidence:** **medium** for feasibility, **low** as a supported mechanism

I found multiple community reports treating `tmux send-keys`, `tmux paste-buffer -p`, or PTY automation as the practical workaround for driving a live Claude CLI session.

Evidence includes:
- older issue requesting programmatic control says current workaround is `tmux send-keys` + `capture-pane`
- external project issue says Claude must be spawned under a real PTY for interactive behavior; otherwise `isatty() == false` changes behavior
- tmux/TTY/bracketed-paste bugs show this path is real but fragile

This is **not** a Claude-built IPC API. It is terminal automation against the TUI.

**Why it is brittle**
- Claude uses bracketed paste / TUI raw-mode behavior
- multiple bugs exist around paste handling and tmux interaction
- one issue shows `tmux send-keys -l` breaking after Esc,Esc interruption of multiline input, while `tmux paste-buffer -p` still works
- bracketed paste mode cleanup/input handling bugs appear repeatedly across 2025-2026 issues

So PTY/tmux injection is possible, but not something I would call a built-in Claude IPC/session API.

---

## What does **not** count as live injection

### 4) `--resume`, `/resume`, SDK `resume`, `continue`, `fork`
**Status:** session persistence only  
**Confidence:** **high**

Docs clearly describe these as loading prior session history from disk and continuing it, usually from the most recent session or by a captured session ID.

This is **not** message injection into an already-running process.
Relevant evidence:
- SDK sessions docs define continue/resume/fork around persisted session history on disk
- `resume` requires session ID and same `cwd`/host assumptions
- issue #24947 explicitly states current problem: `claude --resume <id>` starts a **new process** rather than injecting into the currently running one

Conclusion: resume gives **historical continuity**, not **live inbox semantics**.

### 5) `--session-id`
**Status:** conversation identity selection, not injection  
**Confidence:** **medium-high**

CLI docs expose `--session-id`, but there is no documentation indicating it can target and inject into an already-running TUI session. It appears to control conversation identity for a started invocation, not attach/send into a live process.

### 6) `claude mcp serve`
**Status:** Claude Code as an MCP server exposing tools, not live-session messaging  
**Confidence:** **high**

Docs say `claude mcp serve` makes Claude Code act as an MCP server so other apps can use Claude Code tools. The docs describe it as exposing tools like View/Edit/LS/etc.

I found **no evidence** that `claude mcp serve` exposes an inbox into an already-running normal Claude terminal session, or that it attaches to one. It looks like a separate MCP-server mode, not session injection.

---

## Evidence of missing generic built-in IPC

Several issue reports explicitly describe the gap:
- **#24947** proposes `claude inject <session_id>` because there is no way to send a message to a running session from an external process; issue body suggests possible designs like Unix sockets, named pipes, or inbox files.
- **#27441** explicitly says there is currently **no API, socket, or pipe** to inject a prompt into a running Claude Code session.
- Older **#2929** requested programmatic driving of Claude instances and said current workaround is tmux keystroke automation.

Notably, search results indicate #24947 was closed as “completed”, and the body/highlights plus later cross-links strongly suggest that the practical resolution was **Channels**, not a generic `claude inject` local socket/pipe feature.

So the best current reading is:
- the original gap was real
- Anthropic added **Channels** (and separately **Remote Control**) as sanctioned ways to get information/messages into live sessions
- but I found no documentation for a raw local inject API such as `claude inject`, Unix socket inbox, named pipe, or stdin attach-to-running-session feature

---

## Focused answers to requested subtopics

### Session resume semantics
- `resume` / `continue` / SDK session resume are about **loading persisted transcript history**.
- They are **not** live-session message delivery into an already-running terminal process.

### Remote control session name prefix
- `--remote-control-session-name-prefix` only affects auto-generated **Remote Control session names**.
- It helps discovery/identification in remote UI, not IPC or injection.

### MCP serve
- `claude mcp serve` exposes Claude Code **as an MCP server**.
- No evidence it provides a live-session inbox or attach/send semantics for an already-running normal session.

### Socket / IPC behavior
- Remote Control docs explicitly say outbound HTTPS only, no inbound ports.
- Channels use MCP stdio notifications from a spawned server/plugin.
- I found **no documented local socket/named-pipe/file-inbox API** for arbitrary prompt injection.

### PTY input handling / bracketed paste
- Claude’s TUI clearly uses raw terminal input and bracketed paste behavior.
- There are multiple 2025-2026 bug reports around bracketed paste cleanup, paste corruption, external editor bracketed paste handling, and tmux send-keys breakage.
- This supports the claim that PTY/tmux injection is technically possible but fragile.

### Reports of injecting into live sessions
- **Official/supported:** Remote Control and Channels.
- **Unofficial:** tmux/PTy keystroke injection.
- **Missing:** documented generic local API (`socket`, `pipe`, `claude inject`, inbox file) for a normal local session.

---

## Bottom line

### Most promising non-teams mechanisms
1. **Channels** — best built-in machine-to-session injection mechanism for external systems.  
   **Confidence:** high.
2. **Remote Control** — best built-in human-to-session remote messaging mechanism into the same live local session.  
   **Confidence:** high.
3. **tmux / PTY automation** — workable hack if you own the terminal environment.  
   **Confidence:** medium for practice, low for supportability.

### What I do **not** believe exists
A documented built-in **general local IPC/session injection API** for normal Claude terminal sessions such as:
- `claude inject`
- attach to running session stdin by session id
- session inbox file / named pipe / Unix socket
- `mcp serve`-style attach to existing interactive session

**Confidence in that negative conclusion:** **medium-high** based on official docs plus multiple feature requests whose core complaint is exactly that this API is missing.

---

## Sources and references
1. Remote Control docs — https://docs.anthropic.com/en/docs/claude-code/remote-control
2. CLI reference — https://docs.anthropic.com/en/docs/claude-code/cli-reference
3. MCP docs — https://docs.anthropic.com/en/docs/claude-code/mcp
4. Channels docs — https://docs.anthropic.com/en/docs/claude-code/channels
5. Channels reference — https://docs.anthropic.com/en/docs/claude-code/channels-reference
6. Interactive mode docs — https://code.claude.com/docs/en/interactive-mode
7. SDK sessions docs — https://docs.anthropic.com/en/docs/claude-code/sdk/sdk-sessions
8. `claude inject` feature request — https://github.com/anthropics/claude-code/issues/24947
9. “No API, socket, or pipe” issue — https://github.com/anthropics/claude-code/issues/27441
10. Older programmatic-driving request / tmux workaround — https://github.com/anthropics/claude-code/issues/2929
11. AskUserQuestion missing with channels — https://github.com/anthropics/claude-code/issues/40644
12. Extend channel relay to AskUserQuestion / dialogs — https://github.com/anthropics/claude-code/issues/38498
13. `--channels` suppresses plan tools — https://github.com/anthropics/claude-code/issues/42292
14. Toggle channels on/off runtime request — https://github.com/anthropics/claude-code/issues/39677
15. Remote Control AskUserQuestion answer not received — https://github.com/anthropics/claude-code/issues/28508
16. Remote Control AskUserQuestion UI missing — https://github.com/anthropics/claude-code/issues/33625
17. tmux send-keys multiline interruption bug — https://github.com/anthropics/claude-code/issues/31739
18. Bracketed paste corruption — https://github.com/anthropics/claude-code/issues/3134
19. Bracketed paste on external editor launch — https://github.com/anthropics/claude-code/issues/24418
20. PTY-based external orchestration discussion — https://github.com/moltis-org/moltis/issues/235
