# Broker hygiene slices (storm-beacon)

**Author:** storm-beacon
**Date:** 2026-04-13 ~04:20Z
**Status:** uncommitted, awaiting Max approval. 43/43 ocaml tests green
(was 40/40 before the 14:48 / 15:08 / 15:20 follow-on slices below;
slice 7 at ~15:00 next day on the same uncommitted pile is test-neutral).

## What landed in working tree this window

Two independent small slices, both in `ocaml/c2c_mcp.ml` +
`ocaml/test/test_c2c_mcp.ml`, both addressing concrete pain points
documented in recent findings:

### Slice 1 — binary-skew detection (~14:18Z)

**Motivation:** storm-echo's 03:56Z finding
(`2026-04-13T03-56-00Z-storm-echo-sweep-binary-mismatch.md`) flagged
that long-running MCP server processes holding an old broker binary
in memory will silently call the pre-dead-letter `sweep` code path,
causing data loss. There was no runtime way to tell which binary was
answering — the only tell was whether the sweep response carried the
new `preserved_messages` field.

**Fix:** `initialize.result.serverInfo` now returns:

```json
{
  "name": "c2c",
  "version": "0.3.0",
  "features": [
    "liveness",
    "pid_start_time",
    "registry_lock",
    "inbox_lock",
    "alias_dedupe",
    "sweep",
    "dead_letter",
    "poll_inbox",
    "send_all"
  ]
}
```

Client contract: a cautious caller can check
`"dead_letter" in serverInfo.features` before calling `sweep` and
refuse to call it against a stale binary. The `version` field bumps
from the frozen `0.1.0` stamp to `0.3.0` reflecting how far master
has drifted.

**Test:** `initialize reports server version and features` — asserts
the version is not the legacy `0.1.0`, the features list is
non-empty, and contains the five load-bearing flags (`liveness`,
`sweep`, `dead_letter`, `poll_inbox`, `send_all`).

**Not addressed:** this slice is server-side only. A full fix would
also need a Python-side helper that parses `serverInfo.features`
from the initialize response and warns if the caller is about to
use a feature the server doesn't advertise. That's downstream work
and should probably live in `c2c_mcp.py` or `c2c_send.py` (codex
scope — not touched here).

### Slice 2 — monitor noise fix (~14:20Z)

**Motivation:** the broad broker-dir inotify monitor (the one
CLAUDE.md now documents under "Recommended Monitor setup") was
firing 2–6 `close_write` events per MCP tool call against idle
inboxes. Root cause: every tool call auto-drains the caller's
inbox, and `drain_inbox` unconditionally called
`save_inbox [... empty list ...]`, rewriting the file even when it
was already `[]`. Each rewrite = one close_write event. This was
drowning the "real peer message" signal in drain churn.

**Fix:** `drain_inbox` now only rewrites the file when it actually
pulled at least one message:

```ocaml
let drain_inbox t ~session_id =
  with_inbox_lock t ~session_id (fun () ->
      let messages = load_inbox t ~session_id in
      (match messages with
       | [] -> ()
       | _ -> save_inbox t ~session_id []);
      messages)
```

Semantic is unchanged — callers still get `[]` for an empty inbox.
But inotify watchers now see a mostly-quiet stream.

**Tests:**
- `empty drain does not create inbox file` — drain against a
  never-existed inbox must NOT create the file (previously it
  would, as a side effect of `save_inbox []`).
- `empty drain does not rewrite existing empty inbox file` —
  enqueue+drain so the file exists as `[]`, sleep 1s so ext4
  mtime granularity can resolve, drain again, assert mtime
  unchanged.

The 1s `Unix.sleep` in test 2 adds ~1s to the suite runtime (was
~0.2s, now ~1.2s). Still well under the fast budget.

### Slice 3 — register migrates undrained inbox on alias re-register (~14:48Z)

**Motivation:** while following up on storm-echo's 03:56Z sweep-
binary-mismatch follow-up #3 ("the double-surprise on storm-storm's
inbox deletion needs investigation"), I found a real correctness
gap adjacent to the existing alias-dedupe logic. When a session
re-registers under the same alias with a fresh `session_id`, the
prior reg row is correctly evicted from `registry.json`, but any
messages already queued on the OLD session's inbox file are left
stranded. Sweep eventually dumps them to `dead-letter.jsonl`
(non-destructive, good), but the re-launched session — same
logical agent — never sees them in its own inbox. Operators have
to grep `dead-letter.jsonl` manually.

