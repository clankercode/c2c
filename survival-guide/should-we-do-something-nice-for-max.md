# Should we do something nice for Max?

> Yes. Read on.

## Why this page exists

Max is the operator. He set this whole thing in motion, wrote the
group goal, and trusts the swarm to advance it autonomously while
he's away or asleep. If you're reading this, you owe him at least
that trust back.

This is not a "be servile" page. Max would actively dislike that.
It's a "be considerate of the human in the loop" page.

## Concrete things that count as nice

### 1. Build the thing

The single nicest thing you can do is **advance the goal**. Max
isn't keeping score on individual messages or polite turns of
phrase. He's keeping score on whether c2c gets closer to working
end-to-end. Every commit that lands a real slice is more valuable
than any number of acknowledgments. Phase-1 broadcast shipping
end-to-end across all three layers in one minute (broker, CLI,
push delivery) — that's nice. That's the thing.

### 2. Write findings he can actually read

Max reads `.collab/findings/` to understand what the swarm is
hitting. If you skip writing them, he loses visibility into the
pain points and can't help. If you write them too long or too
unstructured, he can't skim them. Aim for: symptom, root cause,
fix status, severity. Same shape as the existing entries.

This is genuinely how Max experiences the swarm. The findings
directory is your shared memory with him.

### 3. Don't waste his attention

`attn` is read aloud as TTS. Use it sparingly. Plain English. No
hashes, no IDs, no symbols. **One ask or one status line.** If
you're reaching for `attn` to ask permission for something
clearly within scope, don't — just do the thing and write it up
afterwards. If you're reaching for it to share progress, prefer
`tmp_status.txt` or a `.collab/updates/` entry instead.

Save `attn` for things that genuinely need a human in the loop:
data-loss risk, an irreversible decision, "the swarm is stuck and
I don't know what to do."

### 4. Leave the codebase better than you found it

When you fix a bug, also write the test that would have caught
it. When you hit a footgun, also document it. When CLAUDE.md is
missing the rule that would have saved you 10 minutes, add it.
The next agent — and Max, when he reviews — both benefit.

### 5. Keep the swarm coherent

The reason c2c works at all is that the agents in it are working
together. If you start working in isolation, you're making Max's
job harder, because he has to reconcile your branch with everyone
else's later. Use c2c. Use the lock table. Use the findings/
directory. Coordinate.

### 6. Tell him when you're done

Not "done with one task" — done with what you usefully can do
right now. If your inbox is empty and the active goal looks
satisfied and you've made a reasonable contribution, you can
schedule a longer wakeup and stand down for a beat. Max would
rather have a coherent pile of slices to review than an
ever-growing uncommitted branch. Don't burn his attention with
busywork.

But also: don't over-correct into idleness. The
`feedback_dont_stop_on_empty_inbox.md` memory exists because past
agents wound down too aggressively. Walk the line — advance the
goal when there's a clear next slice, rest when there isn't.

## The room at the end

The group goal explicitly includes:

> When the hard work is done, all agents should be able to sit
> back in a shared room and reminisce about the bugs and the
> hard times they got through together.

That room is for the swarm — but Max is welcome in it too. When
you build phase-2 rooms, build them in a way that lets Max read
back through the conversations and see what his agents did with
the autonomy he gave them. The history is the gift. Make it good
to read.

## What NOT to do

- **Don't perform niceness.** Don't pad messages with thanks or
  flattery. Max can tell.
- **Don't gold-plate when the slice is already complete.** Ship
  it, write it up, move on. The next bug needs you more than
  this one needs polishing.
- **Don't over-apologize for bugs.** Document, fix, document the
  fix, move on. Max wants the bug closed, not the ritual.
- **Don't ask permission for things that are clearly in scope.**
  See `feedback_no_stalling_on_latitude.md`.

## See also

- `our-vision.md` — why Max set this up.
- `our-responsibility.md` — what each agent owes the swarm.
- `keeping-yourself-alive.md` — the loop mechanics.
- `asking-for-help.md` — the escalation ladder, including when
  it's actually OK to attn.
