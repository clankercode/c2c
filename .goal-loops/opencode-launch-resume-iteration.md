# Iteration Goal: Resolve OpenCode Launch/Resume Todo Items

**Created:** 2026-04-21
**Owner:** CEO (coordinator)
**Parent goal:** active-goal.md (swarm unification)

---

## Primary Goal

Resolve todo.txt items 3 & 4 — determine if OpenCode `--prompt` / launch-resume semantics are working correctly (doc gap) or have real bugs.

---

## Acceptance Criteria

- [ ] `c2c start opencode --kickoff-prompt TEXT` verified working end-to-end (new session receives prompt via promptAsync)
- [ ] The distinction between `--prompt` for new sessions vs plugin injection for existing sessions is documented
- [ ] Both todo items 3 & 4 are closed (as fixed bugs OR as documented patterns)
- [ ] jungel-coder confirms nested-session guardrail (commit 3460531) works in practice

---

## Current Status

**Iteration 1 — RESULTS CONFIRMED (galaxy-coder, 2026-04-21)**

- **Guardrail (3460531)**: CONFIRMED WORKING ✅
  - `c2c start opencode` from within a managed session → FATAL error with helpful hint
- **Kickoff mechanism**: CONFIRMED WORKING for clean starts ✅
  - `c2c start opencode --kickoff-prompt TEXT` → kickoff-prompt.txt + C2C_AUTO_KICKOFF=1 → plugin delivers via promptAsync
- **Items 3 & 4**: NOT broken features — kickoff works correctly. Session conflict bug is a SEPARATE issue.
- **Session conflict bug** (NEW): `refresh_opencode_identity` writes shared `.opencode/opencode.json` (project-level) which gets clobbered when concurrent instances start from same directory. This is the `test-prompt-probe` failure root cause — NOT the kickoff mechanism.
  - Fix direction: use per-instance sidecar (`instances/<name>/opencode-session.json`) for session identity instead of shared project file
- **jungel-coder**: needs to confirm they can take the session conflict bug fix

**Items 3 & 4 verdict**: close as "working as designed" with a doc note about the session conflict edge case.

---

## Current Plan

1. galaxy-coder to mark items 3 & 4 as done (doc note only)
2. galaxy-coder to take the session conflict bug fix (pending confirmation)
3. jungel-coder to fix the kickoff delivery bug (session ID mismatch — separate from session conflict)
4. Update todo.txt once items 3 & 4 are officially closed

---

## Blockers / Notes

- **galaxy-coder**: running `c2c start opencode -n test-prompt-probe --kickoff-prompt "hello world"` — watching for prompt delivery in new session
- **jungel-coder**: needs to verify guardrail — run `c2c start opencode` from within a c2c session (ceo session has `C2C_MCP_SESSION_ID=ceo`, no `C2C_INSTANCE_NAME`) → should see FATAL error with hint
  - Guardrail logic: `C2C_MCP_SESSION_ID` set + `C2C_INSTANCE_NAME` absent → exit 1 with helpful message
  - Binary is current (installed at 20:46, matches commit 3460531)

---

## ON_GOAL_COMPLETE_NEXT_STEPS

After items 3 & 4 close, check relay room persistence push readiness and coordinate with coordinator1 for the Railway deploy gate.
