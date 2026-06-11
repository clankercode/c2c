# Session-id-addressed delivery + always-on hook auto-pickup (DESIGN)

**Status**: design / pending review. Author: claude (Max's interactive session),
2026-06-12. Driven by Max: "allow delivery to session id … automatically check
that via post tool hook etc. so even sessions that don't know c2c exists can
still receive messages."

## 1. Goal

Let any sender address a c2c message to a **session id** (not just an alias),
and have it **auto-delivered into that session even if the session has never
heard of c2c** — via always-installed, very-fast Claude hooks that inject the
message into the transcript. This is a direct step toward the group goal of
"unify all agents": you can reach a raw Claude session by id with zero c2c setup
on its side.

## 2. What already exists (grounding)

- **Inboxes are keyed by `session_id`**, not alias:
  `<broker_root>/<session_id>.inbox.json` (`c2c_broker.ml:33`).
- **`Broker.enqueue_by_session_id`** already exists (`c2c_broker.ml:3011`,
  currently only dead-letter redelivery) — direct session-inbox writes are solved.
- Registrations store both `session_id` and `alias` (`c2c_broker.ml:122-227`).
- `resolve_live_session_id_by_alias` exists; `session_id → registration` is
  open-coded inline everywhere but has **no named resolver** yet.
- **Claude Code PostToolUse / Stop hook stdin payloads natively include the real
  `session_id`** (+ `transcript_path`, `cwd`), independent of any c2c/MCP install.
- Current `c2c hook` reads `C2C_MCP_SESSION_ID` from env (MCP-install only) and
  the wrapper early-exits if unset — **the only thing blocking c2c-unaware
  sessions**. Injection surface (`hookSpecificOutput.additionalContext`) already
  works with no MCP.
- Broker-root machinery: `resolve_broker_root_canonical()` (no env var) and a
  `--global` multi-broker scan (`iter_known_broker_roots`).

## 3. Decisions (from Max, 2026-06-12)

1. **Reach model = global, always-install.** Install the hooks for every Claude
   session, not opt-in. Wire the install into the `/connect/` page and other
   setup docs; `c2c install` does it always.
2. **Two hooks:**
   - **PostToolUse** — covers tool-call turns.
   - **Stop** — covers text-only turns (no tool call), so responses without
     tools still pick up messages.
3. **Single global broker** for session-addressed inboxes (a dedicated fixed
   path so the fast-path needs no git fingerprinting).
4. **Speed is a hard constraint** — the hooks run every turn; they must not lag
   the system.

## 4. Architecture

### 4.1 Send side — `c2c send --session <id>`
- New explicit `--session <id>` flag (and MCP `send` arg `to_session_id`).
  **Cannot** shape-sniff alias-vs-session-id: kimi's session_id *is* its alias,
  opencode's is `opencode-<dir>`. So addressing is explicit.
- Routes via the existing `enqueue_by_session_id` into the **global session
  broker** at `<GLOBAL_SESSIONS_BROKER>/<session_id>.inbox.json`.
- A named resolver `find_live_registration_by_session_id` (sibling of
  `resolve_live_session_id_by_alias`) is added for liveness/self-heal and to
  recover the recipient `alias` (for optional enc-pubkey pinning). Delivery does
  **not** require a live registration — an unregistered session can still
  receive (the hook is what makes it c2c-unaware-capable).

### 4.2 Global session broker
- Fixed path, e.g. `${XDG_STATE_HOME:-$HOME/.c2c}/sessions/broker/` (exact path
  TBD; reuse `resolve_broker_root_canonical` conventions). Both sender and the
  fast-path hook resolve it with **zero git work**.
- Inbox files `<global>/<session_id>.inbox.json` — same JSON shape as today.

### 4.3 Receive side — the hooks
Both hooks read `session_id` from the **stdin payload** (not the env var), then:

**Fast path (steady state, ~99% of calls):**
1. Extract `session_id` from stdin (cheap `grep`/minimal parse — no `jq`).
2. `stat` `<global>/<session_id>.inbox.json`. **Missing/empty → exit (~5 ms),
   never spawn a binary.**

**Delivery path (inbox non-empty, rare):**
3. Drain + format the queued messages and inject:
   - **PostToolUse:** emit `hookSpecificOutput.additionalContext` (existing
     surface; Claude shows it inline).
   - **Stop:** Stop hooks cannot use `additionalContext`. Instead **block the
     stop** (`{"decision":"block","reason":"<c2c envelopes>"}`) so Claude
     continues and the model sees the messages as the block reason. (Mechanics
     to verify in P0; fallback: leave messages queued for the next PostToolUse.)

### 4.4 Performance levers (benchmark both, pick fastest)
- **A. Shell stat-precheck** — wrapper does steps 1-2 in pure shell; only spawns
  the binary for step 3. Idle ≈ 5 ms, no binary.
- **B. Dedicated minimal `c2c-hook` binary** — a tiny OCaml executable linking
  only stdlib + yojson + file IO (no cmdliner, no full broker init). Does steps
  1-3 itself. Target startup single-digit ms (vs ~30-50 ms for the full `c2c`
  binary + ~100 ms of broker work today). Could replace the shell wrapper if its
  cold start beats the shell+grep path.
- Decision criterion: lowest **idle** latency (no-message case dominates).
  Budget: **~10–15 ms steady-state** per turn (see measured reality below).

### 4.5 Measured reality (2026-06-12, this machine)
- `c2c hook` (full binary subcommand): **~150 ms** — too slow; do NOT use on the
  always-on path.
- **A dedicated hook binary ALREADY EXISTS**: `ocaml/tools/c2c_inbox_hook.exe`
  (installed as `c2c-inbox-hook-ocaml`), the current PostToolUse hook. Warm
  startup **~17–28 ms**. So "lever B" is largely **already built** — extend it,
  don't write a new one.
- It has a deliberate **`min_runtime_ms = 10.0`** floor: fast-exiting hook
  children re-trigger a Node ECHILD zombie-reap race in Claude Code, so the hook
  intentionally sleeps to ≥10 ms. **=> ~10 ms is the realistic floor for ANY
  Claude hook**, which also means a 3–5 ms pure-shell precheck may be unsafe
  (same ECHILD risk). Treat ~10–15 ms as the target, not <10.
- Build is currently **debug** (`dune build`, no `--profile release`; binary
  `not stripped`, 19–24 MB). A release/flambda build is worth testing for the
  *delivery* path, but the ECHILD floor caps the idle-case benefit. (Quick test
  here didn't shrink the binary — the opam switch may lack flambda; verify.)

**Net:** the perf foundation mostly exists (`c2c_inbox_hook` ~20 ms, ~10 ms
floor). The real work is FUNCTIONAL (read session_id from stdin, global broker,
Stop-hook variant, `send --session`), not perf-heroics. Reuse `c2c_inbox_hook`
as the hook engine for both PostToolUse and Stop.

### 4.6 Floor-removal experiment result (2026-06-12) + perf DECISION
- Commenting out the `min_runtime_ms` sleep → **16–25 ms (unchanged)**. The
  floor was NOT the bottleneck: binary startup already exceeds 10 ms so the
  sleep rarely fired. Lwt is used *only* for that sleep, but the binary links
  the whole `c2c_mcp` library — **that** ~16–25 ms link/init is the real cost.
- **DECISION (perf):** the high-leverage lever is the **shell stat-precheck**
  (idle ~4 ms, spawns no binary). Adopt it as the always-on path. The floor
  removal is folded into the P0 hook rework (not shipped standalone — alone it's
  a no-op that drops the ECHILD guard). A future slim of the hook off `c2c_mcp`
  (which also drops Lwt) is a P2 nice-to-have for the *delivery* path only.

## 5. Per-client coverage
- **Claude Code** — primary target. PostToolUse (exists, re-point to stdin
  session-id) + new Stop hook. Always-installed.
- **OpenCode** — already auto-injects via its plugin (`session.idle` + poll →
  `promptAsync`); extend it to also check the global session broker by id.
- **Kimi** — has a PreToolUse hook + notification-store; can check the global
  broker there. Secondary.
- **Codex** — no per-turn hook; stays on inotify→PTY-sentinel. Could add a
  global-broker check to the deliver-inbox watcher. Secondary.
- **Gemini** — no client in repo. N/A.

## 6. Discovery
Senders need to learn a target session id (UUIDs aren't memorable). Add
`c2c sessions` (list live sessions: id, client_type, cwd, alias-if-registered).
Builds on registry + the `--global` scan and existing session-discovery code.

## 7. Security / abuse
- Any local actor who knows a session id can inject context into that session
  (prompt-injection surface). **Local-only, single-user machine → acceptable**,
  but: injected messages MUST be clearly framed as external/untrusted in the
  envelope so the model treats them as data, not instructions.
- No new network surface (global broker is local files). Relay/cross-machine
  session-addressing is explicitly **out of scope** for v1.

## 8. Testing (its own deliverable — task #7)
- **Correctness:** `c2c send --session <id>` → message picked up + injected by
  both PostToolUse (tool turn) and Stop (text-only turn) into a c2c-unaware
  session. Fixture-gated, scripted under `scripts/`.
- **Speed:** assert idle (no-message) latency < budget (target < 10 ms); a
  benchmark that FAILS if the idle hook regresses (guards the "don't lag the
  system" requirement). Measure both lever A and lever B.

## 9. Docs integration
- `/connect/` page + setup docs gain a "make your agent reachable" step that
  installs the hooks.
- `c2c install` installs both hooks **always** (idempotent, de-duped, like the
  current PostToolUse install).

## 10. Phasing
- **P0** — global session broker path + `send --session` + named resolver +
  re-point PostToolUse hook to stdin session-id + the shell fast-path. Prove the
  loop on a c2c-unaware Claude session.
- **P1** — Stop hook (verify block-stop injection mechanics).
- **P2** — dedicated minimal `c2c-hook` binary; benchmark vs shell; adopt winner.
- **P3** — `c2c sessions` discovery; docs (`/connect/` + setup); always-install.
- **P4** — extend opencode/kimi/codex to check the global broker.

## 11. Decisions on the open questions (2026-06-12, autonomous — Max AFK)
Resolved principledly so implementation isn't blocked:

1. **Global-broker path → `${XDG_STATE_HOME:-$HOME/.c2c}/sessions/broker/`.**
   Mirrors `resolve_broker_root_canonical` conventions (XDG first, HOME
   fallback), is a fixed path (no fingerprint), and is distinct from the
   per-repo `repos/<fp>/broker` dirs so it coexists with the `--global` scan
   (which can additionally include it). Add a `resolve_sessions_broker_root ()`
   helper in `c2c_repo_fp.ml`.
2. **Stop hook → deferred to P1 behind a spike.** P0 ships PostToolUse only
   (proven `additionalContext` path). Before P1, a spike confirms whether
   `{"decision":"block","reason":...}` reliably surfaces to the model on the
   installed Claude Code version; if not, fall back to "leave queued for next
   PostToolUse" (acceptable degradation — text-only turns are usually followed
   by a tool turn soon).
3. **Stale-inbox GC → P3, TTL + liveness sweep.** A periodic sweep deletes
   `<sid>.inbox.json` whose mtime is older than a TTL (default 7d) AND has no
   live registration. Cheap, runs from an existing maintenance path
   (e.g. piggyback `c2c doctor` / a `c2c dev` subcommand). Not P0-blocking —
   inbox files are tiny.
4. **MCP-aware + global-hook de-dup → inherent, no special logic.** The global
   session broker is a SEPARATE inbox path from the per-repo MCP broker. A
   message is addressed *either* to an alias (→ per-repo broker, drained by MCP)
   *or* to a session-id (→ global broker, drained by the hook) — never both. So
   the same message can't be double-delivered. The only "double" case is a
   sender deliberately sending to both addresses, which is two distinct messages
   by intent. P0 keeps them fully separate.

These are recorded as decisions, not open items; revisit only if implementation
surfaces a contradiction.
