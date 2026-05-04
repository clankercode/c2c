# cedar-coder: cannot-send-to-yourself race — CLOSED (not reproducible)

**Finding**: `cedar-coder cannot-send-to-yourself-race` (2026-05-03)
**Severity**: MEDIUM
**Status**: CLOSED — not reproducible

## Investigation (2026-05-04, mm27-general)

### Root Cause Analysis

The finding described a "broker respawn race in CLI guard at `c2c.ml:409`" that could allow
a user to send a message to themselves.

**CLI guard** (c2c.ml:409):
```ocaml
if from_alias = to_alias then (
  Printf.eprintf "error: cannot send a message to yourself (%s)\n%!" from_alias;
  exit 1
);
```

**Broker handler protection** (c2c_send_handlers.ml + test_send_self_rejected):
The broker handler also rejects self-sends with "cannot send a message to yourself",
verified by `test_send_self_rejected` in `test_c2c_send_handlers.ml`.

### Why No Race Exists

1. **`from_alias` resolution is env-var based, not registry-based.**
   `resolve_alias` (c2c.ml:105) uses `C2C_MCP_SESSION_ID` → registry lookup for the
   CALLER's own alias. This is stable within a process lifetime.

2. **`to_alias` is a literal string from the command line.** It cannot change between
   the guard check and `enqueue_message` within the same process.

3. **No broker state is consulted between the guard and enqueue.** The only registry
   reads in the send path happen BEFORE the guard (to resolve `from_alias`) and AFTER
   the guard (inside `enqueue_message`). A broker respawn between these would not
   affect either resolution.

4. **The only scenario where the guard could be bypassed is `--from` impersonation,**
   but that requires the caller to already know another valid alias — it's an
   authorization issue, not a self-send race. The handler-level check would still
   catch it if `from_alias` resolves to the same as `to_alias`.

### Conclusion

The self-send guard is not subject to a broker respawn race. Protection exists at
two independent levels (CLI + broker handler). No fix required.

### References

- CLI guard: `ocaml/cli/c2c.ml:409`
- Broker handler: `ocaml/c2c_send_handlers.ml` (self-send rejection)
- Test: `test_c2c_send_handlers.ml:test_send_self_rejected`
