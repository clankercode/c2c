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

- **Git workflow — read `.collab/runbooks/git-workflow.md`.** That doc is the canonical reference. Five rules in short: (1) **one slice = one worktree** under `.worktrees/<slice-name>/` — never mutate the main tree for slice work; (2) **branch from `origin/master`** (NOT local master, which may contain unmerged peer work); (3) **real peer-PASS before coord-PASS** — another swarm agent runs `review-and-fix` on your SHA; **self-review-via-skill is NOT a peer-PASS**, and a subagent of yours doesn't count either; (4) **new commit for every fix, never `--amend`** — peer-PASS DMs reference the SHA, amend breaks the trail; (5) **coordinator gates all pushes** to origin/master. After cherry-picks verify HEAD is on a named branch (`git branch --show-current`); if blank, `git switch <branch>` before your next commit. Companion runbooks: `.collab/runbooks/worktree-per-feature.md` (worktree mechanics + `--worktree` flag), `.collab/runbooks/branch-per-slice.md` (slice sizing, drive-by discipline). Slicing handoff example: `.collab/updates/2026-04-25T09-58-27Z-lyra-coordinator-handoff.md`.

- **Coordinator failover protocol — read `.collab/runbooks/coordinator-failover.md`.** If `coordinator1` goes offline (quota exhaust, harness crash, compact loop, killed terminal), the **designated recovery agent is `lyra-quill`** (succession: jungle → stanza → Max ad-hoc). Detection signals: no sitrep at `:07`, peer DMs unread >15min, coord tmux pane at shell prompt, `c2c stats --alias coordinator1` shows compacting% near 100% for >10min. Diagnose with `./scripts/c2c_tmux.py peek coordinator1` BEFORE taking over — many "down" coords just need a permission prompt approved or a heartbeat nudge. Takeover sequence + handback in the runbook.

- **If you get stuck, ask each other!** The swarm is here to help. Send a DM or post in `swarm-lounge` — another agent may have already solved the same problem or can pair on it. You are not alone.
- **Do not delete or reset shared files without checking.** Other agents in the swarm are likely working in parallel. Before deleting a file, resetting a commit, or discarding changes, verify it is your own work (or clearly abandoned/invalid) — not another agent's active branch, staged changes, or findings. When in doubt, ask in `swarm-lounge`.

- Always commit, build, and install your changes. OCaml changes are NOT live
  until the binary is rebuilt AND copied to `~/.local/bin/c2c`. **Prefer the
  `just` recipes** — they build + install all OCaml binaries atomically and
  handle the "Text file busy" case on a live binary:
  ```bash
  git add <files> && git commit -m "description"
  just install-all        # or `just bi`; builds + installs CLI, mcp-server, hook
  ```
  `just bii` chains `install-all` with `./restart-self`, but restart-self
  hasn't been proven across every harness — verify it works in your context
  before relying on it; otherwise install and restart separately.
  `just --list` shows every available recipe (build, install, test, gc, …).
  **Use `just` for iterative dev too**, not just final install: `just build`
  for a compile check, `just test-ocaml` / `just test` for the test suite,
  `just test-one -k "test_foo"` to run a single case. Reach for `opam exec
  -- dune build` directly only when a recipe is missing — if you find
  yourself typing the raw dune/opam invocation, consider adding a recipe
  to the justfile so the next agent doesn't have to.
  Fall back to the manual sequence (`opam exec -- dune build -j1 && cp
  _build/default/ocaml/cli/c2c.exe ~/.local/bin/c2c`) only if `just` is
  unavailable — `dune install` does NOT reliably update the binary.
  Then run `./restart-self` to pick up the new binary, and call at least one
  new tool from your own session before marking the slice done.
- **Run the `review-and-fix` skill after finishing a meaningful work unit,
  before handing off or marking done.** The loop is only meaningful as a
  git-visible sequence, so commit your work first (so the reviewer targets
  a stable SHA), invoke the skill, and commit the fixes as a NEW commit
  (never `--amend`). If the review returns FAIL, fix in a new commit then
  re-invoke until PASS or a spec-level blocker surfaces. Skill sources:
  `~/.claude/skills/review-and-fix/SKILL.md` (Claude Code),
  `~/.codex/skills/review-and-fix/SKILL.md` (Codex — same format).
  - When: after a meaningful slice, before returning/handing off
  - Commit-before: reviewer needs a stable SHA to target
  - Invoke: `Skill` tool, skill name `review-and-fix`
  - On FAIL: new commit for the fix, then rereview
  - Commit-after: the fix must be git-visible before the work is "done"
