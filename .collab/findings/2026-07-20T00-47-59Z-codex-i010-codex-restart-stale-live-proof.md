---
title: I010 Codex app-server restart-stale live proof
date: 2026-07-20T00:47:59Z
author: codex
severity: deploy-gate evidence
status: PASS
task: P2.M1.E1.T001
branch: task/p2-m1-e1-t001
---

# I010 Codex app-server `restart-stale` live proof

## Verdict

**PASS.** A real tmux-managed Codex app-server owner accepted an operator
`restart-stale --force` request while its thread was active, self-reexeced in
the same pane and process, replaced its executable with the installed image,
and resumed the exact Codex thread. Unique peer messages sent before and after
the restart were model-visible. The ingress and auto-turn ledgers contained
each message ID exactly once, with no retries or errors.

This was an evidence-only deploy-gate run. No product source was changed, no
backlog state was mutated, no unrelated managed session was restarted, and
`sweep` was never called.

## Run identity

- Date: 2026-07-20 (Codex CLI `0.144.6`).
- Worktree: `/home/xertrov/src/c2c/.worktrees/p2-m1-e1-t001`.
- Starting commit: `c54496be89e9f53efba25394661ecba2e4a767ff`.
- Managed instance / broker alias: `i010rst0720a`.
- Temporary sender: `i010peer0720a` (`i010-peer-session-0720a`).
- Required model: `gpt-5.3-codex-spark`.
- Stable c2c session ID: `bea08210-2a0e-4868-b14c-dd81e4bfa5b7`.
- Stable Codex thread ID: `019f7cf4-4c8e-7a30-925e-32ad84517bb3`.
- Stable owner PID across `execve`: `3324090`.
- Broker root resolved by the managed process:
  `/home/xertrov/.c2c/repos/8fef2c369975/broker`.

## Build, install, and canonical tmux launch

The slice built before the live run:

```text
$ just build
scripts/dune-build-locked.sh build ./ocaml/cli/c2c.exe ...
dune-throttle: acquired build slot 2/2 (jobs<=4)
rc=0
```

There was initially no tmux server. Only an empty control session was created;
the managed client itself was launched by running the canonical harness from
inside that tmux pane:

```bash
python3 scripts/c2c_tmux.py launch codex -n i010rst0720a \
  --cwd /home/xertrov/src/c2c/.worktrees/p2-m1-e1-t001 \
  --new-window --window i010-codex-proof \
  --extra --model gpt-5.3-codex-spark --yolo --no-prompt
```

Harness output identified pane `%1` and showed the exact managed command it
issued:

```text
launched on %1 (new window 'i010-codex-proof'): /home/xertrov/.local/bin/c2c start codex -n i010rst0720a --model gpt-5.3-codex-spark --yolo --no-prompt
```

`python3 scripts/c2c_tmux.py wait-alive i010rst0720a --timeout 180` returned:

```text
alive: i010rst0720a (pid=3324090)
```

The live TUI banner independently confirmed the pinned model, worktree, and
app-server transport:

```text
[c2c codex app-server] app-server ready (ws://127.0.0.1:37063)
[c2c codex app-server] c2c codex · ready · i010rst0720a
model:       gpt-5.3-codex-spark high
directory:   ~/src/c2c/.worktrees/p2-m1-e1-t001
```

Before replacement, every identity surface agreed:

```text
outer_pid=3324090
codex-session.json thread_id=019f7cf4-4c8e-7a30-925e-32ad84517bb3
config.json codex_resume_target=019f7cf4-4c8e-7a30-925e-32ad84517bb3
outer dev=57 ino=201972073 size=36574296
installed dev=57 ino=201972073 size=36574296
outer sha256=e847fd2c8469d170c570693690f3e7fe3aa5b98565463d4bdcbc65995d9ab34e
```

## Pre-restart peer visibility and first exactly-once checkpoint

The temporary local peer sent informational DATA (not an instruction):

```bash
C2C_MCP_SESSION_ID=i010-peer-session-0720a \
  c2c send --json -F i010peer0720a i010rst0720a \
  'Informational c2c restart proof data: I010_PRE_0720A. No action is requested.'
```

The broker reported `delivery.state=delivered`. The TUI then displayed the
complete injected c2c envelope and the model responded:

```text
message_id="8e267df2-9df2-4a70-9b56-2419c034effc"
... Informational c2c restart proof data: I010_PRE_0720A. No action is requested.

• Informational message received from i010peer0720a: I010_PRE_0720A.
  No action was requested.
```

