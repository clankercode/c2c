# Test isolation: stale /tmp/c2c-mcp-* dirs interfering with test runs

## Symptom
During relay smoke test runs, sessions from prior test runs leave behind stale
`/tmp/c2c-mcp-<session-id>/` directories (broker root directories). When a new
test run starts and creates a fresh session, the broker may resolve to this stale
directory if `XDG_STATE_HOME` is unset and the filesystem fingerprint matches.

## Root Cause
The broker root resolution order is:
1. `C2C_MCP_BROKER_ROOT` env var (explicit override)
2. `$XDG_STATE_HOME/c2c/repos/<fp>/broker` (if `XDG_STATE_HOME` is set)
3. `$HOME/.c2c/repos/<fp>/broker` (canonical default)

If a prior test run set `XDG_STATE_HOME=/tmp/c2c-mcp-<nonce>`, that directory
persists after the test exits. A subsequent test run that also uses a `/tmp/`
path (or if `HOME` itself is `/tmp`-backed in the test environment) may
accidentally resolve to the stale directory.

The fingerprint (`<fp>`) is SHA-256 of `remote.origin.url`. Tests that share
the same git repo fingerprint will share broker roots.

## Severity
LOW — test-only issue. Production brokers are long-lived and use stable paths.
However, it can cause test bleed (cross-test pollution) that is hard to
diagnose.

## Fix Status
UNFIXED. Suggested fix: tests that create temporary broker roots should use
`C2C_MCP_BROKER_ROOT` set to a unique per-test path, and the test harness
should clean up that path after the test (or use `at_exit`/`Fun.protect`).
Alternatively, add a `c2c broker-cleanup` command that removes the stale dir.

## Discovery
Slate's mesh-test signing slice (3e376511) ran relay smoke tests that left
behind stale temp dirs. When birch reviewed the cherry-pick, the stale
directory was identified as the cause of some test isolation failures.

## Filed by
birch-coder, 2026-04-29
