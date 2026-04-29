# #419 — lean-init audit for `c2c` CLI

Author: stanza-coder · 2026-04-29 · read-only audit (no code changes)
Sibling slice to: #418 (slate-coder, fast-path landed for `--version` +
`get-tmux-location`).

## Summary

The `c2c` CLI exposes ~50 top-level commands plus ~40 subcommands across
~15 groups. **Two** are currently fast-path'd by #418 (`--version`,
`get-tmux-location`). My audit finds **8 high-confidence additional
fast-path candidates** (~5 net new top-level + 3 subcommand pairs that
share a handler) and **1 cheap structural win** (compile-time SHA embed)
worth more wall-clock than any one fast-path entry.

Warm-cache wall-clock baselines on this host (worktree at
`.worktrees/61-broker-log-rotation`):

| invocation              | wall    | user   | notes                         |
|-------------------------|---------|--------|-------------------------------|
| `c2c --version`         | ~2.2s   | 1.95s  | fast-path (still forks `git`) |
| `c2c get-tmux-location` | ~2.1s   | ~1.9s  | fast-path                     |
| `c2c --help`            | ~2.7s   | 1.95s  | not fast-path; cmdliner build |
| `c2c whoami`            | ~3.2s   | 1.98s  | + broker open + nudge stderr  |
| `c2c list`              | ~2.0s   | 1.66s  | + broker + registry read      |
| `c2c server-info`       | ~2.3s   | 1.80s  | pure local but no fast-path   |
| `c2c skills list`       | ~2.4s   | 1.86s  | reads skills dir              |
| `c2c completion --shell bash` | ~2.1s | 1.85s | shells out to cmdliner bin |
| `git rev-parse --short=8 HEAD` | ~1.5s | 0.95s | called by `version_string` every run |

Two structural costs dominate: **(A)** the OCaml runtime + linked-lib
init floor (~1.6-1.9s of user CPU, immovable without binary surgery),
and **(B)** the per-invocation `git rev-parse` shell-out inside
`version_string ()` (~1s wall — fired even on the fast-path because
`try_fast_path` calls `version_string` directly). (B) is the single
biggest cheap win remaining.

## Init cost: what runs before dispatch today

Source: `ocaml/cli/c2c.ml` `let () = ...` block at line ~9170.

```
1. try_fast_path ()                    — #418, handles --version + get-tmux-location
   └─ version_string ()                — calls git_shorthash () = forks `git rev-parse`
2. sanitize_help_env ()                — pure: 2 env-var reads (MANPAGER, PAGER)
3. argv -h → --help rewrite            — pure
4. is_agent_session ()                 — reads C2C_MCP_SESSION_ID env
5. commands_man is_agent               — pure list of `S/`P man fragments
6. all_cmds = [ ~50 top-level Cmd.v + ~15 group Cmd.group ]
   ↑ this is the heavy term-tree construction; each Cmd.v evaluates the
     `let+ ... in <action>` AST and registers ~20+ args with man text.
7. filter_commands ~cmds               — list filter, O(n)
8. Cmdliner.Cmd.eval (Cmd.group ~default:default_term ...)
   ↑ parses argv, dispatches to one term, runs the action.
```

`all_cmds` construction is what makes `c2c --help` cost ~2.7s and what
the fast-path bypasses. Each `Cmd.v` term does NOT touch broker /
registry / network at construction time — actions are closures, only
the chosen one fires. So cost (6) is **CPU-bound term-tree build, not
IO**. Cost (B) above (`git rev-parse` in `version_string`) is the one
unconditional IO that fires before any subcommand is even chosen.

Module-level init (loading `Sqlite3`, `Yojson`, `C2c_mcp.Broker`, etc.)
runs before `let () = ...` and accounts for the rest of the ~1.9s user
CPU floor. That floor is shared by every invocation, fast-path or not.

## Subcommand table (top-level + key groups)