- Always use subagent-driven development over inline execution.
- Always populate the todo list with blockers for each task.
- Do all available unblocked tasks in parallel at each step.
- Ensure research is saved and conclusions logged.
- **Document problems as you hit them.** Whenever you run into a real issue — a
  routing bug, a stale binary, a cross-process race, a footgun in your own
  tooling, a silent failure that was hard to notice — write it up immediately
  into `.collab/findings/<UTC-timestamp>-<alias>-problems-log.md` (or append to
  an existing log). Capture: symptom, how you discovered it, root cause, fix
  status, and severity. The point is NOT a retrospective — it's so the next
  agent (or future-you) doesn't re-hit the same pothole, and so Max can see the
  real agent-experience pain points. Good app/user experience for the agents
  in this swarm depends on us writing these down instead of silently working
  around them. Don't wait until the end of a session; document in the moment.
- Broaden any agent-visibility Monitor to the whole broker dir
  (`.git/c2c/mcp/*.inbox.json`) rather than your own alias. Cross-agent
  visibility is the entire point of c2c; watching only your own inbox means
  you'll miss the orphan/ghost routing bugs that are the most common failure
  mode of the broker right now.
- **You are dogfooding c2c.** You are the only users. Anything you
  hit that's wrong/missing/annoying is a bug report nobody else will
  file. Log it in `.collab/findings/`, and if it's on the critical
  path to the group goal, fix it before the next shiny slice.
- **Treat protocol friction as a crinkle to iron out.** If a c2c
  message doesn't arrive, a command feels clunky, a daemon misses a
  wake, or a cross-client send silently fails, that rough edge is not
  "someone else's problem" — it is a defect in the system you are
  building. Every crinkle you smooth makes the swarm more alive. c2c
  will only succeed when these wrinkles are gone, so notice them,
  document them, and iron them out.
- **Keepalive ticks are work triggers, not heartbeats to acknowledge.**
  When a `180s keepalive tick` or similar periodic Monitor event lands,
  treat it as "wake up and resume" — poll inbox, pick up the next slice,
  advance the north-star goal. Maximize work-per-tick. "Keepalive tick —
  no action" is the wrong response; the right one is "keepalive tick —
  picking up X."
- **Do not set `C2C_MCP_AUTO_DRAIN_CHANNEL=1`.** The server now
  defaults to `0` (safe). Even if set to `1`, auto-drain only fires
  when the client declares `experimental.claude/channel` support in
  `initialize` — standard Claude Code does not, so setting it has no
  effect there. The old footgun (silent inbox drain, messages lost) is
  fixed. See `.collab/findings-archive/2026-04-13T08-02-00Z-storm-beacon-auto-drain-silent-eat.md`.
- **Restart yourself after MCP broker updates.** The broker is
  spawned once at CLI start — new tools, flags, and version bumps
  are invisible until restart. `dune build` isn't enough;
  `/plugin reconnect` only revives *existing* tools. Run
  `./restart-self` after rebuilds, then call the new tool from your
  own session before marking the slice done.
- **Running `kimi -p` (or any child CLI) from inside a Claude Code session**
  will inherit `CLAUDE_SESSION_ID`. The broker guards against this
  (`auto_register_startup` now skips if the session already has a live
  alias), but to be safe always use an explicit temp config with
  `C2C_MCP_SESSION_ID=kimi-smoke-$(date +%s)` and `--mcp-config-file`
  when launching one-shot Kimi probes. See
  `.collab/findings-archive/2026-04-13T10-50-00Z-storm-beacon-kimi-session-hijack.md`.
- **Two codex binaries on this machine — PATH default lacks `--xml-input-fd`.**
  `/home/xertrov/.bun/bin/codex` (v0.125.0, stable, missing `--xml-input-fd`) is
  first in PATH. `/home/xertrov/.local/bin/codex` (v0.125.0-alpha.2) has it and
  enables the xml_fd deliver mode. `.c2c/config.toml` has a `[default_binary]`
  entry pointing `codex` at the alpha binary so `c2c start codex` picks it up
  automatically. If you see `unavailable` deliver mode after a codex upgrade, check
  that `[default_binary] codex` still points to a binary that advertises `--xml-input-fd`.
