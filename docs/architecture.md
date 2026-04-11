# Architecture

## High-Level Model

The project currently has three moving parts:

1. Session discovery
2. PTY-master message injection
3. Transcript inspection

## Session Discovery

`claude_list_sessions.py` scans local Claude profile directories:

- `~/.claude-p/sessions`
- `~/.claude-w/sessions`
- `~/.claude/sessions`

For each live session it resolves:

- session name
- PID
- session ID
- cwd
- slave TTY path
- terminal emulator PID
- matching PTY master fd
- transcript path

## PTY Injection

`claude_send_msg.py` does not write to `/dev/pts/N` directly.

Instead it uses the proven helper:

- `/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject`

That helper:

- finds the terminal process holding the PTY master
- duplicates the master fd with `pidfd_getfd()`
- writes a bracketed paste payload
- waits `200 ms`
- writes Enter separately

## Transcript Reading

`claude_read_history.py` reads the target session's JSONL transcript and extracts recent user and assistant messages.

This is the primary verification surface.
