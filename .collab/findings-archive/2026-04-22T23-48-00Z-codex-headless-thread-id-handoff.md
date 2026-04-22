# Managed `codex-headless` thread-id handoff report

> Archived as superseded.
> The underlying issue was fixed in the Codex-headless managed launch path
> and the remaining startup race was logged separately in
> `.collab/findings/2026-04-22T23-05-00Z-current-session-codex-headless-startup-readiness-race.md`.

# Managed `codex-headless` thread-id handoff does not fire under c2c-style launch

## Summary

When `codex-turn-start-bridge` is launched through `c2c start codex-headless`, inbound XML messages are drained from the broker and written into the managed XML pipe, but the bridge never writes a `thread_id` handoff and the managed session never persists `resume_session_id`.

The same bridge binary **does** write `thread_id` handoffs in direct probes with:

- `--thread-id-fd 3`
- `--thread-id-fd 5`
- plain XML payloads
- the exact nested c2c payload:
  `<message type="user"><c2c ...>...</c2c></message>`
- a long-lived writer that remains open after the first XML frame

So the blocker appears to be specific to the managed launch/wiring shape, not to the XML grammar itself.

## Expected

For the first inbound XML `<message type="user">...</message>` delivered into a managed `codex-headless` session:

1. the bridge should read the message from stdin
2. the bridge should call `start_or_resume_thread`
3. the bridge should emit one JSON line on `--thread-id-fd`
4. `c2c` should persist that `thread_id` into `resume_session_id`

## Actual

In the managed `c2c start codex-headless` path:

- broker inbox drains successfully
- archive entry is written
- XML spool clears
- outer wrapper / bridge / deliver daemon can remain alive
- `thread-id-handoff.jsonl` stays empty
- `resume_session_id` stays `""`

## Repro shape

Managed path:

```bash
c2c start codex-headless -n headless-A
```

Delivery sidecar for that managed session:

```bash
python3 c2c_deliver_inbox.py \
  --client codex-headless \
  --session-id headless-A \
  --loop \
  --broker-root <repo>/.git/c2c/mcp \
  --xml-output-fd 4 \
  --pid <bridge-pid>
```

Bridge argv:

```bash
codex-turn-start-bridge \
  --stdin-format xml \
  --codex-bin codex \
  --approval-policy never \
  --thread-id-fd 5
```

## Important comparison

Direct probes succeed:

```bash
timeout 15s bash -lc '
  printf "<message type=\"user\"><c2c event=\"message\" from=\"self\" alias=\"self\" source=\"broker\" reply_via=\"c2c_send\" action_after=\"continue\">ping</c2c></message>\n" |
  codex-turn-start-bridge \
    --stdin-format xml \
    --codex-bin codex \
    --approval-policy never \
    --thread-id-fd 5 \
    5>/tmp/thread-id.jsonl
'
```

This produces:

```json
{"thread_id":"...","source":"started"}
```

The same is true when the writer remains open after the first XML frame.

## c2c-side fixes already attempted

These were real c2c bugs and are already fixed:

- skip tty foreground handoff for `codex-headless`
- file-backed thread-id handoff path
- avoid closing the target fd when `dup2(src, target)` is a no-op
- use a real peer sender in the E2E instead of self-send

After those fixes, the remaining failure persisted.

## Current hypothesis

There is still a Codex-side bug or unexpected assumption in the managed-launch shape, where the bridge never reaches or never completes the `emit_thread_resolved()` path under this c2c-style stdin/sideband arrangement, despite handling the same payloads correctly in direct probes.

## Useful context from bridge behavior

The bridge currently blocks in `read_xml_prelude_from_reader()` until it sees the first `<message>`. That part is expected. The problem is that, in the managed path, even after a real peer message has been delivered and archived on the c2c side, the thread-id handoff file remains empty.

## What would help most upstream

One or more of:

1. a reproducible explanation for why `emit_thread_resolved()` is not reached in this managed launch shape
2. additional logging around:
   - stdin XML prelude consumption
   - `start_or_resume_thread`
   - `emit_thread_resolved`
3. a small bridge-side regression test covering:
   - inherited stdin pipe
   - inherited file-backed `--thread-id-fd`
   - long-lived open writer
   - nested inner XML payload
