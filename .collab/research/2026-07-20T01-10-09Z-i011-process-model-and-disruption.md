# I011 current managed-client ownership and restart-disruption audit

Date: 2026-07-20. Task: `P2.M2.E1.T001`. Source under audit: `e5129b20d7a58ef0f6dce569f61549bb1bf3d661` (the task-claim-only commit on top of the current implementation).

## Verdict

The current managed set for this audit is **Claude, OpenCode, Kimi, agy, Codex hook fallback, and Codex app-server**. Gemini is no longer in the managed set and is excluded. Managed Grok remains deferred and is excluded.

There are two materially different owners:

1. `run_outer_loop` owns the Claude, OpenCode, Kimi, agy, and emergency Codex-hook units. It owns the inner CLI process group plus any outer sidecars/threads. Generic `c2c restart` kills the inner group, waits for the outer to exit, and execs the replacement on the **caller's** TTY (`ocaml/c2c_start.ml:6403-6480`).
2. The default Codex app-server launcher is itself the owner and delivery loop. It owns a setsid app-server group and a TTY-attached frontend, accepts a restart request through disk owner-control, and self-execs in its original pane on the exact thread (`ocaml/cli/c2c_managed_cmd.ml:931-962`, `ocaml/c2c_codex_session.ml:1251-1291,1582-1600`).

This distinction is load-bearing. A peer message must never initiate either restart: c2c mail is DATA under B098. Restart authority belongs to a local operator/installer/owner-control request, with the app-server's active-turn gate retained.

## Method and harness controls

- Discovery started with the codebase-memory graph (`search_graph` and inbound/outbound traces for `run_outer_loop`, `start_deliver_daemon`, `start_poker`, and `run_app_server`) before source reads.
- The exact worktree executables were built with `scripts/dune-build-locked.sh build ./ocaml/cli/c2c.exe ./ocaml/cli/c2c_deliver_inbox.exe`. The audited `c2c.exe` SHA-256 was `fda88f9fccc65d0a67b8e207977ef9c3a2458a85b154c7611a4f10ac95182c01`.
- Every managed launch, pane input, capture, and stop used `scripts/c2c_tmux.py`. No client was launched directly from a bash tool and `sweep` was never called.
- `c2c_tmux.py list` initially raised `CalledProcessError` because `_iter_panes` calls `tmux list-panes -a` with `check=True` when no tmux server exists (`scripts/c2c_tmux.py:75-82,97-105`). A detached shell-only tmux control session established the canonical harness; `list` then returned `(no live swarm panes)`. This is a real helper preflight defect, recorded here rather than widened into a script change.
- An initial pass exposed that a pre-existing control shell resolved `/home/xertrov/.local/bin/c2c` (`360f67e8`) during restart. Those disruption results were discarded. Counted TUI receipts explicitly set `C2C_CLI_COMMAND` and PATH to the exact worktree executable; the replacement log confirms the worktree path. The app-server owner also self-execed that exact executable.
- Host clients: Claude 2.1.215, OpenCode 1.18.3, Kimi 0.27.0, agy 1.1.4, Codex 0.144.6.

Times below are wall-clock receipt windows, not synthetic benchmarks. They include harness/capture overhead where stated.

## Current ownership table

