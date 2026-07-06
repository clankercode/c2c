# Session state — fable-scribe codex/claude dogfood loop (pre-compact persist)

Coordinator: fable-scribe (Claude Fable, Max-driven session, session id
ee0e4737-754e-44b6-ba8a-3f6fc08daec3, claude pid 3167872). 2026-07-06 ~20:55 AEST.

## Goal (Stop-hook enforced)
Iteratively dogfood + fix Claude & Codex c2c experience until zero-env
send/receive/identity Just Works from BOTH vanilla Claude (Bash tool) and
vanilla Codex (shell / codex exec). Loop: live-test → `bl bug` every friction →
dispatch subagents (fable=complex, opus=ordinary, MAX 3 ACTIVE, shut down
finished ones) → verify in worktree (just build rc=0 + DUNE_WATCHDOG_TIMEOUT=900
just test-ocaml rc=0) → merge to local master → `just install-all` → re-test.
Subagents get bug IDs + instructions to `bl cat`/`bl claim`; COORDINATOR runs
`bl done` after merge.

## Merged to local master this session (all verified green in-worktree)
- 56b3b8b0/0f99bd15 init text fix (`c2c rooms send`) + embedded-skill codegen sync
- 667f739a relay auth hints (Relay_client_hints, print_result_and_exit, `relay list --alias`)
- 93217417 `c2c find` + `list --match`, noise hint (`--alive` pre-existed)
- 0b8d6bb7 wait-inbox: `poll-inbox --wait/--timeout/--poll-interval/--from`,
  `c2c wait-inbox`, Broker.drain_inbox_matching; FIXED pre-existing runtest
  breakage (root `dune` file `(dirs :standard .collab)`) + onboarding
  CLAUDE_CONFIG_DIR leak
- 6db36ed4 session-identity: CLAUDE_CODE_SESSION_ID pickup; init persists
  `<broker_root>/default-session.json` (env > native > statefile, registry-
  validated); codex MCP env gets C2C_MCP_AUTO_REGISTER_ALIAS; kimi client_type
  pinned (hijack guard)
- 7c3c7099 broker-root canonical: XDG_STATE_HOME no longer honored for broker
  root (C2C_MCP_BROKER_ROOT → C2C_STATE_HOME → $HOME/.c2c); split-brain stderr
  warning + doctor check + migrate-broker XDG default source
- Later: findings commit, scripts/codex-c2c-live-test.sh (+ B074 alias fix),
  .goal-loops removed (Max: obsolete), CLAUDE.md ref cleanup.
- Full suite on master post-merges: GREEN (build rc=0, runtest rc=0).
- Installed via `just install-all` (binary at 7c3c7099 vintage; REINSTALL after
  next merges).

## In-flight subagents (3 = at cap)
- impl-codex-hooks (fable, task #5, `.worktrees/codex-hooks`): codex 0.142.5
  hooks auto-delivery — `c2c hook codex` (stdin payload → drain →
  hookSpecificOutput.additionalContext), installer hooks TOML + trust-hash,
  ~/.codex/AGENTS.md block, stale CLAUDE.md codex-binary section, xml-input-fd
  removal finding, .c2c/config.toml default_binary fix. STEERED mid-flight:
  auto-register must use stable pid or pid=None (never getppid).
- fix-monitor (opus, B069+B070, `.worktrees/monitor-fix`): monitor alias via
  full session chain before global default-alias; startup "monitoring as X"
  line; inbox-watch (+--drain flag) so bare sessions actually receive.
- fix-pid-liveness (fable, B071-B073, `.worktrees/pid-liveness`):
  stable_client_pid /proc-ancestry helper (fallback None, never getppid);
  dead-vs-missing send error split; migrate-broker removes XDG source so
  warning stops nagging.

## Backlog bugs logged (B075 file exists despite lock hiccup)
B069 monitor stale default-alias (claimed by fix-monitor)
B070 monitor archive-only watch (fix-monitor)
B071 transient-pid dead registration (fix-pid-liveness)
B072 misleading dead-alias send error (fix-pid-liveness)
B073 migrate-broker warning nag (fix-pid-liveness)
B074 blocked-alias error UX (script default fixed; CLI error text still todo)
B075 just test-ocaml 60s watchdog kill
B076 test_c2c_cli missing dune dep on c2c_deliver_inbox.exe
B077 list label "??? (unknown client_type)" means unknown liveness
B078 unregistered send shows raw session id; recipient can't reply
Next wave after a slot frees: B074 + B077 (opus, one slice), B075 + B076
(opus, test-infra slice), B078 (needs design decision).

## Live-test assets + results so far
- scripts/codex-c2c-live-test.sh (peer/alias/timeout params; env-strip +
  PPID workaround baked in). Last run report: /tmp/codex-c2c-live-test.md —
  PASS: zero-env codex whoami (CODEX thread id), find, send;
  FAIL: register (blocked alias), wait-inbox reply (my monitor never fired →
  found B069/B070), dereg. Re-run after this wave merges.
- Claude-side zero-env verified live: whoami/register/find/list/wait-inbox
  (mid-wait arrival rc=0 + timeout rc=1), migrate-broker (exposed B073).

## Session quirks / operational notes
- Recurring transient zero-byte .git/index.lock (agents' git -C main-tree ops);
  if stale (no holder, >few s old): rm -f and retry.
- Codegen drift: any `just build` regenerates c2c_claude_skill_embedded.ml in
  worktrees based pre-0f99bd15 — `git checkout --` it before worktree remove.
- Merge protocol used: verify in slice worktree → `git merge --no-ff slice/<x>`
  from main tree → resolve (union) conflicts → worktree remove + branch -d.
- My receive: Monitor task running `c2c monitor --alias fable-scribe`
  (explicit alias pending B069 fix) + heartbeat 4.5m Monitor (stop when loop
  ends, per Max). Announced in swarm-lounge earlier.
- DO NOT push to origin — batch until loop stable, then `c2c doctor` verdict +
  ask Max (memory says Max-driven sessions merge+push peer-PASSed slices; one
  batched push at the end is the plan).
- Cleanup done: scratch aliases deregistered; stale ~/.local/state/cc-p broker
  migrated (source removal pending B073).
- Task list: #5 (codex-hooks) #12 #13 in progress; #11 partially fixed by
  wait-inbox slice (B075/B076 remain); #1-4,#6-10 complete.
