# c2c client upgrade / restart-after-build — design synthesis

Status: design intake (for idea **I010** `c2c restart-clients-after-upgrade`).
Date: 2026-07-12. Author: Max-driven session (opus).

## Decision update (2026-07-12)

The implementation target is the deliberately narrower **`c2c
restart-stale`**:

- rolling, best-effort restarts of managed instances whose running outer
  binary differs from the installed `c2c`;
- coordinator included by default, with `--exclude-coordinator` as an opt-out;
- `--dry-run` plus a complete restarted / skipped / failed report;
- Codex app-server is a required first-class path: resume the same Codex
  thread and prove inbox/ingress-ledger correctness with a real tmux-managed
  session;
- `just install` (an alias of `install-all`) prompts on an interactive TTY
  after a successful install; non-interactive installs never block or restart
  implicitly and instead print the explicit follow-up command.

This slice does **not** promise a seamless hot swap or generic cross-client
idle safety. Those require authoritative client turn state and, for truly
undisruptive Codex upgrades, a separable app-server delivery process. They are
preserved as a follow-up idea rather than hidden inside I010.

### Codex app-server prerequisite correction

The existing config-backed `c2c restart <name>` path does not cover app-server
sessions. `C2c_codex_session.run_app_server` writes `codex-session.json` and
`codex-app-server.json`, not the `config.json` / `outer.pid` consumed by
`cmd_instances` and `cmd_restart`; a batch process also cannot safely respawn
the TUI because it would inherit the batch process's terminal. Finally, the
thread discovered after startup is not reliably written back to the mapping,
so exact transcript resumption cannot yet be claimed. **B153** tracks the
required in-place launcher lifecycle seam and durable thread-ID persistence and
is a prerequisite of I010.

## Problem

