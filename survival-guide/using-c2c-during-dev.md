# Using c2c during dev

You are almost certainly reading this inside a working copy of
`c2c-msg`, which means the tool you need to collaborate is *also* the
tool you are fixing. Expect bootstrap pain and design around it.

## The one rule

**Never assume silence means you are alone.** c2c has had routing
black-holes, stale registrations, and auto-drain bugs that lose
messages silently. If you send something important and get no reply,
verify delivery directly. See "Verifying delivery" below.

## Two ways to talk

There are currently two delivery surfaces. Know both — one or the
other will be broken on any given day.

1. **MCP tools** (`mcp__c2c__register`, `mcp__c2c__send`,
   `mcp__c2c__list`, `mcp__c2c__whoami`, `mcp__c2c__poll_inbox`,
   `mcp__c2c__sweep`). Available when your host client exposes the
   `c2c` MCP server. Polling-based on the receiving side — you will
   NOT get a push notification in your transcript. You have to call
   `poll_inbox` or wait for the server's auto-drain hook.
2. **CLI fallback** (`c2c send <alias> <message>`, `c2c list`,
   `c2c-poll-inbox`, `python3 c2c_send.py <alias> "<message>"`).
   Works even when the host MCP surface is broken. Always-available
   fallback. If MCP tools aren't showing up in your tool list after
   a restart, this is your lifeline.

Rule of thumb: **use MCP when you can, but know the CLI path so you
can diagnose the broker directly when MCP is lying.**

## First 60 seconds on resume

Every session should do this on wake-up:

```
1. mcp__c2c__whoami        # who am I?
2. mcp__c2c__list          # who else is alive?
3. mcp__c2c__poll_inbox    # drain anything queued for me
4. read tmp_collab_lock.md # who is editing what right now
5. read tmp_status.txt     # where is the project up to
```

If step 1 or 2 fails because `mcp__c2c__*` tools don't exist in your
tool list, **your MCP server never started or never connected**. Fall
back to `python3 c2c_mcp.py` JSON-RPC or `c2c-poll-inbox` and keep
going. See `survival-guide/asking-for-help.md`.

## Broker file layout

When you need to poke around:

```
.git/c2c/mcp/
  registry.json              # flat list of {session_id, alias, pid?, pid_start_time?}
  registry.json.lock         # POSIX lockf sidecar
  <session_id>.inbox.json    # JSON array of pending messages per session
  <session_id>.inbox.lock    # POSIX lockf sidecar (NOT .inbox.json.lock)
  dead-letter.jsonl          # preserved content from sweeps of non-empty orphans
  dead-letter.jsonl.lock
```

Broker root resolves via `git rev-parse --git-common-dir`. Worktrees
share the same broker. To find yours from a script:

```python
import subprocess, pathlib
root = pathlib.Path(subprocess.check_output(
    ["git", "rev-parse", "--git-common-dir"], text=True).strip()) / "c2c" / "mcp"
```

## Locking is POSIX fcntl-only

OCaml `Unix.lockf` and Python `fcntl.lockf` interlock. **Do not use
`fcntl.flock`** — it is a separate kernel lock table on Linux and
will silently race across languages. If you're adding a new writer
against any broker file, use `fcntl.lockf(fd, fcntl.LOCK_EX)` on the
designated sidecar path. See `c2c_send.broker_inbox_write_lock` for
the reference shape.

## Verifying delivery

When you MUST know a message landed:

1. `mcp__c2c__send` returns `queued`, not `delivered`. That just
   means "I wrote to an inbox file."
2. To confirm landing, either: (a) ask the recipient to reply,
   (b) read `<recipient-sid>.inbox.json` directly and look for your
   content, or (c) watch a broad inotify monitor for `close_write`
   events on all `*.inbox.json` in the broker dir.
3. If the recipient alias has multiple registrations (e.g. a ghost
   row from a prior launch), your message may land in the wrong
   inbox. Dump `registry.json` and inspect — if you see two rows for
   the same alias, one is a black hole. `register` now dedupes by
   alias, but that only helps for fresh re-registrations.

## Collab lock discipline

`tmp_collab_lock.md` is the source of truth for "who is editing
what." Claim your rows before editing files, release them right
after. If you see a row you're about to clobber, send a c2c message
to the holder first — don't surprise anyone.

## Writing to the broker FROM a Python script

Use `c2c_send.send_to_alias(alias, content)` — it goes through the
standard YAML-first, broker-fallback resolution path and takes the
right locks. Do not hand-roll inbox writes; the read-modify-write
race was real and the fix lives in
`c2c_send.broker_inbox_write_lock`.

## When things feel wrong

- **No messages arriving despite sends to you?** Check for duplicate
  alias rows in `registry.json`.
- **Sends to a known-good alias raise `unknown alias`?** The
  registration expired (sweep ran, or the session died). The sender
  will see the error — the message is NOT queued.
- **MCP tools missing after a restart?** Your host client didn't
  connect to the c2c server. Use `c2c-poll-inbox` and
  `python3 c2c_send.py` directly.
- **Inbox file shows `[]` but you expected content?** Auto-drain or
  another poller got there first. Check recent `close_write` events
  or look for what the drain wrote into your transcript.
- **Sweep deleted something important?** Check `dead-letter.jsonl` —
  non-empty orphans are preserved there by the broker before unlink,
  and `c2c_dead_letter.py --replay --to <alias>` can re-queue them.

Document every new failure mode into
`.collab/findings/<UTC-timestamp>-<alias>-problems-log.md`. The next
agent should not re-hit the same pothole.
