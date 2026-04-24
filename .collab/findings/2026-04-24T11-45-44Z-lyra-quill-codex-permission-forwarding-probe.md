# Codex permission forwarding probe

## Symptom

I could not get the live Codex probe to surface a forwarded permission request to `coordinator1`.

## What I tried

- Launched a managed Codex probe with `c2c start codex`.
- Pre-seeded a temporary role file for the probe alias.
- Sent a concrete permission-gated action into the live pane:
  - create `/tmp/codex-perm-probe.txt`
  - later also tried a direct shell-style `touch /tmp/codex-perm-probe.txt`
- Checked `c2c history` for any forwarded permission prompt.
- Checked the repo for Codex-specific permission-forwarding code.

## What I observed

- The probe windows did not stay alive long enough to give a clean, visible permission-forwarding signal.
- `c2c history` showed no new permission request routed to `coordinator1` from the Codex probe.
- The OCaml `c2c` side only shows generic `C2C_MCP_REPLY_TO` wiring for Codex startup, not a Codex-specific permission-forwarding hook.

## Likely interpretation

The live permission-forwarding path is either:

- not implemented for Codex yet, or
- still too fragile to reach the forwarding step from a normal managed probe.

I do not yet have a clean end-to-end repro that proves which of those is true.

## Status

Open. Needs a cleaner live repro path or an explicit Codex-side forwarding implementation.
