# Registration Delay on --auto Restart

## Date: 2026-04-22
## Severity: medium

## Finding

When galaxy-coder was restarted via `c2c start opencode --agent galaxy-coder --auto` (or similar `--auto` path), the registration appeared in `c2c list` ~60 seconds later.

## Expected

Registration should appear immediately (<1s) after process startup.

## Possible Causes

1. The broker's registration write is delayed (async, buffered)
2. The list scan has caching with a TTL
3. The MCP server registration RPC is queued/delayed
4. The `alive` field computation scans sessions with a slow path

## Action

Investigate `c2c list` and `c2c_poll_inbox` timing. Check broker log for registration timestamp vs list appearance.

## Related

- `--auto` restart bug (item 47 in todo.txt) — kickoff not sent on auto-restart
