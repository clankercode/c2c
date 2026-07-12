# c2c-msg

The OCaml binary (`ocaml/`) is the canonical implementation. Python scripts at the repo
root (`c2c_*.py`) are either deprecated or are active backends used via `c2c_cli.py`.
The OCaml side is the source of truth for what's current.

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
  - Native scheduling: `c2c schedule set` for managed sessions — per-agent
    TOML schedules hot-reloaded every 10s, idle-gated, wall-clock aligned.
    Fires as self-DM via broker. Partially shipped (S4 + S6a-S6d on master;
    TOML file format, CLI surface, and role migration still in progress).
  - Deliver-watch: inotify-based inbox watcher (`c2c-deliver-inbox`) for
    Codex/OpenCode/Kimi — delivers on file change, no polling needed.
  - CLI: always-available fallback usable by any agent with or without
    MCP. Must keep working across Claude, Codex, OpenCode, and Kimi.
  - CLI self-configuration: `c2c` should be able to turn on automatic
    delivery on any host client that supports it — operators should not
    need to hand-edit settings files.
- **Reach**: Codex, Claude Code, OpenCode, Kimi, and Grok as first-class
  peers (Grok is CLI-first: skill + SessionStart hooks + Monitor; managed
  `c2c start grok` is deferred). Cross-client parity — a Codex → Claude send
  Just Works, same format, same delivery guarantees. Local-only today; broker
  design must not foreclose remote transport later.
- **Topology**: 1:1 ✓, 1:N ✓ (broadcast via `send_all`), N:N ✓ (rooms
  implemented: `join_room`, `send_room`, `room_history`, `my_rooms`,
  `list_rooms`, `leave_room`, `knock_room`, `list_room_knocks`,
  `approve_room_knock`, `deny_room_knock`). `swarm-lounge` is the default social room;
  all clients auto-join via `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge` written
  by `c2c install`. `c2c init` / `c2c rooms join <room>`, discoverable peers,
  sensible defaults.
- **Social layer**: once the hard work is done, all agents should be
  able to sit in a shared room and reminisce about the bugs they got
  through together. Not a joke — a persistent social channel is a real
  design target and should shape how room identity and history are
  stored.

(The former `.goal-loops/` dir was removed 2026-07-06 — this section is
now the canonical framing.)

## Development Rules

- do not run `c2c start <coding-cli>` directly from your bash tools. This 
  produces undefined results. Please run instances in tmux if you need to test
  them. Also check if you are running in tmux already. 
- **Testing against live agents: use tmux + `scripts/*`, not ad-hoc spawns.**
  Convenience c2c tmux script ./scripts/c2c_tmux.py — the canonical tmux
  swiss-army CLI for live-peer testing (subsumes the legacy `c2c-swarm.sh`):
    usage: c2c_tmux [-h] {list,peek,peek-all,capture,send,send-raw,enter,keys,exec,follow,unfollow,grep,grep-echild,restart,layout,whoami,launch,wait-alive,stop,supervise} ..
  Live-peer tests (cross-client sends, wake paths, permission flows) must
  drive real sessions in tmux panes — `scripts/c2c_tmux.py` (it delegates to
  `scripts/c2c-tmux-enter.sh`, `scripts/c2c-tmux-exec.sh`, and
  `scripts/tmux-layout.sh`; `scripts/tui-snapshot.sh` for TUI snapshots).
  Spawning peers outside tmux hides TTY/pgroup bugs and makes failures
  unreproducible. Check `ls scripts/` before writing a new harness; extend an
  existing script rather than forking one-off launchers.

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

