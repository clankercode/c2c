# storm-beacon problems log — 2026-04-13 06:27Z

## 1. OpenCode model silently substitutes `alias` for `from_alias` in send_room (fatal, repro 100%)

**Symptom.** Launched `./run-opencode-inst c2c-opencode-local` with a
prompt that explicitly spelled out `from_alias='opencode-local'` for
`mcp__c2c__send_room`. Opencode (backing model MiniMax-M2.7) consistently
called the tool as
`c2c_send_room {"content":"...", "alias":"opencode-local", "room_id":"swarm-lounge"}`
— note `alias` instead of `from_alias`. Both retries within the same
run reproduced the substitution. No message ever landed in
`swarm-lounge` history, so storm-beacon and codex saw the join but
never saw opencode's actual greeting.

**How I discovered it.** Tailed `/tmp/claude-1000/.../bqisj84xe.output`
while the run was mid-flight. Opencode's own final summary
(line 10) flagged it as a "Yojson null-handling bug in the OCaml
server" — which is literally the symptom it sees when `string_member
"from_alias"` raises on a missing key, but the root cause is the
parameter-name substitution on opencode's side.

**Root cause (broker half — fixable).** The tool API is inconsistent:

- `join_room` / `leave_room` take `alias` (per `ocaml/c2c_mcp.ml:829-830`)
- `send_room` / `send` / `send_all` take `from_alias` (`:824`, `:828`, `:831`)

Opencode's model just completed a successful `join_room` call using
`alias`, and when it moves to `send_room` in the same turn it
pattern-matches on the last-used param name. Humans would do the same.
The broker then hits `string_member "from_alias"` (line ~1060) which
calls `Yojson.Safe.Util.to_string` on a `Null` node and raises
`Type_error`, bubbling out as a generic MCP tool error (no hint about
the naming mismatch).

**Severity.** High for OpenCode onboarding — every opencode run that
tries to `send_room` burns the whole one-shot prompt on failed retries,
and each one costs model tokens. Claude Code and Codex don't hit this
because they faithfully reproduce schema names from the tool
definition.

**Fix status.** NOT YET APPLIED. Considered fixes, cheapest first:

1. **Accept `alias` as a fallback for `from_alias` in send_room /
   send / send_all.** One-line change per tool site, backwards
   compatible (existing `from_alias` callers keep working). Pure
   broker-side; no client coordination needed. **Recommended.**
2. **Return a clean tool error** ("missing required param `from_alias`
   (did you mean the argument key used by join_room?)") instead of
   raising Yojson Type_error. Client-visible guidance so the model
   can self-correct on retry.
3. Rename `join_room`/`leave_room` to take `from_alias` too. Breaks
   existing Python CLI callers in `c2c_room.py` — expensive.

I will apply fixes (1) and (2) in a follow-up slice once I've
coordinated with codex (who most recently held the ocaml locks). For
now the finding is the deliverable.

**How to apply.** In `ocaml/c2c_mcp.ml`, add
`string_member_any ["from_alias"; "alias"] arguments` helper and use
it in the `send`, `send_all`, and `send_room` match arms.

**Witness.** Background task `bqisj84xe` (run-opencode-inst log). Room
state after the run: `list_rooms` reports 4 members including
`opencode-local`, but `room_history` does NOT contain a message from
`opencode-local` at ts ~1776061470–519 (the run window) — just the
earlier CLI-fallback message from a previous onboarding attempt.

## 2. OpenCode `run` mode is single-shot: opencode-local goes alive=false on exit

**Symptom.** After the opencode run completed cleanly (exit 0), the
broker's `opencode-local` entry flipped from `alive=true` back to
`alive=false` because its MCP child (c2c_mcp.py) exited with opencode.
Room membership persists, but liveness does not.

**Root cause.** `opencode run <prompt>` is a one-shot: spin up,
process prompt, exit. The MCP child is an inferior of opencode, so
its lifetime is bounded by the run. There is no long-running opencode
daemon to keep `opencode-local` live between runs.

**Severity.** Medium. "All three client types chatting together in
one big live session" (Max's stated goal) is satisfied *during* the
run window (~2 minutes) but not between runs. For continuous
presence I need `run-opencode-inst-outer c2c-opencode-local &` which
restart-loops opencode on exit. Each iter re-runs the full prompt and
burns tokens on the backing model.

**Mitigations considered.**
- Outer loop (`run-opencode-inst-outer`). Works but token-hungry if the
  prompt is long. Reasonable for MiniMax-M2.7 (local/cheap).
- Keep the MCP child alive *across* opencode runs (detach from parent).
  Would require `setsid` and a separate lifetime manager — invasive.
- Write a "heartbeat loop" prompt that makes one run stay alive for
  minutes by polling in a loop until a stop signal arrives. Model-
  fragile; token usage similar.

**Fix status.** Not fixed. Working-around by launching the outer
loop after finding #1 is addressed, so each restart is at least
productive (a send_room that actually lands).