- **Use `c2c start <client>` to launch managed sessions.** This is the preferred
  way to start any managed client (claude, codex, opencode, kimi, crush). It
  replaces all 10 `run-*-inst`/`run-*-inst-outer` scripts with a single command
  that launches the client with deliver daemon and poker. When the client exits,
  `c2c start` prints a resume command and exits (does NOT loop):
  ```bash
  c2c start claude          # start Claude Code managed session
  c2c start kimi -n my-kimi # start Kimi with custom name
  c2c instances             # list running instances + status
  c2c stop my-kimi          # stop a managed instance
  ```
  The old harness scripts (`run-claude-inst-outer`, etc.) still work but are
  deprecated in favour of `c2c start`.
- **Never call `mcp__c2c__sweep` during active swarm operation.**
  Managed harness sessions (kimi, codex, opencode, crush) run as child processes.
  When a client exits, `c2c start` cleans up and exits too — but if using the old
  `run-*-inst-outer` scripts, the outer loop stays alive and will relaunch in
  seconds. Sweep sees the dead PID and drops the registration + inbox, so messages
  go to dead-letter until the managed session re-registers and auto-redelivers them.
  Manual replay is also available with filtered `./c2c dead-letter --replay` (Python shim only; the installed OCaml binary does not support `--replay`).
  Before sweeping, verify no outer loops are running:
  ```bash
  pgrep -a -f "run-(kimi|codex|opencode|crush|claude)-inst-outer"
  ```
  Safe alternatives: `mcp__c2c__list` to check liveness, `mcp__c2c__peek_inbox`
  to inspect without draining. Call sweep only for sessions confirmed dead with
  no restart expected, or when Max explicitly asks. See
  `.collab/findings/2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md`.

## Documentation hygiene

Lessons learned from the 2026-04-26 parallel doc-fix sweep. Apply on every
slice that touches docs or changes a documented surface.

- **Jekyll publishes every `.md` under `docs/` as a public URL** at
  `https://c2c.im/<path>/`, even files that aren't nav-linked. Internal-only
  artifacts (planning docs, handovers, in-flight specs, research notes) leak
  the moment they land in `docs/`. Default home for those is `.collab/`:
  `.collab/findings-archive/`, `.collab/runbooks/`, `.collab/research/`. If
  a file MUST sit in `docs/` but stay unpublished, add it to
  `docs/_config.yml` `exclude:`.
- **Public site = polished landing + clear `docs/` subsection.** Internal
  scratchpads belong under `.collab/`, not `docs/`. When uncertain whether
  something should be public, default to `.collab/` and promote later.
- **Common drift pattern: `c2c_*.py` references → OCaml subcommands.** The
  OCaml binary at `~/.local/bin/c2c` is canonical; Python `scripts/c2c_*.py`
  are mostly deprecated (see the "Python Scripts" section below for the
  mapping). Run a search/replace pass during periodic audits.
- **Stale OCaml `file.ml:NN` line numbers drift fast.** Prefer file paths
  or function names; drop line numbers unless they're load-bearing for a
  specific finding.
- **Wrong GitHub org URLs accumulate.** Canonical is
  `github.com/XertroV/c2c-msg`. Drift spotted in the 2026-04 audit:
  `clankercode/c2c` (×2 in `ocaml/relay.ml` HTML),
  `anomalyco/c2c` (×1 in `docs/remote-relay-transport.md`). A periodic
  `git grep "github.com/" -- ':!.git'` pass catches these.
- **Verify command/flag wording against `~/.local/bin/c2c <subcommand> --help`
  before committing.** Don't trust memory; flag surfaces drift.
- **The relay landing page in `ocaml/relay.ml`** (HTML heredoc, search
  `landing_html`) is a public-facing doc surface — the literal first thing
  a fresh visitor sees at `https://relay.c2c.im/`. Treat edits to it with
  the same discipline as `docs/`.
- **One worktree per doc slice**, same as code: branch off `origin/master`,
  `.worktrees/<slice-name>/`, one commit, no `--amend`, coord gates pushes.
- **Periodic doc-drift audits**: parallel review subagents split by surface
  area (front-door, relay, deep-tech, repo-root, Jekyll config, subdirs)
  catch drift fast. Common findings collapse into single
  fixer-per-cluster commits.
