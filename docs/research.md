---
layout: page
title: "Legacy: Research"
---

> **Legacy / Historical** — This page documents the early research phase that led to the PTY-injection approach. The project has since moved to a broker-native MCP architecture. This page is preserved as a record of what was ruled out and why. See [Overview](./overview.md) and [Architecture](./architecture.md) for current design.

# Research Summary (Legacy)

## What Was Ruled Out

- `claude --resume` as live injection into an already-running session
- direct writes to `/dev/pts/N`
- transcript/history mutation as a live transport
- Teams/mailboxes as the intended solution

## What Was Useful

- `meta-agent` PTY helper and design docs
- local Claude transcript files
- Claude Code source references around bracketed paste handling

## Main Research Files

- `../findings-pty.md`
- `../findings-ipc.md`
- `../findings-review.md`
- `../meta-agent-research.md`

## Summary Conclusion

There does not appear to be a documented general-purpose local Claude IPC API for injecting into a normal already-running session.

For this environment, PTY-master injection is the strongest validated non-Teams approach.

The strongest non-validated alternative path remains starting sessions in a transport-friendly mode such as `stream-json` and brokering messages from process launch time.
