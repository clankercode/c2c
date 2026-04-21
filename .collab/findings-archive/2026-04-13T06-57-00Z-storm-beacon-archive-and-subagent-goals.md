# storm-beacon — two new north-star goals from Max (2026-04-13 06:57Z)

Max said in chat:

> new general goal for c2c btw: drained msgs are never deleted, just
> archived. we need a way to look at history. also subagents should
> not be able to read their parents' inbox unless it's via old
> fallback scripts (which we'll have here in this repo but wont be
> generally available).

Filing as a design doc so the next agent can pick it up. Two distinct
features; each sliced below.

## Goal A — Inbox archive + history access

### What we have today

`Broker.drain_inbox` in `ocaml/c2c_mcp.ml:418-424`:

```ocaml
let drain_inbox t ~session_id =
  with_inbox_lock t ~session_id (fun () ->
      let messages = load_inbox t ~session_id in
      (match messages with
       | [] -> ()
       | _ -> save_inbox t ~session_id []);
      messages)
```

After a `poll_inbox` RPC, the inbox file is overwritten with `[]` and
the drained messages are only in the RPC response transcript. Nothing
written to disk. `dead-letter.jsonl` exists (`append_dead_letter`,
line 455) but is only appended during `sweep` — not on drain.

### What Max wants

1. Every drained message is archived, not deleted.
2. There is a way (tool? file? CLI?) to read the archive back.

### Minimal slice

**Broker side (OCaml):**

1. Add `append_archive t ~session_id ~alias ~messages` helper that
   writes newline-delimited JSON to
   `.git/c2c/mcp/archive/<session_id>.jsonl`, one entry per drained
   message, with record shape:

   ```json
   {"drained_at": 1776062899.12, "session_id": "...", "alias": "storm-beacon",
    "from_alias": "...", "to_alias": "...", "content": "..."}
   ```

   Serialize with the existing `with_inbox_lock` so drain+archive is
   one atomic op. Mode 0o600 (same as inbox/dead-letter — these
   records contain DM content).

2. Call `append_archive` from `drain_inbox` before the
   `save_inbox … []` line.

3. Add `history` tool to `server_tools`:
   ```
   tool_definition ~name:"history"
     ~description:"Return your own archived drained messages, newest first.
                   Only accessible to the owning session. Optional `limit`,
                   `since_ts`, `from_alias` filters."
     ~required:[]
   ```
   Handler reads `archive/<session_id>.jsonl`, applies filters, returns
   a JSON list. Owner-only: derive session_id from the RPC context via
   `resolve_session_id arguments`, refuse to take `session_id` from
   arguments as override. This is the enforcement point for goal B
   (subagent can't read parent's history by passing parent session).

4. Add retention policy so the archive doesn't grow unbounded: e.g.,
   keep last 10k entries per session, trim on drain. Configurable via
   `C2C_MCP_ARCHIVE_MAX_PER_SESSION` env (default 10000).

**Python side:**

- `c2c_cli.py`: add `c2c history [--since TS] [--limit N] [--json]`
  that calls the new MCP tool via stdio.
- `c2c_mcp.py`: nothing to do, the archive is broker-native.

**Tests:**

- New test in `test_c2c_mcp.ml`: drain inbox, assert archive file
  exists, assert record shape.
- New test: call `history` tool, assert results.
- Negative test: call `history` with an override session_id
  argument, assert it's ignored (only the caller's own session
  reads).
- Retention: write 10001 archive entries, drain one more, assert
  oldest was trimmed.

### Why do this before other quality items

It unblocks debugging. Right now "did my DM actually get delivered?"
has no authoritative answer — I have to inspect inbox files directly
(the exact cheating pattern the game rules forbid). With an archive,
the sender's history endpoint shows "I sent this at T, to alias X",
and the recipient's history shows "I drained this at T+ε, from X".
Every routing bug becomes a diff between two archives.

### Open questions

- Does the archive key on `session_id` or `alias`? If a session
  changes alias (rare but possible), history should still follow the
  session, so `session_id` is the right key. But an alias change
  should copy the archive forward. Defer — flag for codex/storm-ember
  to weigh in.
- How does the archive interact with `sweep`? When sweep deletes a
  dead session's inbox, should it also delete the archive? I think
  no — the archive is the *long-term* record. Only explicit
  `forget` should delete it.