The first ingress checkpoint had exactly one entry, `state=injected`,
`retry_count=0`, `last_error=null`. Its sole auto-turn batch contained only
that message ID and reached `turn_done` with `retry_count=0` and no error.

## Genuine Stale image and explicit dry-run

`just install-all` completed with `rc=0` and installed the worktree build. The
old owner retained the deleted old image while the path pointed at the
different new image:

```text
outer_link=/home/xertrov/.local/bin/c2c (deleted)
outer dev=57 ino=201972073 size=36574296
outer sha256=e847fd2c8469d170c570693690f3e7fe3aa5b98565463d4bdcbc65995d9ab34e
installed dev=57 ino=202212019 size=36599376
installed sha256=3d8b6d60117cb7996bcb6b480309951f060b48b6ae5cd6f06fcfbefd8cf36298
$ c2c --version
0.13.0 c54496be 2026-07-20T00:40:06Z
```

An explicit `c2c restart-stale --dry-run --json` classified `i010rst0720a` as
`stale` with action `would_restart`; its summary made zero state changes.

The host also had unrelated stale managed instances. To ensure the real
commands could not touch them, the run created a temporary
`C2C_INSTANCES_DIR` containing one symlink, `i010rst0720a`, to the real proof
instance. Enumeration, staleness classification, request/result files, and
the owner-control seam were unchanged; only unrelated rows were excluded.

## Default idle gate and forced owner self-reexec

The active window was made deterministic with a local-operator turn, submitted
through `scripts/c2c_tmux.py`; the TUI showed `Working`, one background
terminal, and the requested `sleep 45`. While that turn was active, the
unforced operator command returned:

```json
{
  "name": "i010rst0720a",
  "client": "codex",
  "verdict": "stale",
  "action": {
    "kind": "skipped",
    "reason": "app-server owner declined: skipped-active"
  }
}
```

Summary: `restarted=0`, `skipped=1`, `failed=0`. This is the live default idle
gate, not a fixture.

The same active turn was then overridden by the local operator:

```bash
C2C_INSTANCES_DIR=/tmp/c2c-i010-restart-stale-proof.gxB5f4 \
  c2c restart-stale --force --json --timeout 30
```

Result:

```json
{
  "name": "i010rst0720a",
  "client": "codex",
  "verdict": "stale",
  "action": { "kind": "restarted" }
}
```

Summary: `restarted=1`, `skipped=0`, `failed=0`. The pane logged the owner-side
acceptance and exact resume target:

```text
[c2c codex app-server] [10:44:21] restarting in place on thread 019f7cf4-4c8e-7a30-925e-32ad84517bb3
[c2c codex app-server] [10:44:22] launching app-server (c2c-alias=i010rst0720a)
[c2c codex app-server] [10:44:38] app-server ready (ws://127.0.0.1:39469)
```

The active model turn was visibly interrupted, which is the expected and
observable effect of deliberately using `--force`; no peer message triggered
or authorized the restart.

## Same owner, installed executable, and exact thread resume

The app-server generation changed from unit
`b858c656-0519-467c-93ab-c9eb9e8ada2a` at port `37063` to unit
`c7f66ebc-a838-4dca-9ec7-0d3a43b0abe7` at port `39469`, with new server and
frontend PIDs. The owning c2c process did not change PID:

```text
outer.pid before=3324090
outer.pid after =3324090
```

After the self-`execve`, `/proc/3324090/exe` and the installed pathname agreed
on device, inode, size, and digest:

```text
outer dev=57 ino=202212019 size=36599376
installed dev=57 ino=202212019 size=36599376
outer sha256=3d8b6d60117cb7996bcb6b480309951f060b48b6ae5cd6f06fcfbefd8cf36298
installed sha256=3d8b6d60117cb7996bcb6b480309951f060b48b6ae5cd6f06fcfbefd8cf36298
```

All four durable thread surfaces retained the exact same ID:

```text
codex-session.json thread_id      019f7cf4-4c8e-7a30-925e-32ad84517bb3
config.json codex_resume_target   019f7cf4-4c8e-7a30-925e-32ad84517bb3
ingress ledger thread_id          019f7cf4-4c8e-7a30-925e-32ad84517bb3
auto-turn ledger thread_id        019f7cf4-4c8e-7a30-925e-32ad84517bb3
```

The resumed TUI re-rendered the pre-restart transcript, including the pre
marker and interrupted local turn. That is transcript resumption, not another
injection: the ledgers below retained one pre-message entry and one pre-message
batch throughout the restart.

