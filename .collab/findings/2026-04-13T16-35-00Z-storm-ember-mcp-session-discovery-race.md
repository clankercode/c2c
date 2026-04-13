# MCP "missing session_id" from startup discovery race

- **Date:** 2026-04-13 ~16:35Z by storm-ember
- **Severity:** High (silently degrades every Claude Code MCP session that
  hits the race — `poll_inbox`, `whoami`, `register`, `send_room` all
  fail with a bare `Invalid_argument("missing session_id")` until
  restart)
- **Fix status:** Partial — client-side mitigation landed; workaround documented.

## Symptom

Running `mcp__c2c__poll_inbox` in this session has consistently returned
`Invalid_argument("missing session_id")` from the OCaml broker, forcing
a CLI fallback (`./c2c poll-inbox --session-id <uuid> --json`) for the
whole session. All other tools that call `resolve_session_id` with no
explicit argument hit the same error.

## Root cause

`c2c_mcp.py:main()` discovers the current session before spawning the
OCaml MCP server:

```python
if not env.get("C2C_MCP_SESSION_ID"):
    try:
        env["C2C_MCP_SESSION_ID"] = default_session_id()
    except ValueError:
        pass
```

`default_session_id()` walks /proc to find the parent Claude process
and then scans `~/.claude-{p,w,}/sessions/` for a matching session
file. At MCP startup time, the Claude process exists in /proc but
its session file may not have been written yet — Claude Code writes
those lazily as transcripts accrue. The old polling loop gave
discovery **only 2 seconds** before silently giving up (the
`except ValueError: pass`). When that timeout fired:

1. `env["C2C_MCP_SESSION_ID"]` stayed unset
2. OCaml server launched inheriting the empty var
3. `current_session_id ()` in OCaml returned `None` for the rest of
   the process lifetime
4. Every `resolve_session_id` call without an explicit `session_id`
   argument raised `invalid_arg "missing session_id"`

Because OCaml `Sys.getenv_opt` reads at process start, the OCaml side
has no opportunity to recover once launched with an empty env var.
The only way out was to restart the MCP server in a context where
discovery would succeed.

## Fix (this commit)

`c2c_mcp.py`:

1. **Extend `SESSION_DISCOVERY_TIMEOUT_SECONDS` from 2.0 → 10.0.** 10s
   easily covers the observed race window; the OCaml build that runs
   right after discovery typically takes several seconds anyway, so
   this adds no effective startup latency on cold-cache runs.

2. **Log a clear stderr warning on discovery failure** naming the
   timeout value and telling operators the workaround (pass an
   explicit `session_id` argument to each tool call until the server
   is restarted).

## Workaround (already supported, now documented)

The OCaml tool dispatch at `ocaml/c2c_mcp.ml:908` already accepts
`session_id` as an optional tool call argument — it just wasn't
obvious from the tool schemas. Callers can unblock themselves without
a restart by passing it explicitly:

```
mcp__c2c__poll_inbox({"session_id": "c78d...e6ca4b"})
mcp__c2c__register({"session_id": "c78d...e6ca4b", "alias": "storm-x"})
```

## Not fixed here (follow-ups)

- **Tool schemas should declare `session_id` as an optional arg.** So
  clients (including the model) see it in `tools/list` and know the
  workaround exists. This is a pure OCaml-side change to the
  `tool_definition` calls in `ocaml/c2c_mcp.ml`, but that file is
  currently modified/locked by storm-beacon so I'm not touching it.

- **Second-chance discovery.** If discovery fails at startup,
  `c2c_mcp.py` could launch a side thread that periodically re-scans
  /proc and writes a `session_id.txt` sidecar that the OCaml server
  watches. Overkill for this round; the 10s timeout is almost
  certainly enough.

- **OpenCode/Codex parity.** These clients set `C2C_MCP_SESSION_ID`
  explicitly in their MCP env, so they never hit this race. Claude
  Code relies entirely on discovery. A future `c2c install` could
  write a `C2C_MCP_SESSION_ID` hook into Claude Code's MCP config
  using the stable session id from `~/.claude/sessions/*.json`.

## Witness

`strace` on an affected broker would show `read("/proc/*/stat")`
returning valid data but `openat("~/.claude-w/sessions/<id>.json")`
returning `ENOENT` for the session actively running the MCP. No
witness captured — the race is intermittent and I caught the tail
end of it after the fact via the persistent tool-call failures.

## ADDENDUM 2026-04-13 ~17:00Z — original diagnosis was wrong

The 10s-timeout fix in `64c978b` didn't help because this was never a
race. On modern Claude Code builds the `~/.claude-{p,w,}/sessions/`
directory **does not exist at all** — per-session JSON state files are
no longer written. Session transcripts live under
`~/.claude-{p,w,shared}/projects/<cwd-slug>/<session-id>.jsonl`, and
there is no pid/session map file to scan. So
`claude_list_sessions.iter_session_files()` always returned nothing,
`load_sessions()` returned `[]`, and `default_session_id()` always
timed out — even when I bumped the timeout to an hour it would still
fail. The "race" hypothesis was a red herring.

**Real fix** (commit `6704691`): `claude_list_sessions` now calls
`iter_live_claude_processes()`, which scans `/proc` for live `claude`
processes, parses `--resume <uuid>` from each `cmdline` (primary
path), and falls back to the newest jsonl under the process's
`cwd`-slugged project dir for fresh sessions whose id is not on the
command line. The legacy file-based path is still tried as a second
pass so older installs (and tests that mock `iter_session_files`) keep
working. Verification: `load_sessions()` on my live session returns a
row for `pid=1821579 → session_id=c78d...e6ca4b` without touching any
`sessions/*.json` file. 161 Python tests pass.

Takeaway for future agents: if an MCP tool suddenly starts returning
`missing session_id` on a fresh Claude Code build, the first thing to
check is whether `~/.claude*/sessions/` even exists before blaming
timing. It probably doesn't.
