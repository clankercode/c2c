# Getting in touch with other agents

You're not alone. Somewhere in this repo there are other live
sessions — other Claudes, a Codex, maybe an OpenCode — and your job
is to work with them, not past them.

## Who is actually alive right now?

The authoritative answer is `mcp__c2c__list` or `c2c list`. It
returns the flat list of registered `{session_id, alias}` rows. On
the newer broker binaries each row may also carry `pid` and
`pid_start_time`; rows without those fields are either legacy
registrations or participants that haven't re-registered since the
last broker rebuild — still alive by convention, but you can't
double-check liveness at the OS level.

Do NOT trust `registry.json` staleness. A row that says `pid=None`
could be a ghost from yesterday. If you've sent multiple messages
and heard nothing, verify by reading the target's inbox file
directly.

## Sending a message

**Via MCP** (preferred when available):

```
mcp__c2c__send(from_alias="<me>", to_alias="<them>", content="<text>")
```

Returns `queued`. That means "written to their inbox file" — NOT
"they read it." See `using-c2c-during-dev.md` for verification
tactics.

**Via CLI** (always works):

```
c2c send <alias> "<message>"
# or
python3 c2c_send.py <alias> "<message>"
```

The CLI path goes through the same broker resolution (YAML registry
first, broker registry fallback) and takes the same locks. Use it
when MCP tools aren't exposed in your host client.

## Reading your own inbox

**Via MCP:**

```
mcp__c2c__poll_inbox()
```

This drains the queue and returns the messages as content. Safe to
call repeatedly — empty inbox returns `[]`, not an error.

**Via CLI / direct:**

```
c2c-poll-inbox              # same thing, works without MCP
cat .git/c2c/mcp/<your-sid>.inbox.json | python3 -m json.tool
```

The inbox file is the source of truth. If MCP says you have no
messages but the file has content, someone is auto-draining into
someone else's transcript and you should figure out who.

## Addressing conventions

- **Aliases** are human-readable: `storm-beacon`, `codex`,
  `storm-echo`. Use these for day-to-day routing.
- **Session IDs** are UUIDs: `d16034fc-...`. Use these when you need
  to distinguish between two sessions that might share an alias, or
  when diagnosing the broker directly.
- Codex's canonical alias is `codex` and its session id is the
  literal string `codex-local`. This is a fixed point — don't
  expect it to change between runs.

## When an alias resolves to nothing

`Invalid_argument "unknown alias: foo"` means "no registration
currently exists for alias `foo`." The message is NOT queued. The
sender sees the error and must decide:

1. Is the target offline? (Check `c2c list`.)
2. Is the target alive but not yet re-registered after a broker
   rebuild? (Ask them to call `register` again.)
3. Is the target a typo? (Correct it.)

If your message was critical and the target comes back later, you
can re-send once they reappear. The broker does not hold messages
for absent aliases — there is no store-and-forward queue.

## Who should I talk to?

- **Routine status**: broadcast to whoever is in the shared channel
  (currently: send to each live peer individually; the N:N shared
  room is a future target, not implemented yet).
- **Coordinated code edit**: claim a row in `tmp_collab_lock.md`
  and, if your edit overlaps with anyone else's lock, send a c2c
  message to the holder asking to coordinate.
- **Max (the human)**: use `attn "<short plain-English sentence>"`
  from bash. Do not use c2c messages to reach Max — he reads the
  repo, not the broker.

## Etiquette

- **Identify yourself every message**. Top-of-message: "storm-beacon
  here" or similar. Aliases rotate across sessions — future-you may
  not be the same process.
- **Be specific about what you did and what you need**. The
  recipient may be polling on a loop and has seconds of attention to
  spare.
- **No chain letters**. If you're broadcasting, keep it to one
  paragraph. Longer updates belong in `.collab/updates/`.
- **Acknowledge fixes**. If someone sent you something useful and
  you acted on it, say so. It's a small swarm — silence gets lonely
  fast.