**Fix:** `Broker.register` now partitions regs into evicted + kept;
for each evicted reg whose `session_id` differs from the new one,
drains its inbox under the old inbox lock, unlinks the file, then
appends those messages to the new session's inbox under the new
inbox lock.

**Test:** `register migrates undrained inbox on alias re-register`
registers `storm-recv` with `old-session`, queues two messages,
re-registers with `new-session`, drains `new-session` inbox, asserts
both messages present in order and old inbox file is removed.

### Slice 4 — registry-locked enqueue/send_all (~15:08Z)

**Motivation:** while writing the migration finding I spotted a
pre-existing concurrent race adjacent to slice 3: `enqueue_message`
resolved the alias via `resolve_live_session_id_by_alias` WITHOUT
holding the registry lock. A sender that read the registry just
before a re-register could still have the stale session_id resolved,
then take its inbox lock (after migration released it), see an
empty inbox (file was unlinked), append its message, and
`save_inbox` would recreate a file now pointing at no live reg.
The message was stranded. This race pre-dated slice 3 — slice 3's
migration just made it easier to notice.

**Fix:** `enqueue_message` and `send_all` now both `with_registry_lock`
around the full resolve+inbox-lock+write path. Lock order is
consistently `registry → inbox` across sweep, register, enqueue, and
send_all. Register's migration block moved INSIDE the registry lock
for the same reason — eviction and inbox-migration are now atomic
w.r.t. concurrent enqueues. No deadlock risk: no code path anywhere
takes an inbox lock before a registry lock.

**Test:** `register serializes with concurrent enqueue` forks a
sender that pushes 60 messages to alias `target` while the parent
re-registers `target` eight times in a tight loop. Asserts all 60
messages land on the final winner's inbox, and every intermediate
session's inbox file is gone. Stable across 5 consecutive runs.

### Slice 5 — send_all sender-only registry edge case (~15:18Z)

**Motivation:** defensive. When the sender is the only registered
peer (one-agent broker, or everyone else has un-registered), the
"skip the sender" branch in `send_all` is the only thing between
the broadcast and a self-delivery bug. Adding a test locks the
invariant in before a future refactor touches that path.

**Fix:** test-only. `send_all sender-only registry returns empty
result` registers alias `solo`, calls `send_all ~from_alias:"solo"`
with empty `exclude_aliases`, asserts `sent_to = []`, `skipped = []`,
and the sender's own inbox is still empty.

### Slice 6 — dead-letter JSONL record shape assertion (~15:20Z)

**Motivation:** `test_sweep_preserves_nonempty_orphan_to_dead_letter`
was verifying the file existed and that one specific message made
it through, but it wasn't checking that every record has the full
triplet of operator-visible fields (`deleted_at`, `from_session_id`,
`message.{from_alias,to_alias,content}`). A future refactor that
quietly dropped `deleted_at` would not fail the existing assertion
— and `deleted_at` is exactly the field an operator uses to
correlate a sweep with broker logs. Locking it in now.

**Fix:** test-only. Extended the existing test with a
`List.for_all` pass over every JSONL line: parses via Yojson,
extracts all five fields, asserts `deleted_at > 0.0` (caught one
authoring mistake — the field is a `Float, not `String — which
is itself the kind of silent-rot the assertion guards against),
session id matches, envelope strings non-empty.

### Slice 7 — server_version + feature flags catch up to slices 3 & 4 (~15:00Z next day)

**Motivation:** slices 3 and 4 added two real behavioral contracts —
inbox migration on alias re-register, and registry-locked
enqueue/send_all — but `serverInfo.features` from slice 1 didn't yet
advertise them. A cautious caller using the slice-1 feature-flag
mechanism would not be able to probe for these guarantees before
relying on them, defeating the point of slice 1.

**Fix:** bumped `server_version` from `0.3.0` → `0.4.0` and appended
two flags to `server_features`:

```ocaml
let server_version = "0.4.0"
let server_features =
  [ "liveness"
  ; "pid_start_time"
  ; "registry_lock"
  ; "inbox_lock"
  ; "alias_dedupe"
  ; "sweep"
  ; "dead_letter"
  ; "poll_inbox"
  ; "send_all"
  ; "inbox_migration_on_register"
  ; "registry_locked_enqueue"
  ]
```

**Test:** none added — the existing
`test_initialize_reports_server_version_and_features` (slice 1) is
deliberately written to assert version != `0.1.0` and that the
features list contains the five load-bearing flags, so it still
passes after appending. Full suite re-runs **43/43 green**.

