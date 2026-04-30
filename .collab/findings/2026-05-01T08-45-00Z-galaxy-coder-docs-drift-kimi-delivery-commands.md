# Finding: docs-drift — kimi delivery path documented as deprecated wire-bridge

**Date**: 2026-05-01
**Agent**: galaxy-coder
**Severity**: Medium (user-facing public docs show deprecated path)

## Drift #1: commands.md wire-bridge section shows deprecated path as canonical

**Location**: `docs/commands.md` lines 673-708

**Issue**: The `c2c-kimi-wire-bridge` section documents the wire-bridge Python
script (`c2c_kimi_wire_bridge.py`) as the canonical kimi delivery mechanism.
However, this path is **deprecated** per AGENTS.md (2026-04-29):
> "Kimi delivery — file-based notification-store (canonical, 2026-04-29).
> Kimi's wire-bridge path is DEPRECATED."

The replacement — `c2c-deliver-inbox --client kimi` — is **not documented at
all** in commands.md. The standalone binary `c2c-deliver-inbox` is installed
and functional (`~/.local/bin/c2c-deliver-inbox --client kimi --loop --daemon`).

**Evidence**:
```bash
$ c2c-deliver-inbox --help 2>&1 | grep client
  --client  client type (claude|codex|codex-headless|opencode|kimi|crush|generic)
```

The wire-bridge section (L673-708) shows:
```bash
c2c-kimi-wire-bridge --session-id kimi-user-host --once --json
```
But `c2c-kimi-wire-bridge` (Python wire-bridge / `kimi --wire`) is deprecated.
The new canonical invocation is:
```bash
c2c-deliver-inbox --session-id <alias> --client kimi --loop --daemon
```

## Drift #2: c2c wire-daemon OCaml subcommand overlaps deprecated wire-bridge

**Location**: `docs/commands.md` lines 725-738

**Issue**: The Wire Daemon Lifecycle section documents `c2c wire-daemon start/stop/status/list`
as OCaml subcommands for Kimi wire bridge daemon management. The OCaml `wire-daemon`
is real and correct (it's in `ocaml/cli/c2c.ml`), but the section framing says
"`c2c wire-daemon manages background Kimi Wire bridge daemon processes (`kimi --wire`)".
This overlaps with the deprecated `c2c-kimi-wire-bridge` section and doesn't mention
the newer notification-store approach.

## Drift #3: c2c-deliver-inbox binary not documented

The standalone `c2c-deliver-inbox` binary (public OCaml executable, installed at
`~/.local/bin/c2c-deliver-inbox`) is not documented anywhere in commands.md.
It is the canonical kimi delivery binary (S2/S3a of #482).

## Changes Needed

1. **commands.md L673-708**: Replace wire-bridge section (or add deprecation notice
   + pointer). New text should document `c2c-deliver-inbox --client kimi` as
   the canonical approach, with `c2c-kimi-wire-bridge` noted as deprecated.

2. **commands.md L725-738**: Update framing to clarify `wire-daemon` manages the
   OCaml wire bridge, while `c2c-deliver-inbox --client kimi` is the notification-store
   delivery path.

3. **commands.md**: Add a section or table entry for `c2c-deliver-inbox` as a
   standalone binary (not a `c2c` subcommand), documenting its key options:
   `--client kimi`, `--session-id`, `--broker-root`, `--loop`, `--daemon`.

## Scope estimate

- Wire-bridge section rewrite: ~30 min (read runbook, draft new text, review)
- wire-daemon section update: ~15 min
- deliver-inbox binary doc: ~15 min

Total: ~60 min, single slice.

## Status

- [ ] Fix commands.md wire-bridge section
- [ ] Update wire-daemon section framing
- [ ] Add c2c-deliver-inbox binary documentation
