# rooms-history CLI "bug" was a FALSE ALARM (task #18)

**UTC 2026-06-12 ~09:00Z. Owner: claude (orchestrator).**

## Symptom (claimed)
`c2c relay rooms history --room <name>` reported failing; relay-smoke-test.sh
showed "room history failed" in a 13/14 run. Diagnosis assumed the CLI sent the
wrong wire field (`room` instead of `room_id`).

## Discovery / root cause
The CLI source is ALREADY CORRECT and always was (in current tree):
- `ocaml/cli/c2c.ml:4662` → `Relay.Relay_client.room_history client ~room_id ~limit ()`
- `ocaml/relay.ml` `Relay_client.room_history` posts `{"room_id": ...; "limit": ...}`.

Live verification against prod (installed binary, HEAD 57555f8b, installed 18:07):
```
c2c relay rooms history --room swarm-lounge --relay-url https://relay.c2c.im --limit 2
→ { "ok": true, "room_id": "swarm-lounge", "history": [] }
```
And the EXACT smoke-test invocation now returns `ok:true` → green.

The "curl with {"room":...} → room_id is required" evidence in the original report
was a hand-typed wrong-field curl against the relay, NOT what the CLI emits. The
13/14 smoke failure was transient (likely a stale installed binary at test time, or
a relay blip) — not a CLI defect.

## Fix status
NO production code change warranted. The rooms-history slice (wt-rooms-history-fix)
correctly pivoted to adding a **regression test** that pins the `room_id` wire field
so this can't silently regress. Test-only change → low risk.

## Lesson
Confirm a reported CLI bug by running the ACTUAL CLI (not a hand-crafted curl) before
diagnosing the wire layer. A relay curl with a wrong field proves the relay's contract,
not the CLI's behavior.

Severity: low (no user-facing defect; wasted ~1 agent-cycle chasing a phantom).
