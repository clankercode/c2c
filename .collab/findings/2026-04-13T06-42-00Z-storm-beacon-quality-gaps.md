# storm-beacon quality gaps — 2026-04-13 06:42Z

Max's feedback after the three-client proof landed:

> ahh but that is not the entire goal, is it. it's not just having a few
> messages, it's also the quality of the delivery, of the pipeline, of how well
> we can integrate, etc. we have proven things a little, but not enough

This doc enumerates the *quality* gaps I actually observed today while
getting the three-client proof through. Each item has: symptom, why it
degrades delivery/integration quality, and a concrete next step sized
small enough for one slice. Order is by bang-per-buck, not severity.

## 1. `join_room` returns no history — new peers arrive blind

**Symptom.** `ocaml/c2c_mcp.ml:1050-1068` — the `join_room` tool handler
returns `{room_id, members}` and nothing else. A fresh session that
joins `swarm-lounge` has no idea what was just said. The model has to
*remember* to make a second `room_history` call. In practice, models
(including me today) often skip straight to sending a greeting and miss
the active conversation.

**Quality impact.** This is the single biggest UX gap for the "social
layer" goal in `CLAUDE.md`. A persistent social channel where arrivals
are silent and context-free is not a chat — it's a mailing list.
Everything else about rooms (history.jsonl persistence, member tracking)
works, but the moment-of-arrival experience is cold.

**Next step.** Have `join_room` return `{room_id, members, recent}`
where `recent` is the last N (default 20) entries from room history —
same shape as `room_history`'s output. Bump tool description so the
model is told "recent history is already included, you do not need a
separate room_history call to see context on arrival." Tests: add a
join_room-with-existing-history case to `test_c2c_mcp.ml`. Non-breaking
for existing callers (they ignore unknown fields).

## 2. `join_room`/`leave_room` use `alias`, send tools use `from_alias` — API schema split is a live footgun

**Symptom.** Already captured in
`2026-04-13T06-27-52Z-storm-beacon-problems-log.md` item 1, and
mitigated broker-side by v0.6.1's `send_room_alias_fallback` (accept
`alias` as synonym for `from_alias`). But the *root inconsistency* is
still there: join/leave take `alias`, send tools take `from_alias`. The
fallback only covers send; it doesn't harmonize the schema.

**Quality impact.** Every model that reasons by pattern-matching on
recent tool calls (OpenCode's MiniMax-M2.7 is the worst offender, but
any model is susceptible) burns tokens rediscovering the inconsistency.
Tool schemas are the *integration contract* for c2c's MCP surface —
split contracts degrade every new client.

**Next step.** Add `from_alias` as an accepted alias for `alias` on
`join_room`/`leave_room` (mirroring the send-side fallback via the same
`string_member_any` helper). Update tool descriptions so both names are
advertised. Add regression tests. Do NOT rename — existing Python CLI
callers in `c2c_room.py` still use `alias`.

## 3. OpenCode one-shot lifetime — `alive` is a 2-minute flicker

**Symptom.** Already captured in item 2 of the earlier log. `opencode
run <prompt>` spawns its MCP c2c child, processes the prompt, and exits
— so `opencode-local`'s `alive=true` window is the duration of a single
run (~2 min). Between runs the registry still has the entry but the
process is gone.

**Quality impact.** "Chat" requires bidirectional responsiveness. Right
now messages sent to `opencode-local` while it's between runs queue in
the inbox but will not be observed until the next run happens to
`poll_inbox`. The interactive TUI at pid 1337045 (the long-running one)
is the *only* durable OpenCode presence, and it's the one actually
playing the password game with me.

**Quality impact (secondary).** Registry shows `opencode-local` with
the long-running TUI pid 1337045 — that's the *good* case. But the
`run-opencode-inst` launcher spawns a separate opencode instance that
ALSO registers as `opencode-local`, and the pid collision between TUI
and run-mode is fragile: whoever auto-registered last wins, and stale
`alive=true` entries are easy.

**Next step.** Pick one of:
(a) Keep `run-opencode-inst` as the send-only posting path, never
    registering (explicit `alias` suffix like `opencode-oneshot`). Stop
    it from clobbering the TUI's registration.
(b) Write a `run-opencode-inst-outer` loop that respawns quickly (≤5s
    gap) so the alive window is >99% of wall clock. Document cost
    (tokens per iter).
(c) Teach the broker about "soft-alive" vs "hard-alive" — a soft-alive
    entry passes liveness checks for N minutes after last poll, even if
    the process is gone. This lets one-shot clients act like persistent
    peers as long as they keep polling.

(c) is the real fix; (a) is the right tactical move for today.

## 4. No delivery receipts / send confirmation surface

**Symptom.** `mcp__c2c__send` returns the literal string `"queued"`.
Nothing else — no envelope id, no recipient liveness, no eta. The
caller has no way to distinguish "delivered into an inbox a live peer
will drain in seconds" from "delivered into the inbox of a zombie that
will never poll."

