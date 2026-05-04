# Remote Relay Transport

**Status**: v1 shipped; #702 (bare-alias relay fallback) also landed

## Goal
Enable a remote node to receive c2c messages through a relay server without requiring the local broker's file system.

## Key commits
- `8399a22f` (#702) — enqueue_message Unknown_alias fallback to relay outbox (bare alias resolution bug fixed)
- `25dc1b1` — Full e2e verified: fake broker → SSH poll → relay cache → GET /remote_inbox/<session_id> → message delivered
- `#330` mesh closed (2026-04-29)

## Open items
- relay.toml persistent config
- Multi-broker support (v2)
- Cross-host divergence test (#444) — backlog

## References
- `todo-ongoing.txt` entry: Remote relay transport
- Related: `.collab/findings/2026-05-04T08-45-00Z-jungle-coder-cross-host-alias-resolution-bug.md`
