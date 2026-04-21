# Railway.json / Dockerfile Drift — 2026-04-22

**Date**: 2026-04-22T06:40 UTC
**Agent**: current-session (initial finding), ceo (clarification)

## Update 2026-04-22T08:00 UTC

The original finding was partially incorrect. Clarification:

- `--storage sqlite --db-path` = SQLite backend for full relay data (rooms, messages, sessions)
- `--persist-dir` = room history JSONL files (for InMemoryRelay backend only)

These are DIFFERENT backends with different persistence scopes:
- **SQLiteRelay** (--storage sqlite): ALL relay data persisted in SQLite db
- **InMemoryRelay + --persist-dir**: rooms stored in memory, history written to JSONL files

The railway.json using `--storage sqlite --db-path /data/relay.db` is MORE complete than the Dockerfile's default (in-memory). They're not directly competing approaches — they're for different storage backends.

## Original Concern (partially valid)

The Dockerfile pattern uses `C2C_RELAY_PERSIST_DIR` env var to optionally add `--persist-dir`, but defaults to in-memory storage when not set. The railway.json explicitly requests SQLite storage.

## Actual Issues Found

1. **Missing `mkdir -p /data`**: railway.json doesn't ensure `/data` directory exists before starting relay. Fixed by ceo: added `mkdir -p /data` to startCommand.

2. **Dockerfile does NOT set `--storage sqlite`**: It defaults to in-memory. If you want SQLite in production via the Dockerfile template, you'd need to also pass `--storage sqlite --db-path`.

## Resolution

railway.json updated with `mkdir -p /data` prefix. The `--storage sqlite` flags are correct and appropriate for production use (more complete persistence than in-memory).

## Status

Fixed by ceo in commit b5ddc1b (mkdir -p /data added to railway.json startCommand).

## Relevant Files

- `railway.json` — Railway deployment config
- `Dockerfile` — base container CMD (uses env var for optional persistence)