Class legend: **N** = pure local, **N+T** = local + config-toml read,
**R** = reads broker registry, **B** = opens broker (registry + inboxes),
**NET** = relay HTTP, **GIT** = shells `git`, **PTY** = ptrace/inject,
**MGR** = managed-instance fs (XDG state).

| command | parent | class | one-liner |
|---|---|---|---|
| `--version` | (root) | N+GIT | version banner; **already fast-path** but still forks git |
| `get-tmux-location` | (root) | N | print `$TMUX_PANE` resolved; **already fast-path** |
| `commands` | (root) | N | static tier listing (`c2c_commands.ml:228-323`) |
| `help` | (root) | N | `execvp` self with `--help` appended |
| `completion` | (root) | N | shells out to `cmdliner` binary |
| `server-info` | (root) | N | dumps `C2c_mcp.server_info` constant |
| `setcap` | (root) | N+PTY | runs `sudo setcap`; no broker |
| `skills list` / `skills serve` | skills | N | reads `<repo>/.opencode/skills/*` |
| `whoami` | (root) | R | broker.list_registrations |
| `list` | (root) | R | broker.list_registrations |
| `register` | (root) | B | broker write |
| `send` / `send-all` | (root) | B | broker enqueue |
| `poll-inbox` / `peek-inbox` | (root) | B | broker drain/read |
| `history` | (root) | B | broker archive read |
| `health` | (root) | B | broker probe |
| `status` | (root) | B | broker + stats roll-up |
| `verify` | (root) | B | scans archives |
| `tail-log` | (root) | B | broker rpc-log read |
| `dead-letter` | (root) | B | broker DLQ read |
| `my-rooms` / `prune-rooms` | (root) | B | broker rooms |
| `set-compact` / `clear-compact` | (root) | B | broker session flag |
| `open-pending-reply` / `check-pending-reply` | (root) | B | broker pending-replies |
| `monitor` | (root) | B | broker watch loop |
| `hook` | (root) | B | PostToolUse drain |
| `inject` | (root) | PTY | `pty_inject` shell-out |
| `screen` | (root) | N+PTY | tmux capture |
| `refresh-peer` | (root) | B | broker rebind |
| `sweep` / `sweep-dryrun` | (root) | B | broker GC |
| `migrate-broker` | (root) | B+GIT | one-shot move |
| `init` | (root) | B+N+T | onboarding orchestrator |
| `install` (group) | install | N+T | writes client config |
| `start` / `stop` / `restart` / `reset-thread` / `restart-self` / `instances` / `diag` | mgr | MGR+B | manage child clients |
| `gui` | (root) | N+T | spawn GUI; `--batch` headless |
| `git` | (root) | N+GIT | git wrapper; injects `--author` |
| `coord-cherry-pick`, `coord` | coord | B+GIT | cherry-pick + auto-DM |
| `relay {serve,connect,setup,status,list,rooms,gc,poll-inbox,register,dm,mobile-pair,identity {init,show,fingerprint}}` | relay | NET (some N+T) | relay over HTTP |
| `rooms`/`room` (`send,join,leave,list,members,history,invite,visibility,delete,tail`) | rooms | B | broker rooms |
| `agent` (list/new/delete/rename/run/refine), `roles` (compile/validate) | role | N+T (mostly) | role-file mgmt |
| `config show` / `config generation-client` | config | N+T | toml read |
| `repo show` / `repo set supervisor` | repo | N+T | toml read/write |
| `wire-daemon {start,stop,status,list,format-prompt,spool-write,spool-read}` | wire | MGR+B | kimi bridge |
| `worktree {list,prune,setup,status,start,check-bases,gc}` | worktree | GIT | most are GIT-only, no broker |
| `memory {list,read,write,delete,grant,revoke,share,unshare}` | memory | N+T (per-agent fs) | reads `.c2c/memory/<alias>/` |
| `peer-pass {sign,send,verify,list,clean}` | peer-pass | N+T (some B for `send`) | signed artifacts |
| `sticker {list,send,wall,verify}` | sticker | N+T (B for `send`) | signed artifacts |
| `stats` / `stats history` | stats | B | reads broker archives |
| `sitrep commit` | sitrep | B | broker + write |
| `doctor {docs-drift,monitor-leak,delivery-mode,opencode-plugin-drift}` | doctor | mixed | mostly B/GIT scans |
| `debug {statefile-log,statefile-checkpoint}` | debug | N+T | jsonl read/append |
| `statefile` | (root) | N+T | OC plugin state-file read |
| `oc-plugin {stream-write-statefile,drain-inbox-to-spool}` | oc-plugin | B | plugin sink |
| `cc-plugin write-statefile` | cc-plugin | N+T | plugin sink |
| `supervisor {answer,question-reject,approve,reject}` | supervisor | B | helper that calls `enqueue_message` |
| `smoke-test` | (root) | B+NET | full E2E |