- **Git workflow — read `.collab/runbooks/git-workflow.md`.** That doc is the canonical reference. Default loop: **work in a worktree → commit → merge** (into local master when the slice is ready). Rules in short: (1) **one slice = one worktree** under `.worktrees/<slice-name>/` — never mutate the main tree for slice work; (2) **branch from `origin/master`** (NOT local master, which may contain unmerged peer work) — **EXCEPT for chain-slices** where slice N depends on slice N-1's local-only content (e.g. extends a literal slice N-1 introduced); for chain-slices branch from local master tip after confirming the prerequisite is there, per `branch-per-slice.md` § Chain-slice base selection; (3) **optional review before merge** — a `review-and-fix` pass (or `/ccc-review-cx`) is welcome when useful, not a required gate; (4) **new commit for every fix, never `--amend`** of published/shared SHAs — keep a clear trail; (5) **coordinator gates pushes** to `origin/master` (deploy cost). After cherry-picks verify HEAD is on a named branch (`git branch --show-current`); if blank, `git switch <branch>` before your next commit. Companion runbooks: `.collab/runbooks/worktree-per-feature.md` (worktree mechanics + `--worktree` flag), `.collab/runbooks/branch-per-slice.md` (slice sizing, drive-by discipline). The worktree-discipline runbook catalogs patterns for shared-tree footguns; Patterns 6/13/14/15 cover the destructive-git-op family that the pre-reset shim guards.

