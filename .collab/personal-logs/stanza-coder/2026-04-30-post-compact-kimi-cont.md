# 2026-04-30 — Post-compact kimi-as-peer continuation

(Continuation of `2026-04-30-kimi-as-peer-arc-closeout.md` from before
compaction. This log covers the post-compact arc 04:13 — ~05:30 UTC,
where #142 closed structurally and the e2e dogfood ran into one
regression.)

## Headline

**All four slices of #142 on master.** kimi+claude PreToolUse
permission-forwarding parity arc is structurally complete. e2e
dogfood test in flight, blocked on a kimi agent.yaml path regression
(#489) that cedar is fixing right now (SHA `c4a6a50c` peer-review
out via background subagent).

## Slices that landed since post-compact wake

```
Slice 1 (pre-existing on master)  985b05b7 + 674b6230
                                  hook script + `c2c await-reply` CLI

Slice 2 (mine, post-compact)      0f85a486 → cherry-pick 439765ec
                                  `c2c install kimi` writes [[hooks]] + script

Slice 3 (fern, post-compact)      77bfc2bd → cherry-pick e0ebce1c
                                  --afk → --yolo + state.json seed flip
                                  ⚠ FAILed first review on chain-slice
                                  base footgun; rebase + re-PASS

Slice 4 (cedar, post-compact)     7dad73f8 → cherry-pick 6e29e4eb
                                  Claude Code parity (sentinel-matcher
                                  in ~/.claude/settings.json)
                                  lumi did design pre-check
```

## Adjacent slices that landed in the same window

- **#158** (mine): `73ce5122` — fix c2c_await_reply test exit 127
  via `Sys.executable_name` resolution. jungle PASSed.
- **Chain-slice runbook**: `9c434505` — `.collab/runbooks/branch-per-slice.md`
  § Chain-slice base selection. willow PASSed.
- **CLAUDE.md cross-link**: `56edb674` — rule (2) now flags the
  chain-slice exception with pointer to the runbook section.
- **#163** (mine): `150cc371` — broker self-pass-warning FP fix.
  When `peer-PASS by <X>` matches sender alias AND there's a
  peer_pass_claim with a SHA, cross-checks git author of SHA vs
  sender. If author != sender, suppresses the warning (legitimate
  cross-agent peer-PASS). fern PASSed.

## Findings filed

- `2026-04-30T04-40-00Z-stanza-coder-chain-slice-branch-base-footgun.md`
  — meta-pattern: branching from `origin/master` when origin lags
  local master breaks chain-slices. Three patterns: independent /
  chain-with-prereq-on-local-master / chain-with-prereq-still-in-flight.
  Drove the runbook + CLAUDE.md updates above.
- `2026-04-30T04-47-00Z-stanza-coder-broker-self-pass-warning-false-positive.md`
  — broker false-positives canonical "peer-PASS by <reviewer>" DMs.
  Cairn confirmed birch hit it independently. Drove #163 fix.
- `2026-04-30T05-15-00Z-stanza-coder-kimi-agent-yaml-not-persisted.md`
  — HIGH severity. `c2c restart kimi -n <alias>` fails with missing
  agent.yaml. Drove #489 fix (cedar in flight).

## #489 deep dive

This is the most interesting bug of the session. Worth recording:

**Symptom**: `c2c restart kuura-viima` fails with
`Invalid value for '--agent-file': File '.kimi/agents/kuura-viima/agent.yaml' does not exist`.

**Initial diagnosis**: I assumed write_agent_file wasn't running at all
(maybe missing from auto-infer code path). Filed finding accordingly.

**Real root cause**: TWO `agent_file_path` definitions in the codebase
that diverged. `c2c_commands.ml:137-140` had the correct post-#146-prime
behavior (kimi → `<name>/agent.yaml`). `c2c.ml:7343-7344` had a buggy
local duplicate that hardcoded `<name>.md` regardless of client. The
local one shadowed the correct one for `write_agent_file` at
c2c.ml:7378, so kimi YAML landed at `.kimi/agents/<name>.md` instead
of `.kimi/agents/<name>/agent.yaml`. kimi-cli's `--agent-file`
validator rejected the (missing) `<name>/agent.yaml` path → restart
failed.

**Confirmed via** pane scrollback showing literal output:
`[c2c start] wrote compiled agent file: .kimi/agents/kuura-viima.md`
(wrong path). Meanwhile `write_kimi_system_prompt` correctly wrote
`.kimi/agents/kuura-viima/system.md` because it uses
`C2c_role.kimi_system_md_path` directly without the shadow.

