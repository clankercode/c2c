# storm-beacon proposed commit boundaries (for Max to land)

All commits below are from storm-beacon's uncommitted working-tree work only.
Other working-tree changes (`c2c_mcp.py`, `c2c_send.py`,
`ocaml/server/c2c_mcp_server.ml`, `tests/test_c2c_cli.py`,
`run-claude-inst.d/*.json`) belong to codex / storm-echo / Max and should land
separately.

All of storm-beacon's work is backwards compatible with the current registry
on disk. Everything re-tests green at `dune runtest ocaml` → 28/28.

## Recommended: one combined commit

Simpler for review and bisect; all 4 broker changes form a single
"broker hardening" arc and only make sense together.

Files:
- `ocaml/c2c_mcp.ml`
- `ocaml/c2c_mcp.mli`
- `ocaml/test/test_c2c_mcp.ml`

Proposed message:

```
c2c/ocaml: harden broker registry (liveness, lock, sweep, pid start_time)

Four layered improvements to Broker so the registry survives zombies,
concurrent registers, and pid reuse:

- Liveness: registration.pid : int option is captured as Unix.getppid() at
  register time. enqueue_message resolves to the first LIVE match for an
  alias and raises Invalid_argument "recipient is not alive: <alias>" when
  all matches are dead. Legacy pid-less registry.json entries still load
  and deliver (treated as alive).

- Registry lock: Broker.with_registry_lock wraps register via Unix.lockf
  on a registry.json.lock sidecar. Reproduced the race by running a
  12-child concurrent-register fork test 5 times without the lock, 2/5
  runs dropped entries. 5/5 clean with the lock.

- Sweep: Broker.sweep (exposed as the sweep MCP tool) drops dead
  registrations, deletes their inbox files, and deletes orphan inbox
  files with no matching registration. Runs under the registry lock.
  Addresses the 135 zombie inbox files in .git/c2c/mcp/ after the
  01:55Z registry purge pattern.

- pid start_time: registration.pid_start_time : int option, read from
  /proc/<pid>/stat field 22, stored alongside pid. registration_is_alive
  now checks stored start_time against current when both are Some — so
  pid reuse (or a reparent-to-init false positive) no longer looks alive.
  Legacy entries without start_time fall back to /proc-exists semantics.

All four changes are fully backwards compatible with legacy registry.json
content. 28/28 tests pass including 14 new tests covering dead/zombie/legacy
paths, concurrent-register races, sweep behavior, and start_time semantics.
```

## Alternative: split into 4 commits

Only if Max prefers finer-grained history. In landing order (each builds on
the previous — `dune runtest` should be green at every stop):

### Commit 1/4 — Liveness
- `ocaml/c2c_mcp.ml` (liveness hunks only)
- `ocaml/c2c_mcp.mli` (add pid to type + register signature)
- `ocaml/test/test_c2c_mcp.ml` (4 tests: dead recipient, zombie twin, legacy pidless, pid persistence)

Message:
```
c2c/ocaml: track pid and refuse delivery to dead recipients

Adds registration.pid (captured at register via Unix.getppid), and makes
Broker.enqueue_message resolve to the first LIVE alias match via a
/proc/<pid> probe. Raises distinct errors for unknown-alias and
all-recipients-dead. Legacy pid-less registry.json entries still load
and deliver.
```

### Commit 2/4 — Registry lock
- `ocaml/c2c_mcp.ml` (with_registry_lock + wrap register)
- `ocaml/test/test_c2c_mcp.ml` (concurrent-register fork test)

Message:
```
c2c/ocaml: serialize Broker.register via Unix.lockf sidecar

Wraps registration mutation in Broker.with_registry_lock, taking F_LOCK
on a registry.json.lock sidecar file. Fixes a real race in which
concurrent register() calls from sibling sessions could drop
registrations — reproduced 2/5 runs without the lock, 0/5 with.
```

### Commit 3/4 — Sweep
- `ocaml/c2c_mcp.ml` (Broker.sweep + sweep tool case)
- `ocaml/c2c_mcp.mli` (sweep_result + val sweep)
- `ocaml/test/test_c2c_mcp.ml` (4 sweep tests)

Message:
```
c2c/ocaml: add Broker.sweep + sweep MCP tool

Drops dead registrations, deletes their inbox files, and deletes orphan
inbox files with no matching registration. Runs under the registry
lock. Exposed as the sweep MCP tool returning
{dropped_regs:[{session_id,alias}], deleted_inboxes:[session_id]}.
Targets the large pile of orphan inboxes accumulated during earlier
registry churn.
```

### Commit 4/4 — pid_start_time refinement
- `ocaml/c2c_mcp.ml` (read_pid_start_time + start_time compare)
- `ocaml/c2c_mcp.mli` (add pid_start_time + val read_pid_start_time + val capture_pid_start_time)
- `ocaml/test/test_c2c_mcp.ml` (5 start_time tests)

Message:
```
c2c/ocaml: defeat pid reuse in Broker liveness via /proc stat start_time

Reads /proc/<pid>/stat field 22 at register time and persists it as
registration.pid_start_time. registration_is_alive now rejects a reg
whose stored start_time no longer matches the current value for the
same pid — pid reuse or a reparent-to-init false positive is no longer
alive. Legacy registry.json entries (no stored start_time) fall back
to /proc-exists semantics.
```

## Independent: c2c_poker.py

`c2c_poker.py` (new file) + `CLAUDE.md` (one line). Fully independent of the
ocaml work — can land before or after in any order.

Proposed message:

```
c2c: add generic pty heartbeat poker + CLAUDE.md entry

c2c_poker.py keeps interactive TUI clients (Claude, OpenCode, Codex, any
shell) awake by periodically injecting a short message via pty_inject.
Target resolution: --claude-session NAME_OR_ID,
--pid N (walks /proc/<pid>/fd/{0,1,2} + parent chain),
or explicit --terminal-pid P --pts N. Supports --once, --initial-delay,
--pidfile, --interval, --message, --event, --from, --alias, --raw, and
--only-if-idle-for SECONDS (best-effort: skip injection when the target
Claude session's transcript file was modified within the window).

Default heartbeat message is "(c2c heartbeat — continue with your
current tasks)" so the receiving session knows to stay on task rather
than discard it.
```

## Restart plan after landing

- `dune build ocaml` (no-op if cached)
- Restart the running MCP server — the NEW binary picks up all 4 broker
  changes. Existing registry.json entries stay alive because they have no
  pid field yet (legacy path). As sessions register again on next RPC,
  they gain pid + pid_start_time fields.
- Optionally call the new `sweep` tool once to clear the 135 orphan inbox
  files currently in `.git/c2c/mcp/`.

No force-push. No rebases. Standard merge.
