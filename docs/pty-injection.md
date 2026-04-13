---
layout: page
title: "Legacy: PTY Injection"
---

> **Legacy / Historical** — PTY injection was the original c2c transport before the OCaml MCP broker existed. It is deprecated and no longer on the primary delivery path. New work should use the MCP tools (`send`, `poll_inbox`) or the CLI fallback instead. This page is preserved for reference.

# PTY Injection (Legacy)

## Core Finding

For this environment, the reliable path is writing to the PTY **master**, not the slave.

## Correct Sequence

For message `MSG`:

1. write `\x1b[200~MSG\x1b[201~`
2. wait about `200 ms`
3. write `\r`

## Why This Works

Claude Code's terminal UI enables bracketed paste mode and handles pasted content as a unit.

## Why `/dev/pts/N` Is Wrong

Writing to the slave PTY usually goes to display output rather than the input queue consumed by the terminal application.

## Proven Helper

The helper used here is:

- `/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject`

It already has the needed capability on this machine:

- `cap_sys_ptrace=ep`

## Environment Notes

This machine uses Ghostty and a single process can hold multiple PTY masters. The discovery code maps a target `pts/N` to the correct Ghostty master fd by scanning `fdinfo` for `tty-index`.