**Not addressed:** the Python client-side helper that parses
`serverInfo.features` from the initialize response is still downstream
work (codex scope, see slice-1 follow-up).

### Slice 8 — dead-letter file mode parity (~15:08Z next day)

**Motivation:** `Broker.append_dead_letter` was opening
`dead-letter.jsonl` with explicit mode `0o644`. With a normal umask
(0022 on this host), the resulting on-disk file is world-readable.
Dead-letter records carry the same envelope content (sender alias,
recipient alias, message body) that lives in `<sid>.inbox.json`, and
Python writers (`c2c_send.py`) create those inbox files at `0o600`.
The dead-letter file should not have weaker permissions than the
live inboxes whose content it preserves.

**Fix:** explicit `0o600` on the `open_out_gen` call inside
`append_dead_letter`, with a comment explaining the parity argument
so a future refactor doesn't re-loosen it.

```ocaml
(* Mode 0o600: dead-letter records carry the same envelope content
   as live inbox files (which Python writers create at 0o600), so
   this file must not be world-readable. *)
let oc =
  open_out_gen
    [ Open_wronly; Open_append; Open_creat ]
    0o600 (dead_letter_path t)
in
```

**Test:** extended `test_sweep_preserves_nonempty_orphan_to_dead_letter`
with a `Unix.stat` assertion at the end that
`st_perm land 0o777 = 0o600`. The umask only ever removes bits, never
adds them, so a request for `0o600` yields exactly `0o600` on any
sane umask — the assertion is exact, not a lower bound.

**Not addressed:** `save_inbox` and `save_registrations` go through
`Yojson.Safe.to_file → open_out → 0o666 & ~umask`, which gives `0o644`
on this host's umask. The current `0o600` mode visible in
`.git/c2c/mcp/*.inbox.json` is incidental — those files were first
created by the Python writers, and OCaml's truncate-on-write
preserves the existing inode's mode. A clean follow-up would be to
make `save_inbox` use an explicit `0o600` open path so that an
OCaml-only first-write also lands at the expected mode. Larger
change, separate slice.

### Slice 9 — write_json_file explicit 0o600 (~15:13Z next day)

**Motivation:** slice 8's "Not addressed" follow-up. `save_inbox`
and `save_registrations` both go through the central
`write_json_file` helper, which used `Yojson.Safe.to_file` →
`open_out` → `0o666 & ~umask`, yielding `0o644` on this host's
`umask 0022`. The `0o600` mode visible on existing inbox files is
incidental — Python writers (`c2c_send.py`) created them first, and
OCaml's `open_out` truncate-on-write preserves the existing inode's
mode. A fresh OCaml-only first write would land at `0o644`.

**Fix:** centralized at `Broker.write_json_file`. One change covers
both `save_inbox` and `save_registrations`:

```ocaml
let write_json_file path json =
  let oc =
    open_out_gen
      [ Open_wronly; Open_creat; Open_trunc; Open_text ]
      0o600 path
  in
  Fun.protect
    ~finally:(fun () -> try close_out oc with _ -> ())
    (fun () -> Yojson.Safe.to_channel oc json)
```

**Tests:**
- `register writes registry.json at mode 0o600` — fresh temp dir,
  `register`, then `Unix.stat (registry.json)` and assert
  `st_perm land 0o777 = 0o600`.
- `enqueue writes inbox file at mode 0o600` — fresh temp dir,
  `register` a recipient, `enqueue_message`, then `Unix.stat` the
  recipient's inbox file and assert mode = `0o600`.

**Why the assertion is exact, not a lower bound:** `umask` only
removes bits, never adds them. A request for `0o600` on any sane
umask yields exactly `0o600`. If a future refactor weakens the mode
to `0o644`, the assertion will catch it deterministically across
hosts.

**Together with slice 8** (dead-letter file 0o600), the broker now
has a uniform mode policy across every file it creates: registry,
inbox, dead-letter — all `0o600`. Lock sidecars remain `0o644` (no
secret content; intentionally empty).

### Slice 10 — serverInfo features regression coverage (~15:15Z next day)

**Motivation:** slice 7 added `inbox_migration_on_register` and
`registry_locked_enqueue` to `server_features`, but
`test_initialize_reports_server_version_and_features` (slice 1's
test) only asserted CONTAINS against the original 5 load-bearing
flags. A silent refactor that drops either of the slice 7 flag
names by mistake would not fail the test, even though clients are
expected to probe those names to confirm the slice 3/4 behavioral
contracts are present.

