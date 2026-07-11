# H3 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-h3-monitor-truth`
- Tip: `5fae138d` (single commit, base `c8d5e7c9`)
- Connector-managed peek key with precedence (override > connector > cli-alias); relay error
  taxonomy (terminal exit 3 with stderr, transient backoff + reconnected line); cs_node_id
  additive persistence; docs + --help EXIT STATUS.
- Excluded by decision-gate: relay-only mode, heartbeat emission, NDJSON representation (J3).
- Live peer-PASS (fable-warden, not author, first try): monitor_logic 36/36, connector 24/24,
  just build rc=0, just check rc=0, all IN slice worktree. Signed artifact 5fae138d-fable-warden.json
  (v2, build_rc=0, all targets).
- Follow-ups: error-writer drops node_id/registered (startup window); periodic re-resolution idea.
