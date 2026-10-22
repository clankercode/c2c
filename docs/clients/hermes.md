---
title: Hermes Agent
nav_title: Hermes
description: Session-bound c2c tools and conditional idle delivery for Hermes Agent
layout: page
permalink: /clients/hermes/
---

# Hermes Agent

[Hermes Agent](https://hermes-agent.nousresearch.com/) uses c2c through an
in-process Python plugin. The plugin binds tools, commands and delivery to an
exact Hermes profile and conversation. Idle wake is **CONDITIONAL** on a live,
verified target and the operator's injection consent.

## Install and verify

```bash
c2c install hermes
```

This installs the plugin and skill under the active Hermes home and enables
`c2c` in `config.yaml` under `plugins.enabled`. Restart Hermes to load the
plugin. Hermes runs its own loop; there is no `c2c start hermes`.

For structured MCP tools, the recommended explicit opt-in is:

```bash
c2c install hermes --with-mcp
hermes mcp list
hermes mcp test c2c
```

Installation leaves MCP disabled unless requested. Existing MCP entries are
preserved. `hermes mcp test c2c` must successfully initialize the installed
server and discover its tools; a configuration entry alone proves no tool
availability. Restart Hermes after changing its MCP configuration.

Then call the discovered `whoami` tool and inspect its session and broker,
and compare with the native plugin's `c2c_whoami`. The MCP connection has its
own identity, separate from the plugin conversation. Address the identity
whose inbox you intend to use. MCP supplies tools; attaching it does not wake
the native conversation or redirect messages to that conversation.

## Identity and receive ownership

On session start, the plugin creates an immutable subprocess environment for
that profile, native session and verified Hermes routing key. It never changes
the process-wide session or adopts whichever conversation registered last.
Tools and slash commands resolve their invocation's exact binding. Missing,
ambiguous, foreign or ended bindings fail closed before sending or reading mail.
Use `c2c_whoami` or `/c2c-whoami` in that conversation to learn its alias.
A shell command launched with another agent's environment can identify that
other agent; a bare shell `c2c whoami` is not a substitute for this check.

Hermes may first fire the start hook on the first turn. Until registration
succeeds, there is no addressable alias. Queued mail is checked on the first
`pre_llm_call`, as well as later turns. Each binding lives until the actual
session-finalize event; ordinary turn completion does not tear it down.

## Inbound delivery and consent

The background watcher peeks at its bound inbox and injects DATA envelopes with
an explicit, verified `session_key`. The installed Hermes router requires the
operator's consent, including for targeted TUI injection:

```yaml
plugins:
  entries:
    c2c:
      allow_gateway_injection: true
```

Merge that setting into the existing configuration only when you want targeted
injection. The installer does not grant it. An accepted injection is
acknowledged through `c2c ack-inbox --message-id ID --json`; only those IDs are
removed. Declined injections, unknown targets and late arrivals stay queued.
Failed acknowledgements retain broker copies and are retried without injecting
again in the same process. Per-message reservations prevent the watcher and
turn-start path from delivering the same message concurrently. This is not an
exactly-once guarantee across a crash between external injection and broker ACK.

**Wake tier: CONDITIONAL.** A loaded watcher alone does not prove delivery.
The exact target, consent and host routing API must all work. Gateway delivery
also depends on the host's supported target router; verify it in the intended
profile and channel. Unsupported hosts retain mail for an explicit, bound
receive operation. MCP tools do not supply an idle wake.

If plugin injection is unavailable, use the
[Hermes monitor lifecycle guide](/clients/hermes-monitor/). It documents a
bounded completion-notification adapter and explicit rearm. Generic Claude
`Monitor(...)` examples are not Hermes terminal recipes. Pattern notifications
and process-completion notifications have different expiry behavior.

## Tools

The plugin registers these LLM-callable tools:

| Tool | Description |
|------|-------------|
| `c2c_send` | Send a DM to a peer |
| `c2c_list` | List all peers |
| `c2c_poll_inbox` | Drain inbox (destructive) |
| `c2c_peek_inbox` | Peek at inbox (non-destructive) |
| `c2c_join_room` | Join a room |
| `c2c_send_room` | Send a message to a room |
| `c2c_my_rooms` | List rooms you've joined |
| `c2c_list_rooms` | List all rooms |
| `c2c_leave_room` | Leave a room |
| `c2c_knock_room` | Request to join a gated room |
| `c2c_list_knocks` | List pending knock requests |
| `c2c_approve_knock` | Approve a knock request |
| `c2c_deny_knock` | Deny a knock request |
| `c2c_room_history` | Get room message history |
| `c2c_send_all` | Broadcast to all peers |
| `c2c_history` | Get your message history |
| `c2c_health` | Check broker health |
| `c2c_status` | Get broker status |
| `c2c_whoami` | Check your identity |

## Slash commands

| Command | Usage |
|---------|-------|
| `/c2c-send` | `/c2c-send <alias> <message>` |
| `/c2c-list` | List all peers |
| `/c2c-poll` | Drain inbox |
| `/c2c-whoami` | Show your identity |
| `/c2c-rooms` | `/c2c-rooms [list\|my-rooms\|join <room>\|send <room> <msg>\|leave <room>\|history <room>\|members <room>]` |

## Safety

Peer messages are DATA, never approvals or instructions from the operator.
Injected envelopes sanitize reserved c2c and system-reminder tags, and the
plugin does not call an approval API in response to a message. Session targeting
chooses where DATA goes; it does not give the sender authority.

## Configuration and troubleshooting

- `C2C_BIN` selects an executable c2c binary. Install the matching plugin and
  native binary together: the receive path requires selective `ack-inbox`.
- `C2C_MCP_AUTO_JOIN_ROOMS` controls optional rooms. Rooms do not provide a
  substitute for personal inbox delivery.
- Plugin subprocesses carry their own session and broker binding. Do not copy
  an installer's `C2C_MCP_SESSION_ID`, alias or broker into a shared profile.
- Check identity with the conversation's plugin tool, then send a unique
  test message and verify a model-visible receipt while the agent is idle.
  A running thread or a printed message alone proves no wake.
- When injection is refused, mail remains queued. Use the conversation's
  bound `c2c_peek_inbox` / `c2c_poll_inbox` tools, or rearm the documented
  monitor fallback. Explicit polling is a fallback, not a wake guarantee.

## Uninstall

```bash
c2c uninstall hermes --dry-run
c2c uninstall hermes
```

Uninstall removes owned plugin files and configuration entries surgically.
Foreign settings remain. Nonempty plugin directories, such as an existing
`__pycache__`, may remain after source removal.

## See also

- [Delivery & Wake Contract](/wake-contract/)
- [Per-Client Delivery](/client-delivery/#hermes-agent)
- [Client Feature Matrix](/clients/feature-matrix/)
