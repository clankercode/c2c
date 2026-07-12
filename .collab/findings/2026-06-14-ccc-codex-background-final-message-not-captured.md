# ccc/codex: final assistant message not captured when run non-interactively

**UTC:** 2026-06-14 · **Author:** orchestrator (main Claude session, Max-driven) ·
**Severity:** MEDIUM (tooling/peer-PASS friction — blocks capturing an
independent reviewer's verdict; wastes cycles + tokens on re-runs)

## Symptom
Running `ccc --yolo @cx-reviewer "<review prompt>"` non-interactively (both
`run_in_background:true` via Bash AND foreground with stdout piped) for a
peer-PASS review: the captured output contains codex's **intermediate**
narration and **every `exec` tool call + its output**, but the **final
assistant message** (the one carrying `VERDICT: PASS/FAIL` + findings) is
**missing**. The stream just ends after codex's last `exec` block. Exit code
is 0 — looks "complete" but the deliverable isn't there.

Hit twice in a row reviewing c2c-watch B0:
- First run: 3240+ lines captured (full investigation), ends mid-verification
  after a `git show --check`, no verdict line.
- Terse re-run: ends right after codex reads the file + `git show --stat`, no
  verdict.

## Root cause (hypothesis)
ccc/codex renders its final answer through a path that only reaches a TTY
(interactive UI), not the piped/redirected stdout used for background or
captured runs. Streaming narration + exec logs DO go to stdout (so codex text
*can* be captured), but the concluding turn's rendered answer does not flush to
the pipe. Not a read-timing issue — the process had exited 0 and the file was
final.

## Fix / workaround that WORKS
Make codex's **deliverable a FILE it writes via its own shell tool**, not its
chat reply. `exec` output and side-effect files ARE reliably captured/persist.
Prompt pattern:

> "... THEN, as your FINAL shell action, write your verdict to
> /tmp/<name>.txt — first line exactly 'VERDICT: PASS' or 'VERDICT: FAIL',
> then justification + numbered findings. Use:
> `printf '%s\n' 'VERDICT: ...' 'line2...' > /tmp/<name>.txt` . Then cat it."

Then `cat /tmp/<name>.txt` from the orchestrator after ccc exits. This
sidesteps the final-message routing entirely. Verified: produced a clean
`VERDICT: FAIL` (with 2 findings) and on the fixed SHA a clean `VERDICT: PASS`.

## Recommendations
- For any ccc/codex peer-PASS or structured-deliverable run invoked
  non-interactively, **always** request a file-write deliverable; never rely on
  the final chat message reaching captured stdout.
- Possible upstream fix to investigate: a ccc/codex non-interactive/exec flag
  that emits the last message to stdout (cf. codex `exec --output-last-message`).
  If ccc exposes such a flag, prefer it and update the `ccc-review-cx` skill.
- The `ccc-usage-prefs` memory ("no >log 2>&1 output-hiding") is unaffected —
  the file-write trick is an *additional* deliverable, not output hiding; full
  ccc output still streams to the task output file.

## Context
Discovered during the c2c-watch TUI build (B0 peer-PASS). Codex's review was
genuinely valuable — it found two HIGH-severity terminal-teardown signal-race
windows the inline workflow verifiers missed — so capturing its verdict
reliably matters.
