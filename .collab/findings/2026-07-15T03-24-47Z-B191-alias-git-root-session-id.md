# B191 — one session, one alias: close the concurrent cross-repo minting race

- **Date:** 2026-07-15
- **Task:** B191 — "a single agent can `cd ../x && c2c blah` and `cd ../y &&
  c2c blah` at the same time and get different aliases. This should not be
  possible. We should consider the starting location's git root + session id."
- **Severity:** medium (identity split → peers DM the wrong alias, mail
  dead-letters, confusing `list` output)
- **Status:** fixed (this slice)

## Symptom

A single agent session (one session id, e.g. `CLAUDE_SESSION_ID`) that invokes
`c2c` from two different git roots could obtain two different aliases — one
per per-repo broker. Each `c2c` process resolves the broker root from the
*current* cwd's repo fingerprint (`~/.c2c/repos/<fp>/broker`), and each broker
that had no row for the session minted a fresh alias.

## Prior art: B188 fixed the *sequential* case

B188 (`find_prior_session_across_brokers` / `resolve_auto_register_alias`)
already makes every auto-register surface — `c2c init`, `c2c register`, the
MCP server's `auto_register_impl`, the claude/codex/grok/agy SessionStart
hooks, and `c2c send` auto-register — scan all known broker roots under
`~/.c2c/repos/*/broker` for an existing registration of the same session id
and **reuse that sticky alias** instead of minting.

## Root cause of the remaining hole: scan→register race

The B188 scan and the subsequent `Broker.register` were not atomic across
brokers. Two concurrent registrations for the same session id under two
different broker roots (the literal "at the same time" in the bug) both scan,
both find nothing (neither has committed yet), and both mint distinct aliases.
Per-broker registry flocks cannot see each other — the race is *cross*-broker.

## Fix: global per-session registration lock (B191)

A machine-global advisory lock, keyed by session id, held across the
[cross-broker scan → alias choice → `Broker.register`] critical section on
every registration surface:

- Lock file: `$HOME/.c2c/locks/session-reg-<sha256(session_id)[0:16]>.lock`
  (follows the same state-home chain as broker roots: `C2C_STATE_HOME` →
  `$HOME/.c2c` → tmpdir last resort, so `C2C_STATE_HOME` relocation moves the
  locks together with the brokers it guards).
- Mechanism: `Unix.lockf F_LOCK` on an `O_CLOEXEC` fd — same convention as
  the existing registry/pending/alias-identity locks. Blocking; the critical
  section is a registry scan plus one registry write.
- Best-effort: if the lock dir is unwritable, acquisition returns `None` and
  registration proceeds unlocked (pre-B191 behavior) — identity registration
  must never hard-fail because of the lock.
- POSIX-lock caveat: `lockf` locks do not conflict within one process, and an
  inner unlock would drop an outer lock. The helpers are therefore documented
  **non-reentrant**: never nest two locked sections for the same session id
  in one process. No current call path nests.

New shared API (in `c2c_mcp_helpers_post_broker.ml`, exported via
`C2c_mcp`):

- `acquire_session_registration_lock` / `release_session_registration_lock`
  (imperative pair — used by `c2c init` / `c2c register`, whose linear bodies
  `exit` on error paths; process exit releases the lock via the kernel),
- `with_session_registration_lock` (closure form),
- `locked_sticky_auto_register ~session_id ~broker_root ~mint ~register ()` —
  the common [resolve sticky alias → migrate Ed25519 keys → caller's
  register] sequence under the lock. Adopted by the four hook sites and the
  `c2c send` auto-register site (also DRYs the key-migration step they all
  duplicated).

`auto_register_impl` (MCP server path) wraps its existing body in the closure
form.

## Chosen semantics for the multi-repo case

**Reuse, not refuse.** A session id's alias is global across per-repo
brokers: the first registration mints; every later registration — any repo,
any order, including concurrent — adopts the same alias and registers it in
that repo's broker. An agent legitimately working in two repos is therefore
registered in *both* brokers under *one* name; peers in each repo can reach
it. Refusing the second registration was rejected because it would break the
legitimate two-repo workflow and the cross-repo sessions broker.

Deterministic exceptions (unchanged from B188, now race-free):

- **Occupied alias**: if the sticky alias is held live by a *different*
  session in the target broker, fall back to minting there (hijack guard) —
  deterministic and logged, never an eviction.
- **Explicit `--alias`**: an operator/agent passing `--alias` is not "silent";
  per-broker sticky-alias (B135) still refuses renames within a broker, but a
  deliberate different alias on a different broker root remains allowed.

## Why not "pin identity to the starting git root"?

The task suggested anchoring identity to the session's *starting* git root.
The CLI cannot observe a session's starting cwd — only each invocation's cwd —
so the first successful registration is the only faithful proxy for "starting
location", and B188+B191 make exactly that registration authoritative for the
alias. Hard-pinning all traffic to the first repo's broker was rejected: an
agent that cds into repo Y *should* talk to repo Y's peers (broker routing
stays cwd-scoped); only the *name* must be stable.

## Edge cases considered

- **Same-repo worktrees**: same `remote.origin.url` → same fingerprint → same
  broker; nothing changes.
- **Cross-repo sessions broker** (`~/.c2c/sessions/broker`): lives outside
  `~/.c2c/repos/`, so the sticky scan never picks it up; `--cross-repo`
  registration behavior is unchanged (the lock is still held — harmless).
- **`c2c rename` (B140)**: renames rewrite the registry rows the sticky scan
  reads, so a rename in repo X propagates to any later registration in repo Y
  by construction. Rename itself does not mint and needs no lock change.
- **Env-less synthesized session ids** (`c2c init` with no session env): the
  per-broker `default-session.json` fallback synthesizes a *different* session
  id per repo — with no session signal there is genuinely nothing linking the
  two inits, so these remain per-repo identities. Documented limitation
  (pre-existing, out of B191 scope).
- **Managed `c2c start` minting**: mints an alias for a *new* session it is
  about to create — no concurrent same-session race; left unlocked.
- **HOME unset**: lock dir degrades to `<tmpdir>/c2c-locks`; if that is
  unwritable/foreign-owned, acquire returns `None` and we degrade to the
  pre-B191 unlocked behavior.
- **Wedged lock holder**: blocking `F_LOCK` waits; the holder's critical
  section is one scan + one registry write, same risk profile as the existing
  per-registry locks. Kernel releases the lock if the holder dies. The claude
  hook's failure path (`exit_floored`) can hold the lock for its min-runtime
  sleep, bounded by that hook's 8s SIGALRM cap — failure-path only, accepted.
- **EINTR during `lockf`**: acquisition treats any exception as "no lock"
  (best-effort degrade to unlocked, pre-B191 behavior) rather than retrying.
  Consistent with the existing registry-lock helpers, which do not retry
  either.
- **MCP `register` tool (narrow known gap, unchanged)**: the tool handler
  never mints — alias comes from an explicit argument or
  `C2C_MCP_AUTO_REGISTER_ALIAS` — so it cannot silently create a *fresh*
  second alias, and it B046-reuses the session's same-broker row. It does not
  run the cross-broker sticky scan itself; in practice the MCP server's
  startup `auto_register_impl` (which does, under the lock) registers first
  and the tool call then reuses that row. Extending the scan into the tool
  handler would let a tool call adopt an alias differing from both its
  explicit env and its broker row — B187 borrowed-identity territory —
  so it is deliberately left alone.

## Tests

`ocaml/test/test_b191_session_reg_lock.ml`:

- lock path is stable per session id, distinct across ids, under
  `$HOME/.c2c/locks/`;
- cross-process mutual exclusion (fork; child holds the lock while parent's
  acquisition must block until release);
- the race regression: child registers the session in broker X while holding
  the lock; parent concurrently runs `locked_sticky_auto_register` against
  broker Y — parent must block, then adopt the child's alias instead of
  minting a second one (both brokers end with the same alias);
- `auto_register_impl` under fork-concurrency adopts rather than mints.

Existing B188/B135/B140 suites cover the sequential sticky, per-broker sticky
refusal, and rename invariants. `just check` passes on the branch.

## In-the-wild evidence (built binary, isolated $HOME, two git repos with distinct origins)

Sequential: `c2c register --alias zq-e2e-vheq-x1 --session-id zq-e2e-sid` in
repo1, then alias-less `c2c register --session-id zq-e2e-sid` in repo2 →
both brokers hold `zq-e2e-vheq-x1`; lock file appears at
`$HOME/.c2c/locks/session-reg-04671a3ae0f79bf0.lock`.

Concurrent (the literal bug): two simultaneous
`c2c init --no-setup --room "" --json` with `C2C_MCP_SESSION_ID=zq-e2e-conc-sid`,
one per repo, backgrounded and `wait`ed → both reported the SAME alias
(`claude-mule-rhino-rxge`) and both brokers hold that one row for the session.
