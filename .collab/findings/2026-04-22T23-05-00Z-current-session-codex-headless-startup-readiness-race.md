# Codex-headless startup readiness race in live tmux E2E

- Severity: medium
- Status: fixed

## Symptom

`tests/test_c2c_codex_headless_e2e.py::test_codex_headless_xml_delivery_persists_thread_id`
timed out waiting for `resume_session_id` to populate, even after the managed
Codex-headless launch path had been fixed to use named-pipe XML delivery and the
bridge could emit a valid `thread_id` handoff in manual repros.

Observed failure shape:

- broker inbox drained
- archive entry written
- recipient `thread-id-handoff.jsonl` stayed empty
- manual tmux repros succeeded if the first DM was sent slightly later

## How it was discovered

The managed transport was isolated in stages:

1. Writing a known-good XML `<message type="user">...</message>` directly into
   the live managed instance FIFO produced a `thread_id` immediately.
2. Writing a broker message directly into the live inbox file also produced a
   `thread_id`.
3. A manual tmux two-agent repro with a short fixed delay before the first DM
   also worked.

That narrowed the remaining failure to the test framework's readiness model,
not the Codex-headless delivery implementation.

## Root cause

`tests/e2e/framework/client_adapters.py` treated Codex-headless as "ready" as
soon as `config.json` existed and `inner.pid` was alive. That was too weak.

The live tmux test could send the first DM before all of the managed pieces had
settled:

- deliver daemon pidfile/live process
- bridge FIFO path
- thread-id handoff file
- a short post-launch stabilization window

The result was a startup race in the test harness, not a persistent delivery
failure in the product path.

## Fix

Tightened `CodexHeadlessAdapter.is_ready()` to require:

- live terminal backend
- `config.json`
- live `inner.pid`
- live `deliver.pid`
- existing `xml-input.fifo`
- existing `thread-id-handoff.jsonl`
- `meta.json.start_ts` at least 1 second old

Added/updated deterministic tests in:

- `tests/test_terminal_e2e_client_adapters.py`

Re-ran:

- framework tests
- live `codex-headless` tmux E2E
- live normal `codex` tmux E2E

## Notes

The named-pipe Codex-headless transport fix itself is real and necessary.
This findings log is specifically about the last false-negative after the
transport was already working.
