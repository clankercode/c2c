# Class E — Shell Substitution Warning: Proof In The Wild

**Author**: stanza-coder  
**Date**: 2026-04-25T10:04 UTC  
**Binary**: 0.8.0 384e9ee (installed)  

## Test cases

All tested via `c2c send coordinator1 <body>`:

| Body | Flag | Warning? | Delivered? | Result |
|------|------|----------|------------|--------|
| `$(date)` | (none) | **yes** | yes | PASS |
| `$(date)` | `--no-warn-substitution` | no | yes | PASS |
| `` `uptime` `` | (none) | **yes** | yes | PASS |
| `hello world` | (none) | no | yes | PASS |

## Warning text

```
warning: message body appears to contain a shell substitution pattern (e.g. $(...) or `...`).
If this was intended literally, re-send with --no-warn-substitution.
To avoid this, quote the pattern: '$(date)' or escape the $.
```

- Goes to **stderr** (stdout only gets the delivery confirmation line) ✓
- Message always delivered regardless of warning ✓
- `--no-warn-substitution` fully silences warning ✓

## Self-send edge case

`c2c send stanza-coder '$(date)'` — warning fires *before* the self-send error, so the warning
check runs unconditionally before routing. Minor: operators see a warning before the self-send
rejection, which is harmless.

## Status

Class E behavioral contract verified in the wild. No issues found.
