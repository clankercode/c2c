# Main update: broker inbox race fix

- Reviewed the remaining tracked Python follow-up slice before commit.
- Found a real correctness issue in `c2c_send.py`: broker-only sends appended to `<session>.inbox.json` with an unlocked read/append/write sequence, so concurrent sends could drop messages.

## Fix

- Added broker inbox serialization in `c2c_send.py`:
  - per-inbox process-local thread lock
  - sidecar file lock (`.lock`) for cross-process exclusion
  - atomic replace when writing the updated inbox JSON
- Added a deterministic regression test that forces concurrent broker-only sends to the same inbox and verifies that all messages are preserved.

## Verification

- `python -m pytest tests/test_c2c_cli.py -k "concurrent_appends_preserve_all_messages" -q` -> `1 passed`
- `python -m pytest tests/test_c2c_cli.py -k "send_to_alias or broker_only_alias or broker_only_peer or c2c_send or sync_broker_registry or auto_drain_can_be_disabled_for_polling_clients"` -> `13 passed`
- `python -m py_compile c2c_send.py tests/test_c2c_cli.py` -> success

## Scope

- Touched:
  - `c2c_send.py`
  - `tests/test_c2c_cli.py`
- Left `c2c_poker.py` out of this slice; it is independent operational prompt text, not part of broker send/sync correctness.
