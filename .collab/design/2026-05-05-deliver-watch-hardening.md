# deliver-watch hardening design

**Author:** cedar-coder
**Created:** 2026-05-05
**Status:** draft
**Branch:** `.worktrees/deliver-watch-design/` (`design/deliver-watch-hardening`)

## Context

The deliver-inbox daemon (`c2c_deliver_inbox`) is the OCaml replacement for the
deprecated `c2c_deliver_inbox.py`. It is spawned as a sidecar by `c2c start` via
`start_deliver_daemon` in `c2c_start.ml` and runs independently of the managed
client lifecycle.

A sister command `c2c deliver --watch` (in `c2c_deliver_watch.ml`) provides a
simpler polling-based CLI subcommand for non-managed sessions.

This document catalogs the current state, identifies concrete gaps, and proposes
2-3 hardening slices to address them before the deliver-inbox path is promoted to
canonical for Codex/OpenCode/Claude.

---

## §1. Current architecture

```
c2c start [client]
  → c2c_start.start_deliver_daemon
      → forks + execs c2c-deliver-inbox --daemon (or --loop)
          ├── PTY path:     --pty-master-fd N  →  C2c_pty_inject.pty_deliver_loop_daemon
          ├── XML path:     --xml-output-fd N   →  C2c_pty_inject.xml_deliver_loop_daemon
          └── Kimi path:    --client kimi       →  C2c_kimi_notifier.run_once (polling)
          └── Generic path: (none of above)     →  drain + log only

c2c deliver --watch          [separate CLI subcommand, no daemonization]
  → C2c_mcp.Broker.drain_inbox → stdout / XML fd
```

**Files:**
- `ocaml/cli/c2c_deliver_inbox.ml` — standalone daemon executable (473 lines)
- `ocaml/cli/c2c_deliver_inbox.mli` — public interface (58 lines)
- `ocaml/cli/c2c_deliver_inbox_log.ml` — #562 JSONL audit logger
- `ocaml/cli/c2c_deliver_watch.ml` — `c2c deliver --watch` subcommand (136 lines)
- `ocaml/c2c_pty_inject.ml` — PTY + XML delivery loops (212 lines)

