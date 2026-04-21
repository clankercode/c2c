#!/usr/bin/env bash
# Runs the OpenCode plugin test suite end-to-end from a fresh shell.
#
# Coverage:
#   1. vitest unit: event → DM → c2c reply → postSessionIdPermissionsPermissionId
#   2. python integration: real plugin under node, mock HTTP server, mock c2c CLI
#
# The v2 permission flow resolves the TUI dialog via the HTTP API because
# opencode does not dispatch to the declared "permission.ask" plugin hook.
# See .opencode/plugins/c2c.ts for the event handler.
#
# Exit 0 on success.

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

echo "=== [1/2] vitest (plugin unit, incl. permission.asked → HTTP resolve) ==="
( cd .opencode && ./node_modules/.bin/vitest run tests/c2c-plugin.unit.test.ts )

echo
echo "=== [2/2] pytest (plugin integration: real plugin under node + mock HTTP) ==="
pytest --force-test-env tests/test_c2c_opencode_plugin_integration.py -v

echo
echo "OK: OpenCode plugin v2 permission flow — unit + integration green."