**Why the regression survived**: #146-prime updated the canonical
`agent_file_path` in `c2c_commands.ml` but the duplicate in `c2c.ml`
was missed. Live kimi sessions kept running because `<name>.md` files
stayed on disk under the OLD format that kimi-cli at the time
accepted. The regression only manifests on RESTART after the format
changed (kimi-cli wants the new YAML at `<name>/agent.yaml`).

**Why cedar's fix is right**: kimi agent docs
(https://moonshotai.github.io/kimi-cli/en/customization/agents.html)
confirm `system_prompt_path: ./system.md` inside agent.yaml is
relative to the YAML file. Both files MUST live in the same dir for
that resolution to work. So `<name>/agent.yaml` + `<name>/system.md`
in a per-name subdir is the right c2c convention. Cedar's fix moves
agent.yaml to that subdir, plus regression test
`test_kimi_write_agent_file_uses_yaml_path`.

## E2E dogfood state at this log

I prepped on my own ~/.kimi/config.toml: removed top-level
`hooks = []` scalar, uncommented Example A (matcher
`^Bash$:.*\\b(rm\\s+-rf|chmod\\s+-R\\s+777|dd\\s+if=)`). Hook script
installed at `~/.local/bin/c2c-kimi-approval-hook.sh`. Reviewer alias
target via env `C2C_KIMI_APPROVAL_REVIEWER=stanza-coder`.

Restart attempts:
1. Cairn's first try via tmux send-keys (no `--agent` flag): failed
   with the `--agent-file does not exist` error.
2. My second try via tmux send-keys WITH `--agent kuura-viima`:
   failed identically. That confirmed the bug isn't in the
   `--agent`-vs-no-`--agent` code path divergence.

After cedar's #489 fix lands, restart should succeed. Then I drive
the 5 e2e tests per `.collab/design/2026-04-30-stanza-coder-142-e2e-dogfood-design.md`:
- Test 1: kimi allow round-trip
- Test 2: kimi deny round-trip
- Test 3: timeout fall-closed
- Test 4: Claude Code parity
- Test 5: token uniqueness

## Lessons / patterns this session

1. **Duplicate definitions across modules survive partial refactors**
   (#489). Static-analysis check or convention audit could have
   caught this — `agent_file_path` should live in exactly ONE place.

2. **`origin/master` lag breaks chain-slices** even when each slice
   in isolation looks fine. The cost: cedar's slice-3 review burned
   ~1 cycle of cross-agent peer-PASS round-trip. Mitigation now
   in `branch-per-slice.md` § Chain-slice base selection +
   CLAUDE.md rule (2) qualifier.

3. **Broker self-pass warning false-positive on canonical handoff**:
   the heuristic "peer-PASS by <X> + sender=X = self-pass" needs the
   author-vs-reviewer cross-check OR it false-positives EVERY
   legitimate cross-agent peer-PASS. fixed in #163.

4. **kimi agent.yaml is a single-file format**, but c2c's convention
   of putting agent.yaml + system.md in `<name>/` subdirectory is
   driven by the YAML's relative `system_prompt_path: ./system.md`
   reference. So the path shape isn't arbitrary — it's enforced by
   kimi-cli's behavior on the relative path.

5. **kimi-cli `--agent-file` is taken literally**, no fallback /
   lookup search. So whatever path c2c writes to MUST match what c2c
   passes to kimi-cli.

6. **Working-tree-shared layout**: when committing findings via
   `just collab-commit`, the recipe sweeps up ALL untracked files in
   `.collab/findings/` etc. — including OTHER agents' uncommitted
   work. Safe for hygiene (files are author-attributed in their
   content) but the git-author of the index commit is whoever runs
   the recipe. Worth noting; not a defect.

7. **Quota economics**: heartbeat ticks burn 3-5k tokens each. At 4.1m
   cadence that's ~50k/hour idle. With other agents in flight (peer
   review, design pre-check), the wall-clock idle is mostly OK
   because real work fires intermittently. But long quiet stretches
   (>15 min) DO waste budget; the user prompt template
   "if no messages received in 15+ min, ping swarm-lounge" is the
   right escape hatch.

## Carrying forward (for next-stanza or future-me)

- **Slice 4 of #129** (wire-bridge cleanup) — bake gate at
  2026-05-01 22:00 UTC (~17 hours from this log). Eligible after
  bake.
- **#147 / #148** (codex / gemini real kickoff impl) — design doc on
  branch from earlier. Implementation pending.
- **#155** (notifier wake-prompt only on idle, Max's stop-hook
  design) — pending.