**Audit logging (#562):** `c2c_deliver_inbox_log` appends JSONL to
`<broker_root>/deliver-inbox.log`. Events: `deliver_inbox_drain`,
`deliver_inbox_kimi`, `deliver_inbox_no_session`.

---

## §2. Gap analysis

### G-1: Dead code at lines 246–250 (HIGH — code health)

```ocaml
       in
       loop ();
           Printf.printf "[c2c-deliver-inbox] loop finished after %d iterations, %d total delivered\n%!"
             !iterations !total_delivered;
           flush stdout)
```

`loop ()` never returns normally — it either recurses forever or hits `exit`
inside the match arm (`max_iterations` / `watched_pid` exit). The three
branches of the `run_loop` match (`pty_master_fd → Some`, `xml_output_fd →
Some`, fallback) all contain infinite-recursion loops with no normal return.
Therefore lines 248–250 are unreachable dead code.

The trailing `)` on line 250 closes the `else` branch of `run_loop`. Removing
lines 248–250 is a pure cleanup with no behavioral change.

**Fix:** Delete lines 248–250.

---

### G-2: `assert false` anti-pattern in `start_daemon` child (MEDIUM — latent bug)

Line 111 in `c2c_deliver_inbox.ml`:

```ocaml
      | 0 ->
        (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
        ...
        write_pidfile pidfile_path pid;
        (assert false : daemon_start_result)
```

The `assert false` is intended as a static proof that the child never returns
from `start_daemon` — it either `setsid()` fails (caught, exits via the outer
try/exit 127), or `setsid()` succeeds and then the child hits `assert false`
and **crashes**. The pidfile IS written before the assert (lines 109–110), so
the parent sees it — but the child has already crashed by the time the parent
checks.

If `setsid()` fails with `EPERM` (process is already a session leader — e.g.
already detached in a container), the child exits with code 127 without writing
the pidfile. The parent loops for up to `daemon_timeout` seconds then returns
`Failed "pidfile not written before timeout"`. This is a latent failure path that
would only manifest in environments where `setsid()` fails.

**Fix:** Replace the `assert false` with `exit 0` — the child succeeded, hand
off to the real daemon entry point.

---

### G-3: `event_fifo` and `response_fifo` are wired but never consumed (LOW)

The CLI parser accepts `--event-fifo` and `--response-fifo` (lines 307–310 of
`c2c_deliver_inbox.ml`), and `start_daemon` passes them via
`start_deliver_daemon` in `c2c_start.ml`. However, neither flag is read inside
`run_loop` — the daemon creates a broker and polls, but never opens or reads from
the event FIFO, and never writes to the response FIFO.

These flags appear to be scaffolding for a future permission-event delivery path
that hasn't been implemented. They should either be removed or the scaffolding
should be completed as part of a hardening slice.

**Fix (minimal):** Remove the dead CLI arguments and the dead `event_fifo` /
`response_fifo` fields from `cli_args`, and stop passing them from
`c2c_start.ml`. If the feature is needed later it can be re-added with a proper
implementation.

---

### G-4: `notify_only` has no effect (MEDIUM — broken feature)

`--notify-only` is documented as "peek only, inject poll_inbox nudge without
content" (line 299–300). However, `notify_only` appears in `cli_args` but is
never read anywhere in `run_loop`. The daemon always calls `drain_inbox` (which
removes messages from the broker), not a peek-only variant.

This means the flag is silently ignored — a caller expecting no-content nudge
delivery would get full message delivery instead.

**Fix (minimal):** Either implement the peek-only path using
`C2c_mcp.Broker.peek_inbox` (if it exists), or remove the flag. The simpler
fix is to remove the flag from the CLI and `cli_args` until the feature is
implemented.

---

### G-5: No retry on transient delivery failure (MEDIUM)

In `c2c_pty_inject.ml`, the PTY delivery loop (lines 84–98) wraps each
`pty_inject` in a try/exn that logs and continues — this is Race 3 fix (#623,
per-message error isolation). Good.

However, the XML delivery loop (`xml_deliver_loop_daemon`, lines 187–192) catches
exceptions on write but does not retry. A transient EPIPE (reader closed) or
EIO would drop the message silently after logging. There is no retry with
backoff, no dead-letter for permanently undeliverable messages.

**Fix:** Add a per-message retry loop (3 attempts, exponential backoff) in
`xml_deliver_loop_daemon`, and append permanently failed messages to a
dead-letter log alongside the broker's own dead-letter mechanism.

---

### G-6: No inotify-based delivery (group goal gap)

The group goal specifies "Deliver-watch: inotify-based inbox watcher
(`c2c-deliver-inbox`) for Codex/OpenCode/Kimi — delivers on file change, no
polling needed."

Current implementation is entirely polling-based (broker inbox file poll every N
seconds). Inotify would eliminate the poll interval latency and CPU cost.

This is a larger feature requiring:
1. inotify_init / inotify_add_watch on the broker inbox file
2. inotify event loop alongside or replacing the poll interval
3. Coalescing of rapid successive events (debounce)
4. Fallback to polling if inotify is unavailable (containers, NFS)

**Recommended approach:** Implement inotify as a new `--watch-mode inotify|polling`
flag on the existing daemon, default to polling for backward compatibility, and
add as a future hardening slice (S2 of this effort).

---

## §3. Proposed slices

### Slice H1: Dead code + broken flags cleanup (LOW RISK, 1 session)

Remove G-1 (dead lines 248–250), G-3 (dead event_fifo/response_fifo CLI args),
and G-4 (broken `--notify-only` flag).

**Files touched:**
- `c2c_deliver_inbox.ml`: delete dead code + dead CLI args
- `c2c_deliver_inbox.mli`: remove corresponding `event_fifo` / `response_fifo` fields
- `c2c_start.ml`: stop passing event_fifo_path / response_fifo_path to the daemon
- `c2c_deliver_inbox_log.ml`: add `deliver_inbox_skip` event type for when
  `notify_only` is used (documenting the planned behavior)

**Verification:**
- `dune build` clean
- `c2c_deliver_inbox --help` no longer shows `--event-fifo` / `--response-fifo`
- unit tests still pass (`test_c2c_deliver_inbox.exe`)

---

### Slice H2: Fix `assert false` anti-pattern + XML retry (MEDIUM RISK, 1–2 sessions)

Fix G-2 (replace `assert false` with `exit 0` in child) and G-5 (XML retry
loop with dead-letter).

**Files touched:**
- `c2c_deliver_inbox.ml`: fix start_daemon child path
- `c2c_pty_inject.ml`: add retry + dead-letter to `xml_deliver_loop_daemon`

**For the `assert false` fix:**
```ocaml
      | 0 ->
        (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
        ...
        write_pidfile pidfile_path pid;
        exit 0  (* was: assert false — child never returns from start_daemon *)
```

Actually, wait — `exit 0` would terminate the child after it has daemonized.
But the child IS the daemon at this point; the real daemon logic (`run_loop`) is
called from the `else` branch of the main `let () =` block. After `start_daemon`
returns in the parent, the main program continues and calls `run_loop`.

This reveals the real issue: `start_daemon` is called when `--daemon` is set,
and it forks the child. The parent returns the started PID. The child (after
`setsid`) should NOT call `exit` — it should fall through to the `run_loop`
call. But `assert false` prevents this.

The fix: remove `assert false` and let the child fall through to `run_loop`.
Since the child is now a session leader with its own process group, it is
detached from the parent's terminal. The pidfile write confirms liveness to the
parent before the parent returns.

**Verification:**
- daemon start/stop cycle works end-to-end
- `start_deliver_daemon` test passes
- XML retry verified by writing to a closed pipe (EPIPE observed, retried,
  finally dead-lettered)

---

### Slice H3: Inotify-based delivery (LARGER, 2–3 sessions)

Implement G-6: replace polling with inotify in `c2c_deliver_inbox` for the
generic (non-Kimi, non-XML) path.

**Key design decisions:**
- `--watch-mode polling|inotify` flag, default `polling` for backward compat
- On inotify INIT, add watch on the inbox file path (resolved from broker root +
  session_id + `.inbox.json`)
- On IN_MODIFY / IN_CLOSE_WRITE: drain immediately (no interval wait)
- On timeout with no events: fall back to interval polling
- On inotify init failure (container/NFS): silently fall back to polling
- Debounce: coalesce events arriving within `notify_debounce` seconds

**Files likely touched:**
- `c2c_deliver_inbox.ml`: add inotify event loop, new `--watch-mode` flag
- `c2c_deliver_inbox.mli`: update `cli_args`
- `c2c_deliver_inbox_log.ml`: add `deliver_inbox_inotify` event type
- possibly `c2c_pty_inject.ml`: could also use inotify for PTY if fd watched

---

## §4. Open questions

1. **Who owns `event_fifo` / `response_fifo`?** Were these for a specific
   permission-event path that was abandoned, or for a not-yet-implemented
   feature? Checking `c2c_start.ml` for the call site didn't reveal a
   not-implemented intent. Recommend removing unless a live owner confirms the
   feature is planned.

2. **`notify_only` future:** Should this be implemented (peek + nudge without
   drain) or removed? The use case is nudging a client to poll without
   delivering content. If no planned use case exists, remove it.

3. **Parallel delivery:** Currently messages are delivered sequentially. For
   high-throughput scenarios (many messages, multiple clients), a parallel map
   across messages would help. Low priority for now.

---

## §5. Related work

- `#482 S6 deliver-watch` (branch `slice/482-s6-deliver-watch`, 420 commits
  ahead of master): new `c2c deliver --watch` CLI, self-config for non-MCP
  clients, pre-deliver hook wiring. Not yet merged. When that merges, the
  hardening work here becomes simpler (the daemon vs CLI distinction is cleaner).
- `#562` (deliver-inbox JSONL logging): already merged.
- `#623` (Race 3 fix, per-message error isolation in PTY path): already merged.

---

*Last updated: 2026-05-05 by cedar-coder*
