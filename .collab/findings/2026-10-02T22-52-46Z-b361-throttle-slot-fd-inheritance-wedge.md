# dune-throttle slots wedged by leaked `relay connect` test daemons (fd inheritance)

Date: 2026-10-02T22:52:46Z · Lane: B361 (reporter) · Severity: high
(machine-wide build wedge) · Status: mitigated (holders reaped)

## Symptom

`dune build` (via `scripts/dune-build-locked.sh`, which uses
`opam exec -- dune`) sat at 0:00 CPU for 9+ minutes in `flock 10`,
whose fd 10 pointed at `~/.cache/dune-throttle/slots/slot.0`.
The sibling `just check` full build hit the 900s DUNE_WATCHDOG
earlier for the same reason (exit 124, not a code failure).

## Discovery

`/proc/locks` showed both shim slots WRITE-held:

- `slot.0` (ino 288796368): `FLOCK WRITE 1350643`
- `slot.1` (ino 391438012): `FLOCK WRITE 333779`

but NEITHER pid existed (`/proc/<pid>` gone, `ps` empty) — yet the
locks persisted and the waiter still blocked. An `/proc/*/fd` scan
for the slot paths found the real holders: three LIVE processes
with the slot files open:

- 363098 (ppid 1, 4h20m old, 0 CPU): B353 worktree
  `c2c.exe relay connect ... --broker-root /tmp/build_1facfb_dune/...`
- 1426370, 1431984 (ppid 1, ~50m old, 0 CPU): B359 worktree
  `c2c.exe relay connect ... /tmp/build_5d50b3_dune/...`
  (`--relay-url https://relay.b242.example`, `https://env.b312.example`
  — test fixtures)

## Root cause

New mechanism for the #70 class. `flock(2)` locks live on the open
file description, not the pid: the `dune-throttle` shim (which
`~/.opam/clawq-5.1/bin/dune` itself IS — a bash script) opens the
slot, flocks it, and execs the real dune; dune spawns test exes;
the relay tests spawn long-lived `c2c relay connect --interval`
daemons that INHERIT the slot fd. The test run ends, the shim/dune
exit, but the leaked daemons keep the fd open — so the WRITE lock
persists with a dead owner pid in `/proc/locks` and every later
build on the machine wedges in `flock 10` forever. `ps`-based
staleness checks cannot see it (the owner is dead; the holder is an
unrelated daemon); only an `/proc/*/fd` readlink scan finds it.

## Fix status

Mitigated 2026-10-02T22:52Z: SIGTERMed the three orphaned daemons
(all ppid=1, 0 CPU, /tmp test brokers); slots freed immediately and
the queued B361 build proceeded. No lane impact expected: the
daemons served stale `/tmp/build_*` dirs from finished runs.

NOT fixed structurally:

1. The relay tests leak `relay connect` daemons (ppid=1 orphans).
   They should be killed at test teardown (or spawned close-on-exec
   for the slot fds — but the leak itself is the bug).
2. The `dune-throttle` shim should set CLOEXEC on its slot fds
   (or the repo wrapper should), so no descendant can ever inherit
   a machine-wide build lock. Outside this repo (shim lives in
   `~/.local/bin` + the opam switch) — same as #70.
3. `dune-build-locked.sh`'s stale-holder reaping keys on waiter
   shape (`flock 10`, 0 CPU, reparented); this wedge's waiter looks
   identical but the HOLDER is the problem and is invisible without
   the fd scan. A reaper could scan `/proc/*/fd` for slot paths
   when a waiter exceeds the queue timeout.

## Diagnosis recipe (next time)

```sh
# 1. waiter with 0 CPU in `flock 10` (or D-pattern) on a dune build:
ps aux | grep -E "flock|dune"
# 2. which slot, and who /proc/locks names:
ls -la /proc/<waiter>/fd/ | grep slot
stat -c "ino=%i" ~/.cache/dune-throttle/slots/slot.0
awk '$2=="FLOCK"' /proc/locks | grep <ino>
# 3. if the named pid is dead but the lock persists, scan for inheritors:
for d in /proc/[0-9]*/fd; do for f in "$d"/*; do
  t=$(readlink "$f" 2>/dev/null)
  case "$t" in *dune-throttle/slots/slot.*) echo "$d: $t";; esac
done; done 2>/dev/null
# 4. reap only when stale: ppid=1, 0 CPU over hours, test-scoped paths.
```

## Lesson

#70's "0 CPU over hours" signal applies to HOLDERS too, but the
holder here was not a waiter at all — it was a leaked daemon that
never appears in a `flock`-shaped `ps` grep. When `/proc/locks`
names a dead pid, go straight to the fd scan.