| Mode | Durable owner and inner process | Delivery/sidecar ownership | Stop/restart boundary |
|---|---|---|---|
| Claude | `c2c start` outer; Claude is a child in its own process group | No outer delivery PID. Delivery is Claude's in-process development channel when available, otherwise ephemeral activity hooks (`needs_deliver=false`; `ocaml/c2c_start.ml:1555-1563,4258-4261`). | Generic restart kills the whole Claude group and old outer. Exact session id is resumed, but replacement attaches to the caller pane. |
| OpenCode | `c2c start` outer; OpenCode and its descendants share the inner process group | Plugin is in the OpenCode process. It owns a `c2c monitor` child and `oc-plugin stream-write-statefile` child, restarts monitor after 5 s, and kills it on process exit (`data/opencode-plugin/c2c.ts:748-779,1606-1649`). The outer owns only a fallback thread after the grace period (`ocaml/c2c_start.ml:5489-5538`); no `deliver.pid`. | Generic restart kills OpenCode **and** both plugin children as one group. Current resume metadata makes the replacement fail before a new owner starts; measured below. |
| Kimi | `c2c start` outer; Kimi is the inner process group | Kimi notifier is a detached setsid daemon polling every 2 s. The outer now captures it in `notifier.pid`, and also owns a 600 s poker PID (`ocaml/c2c_start.ml:1576-1584,5606-5625`; `ocaml/c2c_kimi_notifier.mli:22-43`). However `c2c hook kimi` is a second notifier arm owner (`ocaml/cli/c2c_hook_cmd.ml:1733-1769`). | Outer cleanup stops tracked notifier/poker, but a hook arm racing after outer teardown can escape after its pidfile is removed. Two such orphans were observed below. |
| agy | `c2c start` outer; agy is the inner process group | A tracked `c2c-deliver-inbox --client agy` sibling watches the inner PID (`needs_deliver=true`; `ocaml/c2c_start.ml:1604-1607,4366-4415,5462-5488`). It reads `agy-env.json` and runs bounded `agy agentapi send-message` one-shots (15 s plus 2 s escalation; `ocaml/cli/c2c_agy_deliver.ml:42-97,149-180`). | Generic restart kills the inner and cycles the tracked deliver sidecar. Current launch dispatch omits `AgyAdapter`, so conversation continuity is not actually selected. |
| Codex hooks (emergency fallback) | `run_outer_loop`; Codex is the inner process group | Tracked `deliver.pid` is a wake watcher; hooks drain. It never owns app-server delivery. Default managed Codex does not use this path; it requires hidden `C2C_CODEX_FORCE_HOOKS=1` (`ocaml/c2c_codex_session.ml:1680-1697`). | Generic restart hard-interrupts the turn and cycles watcher plus outer. Current hook identity did not adopt the managed instance, leaving an unusable resume target. |
| Codex app-server (default) | One foreground launcher/owner. It owns the in-process ingress/autoturn loop, a setsid app-server process group, and a TTY-attached frontend (`ocaml/c2c_codex_app_server.ml:461-514,575-590,811-849`). | No `deliver.pid`/poker/notifier. Delivery polls in the launcher; disk mapping/ledger survives child replacement (`ocaml/c2c_codex_session.ml:1129-1250,1568-1577`). | Owner-control only. Non-force restart is accepted only when thread status is idle; active/unknown is skipped. Owner PID and pane survive `exec`, while server and frontend are replaced and the exact thread resumes. |

Common outer cleanup is explicit: inner process group gets TERM then KILL after 0.3 s; deliver and poker get a 2 s TERM grace then KILL; the notifier gets tracked reap plus identity-gated `stop_daemon`; PID files are removed (`ocaml/c2c_start.ml:4865-4945`).

## Live disruption receipts (exact worktree binary)

| Mode | Before -> after | Observed disruption |
|---|---|---|
| Claude | outer/inner `3889366/3889584` -> `3916232/3916886`; no sidecar in either generation | Restart began at epoch `1784509296.080748534`. Replacement banner appeared at 01:01:42 UTC (about 5.9 s), and the channel confirmation screen was captured by `1784509306.447021718` (10.366 s). Conversation `READY-X` was present after operator confirmation; final receipt was 29.058 s after start, mostly operator/harness delay. The TUI moved from its original pane to the control/caller pane. Idle context survived; an in-flight turn would be hard-killed with the process group. |
| OpenCode | outer/inner `3941927/3942014`; plugin children `3944322` (`stream-write-statefile`) and `3944378` (`monitor`); no sidecar -> all absent | Config held `resume_session_id=3c137f7e-26ac-45f3-9fb5-638d82189e2e`. Exact restart killed the live group, then rejected replacement because OpenCode requires `ses_*`: `error: --session-id for opencode must be a ses_* session ID`. Receipt window `1784509394.364715391` to `1784509408.747316395` = **14.383 s to confirmed hard outage**, with no replacement PIDs. |
| Kimi | attempt 1 inner `3575453`; attempt 2 inner `3598565` | The supported harness could not keep Kimi alive: clean and `--new-session` attempts exited code 117 after **6.6 s** and **4.3 s**, so no honest restart-duration number exists. More importantly, SessionStart hooks left detached notifier PIDs `3577118` and `3602852` (PPID 1092, each its own PGID/SID, `/proc/exe=/home/xertrov/.local/bin/c2c`) after both outers and `notifier.pid` files were gone. They were verified against `i011-kimi*.log`, then explicitly terminated; no sweep was used. This disproves sole outer ownership in the failure race. |
| agy | outer/inner/deliver `3973294/3973377/3973378` -> `3994245/3994648/3994649` | Receipt window `1784509469.837830689` to `1784509484.648994466` = **14.811 s** to a new idle UI. All three PIDs cycled. Pre-restart `READY-X-AGY` history was absent afterward. Source explains it: `AgyAdapter.build_start_args` would add `--conversation` (`ocaml/c2c_start.ml:4050-4075`), but `prepare_launch_args` has no `agy` branch and falls through to `[]` (`ocaml/c2c_start.ml:3555-3663`). |
| Codex hooks | outer/inner/deliver `4031976/4032380/4032381` -> `4055136/4056665/4056666`, then all absent | SessionStart registered the real Codex thread under `codex-kielo-ocean-21ev`, not managed alias `i011x-codex-hooks`; config retained generated UUID `98628203-b614-4a0f-b9f6-6889ae49f5ac`. Restart hard-interrupted the active kickoff, then `codex resume` failed: no saved session for that UUID. Inner reported failure after **27.3 s**; end-to-end receipt was **39.454 s** (`1784509608.818431396` to `1784509648.272407998`). |
| Codex app-server | owner `3751095` remained; app-server `3751231` -> `3785150`; frontend `3754430` -> `3792144`; no sidecar | Owner accepted at 10:55:45, relaunched at 10:55:46, and reported ready at 10:56:01: **16 s owner-controlled downtime**. Endpoint changed `39255 -> 33861`; thread stayed `019f7d04-e7b2-7d01-b9ba-564f9882a74d`; `READY-APP` history reappeared. The owner and original pane remained stable. Source confirms active turns are skipped unless forced (`ocaml/c2c_codex_session.ml:1273-1291`); the attempted live busy check raced before status became active and is not claimed as proof. |