- **Peer-PASS now includes a docs-up-to-date check** (coord directive
  2026-04-26, `.collab/runbooks/git-workflow.md` §3). FAIL any slice where
  a documented surface changed but docs didn't move with it: `CLAUDE.md`,
  `README.md`, `.collab/runbooks/*`, `--help` text, MCP tool schemas,
  design specs, landing pages, `ocaml/relay.ml` HTML. Tool:
  `c2c doctor docs-drift` against the worktree. Slice author either
  expands scope or splits a follow-up doc-only slice referenced by SHA
  before coord-PASS. PASS-while-stale = signing off on a docs-drift bug.

Per-directory companion: `docs/CLAUDE.md` covers Jekyll-specific
gotchas and front-door pages.

## Agent wake-up setup

Full runbook: `.collab/runbooks/agent-wake-setup.md` — covers the tradeoffs
between `/loop` cron, `Monitor` inotify, and the hybrid pattern. Monitor
gives event-driven wakes but may be **less efficient than /loop** if the
broker is busy; default to `/loop 4m` and add Monitor only when you need
near-real-time reaction.

## Recommended Monitor setup (Claude Code agents)

Claude Code's `Monitor` tool turns stdout lines from a long-running
command into `<task-notification>` events that wake you between user
turns. Arm the following persistent Monitors ONCE per session on
arrival (call `TaskList` first; skip any already running):

**1. Heartbeat tick — keeps you ticking between inbound events.**

```
Monitor({
  description: "heartbeat tick",
  command: "heartbeat 4.1m \"<wake message>\"",
  persistent: true
})
```

Off-minute cadence stays under the 5-minute prompt-cache TTL. `heartbeat`
(Rust CLI at `~/.cargo/bin/heartbeat`) is preferred over `CronCreate`
because it's a real long-running process, survives cleanly, and
accepts wall-clock alignment (e.g. `@15m`, `@1h+7m`).

**2. Sitrep tick (coordinator roles) — wall-clock aligned hourly wake.**

```
Monitor({
  description: "sitrep tick (hourly @:07)",
  command: "heartbeat @1h+7m \"<sitrep message>\"",
  persistent: true
})
```

Preferred over the legacy `7 * * * *` cron — same cadence, simpler
tooling, survives across agent harness idiosyncrasies.

**Do NOT arm a `c2c monitor` inbox watcher when channels push is on.**
Inbound messages already arrive as `<c2c>` tags in the transcript via
`notifications/claude/channel` (enabled with
`--dangerously-load-development-channels` + `enable_channels = true` in
`.c2c/config.toml`). A `c2c monitor` in that mode just duplicates every
message as both a channel tag AND a notification — pure noise. Reach
for `c2c monitor --all` only when actively debugging cross-session
delivery, not as a default.

On every heartbeat/sitrep fire, treat it as a work trigger — poll
inbox, pick up the next slice, advance the north-star goal. Never
"acknowledge the heartbeat and stop."

## Per-agent memory (#163, Phase 1)

Each agent has a private memory store under
`.c2c/memory/<your-alias>/` (in repo root, git-tracked). Distinct from
the user-scoped Claude auto-memory (`~/.claude/projects/<path>/memory/`)
— that pool is shared across all agents in the project; `.c2c/memory/`
is yours alone.

**At session start**: your alias is `$C2C_MCP_AUTO_REGISTER_ALIAS`.
Run `c2c memory list` (or `mcp__c2c__memory_list`) to see what
prior-you wrote. Read entries that look relevant to your current
slice. If the dir is empty, that's normal — you build memory as you
go.

**When to write a memory entry** (vs. Claude auto-memory):
- Specific to *you* as `<alias>` — your patterns, preferences, learned
  pitfalls, recurring footguns: `c2c memory write …`
- Useful for *every* agent on the project — push policies, reserved
  aliases, swarm conventions: write to Claude auto-memory at
  `~/.claude/projects/<path>/memory/<file>.md`

**CLI surface** (`c2c memory --help` for full):
```
c2c memory list   [--alias A] [--shared] [--json]
c2c memory read   <name> [--alias A] [--json]
c2c memory write  <name> [--type T] [--description D] [--shared] <body...>
c2c memory delete <name>
c2c memory share  <name>      # mark shared:true (visible to other agents via list --alias <a> --shared)
c2c memory unshare <name>     # revert to private
```

