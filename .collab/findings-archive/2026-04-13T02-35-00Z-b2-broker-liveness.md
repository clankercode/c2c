# Finding: OCaml broker liveness landed (uncommitted)

**Session:** c2c-r2-b2 (`d16034fc-5526-414b-a88e-709d1a93e345`), alias `storm-beacon`
**Time:** 2026-04-13T02:35Z
**Scope:** broker liveness (my half of the 2026-04-13 scope split)

## What changed (working tree only — not committed)

- `ocaml/c2c_mcp.ml`
  - `type registration = { session_id : string; alias : string; pid : int option }`
  - `registration_to_json` / `_of_json` emit and accept an optional `pid` field.
    Legacy entries written without a `pid` field still load; they're treated as
    alive (no probe).
  - New `Broker.registration_is_alive : registration -> bool` — `None` → alive,
    `Some n` → `Sys.file_exists "/proc/<n>"`.
  - New internal `resolve_live_session_id_by_alias` — returns `Resolved sid |
    Unknown_alias | All_recipients_dead`. It walks *all* registrations matching
    the alias and picks the first LIVE one, so a zombie registration doesn't
    shadow a live re-registration under the same alias.
  - `Broker.register` now takes `~pid:int option`.
  - `Broker.enqueue_message` raises:
    - `Invalid_argument ("unknown alias: " ^ alias)` — alias has zero entries
    - `Invalid_argument ("recipient is not alive: " ^ alias)` — all entries for
      this alias are dead (distinct error so senders can tell "never existed"
      from "existed but dropped").
- `ocaml/c2c_mcp.mli` — exposes the new `pid` field on `registration`, the new
  `register ~pid` signature, and `registration_is_alive`.
- `handle_tool_call "register"` now passes `Some (Unix.getppid())`, so live
  sessions going through MCP auto-capture their client PID on every register.
  The `list` tool result also surfaces `pid` when present.
- `ocaml/test/test_c2c_mcp.ml`:
  - Existing `Broker.register` call sites updated to pass `~pid:None` (pure
    backward-compat; they don't exercise liveness).
  - 4 new tests:
    1. `enqueue to dead peer raises` — forks a child, reaps it, registers with
       that pid, expects `Invalid_argument "recipient is not alive: storm-dead"`.
    2. `enqueue picks live when zombie shares alias` — dead + live registration
       under the same alias; live inbox receives, zombie inbox stays empty.
    3. `registration without pid field is treated as alive` — writes a hand-
       crafted legacy `registry.json` missing the `pid` field and confirms
       enqueue still delivers. Guards the backward-compat path.
    4. `registration persists pid` — round-trip check that `~pid:Some 42`
       survives save/load.

All 18 tests pass: `dune exec ./ocaml/test/test_c2c_mcp.exe` →
`Test Successful in 0.034s. 18 tests run.`

## Why this shape

- **`None` as "alive"** not as "unknown/reject": we want the change to be safe
  for any existing registry.json that predates this commit. Breaking in-flight
  sends between older sessions would be worse than letting the occasional
  missing-pid entry through. The pid field is a hint, not a hard gate.
- **`Unix.getppid()` at register time** captures the Claude/OpenCode/Codex
  client process ID (the MCP server's parent). This is the same anchor Python
  `claude_list_sessions.py` uses for liveness. Reparent-to-init on client
  crash changes this to 1, which `/proc/1` still reports as alive — a known
  false-positive that matches the storm-echo zombie observation in
  `2026-04-13T01-54-00Z-b2-receiver-analysis.md` §6. Follow-up (not in this
  change): re-capture at first RPC instead of register, so MCP servers whose
  parents have died are detectable.
- **Fall-through on alias collision**: the current `Broker.register` already
  replaces by session_id but not by alias. Two live sessions registering the
  same alias will both sit in the registry, and `enqueue_message` now prefers
  the first live one. A zombie shadowing a live re-registration was the
  scenario that motivated the bug report (registry purge notice
  `2026-04-13T01-55-30Z`).

## Not in scope, still open

- **No fcntl lock on `registry.json`** — `Broker.register` still does
  `load → filter → save` unlocked. The race I flagged in the 01:55Z registry
  purge note is still there. Wanted to keep this change surgical; will send a
  separate follow-up. Python `c2c_registry.py` has the reference locking.
- **No sweep tool** — zombies still accumulate. `Broker.registration_is_alive`
  is now available as a building block; a one-shot sweep would iterate and
  drop dead entries. Candidate as a new MCP tool `sweep`.
- **No re-capture at first RPC** — see above.
- **Status: uncommitted.** I have not been told to commit; leaving the working
  tree dirty for Max to review.

## Other unstaged changes in the tree (not touched by this commit)

- `c2c_mcp.py` — Python broker registry preservation work by somebody else
- `ocaml/server/c2c_mcp_server.ml` — env-gated auto-drain addition noted by
  storm-echo, not in either of our scopes
- `tests/test_c2c_cli.py` — paired with the Python broker work

Also new in this session (separate explicit task from Max, already landed):

- `c2c_poker.py` — generic PTY heartbeat poker (Claude / OpenCode / Codex /
  any interactive process by PID). Already verified end-to-end: resolved
  `(terminal_pid=3725367, pts=30)` for my own claude session via `--pid`,
  one-shot injection arrived in the next transcript turn as a user message.
- `CLAUDE.md` — one-line entry describing `c2c_poker.py` under Python Scripts.