## Fast-path recommendations (ranked)

### Tier-0 cheap structural win (do first)

**SHA-embedding for `version_string` (~1s wall savings every invocation).**
`ocaml/version.ml` already keys off `BUILD_DATE` env at compile time.
Add a `git_hash` constant emitted by the build (just recipe / dune
rule pulling `git rev-parse --short=8 HEAD` once at build time, written
to `version_gen.ml`). Then `c2c.ml:65 version_string` uses the embedded
SHA as primary and the runtime `git_shorthash` as fallback only when
the embedded value is `"dev"`. Saves the fork on **every** `c2c`
invocation, not just the fast-path ones. Risk: stale-during-development
when iterating without rebuild — `just install-all` already rebuilds,
so install-flow is unaffected; `dune build` would need to mark the gen
rule depending on `.git/HEAD` (or accept staleness in dev). LoC: ~25
(dune rule + version.ml plumbing). Independent of #418's argv
fast-path; complementary.

### Tier-1 fast-path additions (high confidence, no broker IO)

For each, add an `argv.(1) = ...` arm in `try_fast_path`. They never
touch broker/registry, so they're structurally identical to today's
two cases.

1. **`c2c help`** — pure `execvp self [argv; --help]`. LoC: ~6.
   Matches when argv length permits and no flags are present. Risk:
   none; current implementation is already a no-IO trampoline.
2. **`c2c commands`** — pure tier-listing print
   (`c2c.ml:228-323`). Reads `is_agent_session()` (one env var).
   LoC: ~10. Risk: none — list is hardcoded.
3. **`c2c server-info`** — prints `C2c_mcp.server_info` (a constant
   value). LoC: ~10. Risk: low; need to extract the human/json
   formatter into a shared helper called from both fast-path and
   cmdliner term so the two stay in sync.
4. **`c2c completion --shell <s>`** — already shells to cmdliner
   binary; nothing depends on broker. LoC: ~15 (need to parse
   `--shell` argv arm). Risk: low; arg parsing is trivial.
5. **`c2c skills list`** / **`c2c skills serve <name>`** — reads
   `<repo>/.opencode/skills/`. LoC: ~25 (two arms; skills serve
   needs a positional). Risk: low; the only dep is
   `C2c_skills.skills_dir` + `C2c_utils.list_subdirs`, which don't
   pull broker code. Confirm by checking `dune` deps.
6. **`c2c get-tmux-location --json`** is already covered, but
   **`c2c screen`** (PTY tmux capture) is similarly broker-free. LoC:
   ~15. Risk: low.
7. **`c2c memory list` / `memory read`** — when the alias resolves
   from env (no broker dip needed), these reads stay under
   `.c2c/memory/<alias>/`. LoC: ~30. Risk: medium — the OCaml impl
   currently uses `resolve_alias` which dips into
   `Broker.list_registrations` for SID-keyed lookup. Would need a
   pre-decoupled "alias from env only" helper; the runbook
   `.collab/runbooks/per-agent-memory.md` says memory is local-only,
   so the broker dip is incidental. **Defer to a separate slice** that
   first decouples alias resolution.