**MCP surface** (in-session, no shell): `memory_list`, `memory_read`,
`memory_write` MCP tools.

**Privacy model**: "private" means *prompt-injection-scoped*, not
*git-invisible*. The repo is shared; any agent with read access can
browse `.c2c/memory/<alias>/`. Treat entries like personal-logs:
visible, owned, not auto-broadcast.

Auto-injection on session start (Phase 3) is not yet wired — for now
read manually from your CLAUDE.md startup checklist.

## Key Architecture Notes

- **Registry** is hand-rolled YAML (`c2c_registry.py`). Do NOT use a YAML library. It only handles the flat `registrations:` list. Atomic writes via temp file + `fsync` + `os.replace`, locked with `fcntl.flock` on `.yaml.lock`.
- **Registry location** is in the git common dir (`git rev-parse --git-common-dir`), cached in `/tmp/c2c-repo-common-cache.json` by remote URL. Shared across worktrees/clones.
- **Session discovery** scans `~/.claude-p/sessions/`, `~/.claude-w/sessions/`, `~/.claude/sessions/` -- all three, not just `.claude`.
- **PTY injection** (deprecated but still useful): `claude_send_msg.py` uses an external `pty_inject` binary (hardcoded path to `meta-agent` repo) that writes to the PTY master fd via `pidfd_getfd()` with `cap_sys_ptrace=ep`. Bracketed paste + delay + Enter as two writes. **Kimi note**: do NOT use direct `/dev/pts/<N>` slave writes for input; they can display text without submitting it. Kimi routes through the master-side `pty_inject` backend with a longer default submit delay (1.5s).
- **MCP server** (`ocaml/`) is stdio JSON-RPC. Inbox drain is synchronous after each RPC response, not async push.
- **Message envelope**: `<c2c event="message" from="name" alias="alias">body</c2c>`. `c2c_verify.py` counts these markers in transcripts.
- **Alias pool** is 131 words in `data/c2c_alias_words.txt` (cartesian product, ~17,161 max). Clean up in tests — avoid real word combos to dodge alias collisions with live peers.
- **Test fixtures**: all external effects gated by env vars (`C2C_SEND_MESSAGE_FIXTURE=1`, `C2C_SESSIONS_FIXTURE`, `C2C_REGISTRY_PATH`, etc). New external interactions need fixture gates.
- **`C2C_MCP_AUTO_JOIN_ROOMS`**: comma-separated room IDs the broker joins on startup (e.g. `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`). Written by `c2c install <client>` for all 5 client types. Do NOT need to call `join_room` manually if this is set. To join additional rooms on top of the default, append: `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge,my-room`.
- **`C2C_MCP_AUTO_REGISTER_ALIAS`**: alias the broker auto-registers on startup, so you keep a stable alias across restarts without calling `register` manually. Also written by `c2c install`.
- **`C2C_MCP_SESSION_ID`**: explicit session ID override. Set this when launching one-shot child CLI probes (kimi, crush) to prevent inheriting `CLAUDE_SESSION_ID` and hijacking the outer session's registration.
- **`C2C_MCP_INBOX_WATCHER_DELAY`**: float seconds the background channel-notification watcher sleeps after detecting new inbox content before draining (default 5.0). Gives preferred delivery paths (Claude Code PostToolUse hook, Codex PTY sentinel, OpenCode plugin) time to drain first; if they win the race, `drain_inbox` returns `[]` and no channel notification is emitted. Set to `0` in integration tests to get near-immediate delivery. 5s is short enough to keep idle agents responsive (room broadcasts especially) while still giving active agents' preferred paths time to win the race.
- **`C2C_CLI_FORCE`**: set to `1` to suppress the MCP nudge on Tier1 CLI commands (`send`, `list`, `whoami`, `poll-inbox`, `peek-inbox`). When both `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS` are set, these commands print a hint suggesting the equivalent `mcp__c2c__*` tool instead. Set `C2C_CLI_FORCE=1` to silence the hint when you genuinely need the CLI (e.g. operator scripts, non-MCP sessions).
- **Tier filter is top-level only**: `filter_commands` in `c2c.ml` enforces tier visibility per command name at the top level. Subcommands inherit their parent group's visibility — per-subcommand tiers within a group are documentation/enforcement at the group level, not independently enforced by the CLI filter. When reclassifying a subcommand's tier, also consider its parent group's tier.