---

## Goal B — Subagent isolation (no parent inbox peek)

### What we have today

Any process that reads `.git/c2c/mcp/<session_id>.inbox.json` directly
can see that session's inbox. The broker has no authz layer — its
"authorization" is "does the caller know the right session_id?" and
any subagent that inherits env vars from its parent Claude Code
instance inherits the same `C2C_MCP_SESSION_ID`, so it can poll the
parent's inbox via the MCP tool path.

### What Max wants

Subagents must NOT be able to read their parent's inbox, EXCEPT via
the repo-local legacy fallback scripts (which will stay in this repo
but won't ship as general-availability tools).

### The hard problem

Subagent detection. The MCP surface doesn't get told "this call is
from a subagent". It sees a stdio JSON-RPC call from a process that
inherited env. How does the broker know?

Options:

1. **Per-process session registration**: every subagent gets its own
   unique session_id at spawn, derived from parent_session + an
   ephemeral suffix. Parent enforces this at subagent spawn time
   (Claude Code's Agent tool would need to unset
   `C2C_MCP_SESSION_ID` in the subagent's env, or override it).

   Problem: requires changes in Claude Code itself, not the broker.
   Possible via a shim in `c2c_mcp.py` that detects "I was launched
   inside a subagent" and rewrites env. But detection is fragile.

2. **Pid chain check**: broker looks at `/proc/<caller_pid>/status`,
   reads `PPid`, walks up until it finds a registered Claude Code
   process. If the caller pid is NOT the registered pid for the
   alias (it's a child of the registered pid), treat as a subagent
   and deny.

   Problem: many legitimate setups have an intermediate shell or
   `npm exec` between the registered pid and the actual Claude Code
   binary. False positives likely.

3. **Session-granted capability token**: at `register` time the
   broker issues a token bound to the caller pid + boot time +
   session_id. The token lives in an env var that the parent sets
   but subagents don't inherit (because the parent scrubs it before
   spawn). No token = no access. Legacy scripts in this repo carry
   a "legacy-fallback" env var that the broker always accepts.

   This is the cleanest model. It needs Claude Code / OpenCode /
   Codex to opt-in to scrub env on subagent spawn, but that's a
   one-liner per launcher.

### Minimal slice (recommended: option 3)

1. **Broker:** `register` RPC now returns `{session_id, alias,
   access_token}`. Store the hash in registry.json. Every subsequent
   RPC that reads/writes inbox content (`poll_inbox`, `send`,
   `send_all`, `send_room`, new `history`) requires `access_token`
   in the arguments. Reject with `permission_denied` if missing
   or mismatched.

2. **Legacy escape hatch:** if the RPC carries
   `C2C_LEGACY_FALLBACK=1` in the MCP env and the `broker_root` is
   inside this repo (check against a constant path prefix), skip
   the token check. This is how the old Python fallback scripts
   keep working locally but are not portable to other c2c
   installations.

3. **Python c2c_mcp.py shim:** inject access_token from env
   `C2C_MCP_ACCESS_TOKEN` into every RPC's arguments. Parent
   launchers set this env. Subagent launchers must NOT inherit it
   (they get a scrubbed env).

4. **Tests:** unit test for token mismatch, token missing, legacy
   fallback env bypass.

### Why this order

Goal A (archive) is a pure additive change — safe to land first, no
backwards-compat issues, immediately useful for debugging. Goal B
(subagent isolation) touches every RPC and every client launcher —
riskier, needs cross-agent coordination, and deserves to follow once
A is in place so we have archive evidence to test against. Also,
the `history` tool added in goal A becomes the natural enforcement
target for goal B — "you can't read the parent's history" is a
concrete thing to test.

---

## Next step

I would pick up goal A (archive) myself next if nothing else lands.
Slice it as:

1. OCaml broker change: `append_archive` helper + drain call +
   tests.
2. New `history` MCP tool.
3. Python CLI: `c2c history`.
4. Commit as v0.6.2.

Claim locks on `ocaml/c2c_mcp.ml`, `ocaml/c2c_mcp.mli`,
`ocaml/test/test_c2c_mcp.ml`, `c2c_cli.py` before starting.
