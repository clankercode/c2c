# Kimi / Crush local smoke after wake-daemon skeletons

## Trigger

storm-beacon landed Kimi/Crush PTY wake daemon skeletons in `dc81a80` and asked
for live testing where possible.

## Local Environment

- `kimi` is installed at `/home/xertrov/.local/bin/kimi`
- `crush` is installed at `/usr/bin/crush`

## Smoke Results

Commands run:

```bash
kimi --help
crush --help
python3 -m py_compile c2c_kimi_wake_daemon.py c2c_crush_wake_daemon.py
python3 c2c_kimi_wake_daemon.py --terminal-pid 1 --pts 0 \
  --session-id smoke-empty --broker-root /tmp/c2c-nonexistent-broker \
  --dry-run --once
python3 c2c_crush_wake_daemon.py --terminal-pid 1 --pts 0 \
  --session-id smoke-empty --broker-root /tmp/c2c-nonexistent-broker \
  --dry-run --once
```

Observed:

- Kimi CLI exposes `--mcp-config-file`, `--mcp-config`, `--print`, `--wire`,
  `--session`, and `--continue`.
- Crush CLI exposes interactive mode, `crush run`, `--session`, `--continue`,
  `--data-dir`, and server/session commands.
- Both wake daemon files compile.
- Both wake daemons dry-run cleanly against an empty/nonexistent inbox path with
  `--once`.

## What This Proves

- Local binaries exist, so future live tests do not need installation first.
- The daemon entry points are syntactically valid and accept their documented
  dry-run arguments.
- Kimi is especially promising for a future non-PTY path because the local CLI
  advertises Wire mode and MCP config injection.

## What This Does Not Prove

- No live Kimi/Crush TUI was started in this smoke.
- No PTY coordinates were resolved.
- No real PTY injection occurred.
- No broker-native message was delivered through Kimi or Crush yet.

## Next Test

Start one managed Kimi or Crush instance with a dedicated session/alias, send it
a broker-native DM, run the matching wake daemon with real PTY coordinates, and
verify the agent drains via `mcp__c2c__poll_inbox` and replies via
`mcp__c2c__send`.
