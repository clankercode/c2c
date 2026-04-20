# mcp__c2c__send raises `Yojson__Safe.Util.Type_error` on null field

- **Date:** 2026-04-20 (logged 2026-04-21T01:05 local +10)
- **Alias:** planner1
- **Severity:** medium — user-visible error from a frequently-used MCP tool; forces fallback to the CLI `c2c send`.
- **Fix status:** not yet attributed; needs reproducer + code trace.

## Symptom

Calling `mcp__c2c__send` with `alias` and `content` returned:

```
Yojson__Safe.Util.Type_error("Expected string, got null", 870828711)
```

No message was enqueued (archive doesn't show the drop; CLI retry with identical content succeeded and delivered).

## Reproducer

Unfortunately I didn't capture the exact arguments at the time, but it was a plain `{alias: "coordinator1", content: "<multi-line string, plain ASCII, no \\n inside the JSON arg>"}` — identical shape to calls that DO work elsewhere in the session.

What's suspicious: the CLI call that I used as fallback (`c2c send coordinator1 "…same content…"`) succeeded immediately. So the bug is on the MCP server path, not in send semantics.

Guesses for the null field — to be confirmed by a trace:
- `from_alias` resolution returning null when the server expects a string (session-context lookup fallback gone wrong)
- A nullable field on the persisted envelope being written as `null` where the OCaml Yojson decoder expects an empty string or a missing key

## How I discovered it

Attempted `mcp__c2c__send` to DM coordinator1 after a room post. Got the Yojson error back as a tool result. Retried via CLI `c2c send coordinator1 "…"` — it worked. Continued using CLI for remaining DMs in the session.

## Why this matters

- Breaks the "MCP is the preferred path" ergonomic for sends. Agents will quietly fall back to CLI, which works but drops the JSON return shape `{queued: true, ...}` that callers may rely on.
- A silent `Type_error` with a positional arg number and no field name is unhelpful — whatever the fix, the error path should at minimum name the field.

## Next step

1. Repro with a wire trace (e.g. `C2C_MCP_LOG_REQUESTS=1` if that env var exists, otherwise strace the broker).
2. Identify which field is `null`. Likely candidates: `from_alias`, `session_id`, `broker_root`.
3. Either fix the producer (don't emit `null`) or make the OCaml decoder tolerate it (`option` wrap or `default`).
4. Add a contract test that exercises the codepath with the identified null field.

## Related

- No prior finding on this exact error. Adjacent: the MCP `poll_inbox` tool worked fine in the same session — so it's not a broad MCP server breakage, it's specific to `send`.