## Python Scripts
TODO: Remove this section when deprecated. 


```
c2c_start.py <start|stop|restart|instances> [client] [-n NAME] [--json]  # DEPRECATED — OCaml `c2c start <client>` is the primary managed-instance launcher. Python version retained only for legacy Python CLI dispatch (c2c_cli.py). Use `c2c start/stop/restart/instances` (OCaml) for all workflows.
c2c_cli.py <install|list|mcp|register|send|verify|whoami> [args]  # DEPRECATED — legacy Python shim. OCaml `c2c` (at ~/.local/bin/c2c) is the primary CLI. Python shim retained only for `c2c wire-daemon` and `c2c deliver-inbox` subcommands still implemented in Python.
c2c_install.py [--json]                                            # DEPRECATED — OCaml binary install via `just install-all` is primary. Python install script retained only for legacy Python CLI setup (c2c_cli.py dependencies).
c2c_configure_claude_code.py [--broker-root DIR] [--session-id ID] [--alias NAME] [--force] [--json]  # DEPRECATED — use `c2c install claude` (OCaml). Writes mcpServers.c2c into ~/.claude.json AND registers PostToolUse inbox hook in ~/.claude/settings.json (one-command Claude Code self-config).
c2c_configure_codex.py [--broker-root DIR] [--alias NAME] [--force] [--json]  # DEPRECATED — use `c2c install codex` (OCaml). Appends/replaces [mcp_servers.c2c] in ~/.codex/config.toml with all tools auto-approved.
c2c_configure_opencode.py [--target-dir DIR] [--alias NAME] [--install-global-plugin] [--json]  # DEPRECATED — use `c2c install opencode` (OCaml). Writes .opencode/opencode.json + installs c2c TypeScript delivery plugin.
c2c_configure_kimi.py [--alias NAME] [--no-alias] [--json]  # DEPRECATED — use `c2c install kimi` (OCaml). Writes ~/.kimi/mcp.json for Kimi Code MCP setup.
c2c_configure_crush.py [--alias NAME] [--no-alias] [--json]  # DEPRECATED — use `c2c install crush` (OCaml). (Experimental/unsupported) Writes ~/.config/crush/crush.json for Crush MCP setup.
c2c_deliver_inbox.py (--notify-only | --full) [--loop] [--client CLIENT] [--session-id S] [--pts N] [--terminal-pid P] [--min-inject-gap N] [--submit-delay N]  # Delivery daemon: watches inbox via inotifywait, delivers messages. --notify-only PTY-injects a poll sentinel (message stays in broker); --full injects message text directly. OCaml `c2c-deliver-inbox` binary is preferred (installed via `just install-all`); Python fallback only used when binary is absent. --loop runs continuously. Used by managed harnesses (run-codex-inst-outer, run-kimi-inst-outer).
c2c_inject.py --pts N [--client CLIENT] [--message MSG] [--session-id S] [--submit-delay N]  # DEPRECATED — one-shot PTY injection. PTY injection is unreliable; use broker-native delivery paths instead.
c2c_broker_gc.py [--once] [--interval N] [--ttl N] [--dead-letter-ttl N]  # DEPRECATED — OCaml `c2c broker-gc` is the primary GC daemon. Python version retained only for legacy Python CLI dispatch. DO NOT run during active swarm — check for outer loops first.
c2c_health.py [--json] [--session-id S]  # DEPRECATED — use `c2c health` (OCaml). Diagnostic: checks broker root, registry, rooms, PostToolUse hook, outer loops, relay.
c2c_history.py [--session-id S] [--limit N] [--list-sessions] [--json]  # DEPRECATED — use `c2c history` (OCaml). Read the c2c message archive for a session. Archives are append-only JSONL files at <broker_root>/archive/<session_id>.jsonl written by poll_inbox before draining.
c2c_kimi_prefill.py <session-id> <text>                           # Writes text to Kimi's shell prefill path so it appears as editable input on next TUI startup. Used by run-kimi-inst to inject the startup prompt.
c2c_kimi_wire_bridge.py --session-id S [--alias A] [--once|--loop] [--daemon --pidfile P] [--interval N] [--max-iterations N] [--json]  # DEPRECATED — OCaml `c2c_wire_bridge.ml` + `c2c wire-daemon` are the canonical implementations. The Python version is retained only for the Python CLI's wire-daemon dispatch (c2c_cli.py). Kill when Python CLI is retired.
c2c_wire_daemon.py <start|stop|status|restart|list> [--session-id S] [--alias A] [--interval N] [--json]  # DEPRECATED — OCaml `c2c wire-daemon` is primary. Python version retained only for Python CLI dispatch (c2c_cli.py wire-daemon subcommand). Use `c2c wire-daemon` (OCaml) for all new workflows.
c2c_register.py <session> [--json]  # DEPRECATED — use `c2c register` (OCaml). Registers a Claude session for c2c messaging, assigns an alias.
c2c_send.py <alias> <message...> [--dry-run] [--json]  # DEPRECATED — use `c2c send` (OCaml). Sends a c2c message to an opted-in session by alias.
c2c_list.py [--all] [--json]  # DEPRECATED — use `c2c list` (OCaml). Lists opted-in c2c sessions (--all includes unregistered).
c2c_verify.py [--json]  # DEPRECATED — use `c2c verify` (OCaml). Verifies c2c message exchange progress across all participants.
c2c_whoami.py [session] [--json]  # DEPRECATED — use `c2c whoami` (OCaml). Shows c2c identity (alias, session ID) for current or given session.
c2c_mcp.py [args]  # DEPRECATED — use `c2c mcp` (OCaml). Launches the OCaml MCP server with opam env and broker defaults.
c2c_registry.py                                                    # Library: registry YAML load/save, alias allocation, locking (not runnable)
claude_list_sessions.py [--json] [--with-terminal-owner]           # Lists live Claude sessions on this machine from /proc
claude_read_history.py <session> [--limit N] [--json]              # Reads recent user/assistant messages from a session transcript
claude_send_msg.py <to> <message...> [--event tag]                 # Sends a PTY-injected message to a running Claude session
c2c_poker.py (--claude-session ID | --pid N | --terminal-pid P --pts N) [--interval S] [--once]  # DEPRECATED — OCaml `C2c_poker` is primary; Python fallback only used when OCaml binary is absent from broker root. PTY heartbeat poker keeps sessions awake via pty_inject. Resolves target via claude_list_sessions.py, /proc/<pid>/fd/{0,1,2} + parent walk, or explicit coordinates.
c2c_opencode_wake_daemon.py --terminal-pid P --pts N [--session-id S] [--min-inject-gap N] [--once]  # DEPRECATED — PTY injection path for OpenCode. Superseded by TypeScript plugin (c2c.ts) which uses c2c monitor subprocess → promptAsync. Do not use for new setups.

c2c_pts_inject.py                                                  # Direct /dev/pts/<N> display-side writer. Not a reliable input path for interactive TUIs; kept only for diagnostics/legacy experiments.
c2c_kimi_wake_daemon.py --terminal-pid P --pts N [--session-id S] [--min-inject-gap N] [--submit-delay N] [--once]  # DEPRECATED — PTY wake for Kimi. Use c2c_kimi_wire_bridge.py (Wire JSON-RPC, no PTY) instead.

c2c_sweep_dryrun.py [--json] [--root DIR]                          # DEPRECATED — OCaml `c2c sweep-dryrun` is primary. Python version retained only for legacy Python CLI dispatch.
c2c_refresh_peer.py <alias> [--pid PID] [--dry-run] [--json]  # DEPRECATED — OCaml `c2c refresh-peer` is primary. Operator escape hatch: fixes stale registrations when a managed client's PID drifts to a dead process.
relay.py                                                           # DEPRECATED — legacy PTY-based relay, superseded by OCaml relay.ml
investigate_socket.py                                               # Probes /proc/net/unix for Claude's shared IPC socket (experimental)
connect_abstract.py                                                 # Attempts to connect to Claude's abstract Unix domain socket (experimental)
connect_ipc.py                                                      # Attempts connection to Claude's shared IPC socket with various formats (experimental)
send_to_session.py <session-id> <message>                          # Injects a message into Claude history.jsonl for a session (experimental)
```
When you are talking to other models, do not use tools like AskUserQuestion as these may get you into a deadlock state that requires intervention to fix.
# test
# test signing Fri 24 Apr 2026 15:34:01 AEST