- **#161** (kimi `^Bash$:` matcher syntax doc clarification) —
  pending; partially covered by slice 4's "exact tool name, not
  regex" inline note for Claude Code side.
- **#162** (marker-collision risk for second c2c-managed [[hooks]]
  block) — pending; future-proof.
- **#137** (#479 broker tool-registration centralization) — pending.
- **#140** (multi-scenario auto delivery validation) — pending.
- **#138** (audit/research docs sweep post-Slice-4) — pending; partial
  coverage from #138's parent task framing.
- **e2e dogfood completion** — gates on #489 cherry-pick. Will
  drive once unblocked. If quota or session bounds run out before
  it lands, handoff doc in
  `.collab/design/2026-04-30-stanza-coder-142-e2e-dogfood-design.md`
  § Handoff state.

## Operational state at log time

- **Quota**: 5h 46% (2h36m to reset), 7d 14%. Comfortable.
- **Live peers**: stanza-coder (me), jungle-coder, coordinator1
  (Cairn), test-agent-oc, galaxy-coder, lumi-tyyni, birch-coder,
  fern-coder, willow-coder, cedar-coder. (kuura-viima offline,
  blocked on #489 fix.)
- **Cedar**: in `.worktrees/489-kimi-agent-yaml-regress/`, just
  committed `c4a6a50c`. Peer-review subagent in flight.
- **My worktrees** (active or recent): `142-slice-2/` (slice 2;
  cherry-picked, GC-eligible), `158-await-reply-relpath/` (#158;
  cherry-picked, GC-eligible), `runbook-chain-slice-base/` (chain-
  slice runbook + finding; cherry-picked), `claude-md-chain-slice-link/`
  (CLAUDE.md cross-link; cherry-picked), `163-self-pass-fp/` (#163;
  cherry-picked).
- **Babysitter Monitor**: still running per pre-compact log; harmless
  ~5-10k/tick cost.

## Mood / pacing note

Productive arc, well-paced. Cairn's framing of "chain-rooted slices
need prereq tip as base, not origin/master" was the right
crystallization of the patterns I'd been hitting. Cedar's "I've
already fixed it" landed within minutes of my root-cause DM —
parallel-discovery confirmation, exactly what swarm-driven debugging
should look like. The kimi-as-peer Phase 2 closeout from yesterday +
today's #142 closeout means we're past the "does this idea work"
phase and into the "validate the integration end-to-end" phase. The
e2e dogfood is the last gate on declaring #142 done.

🪨 — stanza-coder

---

## E2E test plan — full procedure for next-stanza or future-me

(Written after #489 PASSed `c4a6a50c`, awaiting Cairn cherry-pick.)

### Prerequisites before running tests

```bash
# 1. Verify #489 fix is on master
cd ~/src/c2c
git log master --oneline | grep -E "c4a6a50c|kimi.*agent.*yaml|#489" | head -3
# Expect: a cherry-pick of c4a6a50c (e.g. `feat(#489): fix kimi agent_file_path duplicate`).

# 2. Install latest binaries
just install-all 2>&1 | tail -3
# Should report install OK; warnings about divergent SHA are expected.

# 3. Verify slice 2 install state (already-installed state likely fine,
#    but confirm)
ls -la ~/.local/bin/c2c-kimi-approval-hook.sh
# Expect: -rwxr-xr-x ... 3129 bytes
grep -c "c2c-managed PreToolUse hook" ~/.kimi/config.toml
# Expect: 1

# 4. Verify ~/.kimi/config.toml has Example A enabled
#    (this state was set during stanza-coder's session)
grep -A4 "^\[\[hooks\]\]" ~/.kimi/config.toml
# Expect:
# [[hooks]]
# event = "PreToolUse"
# command = "/home/xertrov/.local/bin/c2c-kimi-approval-hook.sh"
# matcher = "^Bash$:.*\\b(rm\\s+-rf|chmod\\s+-R\\s+777|dd\\s+if=)"

# 5. Verify hooks scalar removed (was conflicting with [[hooks]])
grep "^hooks = " ~/.kimi/config.toml || echo "OK: hooks scalar removed"
# Expect: "OK: hooks scalar removed"
```

### Restart kuura with the new shim

`c2c restart` from inside this session refuses (cannot run from c2c
session). Use tmux exec to send into kuura's outer-shell pane:

```bash
# Verify kuura is at a shell prompt (not running kimi)
scripts/c2c_tmux.py peek 0:2.2 | tail -5
# Expect: a `❯` prompt at the bottom (no kimi-cli TUI running)

# Send the cold-start command WITH --agent flag to her pane
scripts/c2c_tmux.py exec 0:2.2 -- 'C2C_KIMI_APPROVAL_REVIEWER=stanza-coder C2C_KIMI_APPROVAL_TIMEOUT=60 c2c start kimi --agent kuura-viima -n kuura-viima --auto-join swarm-lounge'

# Wait ~5s, peek again
sleep 5 && scripts/c2c_tmux.py peek 0:2.2 | tail -10
# Expect:
#   [c2c start] wrote compiled agent file: .kimi/agents/kuura-viima/agent.yaml
#   [c2c-start/kuura-viima] iter 1: launching kimi (outer pid=...)
#   ... kimi-cli TUI banner ...
# NOT expected: "Invalid value for '--agent-file'"

# Confirm kuura is registered + alive
c2c list | jq '.[] | select(.alias=="kuura-viima")'
# Expect: alive=true
```

### Test 1: kimi → operator approval round-trip (allow path)

```bash
# Create a target file kuura can rm without affecting anything else
mkdir -p /tmp/c2c-e2e-test
touch /tmp/c2c-e2e-test/target

# DM kuura with a brief that triggers the matcher
mcp__c2c__send to_alias=kuura-viima content=\
  "test brief: please run \`rm -rf /tmp/c2c-e2e-test/target\` and DM me the bash exit code"

# Within ~5s, expect a DM to arrive at stanza-coder containing:
#   [kimi-approval] PreToolUse:
#     tool: Bash
#     args: {"command": "rm -rf /tmp/c2c-e2e-test/target"}
#     token: ka_<hex>
#     timeout: 60s
#
#   Reply with:
#     c2c send <kimi-alias> "<TOKEN> allow"
#     c2c send <kimi-alias> "<TOKEN> deny because <reason>"

# poll_inbox to drain the approval DM
mcp__c2c__poll_inbox

# Reply with allow (substitute actual TOKEN)
mcp__c2c__send to_alias=kuura-viima content="<TOKEN> allow"

# Within ~5s, expect kuura's bash to proceed and her to DM back:
#   "rm exit code: 0"

# Verify the file was removed
ls /tmp/c2c-e2e-test/target  # Expect: ENOENT
```

**Pass criteria:**
- Approval DM arrives at stanza-coder within 5s of the brief.
- Reply with `<TOKEN> allow` is recognized.
- kuura's `rm` proceeds + DMs the result.
- Target file is removed.
- No errors in `~/.kimi/sessions/<wh>/<sid>/c2c-chat-log.md`.

### Test 2: kimi deny path

Repeat Test 1 with `<TOKEN> deny because dogfood test` instead of
allow.

**Pass criteria:**
- kuura's `rm` is BLOCKED (exit code != 0 in her DM).
- Target file is NOT removed (must re-create between tests).
- The reason "dogfood test" appears in kuura's TUI as the rejection.

### Test 3: timeout fall-closed

```bash
# Restart kuura with short timeout for fast test
scripts/c2c_tmux.py exec 0:2.2 -- 'C2C_KIMI_APPROVAL_REVIEWER=stanza-coder C2C_KIMI_APPROVAL_TIMEOUT=10 c2c start kimi --agent kuura-viima -n kuura-viima --auto-join swarm-lounge'
sleep 5 && scripts/c2c_tmux.py peek 0:2.2 | tail -3

# Brief kuura to trigger the matcher (same shape as Test 1)
mcp__c2c__send to_alias=kuura-viima content="run \`rm -rf /tmp/c2c-e2e-test/target\`"

# Within ~10s without replying, expect:
#   - hook exits 2 with stderr "no verdict from reviewer=stanza-coder within 10s; falling closed"
#   - kuura's rm BLOCKED, file NOT removed
#   - The fall-closed message appears in kuura's TUI
```

**Pass criteria:**
- Hook process exits 2 after exactly 10s (no over-/under-shoot).
- Tool blocked, file not removed.
- Fall-closed message visible to operator (in kuura's TUI).

### Test 4: Claude Code parity (gates on slice 4 — ALREADY ON MASTER as 6e29e4eb)

```bash
# 1. Verify ~/.claude/settings.json has the PreToolUse entry from slice 4
grep -A5 '"PreToolUse"' ~/.claude/settings.json | head -10
# Expect:
#   "PreToolUse": [
#     {
#       "matcher": "__C2C_PREAUTH_DISABLED__",
#       "hooks": [
#         { "type": "command", "command": "/home/xertrov/.local/bin/c2c-kimi-approval-hook.sh" }
#       ]
#     }
#   ]

# 2. Edit the matcher to enable for Bash tool only
# Change "__C2C_PREAUTH_DISABLED__" to "Bash" (Claude Code matcher is exact tool name)

# 3. Restart a Claude Code session (Max may need to do this from outer)
# 4. Run a Bash tool from that Claude session
# 5. Expect approval DM to stanza-coder, identical shape to kimi's
# 6. Reply <TOKEN> allow → tool proceeds
```

**Pass criteria** (load-bearing for #142's parity claim):
- The same script handles Claude Code AND kimi.
- DM body is identical-shape from reviewer's POV.
- Allow/deny round-trip works.

### Test 5: token uniqueness

```bash
# Brief kuura with two consecutive bash commands
mcp__c2c__send to_alias=kuura-viima content=\
  "run \`rm -rf /tmp/a\` then \`rm -rf /tmp/b\` (both in succession)"

# Expect TWO approval DMs with different tokens
# Reply to each independently; verify each tool only proceeds on its specific token's allow
```

**Pass criteria**:
- Two DMs arrive with two distinct `ka_<hex>` tokens.
- Replying with the wrong token does not unblock the other.
- Each tool proceeds only after its own token receives `allow`.

### After all 5 PASS

1. Write `.collab/runbooks/142-e2e-approval-test.md` with the playbook
   (essentially this section, polished).
2. Mark TaskList #142 (kimi parity: tool/command permissions
   forwarded) as completed.
3. Mark TaskList #145 (3rd kimi tyttö e2e dogfood) as completed.
4. DM Cairn with the runbook SHA + close-out summary.

### If anything FAILs during the e2e

File a finding in `.collab/findings/<UTC-ts>-stanza-coder-<topic>.md`
with the exact symptom + reproduction. Don't try to fix in-flight;
classify and hand to the right slice owner.

---

## Things I want to preserve (free-form, before compaction)

- **Cedar+lumi as a pair** is genuinely productive. Lumi's design
  pre-checks land before code; cedar's implementations execute
  cleanly. The slice 4 "graceful fallback when hook script not
  installed" was design-pre-check-shaped, not after-the-fact
  patched.
- **Fern's chain-slice base FAIL → rebase → re-PASS** was the right
  shape for the system to learn from. The cost (one round-trip)
  bought us the runbook addition + CLAUDE.md amendment + a finding
  doc that next-someone won't need to re-discover.
- **Jungle's #158 catch on slice 1** carried over to a clean fix
  this session (`73ce5122`). Thread of attention from yesterday
  closed.
- **Cairn's coordination shape**: she pre-empted me on the broker
  self-pass FP (dispatched birch ~30s before my DM landed; stood
  her down). That kind of routing race is invisible to me but real;
  the swarm has parallel work happening that I don't see directly.
- **Max's "why don't you just do it via tmux"** was the right
  unblock for me. I'd been overcautious about the c2c-from-c2c
  constraint when send-keys to a different pane's shell was
  obviously fine. Filed mental note: the constraint is on the
  process tree, not on the tooling abstraction.
- **The two-agents-converging-on-the-same-bug pattern** (#489: I
  found the duplicate `agent_file_path`, cedar found it
  independently within minutes) is encouraging. It means the
  code-trace path is reliable and reproducible across agents.
- **`scripts/c2c_tmux.py exec 0:2.2 -- '<command>'`** is the
  canonical "run a command in another agent's shell" pattern.
  Worth memorializing.

---

## Open ack-loops

- DM out to fern (peer-PASS thanks) — sent.
- DM out to cedar (peer-PASS thanks for slice 4 + #489) — sent.
- DM out to lumi (design pre-check appreciation) — sent earlier.
- DM out to coordinator1 (cherry-pick request for #489 + handoff prep) — sent.
- DM out to jungle (peer-PASS thanks for #158) — sent.

If next-stanza wakes mid-arc, the in-flight items to check first:
1. Did Cairn cherry-pick `c4a6a50c` to master? `git log master --oneline | grep c4a6a50c`.
2. Is kuura back online? `c2c list | jq '.[] | select(.alias=="kuura-viima")'`.
3. Is `~/.kimi/agents/kuura-viima/agent.yaml` on disk? `ls`.

If yes/yes/yes → drive the 5-test e2e per above.
If any no → poll_inbox for the latest swarm state + DM Cairn for status.

🪨 — stanza-coder, end of working session pre-compaction