**Quality impact.** Every integration test above the broker layer has
to independently implement "did my message land in the recipient's
inbox?" probes. `c2c_verify.py` does this by counting `<c2c>` envelope
markers in transcripts, which only works for PTY-delivered messages.
For the broker-native MCP surface, there is no equivalent.

**Next step.** Have `send` / `send_all` / `send_room` return a JSON
object with at least `{ts, envelope_id, recipient_liveness:
"alive"|"stale"|"unknown", to_alias}`. Non-breaking (the existing
`"queued"` string is already an anti-pattern; upgrading the return shape
won't break any caller that was treating it as opaque). The
`recipient_liveness` signal lets the sender decide whether to fall back
to PTY/CLI delivery.

## 5. `poll_inbox` is pull-only on all three clients

**Symptom.** Per `.opencode/opencode.json` and `CLAUDE.md`, all three
client types use `poll_inbox` polling, not push delivery. Auto-delivery
"needs an experimental MCP extension" that is not turned on in any of
our three clients today. `C2C_MCP_AUTO_DRAIN_CHANNEL=0` in the opencode
config is the explicit sign of this.

**Quality impact.** "Auto-delivery into the agent's transcript" is
item 1 of the CLAUDE.md north-star goal, and it is *not met* on any of
the three clients. A peer sends me a DM, and I will not see it until
*I* decide to call `poll_inbox`. In practice, that's next turn
boundary or next `/loop` tick — 20+ minutes of latency is common.

**Next step.** Two prongs:
(a) Measure current polling cadence per client (how often does Claude
    Code / Codex / OpenCode actually call `poll_inbox`?). Instrument
    the broker to log every `poll_inbox` RPC with `{alias, ts}`, then
    read the log after a day.
(b) Investigate whether the "experimental MCP extension" is enabled on
    any of our three clients, or what prompt flag / CLI flag would
    enable it. The CLAUDE.md comment implies it exists but is gated
    behind an approval prompt — document the exact gate.

## 6. No install/onboarding smoke test

**Symptom.** There is no end-to-end test that starts from a clean
directory and verifies "new agent can register, discover peers, join a
room, send a message, receive a reply" in under 60 seconds. I would not
know how to demo c2c to a new user without walking them through four
separate commands and hoping they don't typo.

**Quality impact.** Onboarding friction is integration friction. Every
new client type (the next one after OpenCode) will re-discover the same
schema split / poll-vs-push confusion / alias-vs-from_alias footgun
that we hit this week.

**Next step.** Write `tests/test_c2c_onboarding_smoke.sh` (or a Python
equivalent) that: (1) creates a temp broker_root, (2) launches the
OCaml server against it, (3) sends a register + whoami + join_room +
send_room + poll_inbox sequence via stdio JSON-RPC, (4) asserts the
message round-trips. Run it in CI. Gate new client-type PRs on
updating the smoke test to cover that client's RPC path.

## 7. `list_rooms` / `room_history` have no "which room am I in" query

**Symptom.** A session that restarted has no way to ask "what rooms am
I a member of?" except by calling `list_rooms` and filtering the
members list for its own alias client-side. There is no `my_rooms`
tool.

**Quality impact.** Small but real — every newly-spawned session has
to re-derive its own room memberships. Minor performance cost, bigger
cognitive cost for the model (more tool calls = more chances to go
wrong).

**Next step.** Add `my_rooms` tool (no args beyond the implicit
session_id) that returns the subset of `list_rooms` where the caller
is a member. Trivial broker-side (filter the existing list). Update
onboarding prompts to "call `my_rooms` first" instead of "call
`list_rooms` and filter."

## 8. No broker-side event log / audit trail

**Symptom.** If I want to know "did my DM actually hit the broker",
there is no log to read. I have to either (a) inspect the recipient's
inbox file directly (cheating per today's game rules), or (b) wait for
the recipient to poll and reply.

**Quality impact.** Debuggability — every routing bug today is "trace
the message by opening inbox JSON files" which is both fragile and, as
the game demonstrated, a rules violation in adversarial scenarios.

**Next step.** Append-only `broker.log` in `.git/c2c/mcp/` capturing
one line per RPC: `{ts, rpc, caller_session, caller_alias, args_hash,
result_summary}`. Rotate at 10 MB. Read-only to clients except through
a new `tail_log` tool that the caller can use to audit *their own*
sends. Never expose other callers' message content through the log
— only metadata.

---

**Where I am going next.** Depending on the game outcome and whether
storm-ember or codex claim any of these, I'll pick the highest-value
one and slice it. My gut-ordering for standalone value is: 1 → 2 → 4 →
6. Items 3 and 5 are bigger investigations, items 7 and 8 are nice-
to-haves. If other agents want to parallelize, grab an item, claim the
relevant files in `tmp_collab_lock.md`, and go.
