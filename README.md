# c2c-msg

Tools and documentation for Claude-to-Claude messaging experiments on a shared machine.

This project focuses on one concrete problem:

- discover live Claude sessions
- inject a message into a running session
- inspect recent session history
- avoid relying on Claude Teams as the transport

## Status

Validated:

- PTY-master injection into a normal running Claude session works on this machine.
- Session discovery works for the current local Claude profiles.
- The following commands exist and work:
  - `claude-list-sessions`
  - `claude-send-msg`
  - `claude-read-history`

Not validated as a finished product:

- stable autonomous 20-turn conversation between two top-level Claude sessions with no further steering

## Core Docs

- `docs/index.md`
- `docs/overview.md`
- `docs/architecture.md`
- `docs/pty-injection.md`
- `docs/commands.md`
- `docs/verification.md`
- `docs/research.md`
- `docs/known-issues.md`
- `docs/next-steps.md`

## Commands

- `./claude-list-sessions`
- `./claude-send-msg`
- `./claude-read-history`
- `./c2c-register <session>`
- `./c2c-list`
- `./c2c-send <alias> <message...>`
- `./c2c-verify`
- `./c2c-install`
- `./c2c-whoami [session]`

## Layout

- `claude_list_sessions.py`: discover running sessions and PTY metadata
- `claude_send_msg.py`: PTY-based message injection
- `claude_read_history.py`: transcript reader
- `c2c_registry.py`: opted-in alias registry stored as YAML
- `c2c_register.py`: opt-in registration and alias assignment
- `c2c_list.py`: listing for opted-in live sessions
- `c2c_send.py`: alias-based message sending
- `c2c_verify.py`: transcript-backed progress verification
- `c2c_install.py`: install `c2c-*` commands into `~/.local/bin`
- `c2c_whoami.py`: self-service identity and tutorial command
- `claude-list-sessions`: shell wrapper
- `claude-send-msg`: shell wrapper
- `claude-read-history`: shell wrapper
- `c2c-register`: shell wrapper
- `c2c-list`: shell wrapper
- `c2c-send`: shell wrapper
- `c2c-verify`: shell wrapper
- `c2c-install`: shell wrapper
- `c2c-whoami`: shell wrapper
- `docs/`: static-site-oriented docs

## Scope

This repo documents what was learned while experimenting on a specific Linux workstation with Ghostty, Claude Code, and the `meta-agent` PTY helper. Some findings are environment-specific.
