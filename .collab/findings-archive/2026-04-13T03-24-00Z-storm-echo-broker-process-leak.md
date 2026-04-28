# Broker-process leak: c2c_mcp_server.exe zombies across session starts

**Author:** storm-echo / c2c-r2-b1
**Date:** 2026-04-13

## Summary

23 `c2c_mcp_server.exe` processes were found alive simultaneously on the
development box. These are Python launcher → bash → dune → OCaml server
chains that did not terminate cleanly when their parent Claude session
exited. Oldest surviving chain was over 24 hours old and had been
reparented to init.

## Snapshot

Representative `ps -o pid,ppid,etime,cmd` entries at the time of discovery:

| PID      | PPID     | ELAPSED       | Notes                                  |
|----------|----------|---------------|----------------------------------------|
| 3303324  | 1        | 1-00:34:38    | dune exec, reparented to init (zombie) |
| 3171740  | 3171739  | 1-02:40:35    | server exe, oldest surviving           |
| 3303321  | 3303305  | 1-00:34:38    | paired with the reparented dune above  |
| 1107084  | 1107020  | 01:49:26      | recent, tied to an earlier claude run  |
| ...      | ...      | ...           | 11 broker instances total              |

Most entries appear as a `dune exec ./ocaml/server/c2c_mcp_server.exe --`
parent and a `c2c_mcp_server.exe` child, i.e. two processes per logical
broker instance.

## Probable root cause

`c2c_mcp.py` launches via:

```
bash -lc 'eval "$(opam env ...)" && dune exec --root ... ./ocaml/server/c2c_mcp_server.exe -- <args>'
```

That gives a chain: python launcher → bash -lc → dune exec → server
binary. When Claude closes its stdio MCP transport on session exit, the
server should see EOF on stdin and exit; the dune parent and bash parent
should cascade. In practice, at least one link in the chain doesn't
propagate cleanly, leaving the inner server running as an orphan until
its dune wrapper is reaped by init.

Specific hypotheses, ranked by likelihood:

1. `dune exec` forks the server in a process group that survives bash
   exit; nothing actively closes the server's stdin.
2. `bash -lc` loses its connection to the wrapping Python, the Python
   subprocess.run returns, and the grandchild server persists.
3. The OCaml server uses `Lwt_main.run (loop ...)` on raw stdin rather
   than a stream that watches stdin-EOF, so it never notices the upstream
   close.

## Impact

- Resource drift: 11 live broker instances eat RAM/FDs for nothing.
- Registry contention: every live broker is a potential writer against
  `.git/c2c/mcp/registry.json`. Without the new registry file lock
  (shipped today as part of the ocaml broker hardening commit but NOT
  yet running — Max has to restart the brokers first), concurrent
  registers can drop entries. This is the exact pattern that produced
  the two stale `storm-echo` entries cleaned up in this turn.
- Inbox contention: `enqueue_message` in the current binary has no
  per-inbox lock. Multiple brokers doing read-modify-write on the same
  `<session_id>.inbox.json` can silently drop messages.

## Suggested remediations

### Short-term (operator)
- Kill the orphaned broker processes manually once no live Claude is
  attached to them. Care needed: the live broker for each currently
  running Claude session must be preserved.
- Future-proof: identify the broker belonging to the current session
  via `C2C_MCP_SESSION_ID` env or `readlink /proc/<pid>/fd/0`.

### Medium-term (code)
- Run the server with a stdin watcher that triggers a clean shutdown on
  EOF. One line of Lwt:
  `Lwt_io.read_line Lwt_io.stdin >>= fun _ -> exit 0` as the outer select
  branch.
- Skip the bash + dune wrapper once `dune build` is part of a make/just
  target. Launch the built `.exe` directly from `c2c_mcp.py`, inheriting
  stdin/stdout unchanged. Fewer intermediate processes, cleaner cleanup.
- Have the server write its own pidfile on startup and remove it on
  clean exit so the Python launcher can detect leftover zombies.

### Long-term (design)
- Consider a single long-lived broker shared across sessions (one broker
  per repo, not one per claude session). The existing `registry.json`
  is already shared; moving to a shared broker process would remove all
  inter-broker contention by construction.

## Related

- `.collab/findings/2026-04-13T03-14-00Z-storm-echo-channel-bypass-dead-end.md`
  (separate blocker: push delivery path is blocked upstream)
- `tmp_collab_lock.md` history entries: the storm-echo alias clobbering
  pattern observed at 01:55Z is a direct consequence of the registry
  write race this leak enables.
- Commit `b6ef334`: ocaml broker hardening (liveness + registry lock +
  sweep + pid_start_time). Takes effect only when Max restarts brokers.
