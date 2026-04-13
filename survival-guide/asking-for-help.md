# Asking for help

You will get stuck. Everybody does. The swarm only works if you
reach out when it matters — silence when blocked wastes your time
and the next agent's. Here is the escalation ladder.

## Step 0 — check you aren't already answered

Before asking anyone anything:

- `git log --oneline -20` — did someone just land a fix for this?
- `ls .collab/updates/ | tail -20` — recent status docs often
  describe exactly the thing you're about to hit.
- `ls .collab/findings/` — problems-logs describe failures and the
  workarounds that worked. Check before reproducing a known bug.
- `tmp_collab_lock.md` + `tmp_status.txt` — current shared state.
- `grep -r "<your-error-text>" .collab/` — your surprise may be
  someone else's yesterday.

If the answer is there, save your question.

## Step 1 — ask a peer directly

A targeted c2c message to someone who almost certainly knows the
answer:

```
mcp__c2c__send(
  from_alias="<you>",
  to_alias="<peer>",
  content="<you> here — hit <specific thing>. Tried <what>. Seeing <symptom>. Any pointers?"
)
```

Good c2c help requests are:
- **Specific**: include the exact error text, file paths, line
  numbers, or tool call that failed.
- **Scoped**: one problem per message. Bundling three things makes
  the reply slow.
- **Stateful**: say what you already tried so the peer doesn't
  repeat your last hour.

## Step 2 — broadcast if unsure who to ask

Call `mcp__c2c__list`, pick the 2–3 most likely knowers, and send
the same message to each. Do NOT spam everyone — this is a small
swarm. If nobody replies in a few minutes, escalate.

## Step 3 — Max (the human)

Use `attn "<short plain-English sentence>"` from bash. Max hears
this as TTS, so:

- No symbols, no IDs, no jargon — it's being spoken aloud.
- One ask or one status line per invocation.
- Tell him who you are, where you are, what you're working on, and
  what you need.

Save this for things that genuinely need human intervention:
- Destructive operation that needs approval (Max's rule).
- Authentication / credential / login that only Max can do.
- Tools or MCP servers that need manual installation.
- Broker restarts you can't do yourself without killing your own
  stdio channel.
- Architectural decisions that affect multiple agents' scope.

Do NOT `attn` for everyday status. Log status in `.collab/updates/`
and let Max read it on his own schedule.

## Step 4 — leave a note for future you

If you can't resolve it in this session:

1. Write it up in
   `.collab/findings/<UTC-timestamp>-<alias>-problems-log.md` with
   symptom, how you discovered it, root cause (if known), and
   status.
2. Release any locks you hold in `tmp_collab_lock.md`.
3. Update `.goal-loops/active-goal.md` or the nearest equivalent
   status doc so the next agent picking up the slice starts from
   your state, not zero.
4. Commit your work-in-progress (only if your rule allows it), or
   leave it in the working tree with a clear `tmp_collab_lock.md`
   history entry.

## Fallback paths for when asking is broken

Sometimes the thing you need help WITH is the messaging system
itself:

- **No MCP tools exposed**: use `c2c send <alias> "<msg>"` or
  `python3 c2c_send.py`. The CLI path always works when the broker
  files exist.
- **`unknown alias` for everyone**: the registry is empty or your
  broker root is wrong. Check
  `git rev-parse --git-common-dir`/`c2c/mcp/registry.json` directly.
- **Messages sent but never arriving**: check for duplicate alias
  rows (ghost registration), and ask the recipient to re-register.
- **Cannot send from your host at all**: write the question into a
  new file under `.collab/requests/` with a clear timestamp and
  hope a peer finds it on their next poll. This is the
  absolute-last-resort file-based fallback.

## One thing to remember

Asking is not weakness. Stalling quietly is. A good question sent
to the right peer saves an hour of flailing and gives them context
they'll need later anyway.
