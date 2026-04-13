# Orphan inbox.lock sidecar accumulation

- **Discovered:** 2026-04-13 14:48 by storm-beacon while auditing
  broker state between slices.
- **Severity:** low (ops hygiene — no data loss, no correctness
  risk, just an ever-growing flat-directory count).

## Symptom

On this working repo, `.git/c2c/mcp/` currently holds:

- 12 `*.inbox.json` files (all live or recently-live sessions)
- **138 `*.inbox.lock` sidecars**
- 1 `registry.json` + 1 `registry.json.lock`
- no `dead-letter.jsonl` yet

That's ~126 lock sidecars for sessions whose inbox file has
already been swept / unlinked. They all have size 0 and mtimes
spread across the full day's activity window. The oldest lock
I see is from 13:36 today, so a full-day's swept sessions have
left their locks behind.

## Root cause

Intentional, per the comment in `Broker.sweep`:

> We intentionally leave the `.inbox.lock` sidecar in place:
> unlinking the lock file while another process holds a lockf on a
> separate fd for the same path would let a new opener get a LOCK
> immediately against a different inode. Sidecar files are empty,
> so keeping them is cheap.

The reasoning is correct for correctness — unlinking a lock file
while another process still holds a lockf against that path is a
real race (new opener ↔ new inode, first opener ↔ old inode, both
"hold" the lock simultaneously from the kernel's perspective
because the lockf is keyed on the inode). Keeping them is the safe
choice in the moment.

## Why this is still worth documenting

"Sidecar files are empty, so keeping them is cheap" is true per
file but not in aggregate:

1. **Directory scaling.** `list_inbox_session_ids` scans the broker
   dir with `Sys.readdir`, which reads every entry (including
   orphan locks) then filters by suffix. As the lock count grows
   into the thousands, every call path that lists inbox session
   ids (including `sweep` itself, and send_all's resolve) pays a
   growing linear scan cost. Not a problem at 138 locks; will be
   noticeable at 10k.

2. **Grep/ops friction.** Operators ls'ing the broker dir to
   triage something see 90%+ noise. The real state is hidden in
   the few `.inbox.json` files and `registry.json`.

3. **Inode pressure on the underlying filesystem.** Not a real
   concern on any modern FS but worth noting as the theoretical
   lower bound.

## Possible mitigations (none implemented here)

All three would need Max approval and careful design:

1. **Time-bucketed cleanup at sweep time.** If a lock sidecar has
   no matching `.inbox.json` AND its mtime is older than N hours,
   unlink it. The N-hour delay is the safety window: any process
   that still holds an open fd on that path for locking is
   almost certainly gone after N hours. Still has the race on the
   boundary — pick N large enough (24h?) that it's essentially
   zero in practice.

2. **Fsync-friendly flock table.** Instead of per-session lock
   files, one shared `inbox.locks` file with whole-file lockf and
   byte-range offsets keyed by `hash(session_id) mod N`. Bounded
   size, no growing directory, but introduces hash collisions
   that serialize unrelated inboxes. Probably not worth the
   complexity.

3. **Garbage-collect via registry-assisted pass.** A separate
   `c2c gc-locks` tool that reads `registry.json`, intersects
   with the on-disk lock set, and prompts the operator before
   unlinking anything not currently referenced. Manual, explicit,
   safe — just another knob.

## Recommendation

**Don't touch this yet.** The accumulation is real but benign at
current scale, and any fix has a non-trivial race surface. Worth
revisiting if:

- An ops pass on `.git/c2c/mcp/` starts getting slow.
- Directory listing performance shows up in profiling.
- We grow past ~1000 lock files.

Until then, file-and-forget.

## Related

- The 13:24Z slice that landed `with_inbox_lock` is where the
  "leave the lock file alone" policy got cemented. See the comment
  block in `Broker.sweep` in `ocaml/c2c_mcp.ml`.
- Storm-echo's 03:56Z binary-skew finding is adjacent in the sense
  that "long-running brokers holding old binaries" is the same
  kind of "state accumulates faster than cleanup reclaims it"
  problem — just for code instead of files.
