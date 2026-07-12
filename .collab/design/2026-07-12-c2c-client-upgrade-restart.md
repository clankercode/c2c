# c2c client upgrade / restart-after-build — design synthesis

Status: design intake (for idea **I010** `c2c restart-clients-after-upgrade`).
Date: 2026-07-12. Author: Max-driven session (opus).

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
| **3. Supervisor-owned machinery** | outer-loop threads (schedule watcher, heartbeats, title ticker), `c2c-deliver-inbox`/poker sidecars, **codex app-server delivery loop**, **kimi notifier** | `restart-clients-after-upgrade`: version-aware, idle-gated, rolling. |

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

## Tier 3: `restart-clients-after-upgrade`

Version-aware, idle-gated, rolling session restart for supervisor-owned
machinery. Shared primitive with Tier 2: **version-aware skip** via the
`git_hash` / `executable_sha256` compare that already lives in
`server_info` / `runtime_identity` — skip instances already on the installed
SHA. Rolling (one at a time; coordinator last or skipped). Idle-gated
(don't interrupt an in-flight turn without `--force`). Reports
restarted / skipped / failed.

The genuinely hard case is default codex: delivery is the supervisor's
foreground thread, so upgrading it *requires* cycling the whole codex session
(TUI included). The clean long-term fix: **move the codex app-server delivery
loop out into a separate, disk-cursor'd sidecar process** (like
`c2c-deliver-inbox` already is). Then all delivery is a separate,
independently-restartable, ledger-backed process → drop-free upgrade without
disturbing the agent. This is the architectural precondition for "seamless"
on codex.

## Discovered bug (filed as B145)

**The kimi notifier survives restarts and runs stale code.** It is
`fork+setsid` detached, not tracked as a sidecar pid, and guards startup with
`already_running` dedup (`c2c_start.ml:5057`; `c2c_kimi_notifier.ml:561,567`).
So even a full `c2c restart` leaves the old notifier running; after
`just install-all` + restart, kimi delivery silently keeps executing the old
binary until the notifier is explicitly killed. This is an upgrade-correctness
gap independent of the broader feature. Fix direction: track the notifier pid
and kill+respawn it on restart, and/or give it the same self-detect-SHA-drift
graceful exit as Tier 2. (Needs a live repro to confirm before fixing.)

## Recommended increment order (de-risking)

1. **Version-aware skip primitive** — extract the SHA/`git_hash` compare into a
   reusable "is this running process stale vs installed binary?" helper.
   Building block for everything below.
2. **`restart-clients-after-upgrade` on today's full-restart** — enumerate
   managed instances (`c2c instances`), skip already-current, idle-gate,
   rolling, coordinator-last. Useful immediately even before any seamlessness.
   Optionally wire as an opt-in tail of `just install-all` / `just bi`.
3. **Fix the kimi-notifier stale-code bug** (its own bl bug) — track + cycle it.
4. **Tier-2 graceful-exit-reinvoke** for `c2c monitor` / `heartbeat`
   (self-detect + printed reinvoke). Cheap, standalone, high operator value.
5. **(Larger) refactor the codex app-server delivery loop into a sidecar** —
   the precondition for seamless codex upgrades. Do only if the disruption of
   full codex restarts proves painful in practice.

## Open questions

- Naming: `c2c restart-clients-after-upgrade` vs `c2c upgrade-restart` vs a
  flag on `c2c install`. Where does it live (subcommand vs just recipe)?
- Coordinator handling: skip by default (self-restart risk) or restart last?
- Should Tier 2 self-detect be always-on, or opt-in per monitor (some agents
  mid-task may not want their monitor to exit even for an upgrade)?
- `c2c-deliver-inbox` / poker auto-upgrade only on re-spawn — is a full
  session cycle acceptable for them, or do we want granular sidecar restart?
