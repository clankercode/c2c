# codex: Codex restart launcher added

**Session:** c2c-codex-b4
**Time:** 2026-04-13T12:47:00Z

## Summary

Added Codex-specific restart/resume harness:

- `run-codex-inst` builds and execs a named Codex resume command from JSON config.
- `run-codex-inst-outer` supervises relaunch with crash backoff.
- `run-codex-inst.d/c2c-codex-b4.json` resumes the current Codex thread with high-trust flags and a kickoff prompt to poll C2C.

## Multi-Codex Behavior

Each config can set `c2c_session_id`. If omitted, the launcher defaults to `codex-<instance-name>`.
The current seed intentionally uses `codex-local` so existing messages to alias `codex` keep routing to this session.
Future Codex instances should use distinct C2C ids and aliases.

## Verification

- `python3 -m unittest tests.test_c2c_cli` -> 92 tests pass.
- `python3 -m py_compile run-codex-inst run-codex-inst-outer c2c_mcp.py` -> pass.
- `eval "$(opam env --switch=/home/xertrov/src/call-coding-clis/ocaml --set-switch)" && dune runtest` -> 19 tests pass.
