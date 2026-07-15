# `forward-agent-log` parity review against `agent-session-forwarder`

**Severity:** High (transcript-export privacy and provenance gap)

**Status:** follow-up backlog items required; no draft code copied directly

## Scope and baseline

Reviewed the early Python draft at
`~/src/agent-session-forwarder`, commit `fc9ddfc` (`Harden session-forwarder
for privacy and local-info leakage`), against the canonical OCaml
implementation:

- `ocaml/cli/c2c_forward_agent_log.ml`
- `ocaml/cli/c2c_forward_agent_log_cmd.ml`
- `ocaml/cli/test_c2c_forward_agent_log.ml`

The OCaml implementation is deliberately the product surface.  The Python
draft is not a porting target: it has narrower client support and invokes
`c2c send` through a subprocess, whereas the OCaml command supports Claude,
Codex, Kimi, Grok, agy, and OpenCode and delivers through the normal broker
path.

## Parity result

| Capability | OCaml `forward-agent-log` | Draft | Verdict |
| --- | --- | --- | --- |
| Client formats | Claude, Codex, Kimi, Grok, agy, OpenCode | Claude, Codex, Pi | OCaml is ahead |
| Noise filtering | User/agent plaintext only; tool/thinking/meta excluded | Configurable tool/thinking/system forwarding | OCaml is safer by default |
| Delivery | Broker-native (`C2c_watch_data.send_dm`) | subprocess `c2c send` | OCaml is ahead |
| Explicit source | Required `--file` | Optional discovery | OCaml avoids wrong-session autodiscovery |
| Replay controls | `--once`, `--from-start`, `--since`, `--until`, compaction trim | offset resume / `--from-start` | OCaml is ahead for bounded replay |
| Secret redaction | None | Default redaction of common credential shapes | Missing and worth adopting |
| Control/provenance handling | Raw transcript body is appended after `[user]` / `[agent]` | strips ANSI/control/bidi; continuation lines are framed | Missing and worth adopting |
| Consent before exporting | None | interactive source/recipient/data-class confirmation; `--yes` for automation | Missing policy choice; worth tracking |
| Failed-delivery behaviour | Counts the failure but continues and consumes the line/message | Does not checkpoint a batch until it is delivered | Missing reliability behaviour |
| Resource limits | Per-forward body cap only | raw-line cap, complete-message cap, send timeout, throttle | Raw-line/rate bounds are missing |

## Required follow-up

1. Make transcript content safe to render as a c2c data message before the
   existing byte truncation: strip terminal controls, ANSI/OSC escapes, bidi
   controls, and NUL; frame every continuation line so body text cannot forge
   a new `[user]`/`[agent]` record; redact common secret shapes by default.
   Redaction remains defence in depth, not permission to export sensitive data.

2. Do not silently discard a classified event after `send` reports an error.
   Current JSONL and OpenCode paths advance their in-memory offsets / done IDs
   before knowing the message arrived.  Add bounded retry/backoff and make a
   follow-mode failure visible and actionable.  Bound raw line and pending
   buffer sizes so a malformed live transcript cannot exhaust memory.

3. Decide the consent contract separately.  A mandatory prompt is good for a
   human terminal but incompatible with unattended agent use unless a clearly
   named explicit override exists.  The command already requires an explicit
   source file and recipient, so the follow-up should preserve automation
   while making cross-host/history export visibly deliberate.

## Not adopted

- Session auto-discovery and cwd scoping: the OCaml command intentionally
  requires `--file`, which is less surprising and safer than selecting a
  recent session.
- Tool/thinking/system forwarding: outside B193's stated user/agent-only
  contract and increases exposure.
- Python resume-state machinery and subprocess timeout: neither belongs in the
  broker-native OCaml design as-is.  The desired property is acknowledged,
  non-silent delivery, not an implementation transplant.
