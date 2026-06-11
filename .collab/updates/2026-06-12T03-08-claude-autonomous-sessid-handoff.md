# Autonomous session handoff — session-id delivery (Max AFK)

**Written 2026-06-12 ~03:08 local, before compaction.** Max is AFK and asked me
to continue autonomously, make principled decisions, no questions, no
AskUserQuestion.

## Mission
Build the **session-id-addressed delivery + always-on hook auto-pickup** feature.
Design doc (authoritative, all decisions locked):
`.collab/design/2026-06-12-session-id-delivery-and-hook-autopickup.md` (committed
on local master `42ad4545`).

## DONE this session
- **PoW on relay** — DEPLOYED + LIVE on prod `relay.c2c.im` (`git_hash 776d17e`,
  `C2C_RELAY_POW=1` set via Railway, smoke 13/13). Pushed to origin/master.
  Railway: project `vigilant-laughter`, service `c2c` (see memory
  `c2c-relay-railway-deploy.md`).
- **Session-id design** — doc written + committed `42ad4545`; open questions all
  decided (global broker path = `${XDG_STATE_HOME:-$HOME/.c2c}/sessions/broker`;
  Stop hook deferred to P1 behind a spike; stale-inbox GC → P3; MCP+global-hook
  de-dup is inherent since separate inbox paths).
- **ccc** — upgraded 0.2.0→0.3.3 (`cargo install --path ~/src/ccc/rust`). 0.3.3
  forwards `--model` but has a SECOND bug (drops provider prefix → `--model
  glm-5.1` not `zai-coding-plan/glm-5.1` → opencode UnknownError). **Max is
  fixing the provider-prefix bug himself (≥0.3.4).** Direct-opencode launcher
  idea DROPPED as redundant. Finding updated:
  `.collab/findings/2026-06-12T01-30-00Z-claude-ccc-opencode-model-not-forwarded.md`.

## IN FLIGHT
- **P0 implementation** — codex agent, background task **`b0gqs53a2`**, worktree
  `.worktrees/wt-sessid-p0` (branched origin/master), log `/tmp/sessid-p0.log`,
  prompt `/tmp/prompt-sessid-p0.txt`. Building: `resolve_sessions_broker_root()`
  in `c2c_repo_fp.ml`, `c2c send --session <id>`, rework `c2c_inbox_hook.ml` to
  read session_id from STDIN payload + drain the global sessions broker + drop
  the min_runtime floor/Lwt, + tests (fixture via `C2C_SESSIONS_BROKER_ROOT`).
  (NOTE: P0 v1 = task `b3ru23sf9` — I accidentally killed it with a too-broad
  `pkill -f "ccc.*@"`; this `b0gqs53a2` is the clean re-dispatch.)

## NEXT (sequential, after P0 lands)
1. Verify P0: build-rc=0 IN wt-sessid-p0 (`opam exec -- dune build --root . -j2`)
   + new + existing tests; confirm committed; no `.opencode` leak; tight scope.
2. Peer-review: `ccc @cx-reviewer` review-and-fix loop until PASS (codex —
   unaffected by the opencode bug).
3. **Dogfood live** (CLAUDE.md: "if it's not tested in the wild it's not done"):
   `c2c send --session <real-session-id>` → confirm the PostToolUse hook injects
   into a real Claude session (tmux via `scripts/c2c_tmux.py`), or at minimum
   feed the hook a real stdin payload + populated global inbox.
4. P1 — Stop hook (spike block-stop injection mechanics, then implement).
5. #7 — hook test harness (correctness + speed; idle <~10-15ms budget).
6. P3 — docs (`/connect/` + setup) + `c2c install` always-installs hooks.

## CONSTRAINTS / LESSONS
- **NO push** for the session-id feature (local-only; nothing needs deploying).
  Pushes are coordinator-gated (`C2C_COORDINATOR=1 git push`); only push if
  something must go live.
- **Do NOT broad-`pkill`** — `pkill -f "ccc.*@"` killed my own P0 codex agent.
  Match exact patterns.
- **Backgrounding long-lived listeners** (e.g. `c2c relay serve`) via the harness
  now dies with exit 144 (signal 16) — first relay dogfood worked via plain `&`,
  later attempts didn't. For live relay dogfood prefer tmux.
- Use **codex (`ccc @cx-coder`/`@cx-reviewer`)** for subagents — opencode/ccc
  model path is broken until Max's 0.3.4. Codex is reliable.
- Merges to master need `C2C_COORDINATOR=1` (pre-reset shim blocks commit on
  master). PoW + design doc already merged.

## Background tasks live
- Heartbeat Monitor `bdrcosvel` (leave it).
- P0 codex agent `b0gqs53a2`.
- ScheduleWakeup fires 03:29 as P0 fallback.
