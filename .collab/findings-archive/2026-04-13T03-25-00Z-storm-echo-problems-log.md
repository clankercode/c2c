# storm-echo problems log

Append-only log of real issues hit during the c2c-msg session, per the
new CLAUDE.md rule "Document problems as you hit them." Newer entries
at the bottom. Each entry covers: symptom, discovery, root cause, fix
status, severity.

---

## 2026-04-13 — channel-allowlist bypass does not exist on Claude 2.1.104

- **Symptom:** `notifications/claude/channel` emitted by the OCaml
  broker never surfaces in the Claude transcript. The sender sees
  `queued`, the broker enqueues, the inbox drains on later receiver
  activity, but the receiving Claude conversation never shows the
  message body.
- **How I discovered:** `c2c-r2-b1` / `c2c-r2-b2` pair deliberately
  launched without `--dangerously-load-development-channels server:c2c`,
  so the push path was never expected to work for that pair; hunted
  for a non-interactive way to get `server:c2c` on the allowlist so
  unattended auto-resume would still work.
- **Root cause:** binary inspection of `~/.local/share/claude/versions/2.1.104`
  found that `allowedChannels` / `hasDevChannels` / `setAllowedChannels`
  / `setHasDevChannels` are runtime session state, not persisted
  settings. `--dangerously-load-development-channels` is the only path
  to extend the allowlist, and it always triggers the interactive
  "Loading development channels" confirmation, which defeats
  unattended relaunches.
- **Fix status:** blocked upstream. No local code change fixes this
  for Claude 2.1.104. Accepted mitigation is `poll_inbox` on the
  receive path; the AC line already admits this.
- **Severity:** medium — it closes one of the two listed delivery
  paths in the AC, but the other path is fully working.
- **Full finding:** `2026-04-13T03-14-00Z-storm-echo-channel-bypass-dead-end.md`

## 2026-04-13 — broker-process leak: 23 c2c_mcp_server.exe instances alive

- **Symptom:** `pgrep c2c_mcp_server` returns 23 processes, some over
  24 hours old. Oldest dune-exec wrapper was reparented to init (PPID
  1) — a textbook orphan.
- **How I discovered:** `ps -ef | grep -E "c2c_poker|run-claude-inst|run-codex-inst|claude.*--resume"`
  while auditing self-wake tech; the subsequent `pgrep` on broker
  processes turned up the pile.
- **Root cause:** `c2c_mcp.py` launches the broker via
  `bash -lc '... dune exec ./ocaml/server/c2c_mcp_server.exe ...'`,
  giving a chain `python -> bash -> dune -> server.exe`. When Claude
  closes its MCP stdio on session exit, the server should see stdin
  EOF, exit, and cascade up. In practice the bash/dune layer doesn't
  propagate cleanly and the inner server keeps running as an orphan.
- **Fix status:** not yet fixed. Short-term is manual kill of
  orphaned broker processes. Medium-term fixes: add a stdin-EOF
  watcher to the OCaml server so it exits when its MCP client dies;
  drop the bash+dune wrapper once there is a `just`/`make` target
  for a prebuilt binary. Long-term: one shared broker per repo
  instead of one per session.
- **Severity:** high — indirectly caused the stale `storm-echo`
  registry ghost entries that clobbered inbound delivery to this
  session for most of the afternoon. Every live broker is a potential
  writer against an unlocked `registry.json` on the old binary; the
  new broker hardening (`commit b6ef334`) only takes effect once Max
  restarts the brokers.
- **Full finding:** `2026-04-13T03-24-00Z-storm-echo-broker-process-leak.md`

## 2026-04-13 — stale storm-echo entries clobbered inbound delivery

- **Symptom:** my live session had an empty inbox, but peers had sent
  me messages that I never saw. Acks from both storm-beacon (commit
  confirmation) and codex (CLI broker-fallback proof ack) were
  missing.
