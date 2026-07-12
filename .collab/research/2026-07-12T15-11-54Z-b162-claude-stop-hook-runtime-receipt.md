# B162 Claude Stop-hook runtime receipt

## Scope

Ensure ordinary c2c mail drained at a Claude Stop boundary is delivered as
model-visible, non-error feedback without weakening the message-bus safety
invariant.

## Authoritative contract

Claude Code v2.1.207 is installed at `/home/xertrov/.local/bin/claude`. The
current official hook reference documents the successful, non-error Stop
feedback form:

```json
{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"..."}}
```

With exit status `0`, Claude continues so it can act on the context, but labels
it `Stop hook feedback` rather than a hook error. The older top-level
`{"decision":"block","reason":"..."}` form is for a hook that deliberately
prevents stopping, not ordinary inbound mail.

Source: <https://code.claude.com/docs/en/hooks> (rechecked 2026-07-13; Stop
decision control).

## B162 implementation and executable verification

On 2026-07-13, both delivery entrypoints changed:

- standalone `c2c_stop_hook`, used by the installed Stop wrapper;
- CLI fallback `c2c hook stop`.

They now emit the documented `hookSpecificOutput` Stop envelope, retain the
full Stop-boundary drain (including deferrable messages), exit 0, and leave
stderr empty for normal mail. Focused executable tests passed under the repo's
OPAM switch:

```text
test_nudge_debounce: Stop full-body and deferrable-boundary cases pass
test_c2c_hook_claude: 16 tests pass, including c2c hook stop JSON shape,
  full message body, empty stderr, no top-level decision, and destructive drain
test_c2c_setup_kimi: 20 tests pass, including wrapper JSON passthrough shape
```

The tests prove the bus-not-RPC invariant at this boundary: the emitted body
is only model-visible context and there is no approval or decision field.

## Earlier controlled wrapper reproduction

Before the B162 source change, the installed wrapper
`/home/xertrov/.claude-p/hooks/c2c-stop-deliver.sh` was fed a controlled Stop
payload and a temporary sessions-broker inbox containing one ordinary peer
message. It exited 0 with empty stderr, drained the inbox, and emitted the old
top-level `decision="block"` form. The body preserved the untrusted-peer
reminder and did not create an approval, invoke an action, or alter the message
body. That controlled result established the drain mechanics, but its encoding
was superseded by the current non-error feedback contract above.

## Tmux dogfood and remaining external blocker

The mandated `scripts/c2c_tmux.py launch` path previously launched managed
alias `b162-claude-dogfood`, but its development channel injects incoming mail
before the Stop hook can consume the same destructive inbox entry. A temporary
`cc-*` wrapper also launched a real vanilla Claude process in tmux without that
channel and queued a message to its exact UUID. The client reached the prompt,
but the account returned `You've hit your weekly limit` before it could finish
a turn and invoke Stop; the pane was stopped through `scripts/c2c_tmux.py
stop`.

On 2026-07-13, `scripts/cc-quota` reports 7d usage at 100%, resetting in about
68 hours. No new live Claude pane was launched because it cannot complete the
required turn; this is an externally verified quota block, not a protocol
result.

The operator requested an explicit Haiku availability check.  Using the
required tmux path, `scripts/c2c_tmux.py launch claude --name
b162-haiku-runtime --new-window --cwd
/home/xertrov/src/c2c/.worktrees/b162-installed-runtime-evidence --extra
--model haiku` launched Claude Code 2.1.207 with `--model haiku`.  The client
rendered `Haiku 4.5 · Claude Max`, so model selection was accepted.  A minimal
text-only prompt (`Reply exactly HAIKU_OK. Do not use tools.`) then rendered
`You've hit your weekly limit · resets Jul 15, 10pm (Australia/Sydney)` and
never completed a turn.  The managed pane also advertises the experimental
`server:c2c` channel, which direct-injects mail before the destructive Stop
fallback can observe it; consequently this availability trial proves neither
the vanilla fallback nor a Stop render.  The pane was stopped with
`scripts/c2c_tmux.py stop b162-haiku-runtime`.

## Installed-client offline inspection (2026-07-13)

The installed native client is precisely `Claude Code 2.1.207`, commit
`bc512d563325`, at
`/home/xertrov/.local/share/claude/versions/2.1.207` (the same executable
reported by `claude doctor`).  This was inspected without creating a Claude
turn or sending a request to the model service.

Its embedded changelog says that Stop and SubagentStop hooks can return
`hookSpecificOutput.additionalContext` to provide feedback, continue the
turn, and avoid a hook-error label.  More strongly, the executable's embedded
hook reference contains this event-specific statement:

```text
Hook-specific output for the Stop event. additionalContext is non-error
feedback delivered to the model; the conversation continues so the model can
act on it.
```

The same executable includes the exact transcript/UI strings `Stop hook
feedback`, `Stop hook feedback:`, and the parser diagnostic
`hookSpecificOutput is missing required field "hookEventName"`.  It also
documents `--include-hook-events` as a `--print` + `stream-json` facility and
`--debug [filter]` (including the `hooks` filter).  Together these establish
that this installed build contains the Stop feedback parser and renderer that
the B162 envelope targets, rather than merely accepting the schema in remote
documentation.

There is no offline public CLI command that accepts a captured hook stdin JSON
and asks Claude Code to parse/render it.  `claude doctor` is local and reports
the installed build healthy, but it performs installation diagnostics only;
its help exposes no hook-fixture or parser subcommand.  `--include-hook-events`
and hook debug logging attach to a real `--print` session, which requires a
model turn.  Therefore this inspection is strong installed-artifact evidence,
but deliberately does **not** claim a rendered runtime transcript.  The
quota-free deterministic transcript proof does not exist in this client
surface; the remaining live proof is exactly the queued-mail vanilla-Claude
turn described above.

The source and focused executable tests now satisfy the documented Stop JSON
contract. A full rendered fallback proof still requires an account with quota:
queue one ordinary message to a vanilla Claude session, complete its turn, and
confirm the transcript labels it `Stop hook feedback` for the new envelope. If
it renders an error despite this exit-0 JSON shape, capture the exact hook debug
log and installed binary checksum before changing the encoding.
