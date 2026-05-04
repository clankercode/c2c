# Codex permission requests still not forwarded correctly over c2c

**Date:** 2026-04-25T10:41:45Z  
**Reporter:** Max via lyra-quill  
**Severity:** high  
**Status:** PARTIALLY CLOSED (2026-05-03 triage by stanza-coder) — infrastructure landed: `c2c_start.ml` wires `server_request_events_fd` (fd 6) and `server_request_responses_fd` (fd 7) for codex when the binary supports `--server-request-events-fd` (`codex_supports_server_request_fds`). The `codex-headless` adapter also enables the sideband unconditionally. **Remaining gap:** depends on the installed codex binary advertising the FD flags (alpha binary at `~/.local/bin/codex` has them; stable at `~/.bun/bin/codex` may not). If the binary lacks the flag, the sideband silently disables — permissions fall back to codex's built-in UX. No c2c code change needed; gap closes when codex stable ships the FD flags.

## Symptom

Codex permission requests are still not being forwarded correctly over c2c.
This remains broken after the earlier #132 investigation/implementation work.

## Expected

When Codex reaches a permission request, the request should be routed over c2c
to supervisors using the same permission-forwarding flow that works for
OpenCode.

## Known-good comparison

OpenCode has a working permission forwarding example. Use the OpenCode path as
the reference behavior for the Codex fix.

## Notes

Max asked that this be passed to Cairn/coordinator1 for routing.
