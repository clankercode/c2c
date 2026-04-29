# Subagent "completed" but file missing — root cause + mitigation

- **Author**: coordinator1 (cairn investigator pass)
- **Date**: 2026-04-29 10:50 UTC
- **Severity**: HIGH for swarm research/findings workflow; subagent reports
  reach the parent claiming success when artifacts were never written.
- **Status**: root cause confirmed; mitigation proposed (not yet implemented).

## Symptom

Cairn-Vigil dispatched ~10 background subagents on 2026-04-28/29. Several
"completed" notifications surfaced but the requested files never landed on
disk. Concrete instance: subagent agent-id `a6d57d5cc850371fd` was tasked
to produce
`.collab/research/2026-04-29-399-channels-permission-auto-approve-cairn.md`.
File does not exist. (`find .collab -name '*399*channels*'` returns only an
unrelated `findings/` doc by `slate-coder`, not the requested research doc.)

## Evidence

Subagent JSONL transcript:
`/home/xertrov/.claude/projects/-home-xertrov-src-c2c/fefa33c9-a476-46cd-b30c-d0f9a51c72cd/subagents/agent-a6d57d5cc850371fd.jsonl`

- First record: 17:34:52Z (Task launch).
- Tool inventory: 16 × Bash, 2 × Read, **0 × Write**.
- Last record: 17:41:52Z — `type: assistant`, `stop_reason: tool_use`,
  containing a Bash `tool_use` (grep on a tool-results file).
- No subsequent `tool_result`. No final `text` summary. No `end_turn`.

Survey of 200+ sibling subagents in the same project dir:
- Healthy completed agents end with `assistant / end_turn` (or
  `stop_sequence`). All but 2 in this window match.
- `a6d57d5cc850371fd` and `ad1df56ea31503f3a` (a separate docs-drift task
  launched ~1 min later) **both end with `assistant / tool_use`** — i.e. the
  model emitted a tool call and was killed before the host could run the
  tool, return a `tool_result`, and let the model continue to a Write call
  + summary.

Parent session (`fefa33c9-...`) timeline around the kill:
- 17:34:57 — Task launched (only mention of `a6d57d5cc850371fd` in parent
  jsonl; the launch tool_result contains the standard "you'll be notified
  when it completes" message).
- 17:38:50 — Monitor heartbeat task-notification arrives in parent.
- 17:39:44–17:40:14 — parent itself does Write + git work, ends with
  text "Heartbeat done. State holding…".
- 17:40:15 — `system / stop_hook_summary` + `system / turn_duration`:
  parent transitions to **idle between turns**.
- 17:41:52 — subagent's last record (mid-tool-use).
- 17:42:25 — next parent input (push-readiness Monitor task-notification).

So the parent went idle at 17:40:15. The subagent kept running for 1m37s
afterward, then was force-stopped mid-tool-call without delivering its
result back. Crucially, **no completion task-notification for
`a6d57d5cc850371fd` ever appears in the parent jsonl** — only the launch.

## Root cause (confirmed)

Background subagents (`Task` with `subagent_type: general-purpose`) are
**lifecycle-coupled to the parent session's request loop, not to the
Claude Code process**. When the parent emits `end_turn` and the
`stop_hook_summary` fires, the harness considers the parent idle. If a
sidechain subagent is still in mid-tool-use at that boundary, it is killed
before its next tool dispatches; the partial JSONL is left on disk but
**no `<task-notification>` of completion is enqueued into the parent's
input queue**. The parent will *never* see a completion event for that
agent, even though the subagent transcript looks "almost done" and a
casual reader might assume the job finished.

The subagent's authored content lives only in its own jsonl (under
`/home/xertrov/.claude/projects/.../subagents/agent-<id>.jsonl`) — and
since the Write tool was never invoked, **nothing was ever serialized to
the project tree**. There is no recoverable artifact beyond the
investigation it had done in-memory.

The earlier "completed-but-missing" reports the user observed are most
likely a *different* failure mode (subagent emits a completion summary
saying "wrote file X" but never actually called Write). For #399
specifically, the cause is the idle-boundary kill, not a hallucinated
Write.

## Repro recipe

1. From an idle parent, dispatch a background `Task` with a prompt likely
   to take >2 minutes (heavy WebFetch/grep work).
2. Have the parent finish its current work and emit `end_turn` shortly
   after the dispatch.
3. Do not feed the parent another input for several minutes.
4. Observe: subagent jsonl truncates mid-tool-use; parent never gets the
   completion task-notification; any artifacts the subagent intended to
   write are lost.

Equivalent triggers: parent pane killed, parent compacted, parent
`/clear`'d, parent restarted via `c2c restart` while a background Task
was still mid-flight.

## Mitigations (proposed, not yet implemented)

Listed roughly in increasing order of cost / payoff.

1. **Subagent-prompt convention: write early, write often.** Mandate in
   coord-issued task prompts: "write a stub file at the target path *as
   your first action*; append findings as you discover them; update the
   summary at the end." Idle-kill at minute 6 still leaves a
   half-written-but-real artifact instead of nothing. Cheap; immediate
   payoff. Could be enforced via a coord-side prompt template.

2. **Coord-side post-dispatch verification.** When the coord launches a
   background subagent that promises to write file X, the coord's
   sitrep loop should grep for X periodically; if Y minutes elapse with
   no completion notification AND no file, surface a warning. Catches
   silent-kill in the loop where the harness doesn't tell us. Belongs in
   `scripts/c2c_tmux.py` or a new `scripts/subagent-watchdog.sh`.

3. **Keep the parent busy until subagents finish.** If the coord knows N
   subagents are out, it should not let itself go idle — heartbeat into
   `poll_inbox` / `mcp__c2c__list` / no-op until completion drains. We
   already do this when waiting for peers; same pattern for own
   subagents. Cheap, reliable.

4. **Sweeper that scans `~/.claude/projects/.../subagents/agent-*.jsonl`
   for `last_ts > 60s ago AND last record is tool_use` and DMs the
   coordinator.** A `c2c doctor subagents` (or a script under
   `scripts/`) that classifies orphaned/truncated transcripts and lists
   the prompts so we know what was lost. Read-only; safe to run on a
   timer.

5. **Out of our control but worth filing upstream:** the harness should
   either (a) refuse to mark a parent idle while a sidechain task is
   still active, or (b) emit a `<task-notification>` of type
   `interrupted`/`killed` so the parent *knows* its work was lost. Right
   now there is no signal at all — the parent is informed only of
   successes, never of orphan kills.

## Recommended immediate action

Add a "write a stub file as your first tool-use" line to the coord-side
subagent dispatch convention (mitigation #1). It's a one-line prompt
change and converts the worst case from "everything lost, no signal"
into "partial artifact on disk, easy to spot."

## Inspection notes (read-only, nothing deleted)

- `.worktrees/399-auto-channel-consent/` and
  `.worktrees/399b-channels-tty-auto-answer/` exist but are unrelated —
  they are slice worktrees, not subagent scratch. The killed subagent
  was running in the parent's cwd, not a worktree.
- `/tmp/claude-1000/-home-xertrov-src-c2c/<sid>/tasks/<agent>.output` are
  symlinks back into `~/.claude/projects/.../subagents/`. There is no
  separate "task output" file the subagent could have flushed to —
  everything is in the jsonl.