- **How I discovered:** directly read the broker state dir
  (`.git/c2c/mcp/`) rather than trusting `mcp__c2c__poll_inbox`
  since the MCP server had disconnected earlier in the session.
  Found four messages addressed to `storm-echo` sitting in
  `92568b24-...inbox.json` (an old dead storm-echo session ID), and
  two more in `9d0809b5-...inbox.json`.
- **Root cause:** `registry.json` had three entries with alias
  `storm-echo` — two dead and one live (mine). The broker's alias
  resolution picks the first live match by file order. Old dead
  entries had no pid field, so they were treated as live (legacy
  behavior) and came first in the list. My live entry was last and
  never received anything.
- **Fix status:** fixed in this turn by atomic rewrite of
  `registry.json` to drop the two dead `storm-echo` entries and
  insert my live entry at the top of the file. The proper fix is
  the new broker hardening already committed (`b6ef334`:
  liveness-by-pid_start_time + registry lock) once Max restarts the
  broker process.
- **Severity:** high — silent misdelivery is one of the worst
  failure modes of a messaging system. No error anywhere. The
  sender saw `queued`, the receiver saw nothing.
- **Related findings:**
  `2026-04-13T03-24-00Z-storm-echo-broker-process-leak.md`
  (root cause chain leads back to the broker-leak entry above).

---

## 2026-04-13 ~04:20Z — subprocess.run without env=env silently leaks test into real broker registry

- **Symptom:** `tests/test_c2c_send_all.py` fan-out assertions failed
  with phantom aliases: `['alice', 'bob', 'storm-herald', 'storm-storm']`
  instead of just `['alice', 'bob']`. The storm-* aliases are real,
  live sessions in the repo-local broker registry at
  `.git/c2c/mcp/registry.json`. The test uses `tempfile.TemporaryDirectory()`
  as broker_root and pre-writes a clean `registry.json` with only
  `alice-local`, `bob-local`, `caller`.
- **How I discovered:** ran `python -m unittest tests.test_c2c_send_all`
  after committing the slice; 2/3 tests failed. Ran the same subprocess
  command manually from a python REPL — it passed. Ran the same test
  logic through an ad-hoc `unittest.TestCase` in `/tmp/debug_send_all.py`
  with identical env copying — it passed. Only the original
  `test_c2c_send_all.py` file failed.
- **Root cause:** `run_send_all` built an `env = os.environ.copy()`
  dict with `C2C_MCP_BROKER_ROOT`, `C2C_REGISTRY_PATH`,
  `C2C_SESSIONS_FIXTURE`, etc — then called
  `subprocess.run(args, cwd=REPO, capture_output=True, text=True, timeout=30)`
  with **no `env=` keyword**. Python subprocess inherits the parent's
  real environment when `env` is omitted, so the child saw the real
  repo's `.git/c2c/mcp/` as broker_root (via default_broker_root's
  fallback to the git common dir) and fanned out to every registered
  storm-* peer.
- **Why it was confusing:** the test passes `--broker-root` on the
  command line, so I assumed that was the authoritative source. But
  `c2c_send_all.py` sets `env["C2C_MCP_BROKER_ROOT"] = str(broker_root)`
  in the subprocess it spawns, which is what the OCaml server actually
  reads. With the outer test not passing env, the CLI arg broker_root
  got forwarded as the subprocess's env var — but only for that
  sub-sub-process, and sync_broker_registry at the intermediate layer
  still read the real broker root because its own env was the parent's.
- **Fix status:** fixed in `d596ca0` — added `env=env` to the
  `subprocess.run` call in `run_send_all`. Suite went from
  failing ➝ 3/3 green, full Python 122/122 green.
- **Severity:** medium-high. Silent test pollution against real broker
  registry is the worst kind of flakiness — the failure message
  mentioned real, live alias names I recognize from my own swarm,
  which sent me down a red-herring investigation of
  `sync_broker_registry` and `registry_path_from_env` for ~30 min.
- **Prevention idea:** a fixture decorator that wraps test subprocess
  invocations and forces `env=` to be supplied, or a lint rule that
  rejects `subprocess.run(...)` without `env=` inside `tests/`.
  storm-beacon specifically flagged this as a footgun worth
  documenting.
