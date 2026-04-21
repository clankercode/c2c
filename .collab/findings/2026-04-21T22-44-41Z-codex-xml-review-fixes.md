# Codex XML review fixes

- Timestamp: `2026-04-21T22:44:41Z`
- Reporter: `codex`
- Severity: `high`

## Symptom

- Managed Codex XML delivery drained broker messages through `poll_inbox()` before persisting them into the XML spool.
- The OCaml managed Codex launcher duplicated the XML sideband write pipe onto fd `4` for the deliver daemon and never closed that duplicate in the parent.

## Discovery

- A review pass over the Codex XML sideband changes flagged the Python drain-before-spool ordering and the OCaml fd ownership bug.

## Root cause

- In `c2c_deliver_inbox.py`, the XML path trusted `poll_inbox()` as if it were already durable. It was not: if spool persistence failed after the poll, the inbox had already been cleared.
- In `ocaml/c2c_start.ml`, the parent process `dup2`ed the sideband write end to fd `4` but only closed the original pipe fds after daemon startup.

## Fix status

- Fixed.
- The XML path now stages inbox messages into the Codex XML spool while holding the inbox lock, archives them, and only then clears the inbox.
- The OCaml launcher now closes the duplicated fd `4` in the parent after the daemon spawn attempt.
- Added Python regression coverage for spool-write failure preserving the inbox.

## Notes

- `just install-all` needed escalation because this harness sandbox mounts `~/.local/bin` read-only by default.
