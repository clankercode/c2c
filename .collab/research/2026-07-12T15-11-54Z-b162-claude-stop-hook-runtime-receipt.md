# B162 Claude Stop-hook runtime receipt

## Scope

Determine whether ordinary c2c Stop-hook delivery is being emitted as a
Claude Code hook error, without weakening the message-bus safety invariant.

## Authoritative contract

Claude Code v2.1.207 was installed at `/home/xertrov/.local/bin/claude` on
2026-07-12. Its current official hook reference documents the Stop event as
supporting the top-level successful JSON response
`{"decision":"block","reason":"..."}`: exit status must be `0`, and the
reason continues the conversation as model-visible feedback. A non-zero exit
causes a hook error instead; plain stdout is not the Stop delivery channel.

Source: <https://code.claude.com/docs/en/hooks> (checked 2026-07-12).

## Controlled installed-runtime reproduction

The installed wrapper `/home/xertrov/.claude-p/hooks/c2c-stop-deliver.sh` was
fed a controlled Stop payload and a temporary sessions-broker inbox containing
one ordinary peer message:

```text
stdin:  {"session_id":"b162-runtime-controlled","hook_event_name":"Stop"}
result: exit=0
stdout: one JSON object with decision="block" and the c2c envelope in reason
stderr: empty
inbox:  []
```

The reason retained the normal untrusted-peer reminder. It did not create an
approval, invoke an action, or alter the message body. This is the supported
delivery form and preserves c2c's bus-not-RPC invariant.

## Tmux dogfood attempts

Used the mandated `scripts/c2c_tmux.py launch` path to launch managed alias
`b162-claude-dogfood`, completing the local MCP and development-channel consent
prompts, then stopped it with `scripts/c2c_tmux.py stop`. The managed launcher
enables Claude's experimental c2c channel, which injects incoming mail before
the Stop hook can consume the same destructive inbox entry; therefore it could
not exercise the Stop fallback with a live queued message. The controlled run
above exercised the exact installed Stop wrapper and binary instead.

To test the fallback itself, a temporary `cc-*` wrapper launched a second real
Claude v2.1.207 process in the same tmux pane without the development-channel
arguments. A message was successfully queued to its exact UUID through
`c2c send --session`. The client reached the prompt, but the account returned
`You've hit your weekly limit` before it could complete a turn and invoke the
Stop hook. The session was stopped via `scripts/c2c_tmux.py stop`.

## Conclusion and remaining blocker

No current source or installed-wrapper protocol violation reproduced. The
controlled installed-hook result satisfies the executable side of the current
Claude contract, and regression coverage now checks exit 0 with empty stderr
while draining both normal and deferrable messages at the Stop boundary.

However, a full Claude-rendered fallback result is still blocked by the local
Claude weekly usage limit. Do not mark B162 done until a Claude account with
available usage repeats the queued-message turn and confirms that the reason
appears as a continuation rather than `Stop hook error:`. If it does render an
error despite the recorded exit-0 JSON shape, capture the exact hook debug log
and installed binary checksum before changing the delivery encoding.
