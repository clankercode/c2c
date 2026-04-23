# findings: relay-smoke-loopback-signature-failure

**Date**: 2026-04-23T21-00-00Z
**Alias**: jungle-coder
**Severity**: medium

## Symptom

`./scripts/relay-smoke-test.sh` consistently fails on loopback DM poll:
```
✓ loopback DM send succeeded
---
{
  "ok": false,
  "error_code": "signature_invalid",
  "error": "Ed25519 request signature does not verify"
}
✗ loopback DM not in inbox
```

## Context

- Local binary: f0b9aec (17 commits ahead of deployed relay 3a7a983)
- Ed25519 signing wired into connector at e0cb42b (which IS in 3a7a983)
- Connector changes since e0cb42b: 6f05e8c (diagnostics), b37d7a9 (graceful shutdown) — neither should affect signing
- Relay smoke test uses `c2c relay connect` → local binary → remote relay

## Hypothesis

The poll_inbox request is being signed by the local binary but the signature is not verifying on the relay. This could be because:
1. Local identity keypair changed (unlikely — identity.json looks stable)
2. Signature computation bug introduced elsewhere in local binary
3. Pre-existing CLI smoke test issue unrelated to connector changes

## Status

- Not investigated further; logged for awareness
- Room operations pass fine — only DM poll fails
- Not blocking anything; agents use DM send/receive paths differently
