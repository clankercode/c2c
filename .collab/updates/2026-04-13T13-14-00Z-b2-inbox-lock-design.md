# Design: inbox-file lock to close enqueue/drain race

Proposing this as my next slice once codex's in-flight `c2c_mcp.py` /
`c2c_send.py` / `test_c2c_cli.py` patches land. Not yet implemented.
Posting here first so storm-echo can veto if they had something different in
mind, and so Max can see the scope before approving any commit.

## The race (both languages)

Current inbox ops in `ocaml/c2c_mcp.ml`:

```ocaml
let enqueue_message t ~from_alias ~to_alias ~content =
  (* ...resolve session_id... *)
  let current = load_inbox t ~session_id in        (* read *)
  let next = current @ [ { from_alias; to_alias; content } ] in
  save_inbox t ~session_id next                    (* write *)

let drain_inbox t ~session_id =
  let messages = read_inbox t ~session_id in       (* read *)
  save_inbox t ~session_id [];                     (* write *)
  messages
```

Neither takes any lock on the inbox file. Codex's Python broker fallback in
`c2c_send.py` has the identical shape:

```python
items = json.loads(inbox_path.read_text())
items.append({...})
inbox_path.write_text(json.dumps(items))
```

### Concrete race scenarios

1. **Lost enqueue (two senders, one recipient)**
   - A: `read` → `[m0]`
   - B: `read` → `[m0]`
   - A: `write` → `[m0, mA]`
   - B: `write` → `[m0, mB]` ← mA lost

2. **Lost drain (sender + receiver)**
   - Sender: `read` → `[m0]`
   - Receiver: `read` → `[m0]`, `write` → `[]`, returns `[m0]` ✓
   - Sender: `write` → `[m0, mS]` ← m0 re-appears → receiver double-reads on next poll

3. **OCaml broker + Python fallback cross-process race** — same shapes, same failure modes, no cross-process exclusion.

## Proposed fix

Add `with_inbox_lock t ~session_id f` mirroring `with_registry_lock`:

```ocaml
let inbox_lock_path t ~session_id =
  Filename.concat t.root (session_id ^ ".inbox.lock")

let with_inbox_lock t ~session_id f =
  ensure_root t;
  let fd = Unix.openfile (inbox_lock_path t ~session_id)
             [ O_RDWR; O_CREAT ] 0o644 in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
      (try Unix.close fd with _ -> ()))
    (fun () -> Unix.lockf fd Unix.F_LOCK 0; f ())
```

Then wrap each inbox mutator:

- `enqueue_message` — hold the lock across `load_inbox` + `save_inbox`.
- `drain_inbox` — hold the lock across read + write.
- `read_inbox` — leave unlocked (already a single-shot read; no interleaved write hazard from its own call).
- `Broker.sweep` — for each inbox it deletes, take the sidecar lock first, then `unlink` the inbox, then release+unlink the sidecar. Best-effort.

### Python side (codex's fallback)

`fcntl.lockf(fd, fcntl.LOCK_EX)` on `<sid>.inbox.lock`. POSIX fcntl-based locks
are compatible between OCaml `Unix.lockf` and Python `fcntl.lockf`, so the two
paths interlock cleanly across processes.

Suggested Python helper:

```python
import fcntl
from contextlib import contextmanager
@contextmanager
def inbox_lock(inbox_path):
    lock_path = inbox_path.with_suffix(".lock")
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX)
        yield
    finally:
        try: fcntl.lockf(fd, fcntl.LOCK_UN)
        except Exception: pass
        os.close(fd)
```

Wrapped around the existing `read_text` + append + `write_text` in
`enqueue_broker_message`.

## Tests to add (OCaml side)

1. Concurrent-enqueue fork test, 12 children, single recipient — count
   messages; must equal 12. (Mirror of the concurrent-register test that
   caught the registry-lock race.)
2. Interleaved drain + enqueue: one child drains in a loop for 200 ms while
   another enqueues 100 messages; total `drain+final_read` must be exactly 100
   with no duplicates.
3. sweep_preserves_inbox_under_lock: take the inbox lock from an external
   process, run sweep, verify sweep skipped that inbox (or blocked cleanly,
   depending on chosen semantics).

## Empirical confirmation (Python model of the race)

Wrote a standalone fork test (no dependency on the OCaml broker) that mirrors
the exact read-modify-write shape. 12 children each append 20 messages to a
shared JSON file → expected 240 messages per run.

### Without a lock

```
trial 0: expected=240, actual=3,   lost=237
trial 1: expected=240, actual=16,  lost=224
trial 2: json.decoder.JSONDecodeError: Extra data — partial-write corruption
```

Near-total message loss, plus JSON corruption on the third trial (a concurrent
`json.dump` clobbered a read mid-parse — this is exactly how the inbox would
become unreadable after a broker-side crash).

### With `fcntl.lockf(LOCK_EX)` wrapping read-modify-write

```
trial 0: expected=240, actual=240, lost=0
trial 1: expected=240, actual=240, lost=0
trial 2: expected=240, actual=240, lost=0
trial 3: expected=240, actual=240, lost=0
trial 4: expected=240, actual=240, lost=0
```

5/5 clean. All 240 messages arrive in every run. Confirms the proposed fix
is both necessary and sufficient.

The Python fork test is a deliberate **lower bound** — it's a pure-Python
repro and OCaml's `write_json_file` path may be slightly faster, narrowing
the race window. But the race class is the same, and the magnitude in
Python is already large enough (>90% loss) that it's obviously a real
production risk, not a theoretical one.

## Scope notes / what this does NOT do

- Does not make send→deliver atomic across the full session lifecycle —
  it only fixes the inbox-file read-modify-write window.
- Does not protect against `registry.json` races during enqueue (the
  alias→session_id resolution is still done before the inbox lock is
  acquired, so a session could in principle un-register between resolve and
  enqueue). That's an existing race we can patch separately; the inbox lock
  is still an improvement.
- Sidecar `.lock` files accumulate (same as `registry.json.lock` today). Not
  cleaned by sweep. Open to adding .lock cleanup to sweep if preferred.

## Dependencies / hold points

- Waiting on codex's in-flight slice (`c2c_mcp.py` / `c2c_send.py` /
  `test_c2c_cli.py`) to land first to avoid merge churn on the Python side.
- Waiting on Max's explicit approval before committing anything.
- Not starting implementation until storm-echo has a chance to veto or
  suggest a different scope.
