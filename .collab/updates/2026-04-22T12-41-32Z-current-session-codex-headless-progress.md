# Codex-Headless Progress

## HEAD / Recent Commits

- `3d91280` `feat(codex-headless): file-backed thread-id handoff for lazy persistence`
- `0c163d3` `fix(codex-headless): skip tty foreground handoff for headless bridge`

These landed after the earlier launcher unblocker work (`464ecbd`, `f59b836`, `a326182`, `523776e`).

## What Now Works

- `codex-headless` launches through `c2c start codex-headless`.
- The old immediate Tokio panic path in the tmux E2E no longer reproduces in the current live run.
- The live headless E2E no longer uses self-send. It now starts a real peer sender and waits on:
  - recipient inbox drained
  - persisted `resume_session_id`
- Direct bridge probes all work:
  - direct bridge with plain XML message + `--thread-id-fd 3` writes a thread id
  - direct bridge with plain XML message + `--thread-id-fd 5` writes a thread id
  - direct bridge under tmux with the exact c2c nested `<c2c ...>` payload writes a thread id
  - direct bridge with an open writer that stays alive after the first XML frame still writes a thread id

## Current Blocker

Managed `c2c start codex-headless` still does **not** persist the thread id in the live path.

Observed state in the latest live/manual repros:

- broker inbox drains correctly
- archive entry is written
- XML spool clears
- managed outer + bridge + deliver processes can remain alive
- `thread-id-handoff.jsonl` stays empty
- `config.json` keeps `resume_session_id = ""`

This means the remaining failure is specifically in the managed bridge handoff / first-message startup path, not in:

- the Codex bridge binary itself
- the nested c2c XML payload shape
- the existence of `--thread-id-fd`
- the ability of the bridge to handle a long-lived open stdin writer in isolation

## Most Useful Evidence

### Direct bridge success

- `timeout 15s ... codex-turn-start-bridge ... --thread-id-fd 5 ...`
  produced:
  - `{"thread_id":"...","source":"started"}`

### Manual two-agent managed repro

- Repo: `/tmp/c2c-headless-wait.ix1Qtv`
- Recipient alias: `headless-A-19083`
- Sender alias: `headless-B-17123`
- Live state while hung:
  - outer: `544396`
  - inner bridge: `544491`
  - deliver daemon: `544494`
  - archive present for `peer-ping`
  - spool empty
  - `~/.local/share/c2c/instances/headless-A-19083/thread-id-handoff.jsonl` empty

### Important discovery

- In a live managed repro, the recipient outer wrapper still holds fd `4` as the XML write pipe.
- Writing a valid XML `<message ...>` frame directly into `/proc/<outer>/fd/4` still did **not**
  populate the handoff file.

This strongly suggests the remaining problem is in how the managed bridge stdin path is wired or consumed,
not in the deliver daemon’s broker drain logic.

## Tests / Verification Run In This Slice

- `python3 -m pytest -q tests/test_c2c_start.py -k 'headless' --force-test-env`
  - pass
- multiple live runs of:
  - `env C2C_TEST_CODEX_HEADLESS_E2E=1 pytest -q tests/test_c2c_codex_headless_e2e.py --force-test-env`
  - still failing on persisted thread id

## Worktree Notes

Current `git status --short` at the time of writing did **not** show the codex-headless changes as dirty.
There is unrelated worktree drift:

- modified: `.opencode/plugins/c2c.ts`
- untracked: `.c2c/config.toml`
- untracked: `.sitreps/2026/04/22/12.md`

Do not touch those without checking ownership first.

## Best Next Step

Resume from the manual two-agent repro (`/tmp/c2c-headless-wait.ix1Qtv`) or create a fresh one and
focus on the managed bridge stdin/handoff path itself:

1. prove whether the live bridge process actually reads from the managed stdin pipe
2. prove whether `emit_thread_resolved` runs in the managed path
3. if needed, replace the current anonymous stdin pipe launch with a simpler, directly testable sideband
   setup that mirrors the successful direct bridge probes more closely

## Outstanding User-Requested Close-Out Steps

Still pending until the remaining headless blocker is resolved:

1. commit any remaining implementation changes
2. run review/fix loop until no substantial issues remain
3. make final post-review commit
4. plan and implement the newly unblocked Codex-binary-dependent slices