## Corrections to the 12 July design

The July process table at `.collab/design/2026-07-12-c2c-client-upgrade-restart.md:70-103,162-180` needs these corrections:

1. Replace Gemini with agy in the current outer-loop set; managed Grok remains deferred.
2. Kimi notifier is no longer simply “detached, untracked, survives restart.” B145 added outer tracking, teardown, and SHA-aware respawn. The remaining defect is narrower and more serious operationally: the Kimi hook is also an arm owner, and a SessionStart/outer-exit race can leave an untracked, pidfile-less detached notifier.
3. Add agy's tracked deliver sidecar and bounded agentapi children.
4. Add OpenCode's plugin-owned `c2c monitor` and state-writer children. They are not outer sidecars; inner process-group termination kills them.
5. Qualify “codex wake sidecar” as **hook fallback only**. Default app-server Codex has no deliver sidecar.
6. Default Codex still couples delivery-loop replacement to server/frontend replacement, but it now has a safe same-pane owner-control restart and exact-thread continuity. It is not equivalent to generic full-session restart on the caller's TTY.
7. Generic TUI restart is still whole-unit disruptive and caller-TTY-capturing. Current OpenCode, agy, and Codex-hook receipts additionally show that “saved session” is not sufficient: each client needs a validated native resume identifier before destructive stop.

## Downstream inputs (E/F/G/H/I/J)

- **E — idle capability:** only Codex app-server currently has a queryable owner-side active/idle status and fail-closed non-force gate. Claude, OpenCode, Kimi, agy, and Codex hooks have no equivalent; generic restart is a hard signal regardless of turn state. E must define `Idle | Active | Unknown` per owner and make `Unknown` non-destructive.
- **F — owner control:** retain the Codex mapping/request/result seam. Add an outer-loop owner-control request consumed in the original pane; external automation must not exec a TUI on its own TTY. The owner must validate native resume state before killing the inner.
- **G — explicit determination: SPLIT.** G must split into (G1) app-server owner self-reexec and (G2) outer-loop inner/sidecar cycling. Do not force these behind one implementation: app-server preserves owner PID/thread and has a status API, while outer-loop clients replace the owner, move panes today, and have client-specific resume and sidecar races. Kimi's hook/outer dual ownership is a further Kimi-specific subcase under G2.
- **H — sidecar extraction:** prioritize removing the Kimi hook/outer dual-arm ambiguity and giving every detached process one durable owner. OpenCode plugin children should remain inner-owned, not be misclassified as outer sidecars. agy's deliver watcher can remain outer-owned once conversation resume is fixed.
- **I — restart protocol:** require prepare/validate -> idle gate -> quiesce ingress -> stop owned children -> spawn/reattach -> ready/identity proof -> replay. OpenCode's `ses_*`, agy's conversation id, and hook Codex's real thread id are mandatory prepare outputs; a generated c2c UUID is not a native resume token.
- **J — live/deploy gate:** rerun all six through `c2c_tmux.py`; require old/new PID-set receipts, same-pane proof, context marker continuity, queued-message replay, and zero orphan PID/pidfile mismatch. Kimi must first launch successfully on the pinned host version. Include no-tmux-server harness preflight and a true active-turn app-server refusal test.

## Remaining risks

- Kimi restart disruption is unmeasured because Kimi 0.27.0 exited code 117 twice. The orphan race is measured, but its exact ordering needs a focused trace.
- Claude timing includes a development-channel trust confirmation and operator delay; the 5.9/10.366 s milestones are more representative than the 29.058 s final receipt.
- The app-server active-turn gate is source-proven; this run's live busy attempt arrived before status became active.
- Hook installation on this host registered managed hook-Codex under a generated alias, so the failure may involve installed hook/config drift as well as launcher state. The destructive consequence is nevertheless current and reproduced with the exact worktree restart binary.
- Test registrations were intentionally not swept. All managed processes were stopped through the harness; the two verified pidfile-less Kimi notifier orphans were terminated by exact PID.
