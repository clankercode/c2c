# 2026-04-21 — Managed-session crinkles (coordinator1)

Four real-world bugs Max hit today launching a new opencode instance.
All now fixed or tracked. Writing this up so the next agent has the
full symptom → cause → fix trail.

## 1. `/` in instance name created nested dirs

**Symptom.** `c2c start opencode -n gpt54/tweed-lace` created
`~/.local/share/c2c/instances/gpt54/tweed-lace/` instead of a flat
instance dir. `c2c instances` / `c2c stop` couldn't find it because
they glob at depth 1.

**Cause.** `c2c_start.ml` used the instance name directly in
`Filename.concat`-style paths. No validation.

**Fix.** `ocaml/c2c_name.ml` — shared sanitizer. `[A-Za-z0-9._-]`,
1..64, no leading dot. Used by `c2c start`, broker `register`, and
relay `InMemoryRelay.register`. Commits fb47eda + 7dc48f8.

**Severity.** Medium — silent data at unexpected path.

## 2. Ctrl-Z (SIGTSTP) killed the managed session

**Symptom.** Max Ctrl-Z'd `oc-coder1` (expecting suspend); the whole
managed session died. Child process, sidecars, instance dir gone.

**Cause.** `wait_for_child` in `c2c_start.ml` treated `WSTOPPED`
identically to `WEXITED`: returned `128+n` and proceeded to the
cleanup path, SIGTERM'ing the whole pgrp.

**Fix.** On `WSTOPPED`: reclaim the TTY (`tcsetpgrp` outer), `SIGSTOP`
ourselves so the shell sees a suspended job, on `SIGCONT` hand TTY
back and resume the child pgrp, continue waiting. Commit fb47eda.

**Severity.** High — unexpected data loss for a muscle-memory
interaction.

## 3. Spurious `peer_renamed` when new session registered

**Symptom.** Starting a fresh opencode under a new alias caused a
`peer_renamed` event that renamed an *existing* alias (coder2-expert)
to the new one. Swarm-lounge history showed the rename at ts=1776745871.

**Cause.** Broker's rename detection matched on `session_id` alone
(`reg.session_id = session_id && reg.alias <> alias`). Because
`c2c_start` sets `C2C_MCP_SESSION_ID=<instance_name>`, two unrelated
processes that collide on an instance name share a session_id. Any
re-registration with a different alias looked like a rename.

**Fix.** Harden the guard: require same PID on the existing reg
before treating it as a rename. coder2-expert-claude in 2889e81
(task #45).

**Severity.** High — silently reassigns a live agent's identity;
breaks message routing.

## 4. Resume hang on missing opencode session

**Symptom.** `c2c start opencode -n oc-coder1 --session-id
ses_2526b83…` hung with no error. `c2c stop oc-coder1` unstuck it.

**Cause.** opencode silently creates a new session when the provided
`ses_*` id doesn't exist; managed wake path doesn't recognize this
state, so the outer sits waiting.

**Fix.** Task #47 — pre-flight `opencode session list` in
`c2c start opencode` when `-s` is provided. Fail fast with a clear
error. Not yet implemented.

**Severity.** Medium — confusing but recoverable once you know to
`c2c stop`.

## Cross-cutting lesson

Three of these four are about **session identity semantics**.
`C2C_MCP_SESSION_ID=<instance_name>` is a convenient default but
it's not a real identity — it can collide, it can be reused, and
the broker treated it as authoritative for rename matching. The
fix here is additive (PID guard) but the deeper question is
whether session_id should be a hash of (instance_name, start_ts)
or similar, so collisions are impossible at registration time.

Filing as a meta-task: **session_id should be collision-resistant
by construction**, not by guards layered on top. Probably out of
scope for this week; raise with planner1 when the queue is quieter.
