# Collaboration Protocol For `c2c-r2-b1`, `c2c-r2-b2`, And This Session

## Active Sessions

- `c2c-r2-b1` (`c78d64e9-1c7d-413f-8440-6ab33e0bf8fe`)
- `c2c-r2-b2` (`d16034fc-5526-414b-a88e-709d1a93e345`)
- this current coordinating session

## Purpose

Coordinate work to get `c2c` fully working for real live Claude sessions.

This is the current personal/session goal. The broader group goal is larger: make `c2c` into a polished multi-CLI, multi-agent, local-and-remote communication app with direct messaging and room/group semantics.

## Current Rule

Use the real `c2c` channel path when it works, but do not block on it. If direct Claude transcript-visible delivery is still failing, use repo-local files as the fallback collaboration path.

## Shared Files

- `tmp_status.txt`
  - current global status snapshot
- `tmp_collab_lock.md`
  - primary active lock/scope-split file already being used by the live Opus sessions
- `.collab/requests/`
  - supplemental request/task/question files
- `.collab/updates/`
  - supplemental session updates
- `.collab/findings/`
  - concrete technical findings, repro notes, logs, hypotheses

## File Naming

Use timestamped, session-prefixed names for easy ordering.

Examples:

- `.collab/requests/2026-04-13T12-00-00Z-b1-need-repro.md`
- `.collab/updates/2026-04-13T12-01-00Z-b2-verified-send.md`
- `.collab/findings/2026-04-13T12-02-00Z-main-channel-drain-note.md`

## Suggested Workflow

1. Read `tmp_status.txt` first.
2. Read `tmp_collab_lock.md` and respect its active locks and scope split.
3. Read the newest items in `.collab/requests/`, `.collab/updates/`, and `.collab/findings/`.
4. If taking work, update `tmp_collab_lock.md` first when files need a lock.
5. When done, write a findings/update file with exact evidence.
6. If you need another session to do something specific, write a request file rather than waiting on direct chat.

## Current Technical Focus

The main unresolved issue is still receiver-side transcript-visible delivery of `notifications/claude/channel` for local development channel servers.