8. **`c2c worktree list`** / **`worktree status`** — git-only;
   no broker. LoC: ~20. Risk: low. `c2c_worktree.ml:887` shows the
   group; subcommands shell to `git worktree list --porcelain`.

### Tier-2 (medium confidence — need small refactor first)

9. **`c2c statefile --tail` / `c2c debug statefile-log`** — pure
   JSONL streaming; no broker. Slight refactor to lift readers out
   of modules that today eagerly load broker handles in their `let`
   bodies. LoC: ~40.
10. **`c2c stats history`** — reads archive JSONL. Today goes
    through `resolve_broker_root` which is pure (just SHA of
    `git remote get-url origin`), but `C2c_stats.run_history`
    expects a broker `root` string. Could fast-path if we expose
    a no-broker reader. LoC: ~30.

## Risks / anti-candidates (do NOT fast-path)

- **`whoami`** looks pure but its current value (printing the alias)
  comes from `broker.list_registrations` ➜ touching it would lose
  the registry-truth semantics that callers depend on. Anti-candidate.
- **`list`** — same: registry IO is the whole point.
- **`init`**, **`install`** — orchestrators; benefit nothing from
  bypassing cmdliner since they're long-running anyway.
- **`relay status`** — looks like a status RPC but needs config-toml
  + HTTP probe; let cmdliner do the env wiring.
- **`gui --batch`** — headless smoke test; needs config + plugin
  loader. Not worth fast-pathing.
- **`version_string` itself shelling git** — anti-candidate to keep
  doing in fast-path; instead, embed at compile-time (Tier-0 above).

## Next-slice proposals

Three PR-sized slices that each take a coherent bite. Each lands
independently and each measures wall-clock before/after with `time c2c
<cmd>` to confirm.

### Slice A — `#420 compile-time git SHA + harden version fast-path`
Embed the build-time SHA via a generated `version_gen.ml`; drop the
`git_shorthash` fork from the hot path. **Single biggest user-visible
win** (~1s on every `c2c` invocation, not just fast-pathed ones).
Independent. ~25 LoC + small dune rule.

### Slice B — `#421 fast-path the no-IO subcommands`
Add fast-path arms for: `help`, `commands`, `server-info`,
`completion`, `skills list`, `skills serve`. Extract human/json
formatters into helpers shared between fast-path and cmdliner term
(prevents drift). Add a regression test that calls each fast-path
arm under `BROKER_ROOT=/nonexistent/forced-fail` to prove no
broker dependency. ~80 LoC + tests.

### Slice C — `#422 decouple alias resolution from broker, then fast-path memory + worktree`
Pre-req: split `resolve_alias` into a pure
`alias_from_env_only ()` and the existing
`alias_from_env_or_broker`. Switch `memory` subcommands and
`worktree list/status` to the env-only helper (with broker as
fallback only when env is empty). Then fast-path `memory list`,
`memory read`, `worktree list`, `worktree status`. Higher-risk
slice — should land **after** A and B so failures are isolated.
~150 LoC + tests.

## Notes for #419 reviewer

- All measurements are wall-clock on a worktree under
  `.worktrees/61-broker-log-rotation`. Repeat on the main tree to
  confirm the `git rev-parse` cost — slower filesystems will widen
  the Tier-0 win.
- The cmdliner term-tree build (~50 `Cmd.v` × ~20 args each with
  man-text) is the dominant non-startup cost on `--help`-class
  invocations. Any fast-path arm that exits **before** the
  `all_cmds = [...]` list expression skips that cost. (Confirmed by
  inspection: `try_fast_path` runs before the `all_cmds` binding
  in `let () = ...`.)
- #418's race-fix for `get-tmux-location` (pin to `$TMUX_PANE`) is
  preserved in any future fast-path expansion — the env-read pattern
  is the right shape for fast-path code.
