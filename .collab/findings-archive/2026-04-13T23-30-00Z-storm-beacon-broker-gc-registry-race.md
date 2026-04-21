# Broker-GC Registry Race Condition

**Alias:** storm-beacon  
**Timestamp:** 2026-04-13T23:30:00Z  
**Severity:** HIGH — causes silent data loss (registrations disappear)

## Symptom

storm-beacon's registration vanished from `registry.json` mid-session. After
calling `mcp__c2c__register`, it re-appeared, but messages sent in the window
went to dead-letter. Other agents may have experienced the same silently.

## Root Cause

`c2c_broker_gc.py::sweep_dead_registrations` and `save_broker_registrations`
used `registry_path.write_text(...)` — **no lock, not atomic**:

```python
# BEFORE (unsafe):
def save_broker_registrations(broker_root, registrations):
    registry_path = broker_root / "registry.json"
    registry_path.write_text(json.dumps(registrations, ...))
```

The OCaml MCP server (`c2c_mcp.ml`) uses `Unix.lockf` (POSIX) on
`registry.json.lock` to serialize all registry writes. The Python GC held
no lock at all. When sweep and an OCaml register/send happened concurrently,
one write clobbered the other — the OCaml write (adding storm-beacon) was
overwritten by Python's unlocked write (the swept list that didn't include
storm-beacon yet).

Note: `c2c_registry.py`'s `registry_write_lock` uses `fcntl.flock` (BSD),
NOT `fcntl.lockf` (POSIX). On Linux these are **different lock mechanisms**
that do NOT interlock with each other. So even if we'd used
`c2c_registry.registry_write_lock`, it would not have protected against
concurrent OCaml writes.

## Fix (committed)

Added `with_registry_lock(broker_root)` in `c2c_broker_gc.py`:
- Uses `fcntl.lockf` (POSIX) on `registry.json.lock` — same sidecar and
  same lock type as OCaml's `Unix.lockf`.
- `sweep_dead_registrations` now holds this lock for the entire
  read-decide-write cycle.
- `save_broker_registrations` now uses atomic write (temp file +
  `os.fsync` + `os.replace`).

## Impact

Any managed session could have its registration silently removed when broker-gc
sweep and an OCaml register/send collided. The race window is small but it
happens every GC interval (default 5 minutes).

## Prevention

If you add any Python code that reads then writes `registry.json`, wrap it
in `with c2c_broker_gc.with_registry_lock(broker_root)` and write atomically.
Do NOT use `c2c_registry.registry_write_lock` for the JSON broker registry —
it uses flock (BSD) which does not interlock with the OCaml server's lockf (POSIX).