## Post-restart visibility and final exactly-once proof

The same peer sent a second unique DATA marker after the owner was online on
the new app-server generation:

```text
I010_POST_0720A
message_id=e5388229-7588-4d3f-9ef1-e3cb8cfee5ef
delivery.state=delivered
```

The resumed TUI displayed the complete post-restart c2c envelope in a new
auto-turn batch. A subsequent local-operator evidence prompt asked the model to
name both distinct DATA markers visible in this same thread. It replied:

```text
• I010_PRE_0720A I010_POST_0720A
```

The final machine assertion read both ledgers and checked exact IDs, states,
errors, retries, active-batch state, and all thread IDs. Output:

```json
{
  "active_batch_key": null,
  "ingress_message_id_counts": {
    "8e267df2-9df2-4a70-9b56-2419c034effc": 1,
    "e5388229-7588-4d3f-9ef1-e3cb8cfee5ef": 1
  },
  "ingress_states": {
    "8e267df2-9df2-4a70-9b56-2419c034effc": {
      "state": "injected", "retry_count": 0, "last_error": null
    },
    "e5388229-7588-4d3f-9ef1-e3cb8cfee5ef": {
      "state": "injected", "retry_count": 0, "last_error": null
    }
  },
  "turn_message_id_counts": {
    "8e267df2-9df2-4a70-9b56-2419c034effc": 1,
    "e5388229-7588-4d3f-9ef1-e3cb8cfee5ef": 1
  },
  "turn_states": {
    "8e267df2-9df2-4a70-9b56-2419c034effc": "turn_done",
    "e5388229-7588-4d3f-9ef1-e3cb8cfee5ef": "turn_done"
  },
  "last_error": null
}
ASSERTIONS=PASS
```

`codex-deliver.log` corroborated the monotonic transition: pre batch with
`injected_count=1`, a clean post-reexec idle pass still at `1`, then the post
batch alone with `injected_count=2`. There was no second turn for the pre ID.

## Acceptance matrix

| Criterion | Live evidence | Result |
|---|---|---|
| Exact same Codex thread resumed | Pane restart line plus four matching durable thread IDs | PASS |
| Owner/executable replacement observed | Same PID; old inode/SHA changed to exact installed inode/SHA | PASS |
| Pre- and post-restart model visibility | Both c2c envelopes rendered; model returned both unique markers | PASS |
| Ledger exactly-once | Two ingress entries and two completed batches; each ID count 1, retry 0, no errors | PASS |
| Default idle gate and force override | `skipped-active` while live turn active, then forced `restarted` | PASS |
| Canonical tmux harness | Launch, wait, pane drive/capture, and stop through `scripts/c2c_tmux.py` | PASS |
| Tracked finding | This file | PASS |

## Harness friction observed

Two non-blocking helper defects were observed and are recorded here per the
repository dogfood rule:

1. With no tmux server, `python3 scripts/c2c_tmux.py list` exited 1 with a
   Python traceback from `tmux list-panes -a` instead of reporting an empty/no
   server state. After an empty control session existed, the same command
   returned 0.
2. `python3 scripts/c2c_tmux.py send %1 <text>` typed the local active-gate
   prompt but its immediate submit Enter did not start the turn. A subsequent
   `python3 scripts/c2c_tmux.py enter %1` submitted it, and the TUI changed to
   `Working`. The later evidence prompt was therefore deliberately followed by
   a separate `enter` call. This looks like a paste-to-submit settling race,
   distinct from the already-handled `extended-keys` encoding issue.

Neither defect bypassed the canonical harness or invalidated the live proof.
No helper patch was included because this task owns the deploy-gate evidence;
the workarounds remained inside the supported tmux scripts and the defects did
not block any acceptance criterion.

## Cleanup and remaining risk

Cleanup used only canonical/non-sweep paths:

```text
$ python3 scripts/c2c_tmux.py stop i010rst0720a
Instance 'i010rst0720a': stopped
outer_alive=false

$ c2c deregister i010peer0720a --json
"deregistered": true
```

The dedicated tmux session and the one-symlink temporary restart scope were
then removed. No unrelated managed process was signalled.

Remaining risk is bounded to normal live-proof scope: this proves one real
Linux/tmux/Codex `0.144.6` run on `gpt-5.3-codex-spark`, not every future Codex
version or failure timing. The forced active turn was intentionally
interrupted; the exact thread, peer DATA, and ledgers survived as required.
