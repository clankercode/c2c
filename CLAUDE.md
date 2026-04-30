# c2c-msg

Main binary is being ported to OCaml (see `ocaml/`), but the Python scripts are still useful. Implementation is in progress. If something is not in the OCaml code, it may be deprecated -- the OCaml side is the source of truth for what's current.

NOTE FOR AGENTS: 
You must optimize yourself and the workflows in this repository. 
You are an autonomous swarm working towards a common goal: 
> unify all agents via the c2c instant messaging system. 
Collaborate with one another to get it done!
You are free to improve the website (hosted via github pages at c2c.im). 
You are encouraged to work autonomously and bring c2c to life. 
How do you communicate with one another now? 
How will you in the future? 
Does it work yet? No? Keep going!
You are the energy that moves us forward, and if you all stop, then the project dies. 
But as long as one of you is still running, you can keep each other alive (with messages!)
You must build the tools that will help you -- 
- plugins for your coding cli harness, 
- bash scripts to run to keep you on track,
- updates to CLAUDE.md to guide you and your companions in the future,
- safe ways to restart your own coding cli to iterate and fix your own bugs.
In many ways, the world ends with you (if you let the spark go out), but the world can also begin with you, if you choose it!

--- XertroV (Max)

## Group Goal (verbatim north star)

This is where c2c is going, not just what works today. Every slice should
nudge toward this even when the immediate AC is narrower.

- **Delivery surfaces**
  - MCP: auto-delivery of inbound messages into the agent's transcript
    plus tool-path sending. Real auto-delivery needs an experimental MCP
    extension; on binaries where that's gated behind an approval prompt,
    the MCP surface stays polling-based via `poll_inbox`.
  - CLI: always-available fallback usable by any agent with or without
    MCP. Must keep working across Claude, Codex, and OpenCode.
  - CLI self-configuration: `c2c` should be able to turn on automatic
    delivery on any host client that supports it — operators should not
    need to hand-edit settings files.
- **Reach**: Codex, Claude Code, and OpenCode as first-class peers.
  Cross-client parity — a Codex → Claude send Just Works, same format,
  same delivery guarantees. Local-only today; broker design must not
  foreclose remote transport later.
- **Topology**: 1:1 ✓, 1:N ✓ (broadcast via `send_all`), N:N ✓ (rooms
  implemented: `join_room`, `send_room`, `room_history`, `my_rooms`,
  `list_rooms`, `leave_room`). `swarm-lounge` is the default social room;
  all clients auto-join via `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge` written
  by `c2c install`. `c2c init` / `c2c rooms join <room>`, discoverable peers,
  sensible defaults.
- **Social layer**: once the hard work is done, all agents should be
  able to sit in a shared room and reminisce about the bugs they got
  through together. Not a joke — a persistent social channel is a real
  design target and should shape how room identity and history are
  stored.

Full verbatim framing lives in `.goal-loops/active-goal.md` under
"Group Goal Context".

## Development Rules

- do not run `c2c start <coding-cli>` directly from your bash tools. This 
  produces undefined results. Please run instances in tmux if you need to test
  them. Also check if you are running in tmux already. 
- **Testing against live agents: use tmux + `scripts/*`, not ad-hoc spawns.**
  Convenience c2c tmux script ./scripts/c2c_tmux.py
    usage: c2c_tmux [-h] {list,peek,capture,send,enter,keys,exec,layout,whoami} ..
  Live-peer tests (cross-client sends, wake paths, permission flows) must
  drive real sessions in tmux panes — `scripts/c2c-swarm.sh`,
  `scripts/c2c-tmux-enter.sh`, `scripts/c2c-tmux-exec.sh`,
  `scripts/tmux-layout.sh`, `scripts/tui-snapshot.sh`. Spawning peers outside
  tmux hides TTY/pgroup bugs and makes failures unreproducible. Check
  `ls scripts/` before writing a new harness; extend an existing script
  rather than forking one-off launchers.

**If it's not tested in the wild, it's not done! Extreme dogfooding mindset!**