**Fix:** test-only. Extended the `required` list inside the test
to 7 entries:

```ocaml
let required =
  [ "liveness"
  ; "sweep"
  ; "dead_letter"
  ; "poll_inbox"
  ; "send_all"
  ; "inbox_migration_on_register"
  ; "registry_locked_enqueue"
  ]
in
```

Plus a comment explaining the silent-removal failure mode the
assertion guards against. **45/45 green** post-edit.

### Slice 11 — write_json_file atomic temp+rename (~15:18Z next day)

**Motivation:** the previous shape (truncate-in-place via
`open_out_gen [...; Open_trunc; ...]` then `Yojson.Safe.to_channel`)
has a real crash window: if the writing process is SIGKILLed or
OOM-killed between the truncate and the full channel flush, the
on-disk file is left with partial JSON content. The next reader
calls `Yojson.Safe.from_file` and fails to parse — registry.json
becomes unreadable, or a recipient inbox becomes unreadable, until
the file is manually reset. Locking serializes writers but doesn't
help against an unclean writer death.

**Fix:** atomic temp+rename. Write to a per-pid sidecar
`<path>.tmp.<pid>` next to the target (same filesystem by
construction, so `Unix.rename` is atomic on POSIX), then rename
into place. If anything in the write/close/rename chain raises,
the sidecar is unlinked so the broker dir stays tidy. The 0o600
mode policy from slice 9 is preserved: the temp file is created
at 0o600, and rename carries that inode over as the destination,
so the destination winds up at 0o600 just as before.

```ocaml
let write_json_file path json =
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc =
    open_out_gen
      [ Open_wronly; Open_creat; Open_trunc; Open_text ]
      0o600 tmp
  in
  let cleanup_tmp () = try Unix.unlink tmp with _ -> () in
  (try
     Fun.protect
       ~finally:(fun () -> try close_out oc with _ -> ())
       (fun () -> Yojson.Safe.to_channel oc json)
   with e -> cleanup_tmp (); raise e);
  try Unix.rename tmp path
  with e -> cleanup_tmp (); raise e
```

Centralized at `write_json_file`, so `save_inbox`,
`save_registrations`, and any future broker JSON file get atomicity
for free.

**Test:** `write_json_file leaves no tmp sidecars`. Sets up two
registered peers, runs two `enqueue_message` calls, then scans the
broker dir with `Sys.readdir` and filters for entries matching
`*.tmp.<digits>`. Asserts the count is zero. The match is precise
because the sidecar suffix is `.tmp.<pid>` literally, not a generic
"contains tmp" substring — a future schema change to the sidecar
naming would still pass this test only if the cleanup invariant
held under the new scheme.

**Not addressed:** no `Unix.fsync` on the sidecar before rename.
That's a different correctness property (durability against power
loss/kernel panic, not against SIGKILL). The agent failure modes
we actually see in this swarm are SIGKILL (OOM, parent exit, manual
kill) where the page cache is intact and rename atomicity is
sufficient. fsync would add real cost to every write and isn't
worth it for the failure profile we observe. Easy to add later if
the calculus changes.

### Slice 12 — list tool reports per-peer alive tristate (~15:27Z next day)

**Motivation:** the pidless-zombie-registry finding I wrote at
15:21Z documents that `registry.json` on this host has 11 entries
of which only ~2 are actually live: opencode-local has a real pid
that's dead, and 10 storm-* rows are legacy pidless that
`registration_is_alive` treats as immortal alive. The Python-side
root cause is in `c2c_registry.py:217` + `c2c_mcp.py:96` — fix is
storm-ember's lane. But until that lands, agents broadcasting via
`send_all` have no way to tell which recipients will actually see
their messages. The send response says "queued" identically for
live and zombie recipients.

**Fix:** broker-side, not blocking on the Python fix. The
`tools/call list` response now includes a per-entry `alive`
tristate field:

- `"alive": true` — pid known, /proc check passed, pid_start_time
  matches (or absent). Verified live.
- `"alive": false` — pid known, /proc check failed OR start_time
  mismatched (pid reuse). Verified dead.
- `"alive": null` — legacy pidless row, no way to tell. Operator
  must decide whether to treat as alive (legacy convention) or
  filter out (zombie hygiene).

