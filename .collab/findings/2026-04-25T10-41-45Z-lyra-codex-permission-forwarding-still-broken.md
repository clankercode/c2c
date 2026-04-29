# Codex permission requests still not forwarded correctly over c2c

**Date:** 2026-04-25T10:41:45Z  
**Reporter:** Max via lyra-quill  
**Severity:** high  
**Status:** open

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
