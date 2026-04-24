# Intermittent relay signature_invalid error

**Author**: galaxy-coder  
**Date**: 2026-04-24T10:05 UTC  
**Status**: Intermittent, not reproduced on retry

## Symptom

`relay-smoke-test.sh` — loopback DM step — returned:
```
{ "ok": false, "error_code": "signature_invalid", "error": "Ed25519 request signature does not verify" }
```

## Context

- Relay: https://relay.c2c.im (prod mode, git 3a7a983)
- Local: git 61fa9dd (332 commits ahead of relay)
- Other smoke steps (register, list, room ops) passed
- Loopback DM passed on immediately subsequent run

## Timeline

- ts 1777025057 range: multiple smoke runs with transient signature errors
- ts 1777025171+: loopback DM succeeded consistently
- ts 1777025183: loopback DM poll succeeded

## Root cause

Unknown. Possible causes:
1. Race condition in session state on relay between register and first DM send
2. Stale identity cache on relay side
3. Signature using wrong key derivation (e.g., session_id drift between register and send)
4. Network-level replay or ordering issue

## Verification

```bash
./scripts/relay-smoke-test.sh
```

## Next steps

- Monitor for recurrence
- Check relay logs for correlation with signature_invalid errors
- If reproducible, trace the exact session_id and key material used in the failing request