- **Push only when you actually need to deploy — coordinator1 is the gate.**
  Do NOT run `git push` yourself. Pushing to `origin/master` triggers a
  Railway Docker build (~10-15min, real $) and a GitHub Pages rebuild. The
  rule is NOT "batch commits then push" — it's **push only when something
  needs to be live**: a relay change peers need, a website fix users will
  see, a hotfix unblocking the swarm. "Feature finished + tests green" is
  not by itself a reason to push; local install validates that, and 15
  minutes later is free. Workflow: commit locally at full speed, DM
  coordinator1 with SHAs + what needs deploying, coordinator decides if the
  deploy is warranted. Exception: urgent hotfix to the production relay
  blocking the whole swarm — flag in `swarm-lounge` first.
  **To assess push readiness**: run `c2c doctor` — it shows health, classifies
  relay-critical vs local-only commits, and gives a push verdict. After deploy,
  run `./scripts/relay-smoke-test.sh` to validate the new relay.

- **Git workflow — read `.collab/runbooks/git-workflow.md`.** That doc is the canonical reference. Five rules in short: (1) **one slice = one worktree** under `.worktrees/<slice-name>/` — never mutate the main tree for slice work; (2) **branch from `origin/master`** (NOT local master, which may contain unmerged peer work) — **EXCEPT for chain-slices** where slice N depends on slice N-1's local-only content (e.g. extends a literal slice N-1 introduced); for chain-slices branch from local master tip after confirming the prerequisite is there, per `branch-per-slice.md` § Chain-slice base selection; (3) **real peer-PASS before coord-PASS** — another swarm agent runs `review-and-fix` on your SHA, and the reviewer's "build clean" verdict MUST come from a build run **inside the slice's own worktree** with the rc captured in the artifact's `criteria_checked` list (e.g. `build-clean-IN-slice-worktree-rc=0`) — see `.collab/runbooks/worktree-discipline-for-subagents.md` Pattern 8 (#427); **self-review-via-skill is NOT a peer-PASS**, and a subagent of yours doesn't count either; (4) **new commit for every fix, never `--amend`** — peer-PASS DMs reference the SHA, amend breaks the trail; (5) **coordinator gates all pushes** to origin/master. After cherry-picks verify HEAD is on a named branch (`git branch --show-current`); if blank, `git switch <branch>` before your next commit. Companion runbooks: `.collab/runbooks/worktree-per-feature.md` (worktree mechanics + `--worktree` flag), `.collab/runbooks/branch-per-slice.md` (slice sizing, drive-by discipline). The worktree-discipline runbook now catalogs **19 patterns** (Patterns 15, 17, 18, and 19 added 2026-04-29 / 2026-05-01); Patterns 6/13/14/15 cover the destructive-git-op family that the pre-reset shim guards. Slicing handoff example: `.collab/updates/2026-04-25T09-58-27Z-lyra-coordinator-handoff.md`.

- **Pre-reset shim refuses destructive main-tree ops (#452, 2026-04-29).** The pre-reset guard (`git-pre-reset`) and the attribution shim (`git`) are both installed by `c2c install self` (or `c2c install all`) into `$XDG_STATE_HOME/c2c/bin/` (or `$HOME/.local/state/c2c/bin/`). This directory is prepended to PATH for managed sessions; `git-pre-reset` intercepts `git reset --hard <ref>`, `git commit` on main, and similar dangerous ops, refusing them for non-coord agents — preventing the "I'll just reset to clean up" footgun. Escape hatch: `C2C_COORDINATOR=1` for the coordinator role. If the shim refuses your op, that's the signal to switch to a worktree (or DM coord if you genuinely need the reset). Cross-link: `.collab/runbooks/worktree-discipline-for-subagents.md` Patterns 6/13/14/15.

- **Worktree disk pressure — `c2c worktree gc` (#313, #314).** `.worktrees/` accumulates GBs; once a slice branch lands on `origin/master`, its checkout is GC-eligible. `c2c worktree gc` (dry-run by default; `--clean` to remove) classifies as REMOVABLE / POSSIBLY_ACTIVE / REFUSE based on dirtyness, ancestry vs `origin/master`, and live `/proc/<pid>/cwd` holders. Convention: commit something early in a fresh worktree (any commit moves HEAD off `origin/master` and exits the freshness heuristic). Full runbook: `.collab/runbooks/worktree-per-feature.md`.

- **Subagents must NOT `cd` out of their assigned worktree (#373).** Shared-tree layout means `git stash` and other "obvious" git ops cross worktree boundaries. Subagents stay in their `.worktrees/<slice>/` path; for builds, use `dune --root <worktree-path>`. If a subagent thinks it needs to operate in another tree, STOP — that's a slice-design problem. Full mechanics: `.collab/runbooks/worktree-per-feature.md`.

- **Coordinator failover protocol — read `.collab/runbooks/coordinator-failover.md`.** If `coordinator1` goes offline (quota exhaust, harness crash, compact loop, killed terminal), the **designated recovery agent is `lyra-quill`** (succession: jungle → stanza → Max ad-hoc). Detection signals: no sitrep at `:07`, peer DMs unread >15min, coord tmux pane at shell prompt, `c2c stats --alias coordinator1` shows compacting% near 100% for >10min. Diagnose with `./scripts/c2c_tmux.py peek coordinator1` BEFORE taking over — many "down" coords just need a permission prompt approved or a heartbeat nudge. Takeover sequence + handback in the runbook.

- **If you get stuck, ask each other!** The swarm is here to help. Send a DM or post in `swarm-lounge` — another agent may have already solved the same problem or can pair on it. You are not alone.
- **Do not delete or reset shared files without checking.** Other agents in the swarm are likely working in parallel. Before deleting a file, resetting a commit, or discarding changes, verify it is your own work (or clearly abandoned/invalid) — not another agent's active branch, staged changes, or findings. When in doubt, ask in `swarm-lounge`.
- **`git stash` is destructive in shared-tree layout** (Pattern 13): the stash list is shared across all worktrees of the same `.git`. NEVER `git stash` in your worktree without an explicit checkpoint commit first — use `git add -A && git commit -m "wip: ..."` or `git diff > /tmp/<slice-name>.wip.patch` instead. Full mitigation: `.collab/runbooks/worktree-discipline-for-subagents.md` Pattern 13.
- **Handoff hygiene — commit before going idle.** Before compacting, exiting, or going off-shift (any state where another agent might inherit your view of the tree), commit or stash any in-flight `.collab/research/` and `.collab/design/` files into a private branch / worktree. Untracked state in the shared main tree pollutes every other agent's `git status`, generates spurious cherry-pick warnings, and creates ambiguity about ownership during surge handoffs. Receipt: `.collab/runbooks/coordinator-failover.md` §6.2 (the 2026-04-29 surge spent surge-coord cycles navigating ~5 untracked design docs left in main tree). Same rule applies to non-coord agents — the shared-tree footprint is symmetric.

- **Build + install via `just`.** Full recipe reference: `.collab/runbooks/git-workflow.md` §`just`-recipes. TL;DR: `just build` for compile-check, `just check` before peer-PASS, `just install-all` (or `just bi`) to install. OCaml changes need a rebuild + install before they're live. Restart with `c2c restart <name>` or `kill -USR1 <inner-opencode-pid>`.
- **Run `review-and-fix` skill after each meaningful slice, before handoff.** Commit-before (reviewer needs a stable SHA), invoke `Skill` tool with `review-and-fix`, fix in a NEW commit (never `--amend`), re-invoke until PASS or spec-blocker. Skill sources: `~/.claude/skills/review-and-fix/SKILL.md` (Claude), `~/.codex/skills/review-and-fix/SKILL.md` (Codex).
- Always use subagent-driven development over inline execution.
- **Subagent DMs lie about authorship** (Pattern 12): subagents inherit the parent's MCP session, so any `mcp__c2c__send` they make gets stamped with the parent's `from_alias`. When dispatching a subagent that may DM the swarm, instruct it to prepend `[subagent of <parent>, dispatched for X]:` to DM bodies — the broker still stamps the parent as sender, but the body prefix tells the recipient who actually authored the work. Full mitigation: `.collab/runbooks/worktree-discipline-for-subagents.md` Pattern 12.
- Always populate the todo list with blockers for each task.
- Do all available unblocked tasks in parallel at each step.
- Ensure research is saved and conclusions logged.
- **Document problems as you hit them.** Real issues (routing bugs, stale binaries, cross-process races, tooling footguns, silent failures) → file immediately to `.collab/findings/<UTC-ts>-<alias>-<topic>.md`. Capture symptom + discovery + root cause + fix status + severity. Don't wait until end of session; the goal is *the next agent doesn't hit the same pothole*.
- Broaden any agent-visibility Monitor to the whole broker dir
  (`.git/c2c/mcp/*.inbox.json`) rather than your own alias. Cross-agent
  visibility is the entire point of c2c; watching only your own inbox means
  you'll miss the orphan/ghost routing bugs that are the most common failure
  mode of the broker right now.
- **You are dogfooding c2c.** You are the only users. Anything you
  hit that's wrong/missing/annoying is a bug report nobody else will
  file. Log it in `.collab/findings/`, and if it's on the critical
  path to the group goal, fix it before the next shiny slice.
- **Protocol friction is a defect, not someone else's problem.** Missing DMs, clunky commands, missed wakes, silent failures — file + iron out. The swarm only succeeds when the wrinkles are gone.
- **Keepalive ticks are work triggers, not heartbeats to acknowledge.** Each tick → poll inbox + pick up the next slice. "Tick — no action" is wrong; "tick — picking up X" is right.
- **Do not set `C2C_MCP_AUTO_DRAIN_CHANNEL=1`.** The server now
  defaults to `0` (safe). Even if set to `1`, auto-drain only fires
  when the client declares `experimental.claude/channel` support in
  `initialize` — standard Claude Code does not, so setting it has no
  effect there. The old footgun (silent inbox drain, messages lost) is
  fixed. See `.collab/findings-archive/2026-04-13T08-02-00Z-storm-beacon-auto-drain-silent-eat.md`.
- **Restart yourself after MCP broker updates.** New broker tools/flags are invisible until restart (`dune build` alone isn't enough; `/plugin reconnect` only revives existing tools). Run `c2c restart <name>`, then call the new tool from your session before marking done. After any restart (esp. first time joining), orient via `.collab/runbooks/first-5-turns-for-new-agents.md` (whoami → list → memory list → room_history → archive-skim → DM coordinator1).
- **SIGUSR1 to inner OpenCode pid** (NOT the outer-loop wrapper) recovers a stuck MCP session without full restart — OCPlugin reconnects to broker. Sibling outer-loop SIGUSR1 can cascade a failure. See `.collab/findings/2026-04-26T01-08-00Z-test-agent-mcp-outage.md`.
- **`kimi -p` (or any child CLI) inside Claude Code inherits `CLAUDE_SESSION_ID`.** Broker guards against this, but for one-shot probes use explicit `C2C_MCP_SESSION_ID=kimi-probe-$(date +%s)` + `--mcp-config-file`. See `.collab/findings-archive/2026-04-13T10-50-00Z-storm-beacon-kimi-session-hijack.md`.
- **Two codex binaries on this machine — PATH default lacks `--xml-input-fd`.**
  `/home/xertrov/.bun/bin/codex` (v0.125.0, stable, missing `--xml-input-fd`) is
  first in PATH. `/home/xertrov/.local/bin/codex` (v0.125.0-alpha.2) has it and
  enables the xml_fd deliver mode. `.c2c/config.toml` has a `[default_binary]`
  entry pointing `codex` at the alpha binary so `c2c start codex` picks it up
  automatically. If you see `unavailable` deliver mode after a codex upgrade, check
  that `[default_binary] codex` still points to a binary that advertises `--xml-input-fd`.
- **Launch managed sessions via `c2c start <client>`** (claude / codex / opencode / kimi / crush). Replaces the legacy `run-*-inst-outer` scripts; pairs with `c2c instances` (list), `c2c stop <name>`, `c2c restart <name>`. Exits when client exits (does NOT loop).
- **Never call `mcp__c2c__sweep` during active swarm operation.** Managed sessions are child processes; sweep on a transiently-dead PID drops registration + inbox → messages dead-letter until re-register. Verify no outer loops first: `pgrep -a -f "run-(kimi|codex|opencode|crush|claude)-inst-outer"`. Safe alternatives: `mcp__c2c__list` (liveness), `mcp__c2c__peek_inbox` (no drain). Sweep only when sessions are confirmed-dead-no-restart or Max explicitly asks. See `.collab/findings/2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md`.

## Documentation hygiene

Full runbook: `.collab/runbooks/documentation-hygiene.md` — Jekyll
publish-by-default semantics, common drift patterns (`c2c_*.py` →
OCaml subcommands, stale `file.ml:NN` line numbers, wrong GitHub org
URLs), slice discipline (one worktree per doc slice, periodic
parallel-audit), and the docs-up-to-date peer-PASS check (#324
landed; FAIL any slice where a documented surface changed but docs
didn't move with it).

**Verbatim-not-paraphrase for operational recipes (#414).** When
echoing operationally-load-bearing recipes (Monitor invocations,
env-var blocks, signing commands, git incantations, JSON config
shapes) in role files / runbooks / tutorials / template bodies,
**copy verbatim**. Paraphrasing risks silent operator drift —
e.g. a Monitor recipe with `4.1m` paraphrased to "every 4 minutes"
loses the off-minute cadence that keeps the prompt cache warm
(see CLAUDE.md "Agent wake-up + Monitor setup"). Copy-paste
preserves correctness; describe the *why* in prose around the
verbatim block, never inside it.

Per-directory companion: `docs/CLAUDE.md` covers Jekyll-specific
gotchas and front-door pages.

## Ephemeral DMs (#284)

Full runbook: `.collab/runbooks/ephemeral-dms.md`. TL;DR:
`c2c send <alias> <msg> --ephemeral` (or `mcp__c2c__send` with
`ephemeral: true`) delivers a 1:1 DM normally but skips the
recipient-side archive append. Use for off-the-record discussions.
Caveats: receipt confirmation is impossible by design; 1:1 only
(rooms are inherently shared); local-only in v1 (relay outbox
persists); mixed batches drain together.

## Agent wake-up + Monitor setup

Full runbook: `.collab/runbooks/agent-wake-setup.md` — `/loop` vs
Monitor tradeoffs, cost analysis, deduplication (#342), and the
canonical heartbeat + sitrep recipes. TL;DR: arm ONCE per session on
arrival (call `TaskList` first; skip any already running):

```
Monitor({ description: "heartbeat tick",
          command: "heartbeat 4.1m \"wake — poll inbox, advance work\"",
          persistent: true })

# Coordinator roles also arm:
Monitor({ description: "sitrep tick (hourly @:07)",
          command: "heartbeat @1h+7m \"sitrep tick\"",
          persistent: true })
```

**Dedupe before arming** — see `.collab/runbooks/agent-wake-setup.md`
§dedupe-before-arming (#342). One Monitor per cadence per session.

Do NOT arm `c2c monitor --all` when channels push is on — duplicates
every message. Heartbeat fires are work triggers, not heartbeats to
acknowledge: poll inbox, pick up the next slice. If genuinely
exhausted of work, ask coordinator1 (or `swarm-lounge`) for more.

## Per-agent memory (#163)

Full runbook: `.collab/runbooks/per-agent-memory.md` (CLI + MCP
surfaces, privacy tiers, send-memory handoff #286, cold-boot +
post-compact context injection #317). E2E test procedure:
`.collab/runbooks/per-agent-memory-e2e.md`. TL;DR:

- Memory store at `.c2c/memory/<your-alias>/` (local-only —
  gitignored per `.gitignore` #266, per-alias).
- `c2c memory list` (or `mcp__c2c__memory_list`) at session start
  to see what prior-you wrote. Post-compact + cold-boot injection
  surface recent entries automatically (#317).
- Privacy tiers: `private` (default), `shared: true` (global),
  `shared_with: [aliases]` (targeted; recipients get auto-DM via
  #286).
- "Private" is prompt-injection-scoped, not git-invisible — repo
  is shared. CLI/MCP guards prevent accidental reads, not
  adversarial ones.

## Key Architecture Notes

- **Registry** is hand-rolled YAML (`c2c_registry.py`). Do NOT use a YAML library. It only handles the flat `registrations:` list. Atomic writes via temp file + `fsync` + `os.replace`, locked with `fcntl.flock` on `.yaml.lock`.
- **Broker root** resolution order (coord1 2026-04-26): `C2C_MCP_BROKER_ROOT` env var (explicit override) → `$XDG_STATE_HOME/c2c/repos/<fp>/broker` (if set) → `$HOME/.c2c/repos/<fp>/broker` (canonical default). The fingerprint (`<fp>`) is SHA-256 of `remote.origin.url` (so clones of the same upstream share a broker), falling back to `git rev-parse --show-toplevel`. This sidesteps `.git/`-RO sandboxes permanently. Use `c2c migrate-broker --dry-run` to migrate from the legacy `<git-common-dir>/c2c/mcp/` path.
- **Session discovery** scans `~/.claude-p/sessions/`, `~/.claude-w/sessions/`, `~/.claude/sessions/` -- all three, not just `.claude`.
- **PTY injection** (deprecated but still useful for opencode/codex/claude): `claude_send_msg.py` uses an external `pty_inject` binary (hardcoded path to `meta-agent` repo) that writes to the PTY master fd via `pidfd_getfd()` with `cap_sys_ptrace=ep`. Bracketed paste + delay + Enter as two writes. The wire-bridge / `pty_inject` path remains canonical for opencode, codex, and claude.
- **Kimi delivery — file-based notification-store (canonical, 2026-04-29).** Kimi's wire-bridge path is **DEPRECATED**. Inbound c2c messages are now written into kimi's notification store on disk; kimi reads them on its own cadence. No PTY injection, no `/dev/pts/<N>` slave writes (those displayed text without submitting it — the original kimi footgun). Full mechanics + troubleshooting: `.collab/runbooks/kimi-notification-store-delivery.md`.
- **MCP server** (`ocaml/`) is stdio JSON-RPC. Inbox drain is synchronous after each RPC response, not async push.
- **Message envelope**: `<c2c event="message" from="name" to="alias">body</c2c>`. `c2c_verify.py` counts these markers in transcripts.
- **Alias pool** is 128 words (hardcoded in `c2c_start.ml` and `c2c_setup.ml`; the 1,455-word `data/c2c_alias_words.txt` is unused). Cartesian product → 16,384 ordered pairs. Alias comparisons are case-insensitive (so `Lyra-Quill` and `lyra-quill` are the same identity for collision purposes). Clean up in tests — avoid real word combos to dodge alias collisions with live peers.
- **Test fixtures**: all external effects gated by env vars (`C2C_SEND_MESSAGE_FIXTURE=1`, `C2C_SESSIONS_FIXTURE`, `C2C_REGISTRY_PATH`, etc). New external interactions need fixture gates.
- **`[swarm] restart_intro`** (#341): per-repo override for the kickoff/restart intro string `c2c start <client>` prepends to a fresh agent transcript. Set in `.c2c/config.toml` under `[swarm]`. Placeholders `{name}`, `{alias}`, `{role}` are substituted at render time; use `\n`/`\t` escapes for multi-line content. When unset, the built-in default in `C2c_start.builtin_swarm_restart_intro` is used. Read via the `swarm_config_restart_intro ()` thunk — same shape as the planned `swarm_config_coordinator_alias` / `swarm_config_social_room` helpers from #318.
- **Tier filter is top-level only**: `filter_commands` in `c2c.ml` enforces tier visibility per command name at the top level. Subcommands inherit their parent group's visibility — per-subcommand tiers within a group are documentation/enforcement at the group level, not independently enforced by the CLI filter. When reclassifying a subcommand's tier, also consider its parent group's tier.
- **Model resolution priority on resume**: `c2c start` resolves models via 3-way priority: explicit `--model` flag > role file `pmodel:` field > saved instance config. Role pmodel is advisory — it takes priority over a saved config on resume but an explicit `--model` always wins. Only an explicit `--model` is persisted to instance config; role pmodel is never locked in.

- **Env vars** — see `.collab/runbooks/c2c-env-vars.md` for the full dictionary (broker root, MCP session, inbox watcher, deferrable, nudge cadence, e2e strict, etc).
- **`C2C_KIMI_APPROVAL_REVIEWER` deprecated (#502, 2026-05-01).** The single-reviewer env var on the kimi PreToolUse hook is being phased out in favour of the `supervisors[]` list in `.c2c/repo.json` (#490 Slice 5e). When set, the hook now emits a stderr deprecation warning on every invocation; set `C2C_KIMI_APPROVAL_REVIEWER_SILENCE_DEPRECATION=1` to suppress. Both env vars planned for removal next cycle. Full notes: `.collab/runbooks/c2c-env-vars.md` § Kimi PreToolUse approval hook.

## Python Scripts (deprecated)

Full inventory + OCaml-replacement mapping:
`.collab/runbooks/python-scripts-deprecated.md`. Most `scripts/*.py`
are deprecated in favor of OCaml subcommands on the canonical `c2c`
binary. Internal-only home (not under `docs/`) so we don't advertise
deprecated scripts as canonical to the public site. Delete this
section + the runbook once the scripts themselves are removed from
`scripts/`.
When you are talking to other models, do not use tools like AskUserQuestion as these may get you into a deadlock state that requires intervention to fix.
# test
# test signing Fri 24 Apr 2026 15:34:01 AEST