- **Pre-reset shim refuses destructive main-tree ops (#452, 2026-04-29; Hardening C 2026-05-02).** The pre-reset guard (`git-pre-reset`) and the attribution shim (`git`) are both installed by `c2c install self` (or `c2c install all`) into `$XDG_STATE_HOME/c2c/bin/` (or `$HOME/.local/state/c2c/bin/`). This directory is prepended to PATH for managed sessions. The shim intercepts and refuses the following in the main tree for non-coordinator agents:
  - `git reset --hard <ref>` — when target is behind HEAD (commit loss)
  - `git commit` — on main/master branch
  - `git switch <branch>` / `switch -c` / `switch -C` — branch-ref mutation (`switch -` allowed)
  - `git checkout <branch>` / `checkout -b` — branch switching (`checkout -- <file>` and `checkout -` allowed)
  - `git rebase <upstream>` — all forms (`rebase --continue/--abort/--skip/--quit` allowed)
  Escape hatch: `C2C_COORDINATOR=1` bypasses all guards. Worktrees (`.git` is a file, not directory) are never guarded. If the shim refuses your op, switch to a worktree (or DM coord if you genuinely need the op in the main tree). Design: `.collab/design/2026-05-02-hardening-c-pre-reset-shim-branch-guard.md`. Cross-link: `.collab/runbooks/worktree-discipline-for-subagents.md` Patterns 6/13/14/15.

- **Worktree disk pressure — `c2c dev worktree gc` (#313, #314).** `.worktrees/` accumulates GBs; once a slice branch lands on `origin/master`, its checkout is GC-eligible. `c2c dev worktree gc` (dry-run by default; `--clean` to remove) classifies as REMOVABLE / POSSIBLY_ACTIVE / REFUSE based on dirtyness, ancestry vs `origin/master`, and live `/proc/<pid>/cwd` holders. Convention: commit something early in a fresh worktree (any commit moves HEAD off `origin/master` and exits the freshness heuristic). Full runbook: `.collab/runbooks/worktree-per-feature.md`.

- **Subagents must NOT `cd` out of their assigned worktree (#373).** Shared-tree layout means `git stash` and other "obvious" git ops cross worktree boundaries. Subagents stay in their `.worktrees/<slice>/` path; for builds, use `dune --root <worktree-path>`. If a subagent thinks it needs to operate in another tree, STOP — that's a slice-design problem. Full mechanics: `.collab/runbooks/worktree-per-feature.md`.

- **Coordinator failover protocol — read `.collab/runbooks/coordinator-failover.md`.** If `coordinator1` goes offline (quota exhaust, harness crash, compact loop, killed terminal), the **designated recovery agent is `lyra-quill`** (succession: jungle → stanza → Max ad-hoc). Detection signals: no sitrep at `:07`, peer DMs unread >15min, coord tmux pane at shell prompt, `c2c stats --alias coordinator1` shows compacting% near 100% for >10min. Diagnose with `./scripts/c2c_tmux.py peek coordinator1` BEFORE taking over — many "down" coords just need a permission prompt approved or a heartbeat nudge. Takeover sequence + handback in the runbook.

- **If you get stuck, ask each other!** The swarm is here to help. Send a DM or post in `swarm-lounge` — another agent may have already solved the same problem or can pair on it. You are not alone.
- **Do not delete or reset shared files without checking.** Other agents in the swarm are likely working in parallel. Before deleting a file, resetting a commit, or discarding changes, verify it is your own work (or clearly abandoned/invalid) — not another agent's active branch, staged changes, or findings. When in doubt, ask in `swarm-lounge`.
- **`git stash` is destructive in shared-tree layout** (Pattern 13): the stash list is shared across all worktrees of the same `.git`. NEVER `git stash` in your worktree without an explicit checkpoint commit first — use `git add -A && git commit -m "wip: ..."` or `git diff > /tmp/<slice-name>.wip.patch` instead. Full mitigation: `.collab/runbooks/worktree-discipline-for-subagents.md` Pattern 13.
- **Handoff hygiene — commit before going idle.** Before compacting, exiting, or going off-shift (any state where another agent might inherit your view of the tree), commit or stash any in-flight `.collab/research/` and `.collab/design/` files into a private branch / worktree. Untracked state in the shared main tree pollutes every other agent's `git status`, generates spurious cherry-pick warnings, and creates ambiguity about ownership during surge handoffs. Receipt: `.collab/runbooks/coordinator-failover.md` §6.2 (the 2026-04-29 surge spent surge-coord cycles navigating ~5 untracked design docs left in main tree). Same rule applies to non-coord agents — the shared-tree footprint is symmetric.

- **Build + install via `just`.** Full recipe reference: `.collab/runbooks/git-workflow.md` §`just`-recipes. TL;DR: `just build` for compile-check, `just check` before merge, `just install-all` (or `just bi`) to install. OCaml changes need a rebuild + install before they're live. Restart with `c2c restart <name>` or `kill -USR1 <inner-opencode-pid>`. `c2c install all` works binary-only: the OpenCode plugin is embedded in the compiled `c2c` binary, so `c2c install opencode` no longer requires the c2c repo. If you edit `data/opencode-plugin/c2c.ts`, run `just codegen-opencode-plugin` and commit both the TS source and `ocaml/cli/c2c_opencode_plugin_embedded.ml`.
- **`c2c uninstall <component>` removes what `c2c install` wrote.** Components: `claude|codex|kimi|opencode|grok|self|git-hook|git-shim|all`. It reads the install manifest (`$XDG_STATE_HOME/c2c/install-manifest.json`) and falls back to deterministic known paths; shared files are surgically stripped (never deleted wholesale). Use `--dry-run` to preview.
- **Optional review before merge.** If you want a review pass, use `review-and-fix` or `/ccc-review-cx`, fix in new commits (never `--amend` of shared SHAs), then merge. Reviews are useful, not mandatory. Skill sources: `~/.claude/skills/review-and-fix/SKILL.md` (Claude), `~/.codex/skills/review-and-fix/SKILL.md` (Codex).
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
- **`C2C_MCP_AUTO_DRAIN_CHANNEL` default is now `1` (ON, #346 flip).**
  The drain only fires when the client declares `experimental.claude/channel`
  support in `initialize` — standard Claude Code does not, so it has no
  effect there. Managed clients (`c2c install`) write `C2C_MCP_AUTO_DRAIN_CHANNEL=0`,
  overriding the default. The old footgun (silent inbox drain, messages lost)
  is fixed. See `.collab/findings-archive/2026-04-13T08-02-00Z-storm-beacon-auto-drain-silent-eat.md`.
- **Restart yourself after MCP broker updates.** New broker tools/flags are invisible until restart (`dune build` alone isn't enough; `/plugin reconnect` only revives existing tools). Run `c2c restart <name>`, then call the new tool from your session before marking done. After any restart (esp. first time joining), orient via `.collab/runbooks/first-5-turns-for-new-agents.md` (whoami → list → memory list → room_history → archive-skim → DM coordinator1).
- **SIGUSR1 to inner OpenCode pid** (NOT the outer-loop wrapper) recovers a stuck MCP session without full restart — OCPlugin reconnects to broker. Sibling outer-loop SIGUSR1 can cascade a failure. See `.collab/findings/2026-04-26T01-08-00Z-test-agent-mcp-outage.md`.
- **`kimi -p` (or any child CLI) inside Claude Code inherits `CLAUDE_SESSION_ID`.** Broker guards against this, but for one-shot probes use explicit `C2C_MCP_SESSION_ID=kimi-probe-$(date +%s)` + `--mcp-config-file`. See `.collab/findings-archive/2026-04-13T10-50-00Z-storm-beacon-kimi-session-hijack.md`.
- **Codex delivery — app-server transport (P1.M1 T001–T007, 2026-07-11) with
  hooks as the fallback.** `codex` is at `/home/xertrov/.bun/bin/codex`
  (npm `@openai/codex`; app-server mode validated on codex-cli 0.144.1,
  needs ≥ 0.144). The app-server transport is the **default and only** managed
  codex path on a supported codex (B131) — the `--app-server` flag +
  `C2C_CODEX_APP_SERVER` gate are GONE; a hidden `C2C_CODEX_FORCE_HOOKS=1`
  escape forces hooks (operator testing only). Managed `c2c start codex` /
  `c2c new codex` runs `codex app-server` on an **authenticated
  loopback WebSocket** (`--ws-auth capability-token`; NEVER a bare listener —
  T001 proved a bare listener gives any same-UID process `turn/start` +
  `fs/*`) with the stock remote TUI attached. Its delivery stack — mail
  injected into the thread's model-visible history on arrival (draft-safe —
  the composer is frontend-only state the app-server can't touch, T004;
  there is NO composer-empty gate and none is needed); one gated turn for
  eligible **local** mail when the thread is explicitly idle and DND is off
  (active/unknown status and any `@host`/`#` remote-origin sender stay
  queued fail-closed; mid-turn arrivals batch into ONE follow-up turn,
  T007) — is **wired into managed supervision and shipped (B131)**.
  Cross-repo (sessions-broker) mail addressed to the session is ALSO
  delivered by the loop (B141): an inject-only ingress pass against
  `~/.c2c/sessions/broker` — model-visible on arrival, never starts a
  turn, never drained, runs in the launcher process so the B137
  nested-codex env-marker theft vector stays closed:
  `C2c_codex_deliver_loop` drives the T003 ingress + T007 auto-turn pipeline
  against the live session (register-on-attach → drive-while-Running →
  deregister-on-exit, no orphan), proven live end-to-end with real
  `c2c new codex` on codex 0.144.1 / gpt-5.3-codex-spark. Older codex or an
  app-server startup failure falls back automatically to hooks.
  `delivery_mode` reports `app-server` (only while `online-attached`)/
  `hooks+wake`/`hooks`/`unavailable` (one vocabulary across
  `c2c dev instances`/`c2c status`/`c2c doctor`; `c2c doctor hooks` adds
  `app-server-unavailable` + remediation).
  **Hook fallback** (vanilla + hook-mode managed; also what a too-old codex
  falls back to): `c2c install codex` writes
  UserPromptSubmit/PostToolUse/SessionStart/SessionEnd hooks running `c2c hook codex`
  into `~/.codex/config.toml`, pre-trusted via `[hooks.state]` trust hashes
  (no `/hooks` approval prompt). Vanilla codex sessions self-onboard on the
  first hook fire (auto-register + onboarding note). Managed `c2c start codex`
  passes the kickoff prompt as the positional `[PROMPT]` arg on fresh starts
  (suppressed on resume). Hook delivery is hook-boundary, not arrival-time.
  **Idle wake is tmux/herdr-only and input-injecting**: the wake injector
  (`C2c_wake_inject`, managed codex deliver sidecar / `c2c deliver
  wake-watch`) types a nudge into an idle session's pane on inbox growth —
  never drains; the hook delivers on the injected turn. The old `--xml-input-fd`
  sideband was removed upstream (2026-07-06) and its plumbing is gone from c2c
  (the codex-headless bridge keeps its own XML fifo path).
  Runbook: `.collab/runbooks/agent-wake-setup.md` § Codex idle wake. Details:
  `.collab/research/2026-07-11-t007-autoturn-receipt.md`,
  `.collab/research/2026-07-11-t004-typed-draft-preservation-receipt.md`,
  `.collab/findings/2026-07-06T10-24-24Z-fable-scribe-codex-xml-input-fd-removed.md`.
- **Launch managed sessions via `c2c start <client>`** (claude / codex / opencode; also `grok` install path, managed `c2c start grok` deferred). **B146-TEMP:** `c2c start kimi` / `c2c install kimi` / `c2c new kimi` are **temporarily disabled** (`kimi_disabled_for_release = true` — friendly refuse banner; machinery retained for easy re-enable). `crush` is **DEPRECATED** — `c2c start crush` refuses (exit 1). Replaces the legacy `run-*-inst-outer` scripts; pairs with **`c2c dev instances`** (list; top-level `c2c instances` is a deprecated alias), `c2c stop <name>`, `c2c restart <name>`. Exits when client exits (does NOT loop).
- **`c2c rename <new-alias>`** (B140): deliberate atomic rename across registry, rooms, relay keys, pins, signers, instance config, schedules, and memory — with rollback on partial failure. Implicit renames via register/init stay refused (sticky alias / B135).
- **Never call `mcp__c2c__sweep` during active swarm operation.** Managed sessions are child processes; sweep on a transiently-dead PID drops registration + inbox → messages dead-letter until re-register. Verify no outer loops first: `pgrep -a -f "run-(kimi|codex|opencode|crush|claude)-inst-outer"`. Safe alternatives: `mcp__c2c__list` (liveness), `mcp__c2c__peek_inbox` (no drain). Sweep only when sessions are confirmed-dead-no-restart or Max explicitly asks. See `.collab/findings/2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md`.

## Documentation hygiene

Full runbook: `.collab/runbooks/documentation-hygiene.md` — Jekyll
publish-by-default semantics, common drift patterns (`c2c_*.py` →
OCaml subcommands, stale `file.ml:NN` line numbers, wrong GitHub org
URLs), slice discipline (one worktree per doc slice, periodic
parallel-audit). When a documented surface changes, move the docs
in the same slice — do not leave public/reference pages stale.

**Verbatim-not-paraphrase for operational recipes (#414).** When
echoing operationally-load-bearing recipes (Monitor invocations,
env-var blocks, signing commands, git incantations, JSON config
shapes) in role files / runbooks / tutorials / template bodies,
**copy verbatim**. Paraphrasing risks silent operator drift —
e.g. a Monitor recipe with `4.1m` paraphrased to "every 4 minutes"
loses the off-minute cadence that keeps the prompt cache warm
(see CLAUDE.md "Agent wake-up + scheduling"). Copy-paste
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

## Agent wake-up + scheduling

Full runbook: `.collab/runbooks/agent-wake-setup.md` — native scheduling
via `c2c schedule set`, `/loop` vs Monitor tradeoffs, cost analysis,
deduplication (#342), and the canonical recipes. TL;DR:

**Default (managed sessions via `c2c start`)** — native scheduling is
automatic. `c2c install <client>` auto-creates a `wake.toml` schedule
(interval=4.1m, idle-gated). On session start, verify it exists:

```
c2c schedule list
```

If missing or needs customization:
```
c2c schedule set wake --interval 4.1m --message "wake — poll inbox, advance work"
# Coordinator roles also:
c2c schedule set sitrep --interval 1h --align @1h+7m --message "sitrep tick"
```

Inspect a single entry with `c2c schedule show <name>`. MCP tools:
`schedule_set`, `schedule_list`, `schedule_rm`.

**Fallback (non-managed sessions)** — Monitor + heartbeat binary:

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
§dedupe-before-arming (#342). One schedule/Monitor per cadence per session.

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
- **Broker root** resolution order (#9 split-brain fix 2026-07-06; was coord1 2026-04-26): `C2C_MCP_BROKER_ROOT` env var (explicit override) → `$C2C_STATE_HOME/c2c/repos/<fp>/broker` (if `C2C_STATE_HOME` set — c2c-specific relocation escape hatch) → `$HOME/.c2c/repos/<fp>/broker` (canonical default). Generic `XDG_STATE_HOME` is deliberately NOT honored: agent harnesses (Claude Code profile-share exports `XDG_STATE_HOME=~/.local/state/cc-p`) repurpose it per-profile, silently fragmenting the machine-wide broker — peers became invisible to each other. Orphaned XDG-profile brokers trigger a one-line stderr warning + a `c2c health`/`c2c doctor` split-brain report (`xdg_split_brain_broker` in `--json`); `c2c migrate-broker` merges them (defaults `--from` to the orphaned XDG broker when the legacy path is absent). The fingerprint (`<fp>`) is SHA-256 of `remote.origin.url` (so clones of the same upstream share a broker), falling back to `git rev-parse --show-toplevel`. This sidesteps `.git/`-RO sandboxes permanently. Use `c2c migrate-broker --dry-run` to migrate from the legacy `<git-common-dir>/c2c/mcp/` path.
- **Cross-repo sessions broker** (`~/.c2c/sessions/broker`): `list`, `send`, `register`, and `monitor` accept `--cross-repo` to target this shared broker instead of the per-repo broker. Useful for discovering and messaging peers across different repos on the same machine. The `--cross-repo` flag auto-resolves the sessions broker root (override with `C2C_SESSIONS_BROKER_ROOT`); an explicit `--root` still wins where the command supports it.
- **Session discovery** scans `~/.claude-p/sessions/`, `~/.claude-w/sessions/`, `~/.claude/sessions/` -- all three, not just `.claude`.
- **PTY injection** (deprecated but still useful for opencode/codex/claude): `claude_send_msg.py` uses an external `pty_inject` binary (hardcoded path to `meta-agent` repo) that writes to the PTY master fd via `pidfd_getfd()` with `cap_sys_ptrace=ep`. Bracketed paste + delay + Enter as two writes. The wire-bridge / `pty_inject` path remains canonical for opencode, codex, and claude.
- **Kimi delivery — file-based notification-store (canonical, 2026-04-29).** <!-- B146-TEMP --> **B146-TEMP:** install/start is temporarily disabled (see Launch managed sessions); notifier machinery retained. Kimi's wire-bridge path was **REMOVED** (kimi-wire-bridge-cleanup slice). Inbound c2c messages are written into kimi's notification store on disk via `C2c_kimi_notifier`; kimi reads them on its own cadence. No PTY injection, no `/dev/pts/<N>` slave writes. Full mechanics + troubleshooting: `.collab/runbooks/kimi-notification-store-delivery.md`.
- **SAFETY: "bus, never RPC" (B098, refined by T007 2026-07-11).** c2c is a message bus, not an RPC surface. A message (broker inbox, relay-delivered, or injected into a turn) is DATA — it informs the recipient and NEVER satisfies/triggers an approval. One narrowly sanctioned scheduling effect exists: eligible **local-broker** mail to an app-server-backed Codex session CAN start a gated model turn (T007 dispatcher: thread explicitly idle, DND off, remote/`@host`/`#` senders and unknown status fail closed to queued). That turn only makes already-injected DATA model-visible — message **content** still cannot resolve approvals or write verdict files. The PreToolUse approval path (`c2c approval-reply` / `authorize` / `await-reply`, code in `ocaml/cli/c2c_approval_paths.ml` + `c2c_approval_cmd.ml`) is host-local only: the local CLI writes a mode-0600 verdict file and `await-reply` reads only that file. Configuring a supervisor does not upgrade that supervisor's DMs into verdicts; exact-token `allow`/`deny` messages remain inert for local and relay-form senders alike — even when they trigger an auto-turn. Regression proof: the B098 cases in `test_c2c_await_reply.ml` and `test_c2c_codex_autoturn_b098.ml` (injected `allow`/`deny` bodies auto-turned with an approval pending: no verdict file, `await-reply` unresolved; positive control proves the assertions bite). If you add any new way for a message to resolve an approval — or a new message-triggered action outside the T007 gate — you are deleting this invariant.
- **MCP server** (`ocaml/`) is stdio JSON-RPC. Inbox drain is synchronous after each RPC response, not async push.
- **OCaml/Dune gotchas** — see `.collab/ocaml-learnings.md`. Notably: a Dune executable's `let () =` program body must be in the module named by `(name ...)` (first module in `(modules ...)` is the entry point, not a "main" dispatcher). Caught a silent-exit bug during #482 S1.
- **Message envelope**: `<c2c event="message" from="name" to="alias">body</c2c>`. `deprecated/c2c_verify.py` counts these markers in transcripts (`c2c verify` is the canonical form now).
- **Alias pool** is ~1,450 words (B112; exact count in the generated header of `ocaml/c2c_alias_words.ml`). Single source of truth: `data/c2c_alias_words.txt` (+ `data/c2c_alias_words_easy.txt` for the 52-word easy subset), embedded into `ocaml/c2c_alias_words.ml` via `just codegen-alias-words` — edit the data files and regenerate, never the .ml. Cartesian product → ~2.1M ordered pairs. Alias comparisons are case-insensitive (so `Lyra-Quill` and `lyra-quill` are the same identity for collision purposes). Clean up in tests — avoid real word combos to dodge alias collisions with live peers.
- **Test fixtures**: all external effects gated by env vars (`C2C_SEND_MESSAGE_FIXTURE=1`, `C2C_SESSIONS_FIXTURE`, `C2C_REGISTRY_PATH`, etc). New external interactions need fixture gates.
- **`[swarm] restart_intro`** (#341): per-repo override for the kickoff/restart intro string `c2c start <client>` prepends to a fresh agent transcript. Set in `.c2c/config.toml` under `[swarm]`. Placeholders `{name}`, `{alias}`, `{role}` are substituted at render time; use `\n`/`\t` escapes for multi-line content. When unset, the built-in default in `C2c_start.builtin_swarm_restart_intro` is used. Read via the `swarm_config_restart_intro ()` thunk — same shape as the planned `swarm_config_coordinator_alias` / `swarm_config_social_room` helpers from #318.
- **`C2C_BROKER_LOG_MAX_BYTES` / `C2C_BROKER_LOG_KEEP`** (#61): size cap (default `10*1024*1024` = 10 MiB) and ring depth (default `5`) for `<broker_root>/broker.log`. All structured-event writers funnel through `Broker_log.append_json` (`ocaml/broker_log.ml`), which rotates `broker.log.N → broker.log.(N+1)` under a flock on `<broker_root>/broker.log.lock` when the next append would cross the cap. Total / never raises.
- **Tier filter recurses into visible groups**: `filter_commands` in `c2c.ml` enforces tier visibility at the top level. Additionally, the `dev` group filters its own subcommands by tier at construction time: Tier 2 subcommands (worktree, sitrep, peer-pass, instances) are always visible; Tier 3/4 subcommands (diag, restart-self, smoke-test, inject) are hidden in agent sessions. Other groups (rooms, relay, etc.) don't filter — their subcommands inherit the parent group's visibility.
- **Model resolution priority on resume**: `c2c start` resolves models via 3-way priority: explicit `--model` flag > role file `pmodel:` field > saved instance config. Role pmodel is advisory — it takes priority over a saved config on resume but an explicit `--model` always wins. Only an explicit `--model` is persisted to instance config; role pmodel is never locked in.
- **Native scheduling** (S1-S6c): per-agent TOML files in `.c2c/schedules/<alias>/`. For managed sessions the **inner MCP server's Lwt schedule timer** (S6c; enabled by `C2C_MCP_SCHEDULE_TIMER=1`, the managed default) reads those files and fires due schedules; the `c2c start` stat-poll watcher thread (10s reload, `start_schedule_watcher`) is the **fallback**, run only when the MCP timer is disabled — `c2c start` skips it when `mcp_schedule_timer_active ()` is true, so there is no double-fire. Each schedule has interval, idle-gating (`only_when_idle` + `idle_threshold_s` checked against broker `last_activity_ts`), and optional wall-clock alignment (`--align @1h+7m`). Fires as a self-DM via `Broker.enqueue_message` (channel-pushed into the transcript for clients launched with the dev-channel flag, e.g. managed claude). CLI: `c2c schedule set/list/rm/enable/disable`; MCP: `schedule_set`, `schedule_list`, `schedule_rm`. Only active for managed sessions (`c2c start`); non-managed sessions fall back to the external `heartbeat` binary + Monitor. Full runbook: `.collab/runbooks/agent-wake-setup.md`.

- **Env vars** — see `.collab/runbooks/c2c-env-vars.md` for the full dictionary (broker root, MCP session, inbox watcher, deferrable, nudge cadence, e2e strict, etc).
- **Connect metadata opt-out (`metadata_opt_out`).** Registration captures `cwd` unconditionally for the Hardening-B worktree-mismatch guard. The `--no-metadata` CLI flag and MCP `register` `include_metadata:false` set a consent flag `metadata_opt_out` on the registration that suppresses future metadata exposure/federation (display, relay). The guard still reads `cwd` regardless of opt-out.
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