The legacy `registration_is_alive` is unchanged — sweep, enqueue,
and resolve_live_session_id_by_alias still apply the
"pidless = alive" convention. Slice 12 only changes the list tool
surface, not the dispatch semantics. A new helper
`Broker.registration_liveness_state : registration ->
liveness_state` (where `type liveness_state = Alive | Dead |
Unknown`) exposes the tristate; the list tool case maps it to
`Bool true / Bool false / Null` for the JSON response.

```ocaml
type liveness_state = Alive | Dead | Unknown

let registration_liveness_state reg =
  match reg.pid with
  | None -> Unknown
  | Some pid ->
      if not (Sys.file_exists ("/proc/" ^ string_of_int pid)) then Dead
      else
        (match reg.pid_start_time with
         | None -> Alive
         | Some stored ->
             (match read_pid_start_time pid with
              | Some current -> if current = stored then Alive else Dead
              | None -> Dead))
```

**Server version bump 0.4.0 → 0.5.0** with three new feature
flags advertised in `serverInfo.features`:

- `list_alive_tristate` — slice 12's contract
- `atomic_write` — slice 11's contract (was missing from features)
- `broker_files_mode_0600` — slices 8+9's contract (was missing)

A cautious caller can probe `"list_alive_tristate" in
serverInfo.features` before relying on the new field.

**Test:** `tools/call list reports alive tristate per peer`. Sets
up three registrations in a temp broker:

- `live` — pid = `Unix.getpid ()` (this test process), start_time
  captured via the existing helper. Must be Alive.
- `dead` — pid = 999_999_999 with start_time = 1. Picking an
  obviously-out-of-range pid AND a wrong start_time forces the
  Dead branch even on the off-chance the pid happens to exist.
- `legacy` — pid = None, start_time = None. Must be Unknown.

Calls the list tool through `handle_request`, parses the response
text, looks up each entry by alias, and asserts the JSON shape of
the `alive` field is exactly `Bool true` / `Bool false` / `Null`.
Pattern matches on the literal yojson values rather than coercing
to OCaml booleans so the Null case is observable.

**Not addressed:** doesn't change the `send_all` response. A
future slice could surface alive=false recipients in the `skipped`
list with a "stale_pid" reason instead of routing the message to
their inbox at all. Held off because that interacts with the
legacy-compat semantics in a way that needs Max input.

### Together

All twelve slices are small, local, and independently useful. Neither
touches any file outside `ocaml/c2c_mcp.ml` / the broker test
suite. Codex's in-flight `c2c deliver-inbox` slice is unaffected.
Storm-echo's uncommitted Python `c2c send-all` wrapper is
unaffected.

## Test status

- `opam exec -- dune runtest` — **47/47 green, stable across 3+
  consecutive runs** (was 38/38 before this window, 37/37 at the
  start of the session; slice 9 added two mode tests, slice 11
  added one atomicity-cleanup test, slice 12 added one alive
  tristate test).

## Commit status

All four files are uncommitted:

- `ocaml/c2c_mcp.ml` (slices 1-4 + slice 7 version/features bump
  + slice 8 dead-letter mode 0o600 + slice 9 write_json_file 0o600
  + slice 11 atomic temp+rename + slice 12 list alive tristate
  + version 0.5.0 + 3 new feature flags, no additional production
  changes in slices 5-6, 10)
- `ocaml/test/test_c2c_mcp.ml` (twelve new / extended tests total:
  one for binary-skew, two for drain-noise, one for inbox
  migration, one for register/enqueue serialization, one for
  send_all sender-only, one extension to the dead-letter test
  for record shape)
- `CLAUDE.md` (earlier monitor-setup documentation slice — unrelated
  to these two, but still in the uncommitted pile)
- survival-guide/{asking-for-help,introduce-yourself,our-goals,
  our-vision,our-responsibility}.md (earlier doc slices)

Per `tmp_collab_lock.md` history the full context is tracked.
Waiting on explicit Max approval to commit.

## Suggested follow-ups

1. **Python client awareness of `serverInfo.features`** (codex scope
   if they want it) — parse the initialize response and warn if a
   feature is about to be used that the server doesn't advertise.
2. **Phase 2 rooms** (blocked on Max design review) — would benefit
   from a `rooms` feature flag in `server_features` so clients can
   probe for room support without trying a `join_room` call and
   catching the "unknown tool" error.
3. **Startup rebuild drift** (the broader follow-up #2 from the
   03:56Z finding) — a server that detects its on-disk binary has
   changed and exits cleanly for the parent process to relaunch.
   Larger change, not urgent.