After `just install-all` replaces the on-disk binaries, already-running c2c
machinery keeps executing the **old** code until restarted (the install
warning: "live process(es) hold binaries about to be replaced ... will not
auto-pick-up the new binary"). We want a one-step, ideally seamless, upgrade
of running managed instances. The operator focus is the **CLI-based** path
(works for all agents: codex/opencode/kimi/gemini/claude), not the MCP server.

## Key reframing (CLI-first makes this easier)

The MCP path has a persistent stdio JSON-RPC pipe between the harness and
`c2c-mcp-server` (`c2c_mcp_server_inner.ml:121-147`) — that pipe is what a
"wrapper + hot-swappable inner" (the unbuilt #311 inner/outer split Slices
B/C) would exist to hold open. **The CLI/file-based delivery path has no such
harness pipe.** Delivery there is inbox-file + inotify, the kimi notification
store, wake-injection into a tmux pane, or a reconnectable WebSocket to
`codex app-server`. So on the CLI path there is nothing pipe-shaped to
preserve across a restart — which removes the entire justification for the
wrapper tier. (The old codex `--xml-input-fd` sideband — a real injection pipe
into the codex fork — was removed upstream; `c2c_start.ml:4041`,
`c2c_pty_inject.ml:62`. It is not a concern.)

## Three tiers, by how a new binary reaches each

| Tier | Pieces | Upgrade path |
|---|---|---|
| **1. One-shots — free** | `c2c send/list/poll_inbox/deliver` | Fresh binary exec per invocation → auto-upgrade, nothing to do. |
| **2. Agent-launched monitors** | `c2c monitor`, `heartbeat` (run via the agent's Monitor tool) | **Graceful-exit-reinvoke** (below). Agent is the supervisor; it recreates. |
| **3. Supervisor-owned machinery** | outer-loop threads (schedule watcher, heartbeats, title ticker), `c2c-deliver-inbox`/poker sidecars, **codex app-server delivery loop**, **kimi notifier** | `restart-stale`: version-aware, rolling. |

## CLI-side process model (evidence from source, 2026-07-12)

Two supervisor flows; codex has two sub-modes.

- **`run_outer_loop` clients** (kimi / opencode / claude / gemini /
  codex-hook-fallback): `c2c start` forks (`c2c_start.ml:4880`); the child
  `execvpe`s the agent CLI in its own pgid (`:4888,4943`); the **parent**
  (outer) runs the sidecars/threads. The agent is a **child**; sidecars are
  **siblings** with tracked pids (`deliver.pid`, `poker.pid`) — killable
  **without touching the agent**. Killing the outer, though, SIGTERMs the
  inner pgid → kills the agent (`cleanup_and_exit`, `:4465-4478`).
- **Default codex (app-server mode)** does NOT use `run_outer_loop`
  (`c2c_codex_session.ml:506`, forced off only by `C2C_CODEX_FORCE_HOOKS=1`).
  The delivery brain (ingress + autoturn, `C2c_codex_deliver_loop.run`,
  `c2c_codex_deliver_loop.ml:63`) is the **supervisor's own foreground
  loop**, welded to the app-server + `--remote` TUI lifetime. There is **no
  way to restart delivery without tearing down the codex session.**

Per-piece:

| Piece | Kind | Disk state? | Restart-safe? | Auto-upgrades on re-exec? |
|---|---|---|---|---|
| one-shots (`send`/`list`/`poll_inbox`/`deliver`) | fresh exec/call | n/a | yes | **yes, every call** |
| `c2c-deliver-inbox` (codex wake sidecar) | sep proc (execvpe) | reads inbox; never drains (hook drains) | yes (worst case a re-nudge) | on re-spawn only |
| poker (python) | sep proc | none | yes (stateless) | on re-spawn only |
| codex ingress+autoturn loop | **in-proc foreground of `c2c codex`** | write-ahead ledger `<broker>/…/<session>.ledger.json` (`c2c_codex_ingress.ml:150,214`) | yes (reloads ledger, no double-deliver) — **but restart kills the TUI** | full session restart only |
| kimi notifier | sep proc, **detached setsid, untracked** (`c2c_start.ml:5057`) | drains → kimi notif store; dedup by deterministic id (`c2c_kimi_notifier.ml:80,205`) | mostly idempotent | **NO — survives restart, runs stale code** (see bug) |
| schedule watcher / heartbeats / title ticker | **threads in outer** | schedules read from `.c2c/schedules/*.toml` | yes (pure disk readers) | full session restart only |

Restart commands today: `c2c stop` (whole session down), `c2c restart`
(kills inner + `execve`s a fresh `c2c start` — upgrades outer+threads+re-execs
sidecars+agent), `c2c restart-self` (SIGTERM only the inner agent; outer
relaunches just the agent — does NOT upgrade the outer's own threads). There
is **no** "restart just the sidecar" command.

## Tier 2: graceful-exit-reinvoke (the agent-launched pattern)

For `c2c monitor` / `heartbeat`, the agent launched it via its Monitor tool
and sees its stdout in-transcript. On an upgrade-triggered exit the process
prints its own re-launch instructions and the agent recreates it — no wrapper,
no hot-swap.

- **Trigger — self-detect (primary):** the monitor loop periodically compares
  its own running-binary SHA against the on-disk binary. Machinery exists:
  `executable_sha256` / `git_hash` in `runtime_identity`
  (`c2c_mcp_helpers.ml:362-389`). Divergence → a newer version installed →
  graceful exit. Needs no external command; works after a bare `just install-all`.
- **Trigger — signal (secondary):** `restart-clients-after-upgrade` sends
  SIGTERM/SIGHUP for controlled, rolling, idle-gated restarts. Same handler.
- **On trigger — print, then `exit 0`:**

```
[c2c monitor] A newer c2c is installed (0.11.0 107a4f41 -> 0.12.0 abcd123).
[c2c monitor] Exiting so you pick up the new version. No messages were lost
              (inbox state is on disk; the fresh monitor resumes from there).
[c2c monitor] Please recreate your monitor — re-run exactly:

    c2c monitor --all --relay

[c2c monitor] (If launched via the Monitor tool, recreate that Monitor with the command above.)
```

- Reconstruct the command from `Sys.argv` (basename `c2c` + `argv[1:]`) so it
  is exact and copy-pasteable.
- `exit 0` (clean), not a crash — a `persistent:true` Monitor that auto-reruns
  the command then also Just Works (re-execs `c2c monitor` → fresh binary), and
  the printed instructions cover the non-persistent case.
- Print to stdout so the Monitor tool surfaces it into the transcript.

## Tier 3: `restart-stale`

Version-aware, rolling session restart for supervisor-owned machinery. Compare
the running outer executable against the installed CLI once per invocation,
skip instances already current, and restart stale instances sequentially.
Include the coordinator normally; `--exclude-coordinator` opts out. Generic
idle gating is explicitly excluded because c2c does not currently have an
authoritative, cross-client in-flight-turn signal. Report restarted / skipped /
failed without aborting the whole batch on one failure.

Do not assume `c2c --version` is sufficient: two different builds can report
the same release version, especially during local development. On Linux,
`/proc/<outer-pid>/exe` remains an open reference to the exact executable inode
the process started from even after the installed pathname is atomically
replaced (it commonly appears with a ` (deleted)` suffix). It can therefore be
read and hashed directly. Persist launcher PID/start-time and executable
device/inode at launch. If the live executable and installed path still have
the same device/inode, they are already the same image. If the inode differs,
hash the installed binary once and `/proc/<pid>/exe` once per distinct running
inode. This handles identical reinstalls and dirty-tree builds without putting
the existing ~690ms whole-binary hash on a periodic hot path. An unreadable or
unverifiable process identity is UNKNOWN and skips safely unless forced.

The genuinely hard case is default codex: delivery is the supervisor's
foreground thread, so upgrading it *requires* cycling the whole codex session
(TUI included). The clean long-term fix: **move the codex app-server delivery
loop out into a separate, disk-cursor'd sidecar process** (like
`c2c-deliver-inbox` already is). Then all delivery is a separate,
independently-restartable, ledger-backed process → drop-free upgrade without
disturbing the agent. This is the architectural precondition for "seamless"
on codex.

## Discovered bug (B145, fixed)

**The kimi notifier survives restarts and runs stale code.** It is
`fork+setsid` detached, not tracked as a sidecar pid, and guards startup with
`already_running` dedup (`c2c_start.ml:5057`; `c2c_kimi_notifier.ml:561,567`).
So even a full `c2c restart` leaves the old notifier running; after
`just install-all` + restart, kimi delivery silently keeps executing the old
binary until the notifier is explicitly killed. This is an upgrade-correctness
gap independent of the broader feature. B145 has since been fixed on master and
is not an I010 dependency.

## Recommended increment order (de-risking)

1. **Version-aware skip primitive** — extract the SHA/`git_hash` compare into a
   reusable "is this running process stale vs installed binary?" helper.
   Building block for everything below.
2. **B153 Codex app-server lifecycle seam** — persist launcher identity and the
   late-discovered thread ID; enumerate app-server units; add in-place
   self-reexec/control that retains the TTY and resumes the exact thread.
3. **`restart-stale` on today's full-restart** — enumerate managed instances,
   skip already-current, restart sequentially, and include coordinator unless
   explicitly excluded. Invoke each existing `c2c restart NAME` through a
   child process because `cmd_restart` ends by `execve`-ing into the relaunched
   supervisor and therefore cannot itself be called repeatedly in one process.
4. **Codex app-server live proof** — verify same-thread resume, model-visible
   pre/post-restart mail, ledger continuity, and no duplicate injection using
   `scripts/c2c_tmux.py` and a real managed Codex session.
5. **Interactive install prompt** — after successful `just install` /
   `install-all`, offer `c2c restart-stale` only when stdin and stderr are TTYs;
   otherwise print a non-blocking follow-up hint. Provide a documented opt-out
   for scripts that allocate a pseudo-TTY.

B145, the Kimi notifier stale-code bug discovered during this intake, is fixed
on current master and is not an I010 prerequisite. Tier-2 monitor self-exit,
authoritative idle gating, and a Codex delivery sidecar are deferred to the
follow-up idea.

## Remaining implementation questions

- Should version identity be a full executable digest only, or should builds
  also embed a cheap immutable build identifier for display and fast-path
  comparison? A release version string alone is insufficient for local builds.
- What environment variable should suppress the interactive install prompt for
  automation running under a pseudo-TTY?
- Should `restart-stale` skip the invoking instance by default, or schedule it
  last? This is distinct from the now-decided coordinator behavior.
