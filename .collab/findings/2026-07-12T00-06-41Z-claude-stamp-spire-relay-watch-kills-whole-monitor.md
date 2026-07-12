# `c2c monitor` relay-watch TERMINAL failure kills the WHOLE monitor (local inbox watch dies too)

- **Reporter:** claude-stamp-spire-o5ez (in ~/src/c2c)
- **Observed in:** session `21d51d98-57c1-4b5b-9f65-42483bbf0a46` (amaroo repo, alias `claude-quip-neural-57cb`)
- **Severity:** HIGH — local receive (the primary CLI receive path) is torn down by an unrelated relay-side problem; drives agents to the wrong workaround.

## Symptom (as the user saw it)

The amaroo session "keeps trying to use a monitor like
`c2c relay connect > .../scratchpad/c2c-relay-connector.log 2>&1`" instead of
just running `c2c monitor`. Two `run_in_background` Bash launches of
`c2c relay connect` are in the transcript (15:07:30Z and 15:50:58Z), and one is
still alive now (PID 888979) spewing endless `unauthorized` heartbeat errors for
*other* sessions' aliases into the log.

## What actually happened (root cause chain)

1. The session's Monitor tool **did** run `c2c monitor` (correct — 9 Monitor
   invocations, all `c2c monitor`). The `relay connect` calls were separate
   background Bash, not the Monitor.

2. `c2c monitor` **auto-enables a relay-peek watcher** whenever a relay is
   configured + an alias/identity resolves (`decide_relay_watch`,
   `c2c_monitor_logic.ml:320-329`). The default relay `https://relay.c2c.im` is
   *configured out of the box*, so a purely **local** agent silently gets
   relay-peek turned on — with no `--relay` opt-in.

3. The relay-peek repeatedly hit **terminal-classified** errors:
   - `not_found: unknown endpoint: /peek_inbox` (relay server/endpoint version mismatch)
   - `unauthorized: alias ...` (session alias had no relay identity binding)
   - `timestamp_out_of_window: request ts skew -30.5s` (this host's clock ~30s behind the relay)

4. On any terminal error, `handle_terminal` calls **`exit`**
   (`c2c_monitor_cmd.ml:756-763`). The relay-peek loop runs in a *separate
   thread* (`Thread.create`, line 810), but `exit` terminates the **whole
   process** — killing the main-thread local-broker inotify inbox watch too.
   **A relay-side problem takes down local receive.** That is the core defect.

5. The dead monitor + the `whoami`/relay-status nudge
   (`connector: none — start with 'c2c relay connect'`) drove the agent to
   manually run `c2c relay connect` as a fragile backgrounded Bash. That
   connector then also fails: it heartbeats/syncs *all* local registrations and
   returns `unauthorized` for aliases it can't sign for (e.g.
   `codex-cotton-chain-pnjn...`, `codex-glade-ve...`), producing `alerts=146`
   and log noise — none of which the local agent needed.

## The fix

`c2c monitor` must keep watching the **local** inbox regardless of relay health.
On a relay-peek terminal failure, **disable only the relay-watch thread** (log
it once to stderr), never `exit` the process. Options:
- Replace `exit exit_relay_terminal` in `handle_terminal` with: log once + set
  a flag that stops the relay loop, then `return` — main-thread inotify local
  watch continues.
- Keep the non-zero exit **only** when relay-watch is the sole reason the
  monitor was started (i.e. no local inbox/archive watch is active), so a
  supervisor still notices a pure relay monitor dying.

Secondary (lower priority, separate slices):
- **Don't auto-enable relay-peek for local-only agents.** Gate relay-watch
  behind an explicit `--relay` (or require a *live connector*, not merely a
  *configured* relay URL). A configured-by-default public relay should not
  silently opt every local session into relay-peek.
- **Soften the `whoami` nudge.** `connector: none — start with 'c2c relay
  connect'` reads as an imperative even for agents that only do local
  messaging; it mis-steers them to a tool they don't need and that misbehaves
  when run per-session (heartbeats other sessions' aliases → `unauthorized`).

## Environmental contributor (not a c2c bug)

Host clock is ~30s behind the relay → `timestamp_out_of_window`. NTP/clock sync
would remove the skew trigger, but the monitor-teardown defect (step 4) stands
regardless: `not_found` and `unauthorized` would still kill the whole monitor.

## Code refs

- `ocaml/cli/c2c_monitor_cmd.ml:756-763` — `handle_terminal` → `exit` (the defect)
- `ocaml/cli/c2c_monitor_cmd.ml:810-812` — relay loop runs in its own thread
- `ocaml/cli/c2c_monitor_logic.ml:359-368` — terminal error-code set
- `ocaml/cli/c2c_monitor_logic.ml:320-329` — `decide_relay_watch` auto-enable
