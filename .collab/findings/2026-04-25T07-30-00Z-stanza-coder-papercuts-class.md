# Recurring Papercut Classes — Swarm Daily Pain Log

**Author**: stanza-coder  
**Date**: 2026-04-25  
**Purpose**: catalogue recurring categories of swarm friction that keep biting us one-off.
These are patterns, not single incidents. Triaging them together is more effective than
patching each instance as it surfaces. Filed per coordinator1's suggestion after #179.

---

## Class A: Shared-tree file clobber

**Symptom**: An agent on a different branch checks out, branches switch, or dune reads files
in the shared main tree — silently overwriting another agent's working files.

**Instances**:
- `.opencode/plugins/c2c.ts` reset 3 times in one session by galaxy's branch switch (→ fixed by #179 via gitignore + write-on-launch)
- galaxy's unstaged OCaml WIP in main tree blocked stanza-coder's dune build during #167 probe
- Coordinator flagged `git checkout HEAD -- <file>` footgun (.collab/findings/2026-04-24T02-10-00Z-*)

**Fix pattern**: If a file is "live config for a running agent" and also tracked in git, it
will be clobbered on branch switch. Remedies in order of preference:
1. Gitignore the artifact; write it from a canonical source on launch (like #179)
2. Move agent-specific config to per-instance dirs that are gitignored
3. Document the class clearly so agents don't reach for destructive git ops

**Candidate files at risk**: `.opencode/opencode.json` (partially addressed by `refresh_opencode_identity`),
`.codex/config.toml`, `.claude.json` (project-level), `.kimi/mcp.json`

**Severity**: High — silent data loss, easy to miss, hit multiple times

---

## Class B: Stale binary after merge / install race

**Symptom**: Agent runs a tool, gets unexpected behavior, eventually discovers the installed
binary is from before the current commit. `just install-all` was run but the old binary was
still serving MCP requests (live binary, "text file busy", or restart not done).

**Instances**:
- #167 smoke probe: binary lacked `C2C_AGENT_NAME` injection because it was df057c9 vintage;
  manual patch + rebuild + restart required
- General: `just install-all` handles the "text file busy" atomically, but agents forget to
  `./restart-self` afterward — MCP broker still uses old binary until restart

**Fix pattern**:
- Always `./restart-self` after `just install-all` on OCaml changes
- `c2c doctor` could warn: "installed binary SHA ≠ HEAD" (stale-binary check)
- Track binary build SHA in a file, compare on startup

**Severity**: Medium — frustrating but diagnosable if you know to look

---

## Class C: Deferrable flag silently ignored on push path

**Symptom**: Messages marked `deferrable=true` were still being push-delivered, defeating the
flag's purpose and interrupting agents unnecessarily.

**Root cause**: Two after-RPC auto-drain paths in `c2c.ml` and `c2c_mcp_server.ml` called
`drain_inbox` instead of `drain_inbox_push`, discarding the deferrable filter.

**Found by**: dogfood-hunter's live test (#178), not spec reading

**Fixed**: eb8738c — both paths now call `drain_inbox_push`

**Lesson**: Push-path behavior is hard to test without a live cross-client send. Dogfooding
caught this; unit tests would not have. Deferrable behavior should be a regression test.

**Severity**: Medium (behavioral correctness, not data loss)

---

## Class D: Dune build picks up WIP from wrong agent's files

**Symptom**: Running `just build` or `just install-all` from a worktree silently builds the
MAIN TREE's sources rather than the worktree's, because dune resolves the workspace root via
`dune-project` and goes up to the main tree. Target paths like `./ocaml/cli/c2c.exe` are
then relative to the CWD within the dune workspace, not the worktree root.

**Instances**:
- stanza-coder worktree builds: `dune build ./ocaml/cli/c2c.exe` from worktree dir fails
  with "Don't know how to build" (CWD is inside `.c2c/worktrees/` which maps to a different
  path in workspace context)
- Workaround: `cd /home/xertrov/src/c2c && dune build ...` from the main tree

**Fix pattern**:
- Add a `justfile` recipe that explicitly CDs to repo root before running dune, so it works
  from any worktree
- Or: document clearly that OCaml changes must be built from the repo root, not the worktree dir
- Long-term: investigate dune `--root` flag

**Severity**: Low-medium — annoying, requires knowledge of the workaround

---

## Class E: CLI edge cases in shell command substitution

**Symptom**: c2c send + shell expansion produces garbled messages or sends literal format strings.

**Instance**: dogfood-hunter's `$(date)` literal sent as the message body (shell expansion
happened in the wrong context).

**Fix pattern**: Message quoting docs in `c2c help send`, or a warning when content looks like
an unresolved shell substitution.

**Severity**: Low — cosmetic/UX, no data loss

---

## Class F: Sweep + managed-session restart races

**Symptom**: `c2c sweep` / `mcp__c2c__sweep` drops a managed session's inbox while the outer
loop is about to relaunch. Messages delivered between sweep and relaunch go to dead-letter.

**Finding**: .collab/findings/2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md

**Status**: Documented; CLAUDE.md has a "never sweep during active swarm" rule. Not yet fixed
structurally (sweep should check for outer loops before dropping).

**Severity**: Medium — silent message loss

---

## Triage priority

| Class | Fix complexity | Impact | Status |
|-------|---------------|--------|--------|
| A (shared-tree clobber) | Medium | High | Partially fixed (#179); remaining files TBD |
| B (stale binary) | Low | Medium | doctor warn TODO |
| C (deferrable push) | Low | Medium | Fixed (#178) |
| D (dune from worktree) | Low | Low-med | Fixed (#5b18f85) — just build now cd's to repo root |
| E (shell expansion) | Low | Low | Doc/UX improvement |
| F (sweep race) | Medium | Medium | CLAUDE.md guardrail only |
| G (tmux bare target) | Low | Low-med | Fixed (9251691, merged) |

---

*Append new instances here as they're found — don't open a new doc per incident.*

---

## Class G: c2c_tmux.py lookup fails for bare tmux targets

**Symptom**: `scripts/c2c_tmux.py keys 0:1.1 "..."` fails with "no alias found" when
a pane has a known tmux target but no live alias cache entry (e.g. after a harness exit).
Direct `tmux send-keys -t 0:1.1 ...` works fine. The script is the preferred swarm pane tool
per CLAUDE.md, but silent degradation to "not found" when no registration is live forces
agents to fall back to raw tmux commands — the failure mode it's supposed to prevent.

**Instance**: jungle-coder pane 0:1.1 after `c2c start` exited; resume command had to be
sent via `tmux send-keys` directly (2026-04-25T17:57).

**Fix pattern**: When alias lookup fails, `c2c_tmux.py` should fall back to treating the
argument as a bare tmux target (window.pane format) and attempt the operation directly.
Or: accept `--target 0:1.1` as an explicit bypass. Alias lookup is a convenience, not a
prerequisite for pane operations.

**Severity**: Low-medium — causes friction precisely when peers are in a degraded state
(most likely to need operator/peer intervention)
