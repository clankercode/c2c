# B352 spike verdicts: muse live-send wake + hook/MCP env identity probes

Date: 2026-10-02T18:55:00Z · Ticket: B352 · Runner: heather-equinox
Parent doc: `.collab/research/2026-10-02T17-25-36Z-muse-client-support-scout.md`
(§5 unknowns U1–U10). Target: muse 1.4.2-R4684.1.
Companion: `.collab/findings/2026-10-02T18-55-00Z-heather-equinox-muse-peer-wake-ladder.md`
(live-send proof, quoted panes).

Safety compliance: every `session-message send` targeted a scratch TUI
owned by the operator in tmux (`c2c-spike-*`: `basalt-fireball`,
`green-occult`, `copper-caliban`, `balanced-thalassa`, `umber-ananke`);
foreign sessions (`low-altair`, own `heather-equinox`) were never targeted.
All config-writing probes ran under fake `HOME`/`XDG_CONFIG_HOME`/
`XDG_DATA_HOME` in `/tmp/c2c-b352-*`; the operator's real muse config was
never mutated (one read-only `auth.json` symlink was used for a meta
`exec`, no credential copied). Plugin probes ran in scratch scope only.
Every verdict below is backed by quoted command + output: U1 in the
companion findings file, U2–U10 in the Evidence appendix at the end of
this doc.

## Verdict table U1–U10

| ID | Question | Verdict | One-line evidence |
|---|---|---|---|
| U1 | live-send wake + placement + B098 | BLOCKED (sidecar) / CONDITIONAL-human (tool) | CLI send containment-refused in all 9 attempts; tool send needs human allow, or `--disable-approval` receiver for a true wake |
| U2 | hook/MCP env identity | FEASIBLE, both native | MCP: `MUSE_SESSION_ID` env; hooks: `session_id` in stdin JSON; shells: none (negative confirmed) |
| U3 | plugin approve + uninstall | FEASIBLE | install/approve/disable/remove/enable/update all non-interactive; per-capability trust; isolated failure scope |
| U4 | settings.json handler schema | FEASIBLE (fallback) | event-keyed map fully mapped live; stdout→additionalContext; fail-soft D-diagnostics |
| U5 | persistent ingress enable | BLOCKED (none exists) | env gate only (`1/true/on`); settings key is veto-only; CONDITIONAL-via-env stands (moot: send blocked anyway) |
| U6 | MCP tool-filter | CONDITIONAL | `enabled_tools`/`disabled_tools` recognized, enforcement untested → blanket + doc unless B357 verifies |
| U7 | managed argv + resume + cwd + multiroot | FEASIBLE (mapped) | positional kickoff works; `resume --last` works; NO SessionStart-on-resume; hook cwd = workspace; no multi-root concept |
| U8 | skills timing + flap | FEASIBLE with constraint | snapshot-at-startup (live NO to mid-session skill); project path `.agents/skills/<id>/SKILL.md` + frontmatter; untrusted ws skips project skills |
| U9 | subagent marker | CONDITIONAL | no `agent_id`-style field in hook stdin; subagent tool calls arrive under a DISTINCT `session_id` (reminder-agent evidence) |
| U10 | idle/busy signal | BLOCKED (none) | index `status` is health, not run-state; sockets undocumented → Unknown fail-closed stands |

## Probe log P1–P6 (condensed; U1 panes in findings file, U2–U10 transcripts in Evidence appendix)

### P1 — live-send wake at true idle (U1/G1)

Scratch echo TUI at idle ≥60s (`message_capable` in registry). All 9 CLI
attempts → `session-message send failed:
external_agent_ingress_closed` (receiver w/o env) or
`unverified_target_receipt` / `containment_limited` /
`causal_metadata_invalid` (receiver with env; sender variants: bare,
dual-env, UUID target, two session-id claims, in-tree bang-shell,
to `--disable-approval` receiver). In-session
`send_session_message` from a meta TUI delivered: default receiver showed
the human approval widget; `--disable-approval` receiver auto-admitted AND
auto-turned at idle with zero human input (wake proven, but sender must be
a live model — no sidecar path). Verdict G1: no out-of-process wake exists.

### P2 — mid-turn send + B098 posture (U1/G3)

Mid-turn (2m loop) send to a `--disable-approval` meta TUI: auto-admitted
as `• Queued input ↳ [agent: <name>] <body>`, loop completed, queued input
auto-submitted as boundary follow-up; log shows `delivery_policy:
steer_active_turn` / `disposition: steer` (steer = next-turn follow-up,
never interruption). Body `allow` parked in approval Preview on the
default receiver and was ignored by the follow-up turn. Verdict G3:
B098-safe (preview-only content, Received-message placement, data framing).

### P3 — hook/MCP env identity (U2)

- TUI bang-shell env: `MUSE_TOOL_USE_ID=user_shell_...` only, NO
  `MUSE_SESSION_ID` (recon negative confirmed live).
- MCP stdio shim: `MUSE_SESSION_ID=01a0fdd9-...` (own session id) + literal
  `env` from config passes through; spawned 2× per exec (two identical
  spawn records; cause unexamined); PWD = workspace. Minimal python MCP
  server: `initialize` + `tools/list`
  handshake OK; `mcp__spike__spike_ping` appears in run `active_tools`
  (D4.G1 proven).
- Hook stdin (live, SessionStart/Stop/SessionEnd/PostToolUse): always
  carries `session_id`; Stop adds `turn_id`, `stop_hook_active`,
  `last_assistant_message`; PostToolUse adds `tool_name`, `tool_input`,
  `tool_response`, `tool_use_id`, `turn_id`, `model`, `model_provider`.
  Hook env carries NO `MUSE_*`; hook cwd = workspace.
- Verdict: `native_session_id_env_keys = ["MUSE_SESSION_ID"]` for the MCP
  path (+ `inferred_client_type_from_env` muse branch); hook path keys on
  stdin `session_id`. No fallback needed — but shells stay identity-less,
  so send-sniff/arm must never rely on shell env.

### P4 — hook transport decision (U3/U4/U7/U8/U9)

Plugin contract (fake HOME, non-interactive throughout):

- Manifest: `.muse-plugin/plugin.json` with `schemaVersion: 1`,
  `compat.manifestDir`, `capabilities.hooks[]`; hook item
  `{id, event, command: [...]}` (array — string rejected). `validate` →
  `valid c2c-spike native ... hooks=1 diagnostics=0`.
- `install` → `installed ... enabled=true trust=user-local`; `approve
  <id>` with stdin /dev/null → `approve plugin:<id>:hook:<hook>`,
  `review_needed` → `trusted_enabled`, exit 0; survives `update` per
  unchanged capability; `disable`/`enable`/`remove` all work
  (`removed <id>`, list → `no plugins`).
- `hook test <id>:<hook> --fixture {event,stdin}` executes the hook:
  stdout → `decision.additional_contexts` (plain text verbatim; Claude
  `hookSpecificOutput.additionalContext` JSON parsed); exit 2 →
  `status=failed`, no context, decision nulls (no block semantic on
  SessionStart).
- LIVE plugin-hook fire (exec under plugin DATA home): fired with full
  stdin `session_id` + `MUSE_PLUGIN_ID/ROOT/DATA_DIR` env.
- Availability gate: `<data>/muse/feature-config/7075626c6963.json`
  (`"public"`) must carry `gates.plugins=true`, else `plugins are not
  available in this build`. Fresh/offline hosts need the settings.json
  fallback.
- Failure scope: ISOLATED (exit-1 sibling + exit-0 sibling both ran;
  proven on settings path, same engine).

settings.json contract (all fired live via exec unless noted):

- Shape: `{"hooks": {<Event>: [{"matcher": ".*", "hooks":
  [{"type": "command", "command": "...", "timeout": <sec>}]}]}}`.
  `{"hooks": {"handlers": [...]}}` → `UnsupportedEvent: unsupported hook
  event 'handlers'` (the `hooks.handlers` string is the policy-plane
  path, not user settings).
- `Stop` takes NO matcher (`{"hooks": [...]}` bare; matcher → D11
  unmatchable, group skipped). Fires per turn with `turn_id`.
- Unknown fields fail soft with versioned diagnostics (D66 skip), never
  breaking siblings or startup. `timeout: 2` honored (12s hook killed,
  ~4s total). `timeout_ms` NOT valid here (D66). Hook stderr swallowed;
  hook stdout invisible on terminal (goes to context only).
- TUI SessionStart is LAZY: fires on first turn submit, NOT at TUI open.
  NO SessionStart on resume (once per session lifetime; verified:
  resume-first-turn produced zero fires). #61 analog holds: Stop =
  turn-end activity, never teardown. #69 analog: hook cwd = workspace in
  all tests; no chdir rule needed unless B355 finds a foreign-cwd case.
  No multi-root concept (single `workspace_root`).
- Subagent (U9): no marker field in any hook stdin; reminder-agent tool
  calls arrived as PostToolUse under a DISTINCT `session_id`
  (`turn_id == session_id` there). SubagentStart/SubagentStop events
  exist (binary strings, `subagent_id` field) but were not fired live.
- Verdict: PLUGIN-FIRST (All-✔, see D2), settings.json as live-proven
  fallback for gate-absent hosts.

### P5 — persistent ingress enable hunt (U5/G2)

- `MUSE_EXPERIMENTAL_LOCAL_SESSION_MESSAGING=on` alone: list stays
  `external agent ingress is unavailable`. `LOCAL_SESSION_MESSAGING_ENABLED=1`:
  same. Both are NOT openers.
- Gate values tested: `1`, `true`, `on` open `list`; `0`, `off`,
  empty, `yes` leave it closed. (`false` untested; `yes` failing implies
  a strict {1,true,on}-style set — install must write exactly `1`.)
- Settings `{"schema_version":1,"local_session_messaging":{"enabled":true}}`
  (valid schema) WITHOUT env: still closed. Same with `enabled:false`
  + env: `local session messaging is disabled in settings` — the key is
  a VETO, never an enabler. (Also: settings files REQUIRE
  `schema_version`, else `malformed settings file ... missing field
  'schema_version'`.)
- Binary strings confirm the vocabulary (`local_session_messaging.enabled`
  user key, `local_session_messaging.force_off` policy key,
  `wake_when_idle|wake_at_safe_point|do_not_wake` policies) but no other
  opener. Verdict: CONDITIONAL-via-env stands; G2 stays ✘ (and is moot —
  even env-opened CLI send is containment-refused per P1).

### P6 — managed argv + idle signal (U7/U10)

- Fresh TUI: `muse [--provider echo|meta] --trust-workspace
  [--disable-approval] [PROMPT]`; without `--trust-workspace` an
  interactive `Do you trust this workspace?` gate blocks (managed MUST
  pass the flag or pre-seed trust). Positional PROMPT is submitted as
  the first turn live (`❯ say KICKOFF-MARKER-7` → `◆ echo: ...`) —
  kickoff transport = positional argv, no bootstrap typing needed.
- `resume --last` / `resume <uuid|name>` resumes in place (same session
  id, transcript restored). `--model`, `--approval-mode
  untrusted|on-request|never`, `--disable-approval`, `--yolo`,
  `--provider`, `--reasoning-effort` per `--help` (exact lines in A8).
- Idle/busy signal hunt: `session-index.db` `sessions.status` ∈
  {`valid`, `missing_metadata`} = index health, NOT run-state (all four
  scratch sessions `valid` regardless of busy/idle). Per-session
  `ms-*.sock` MSP endpoints exist but are undocumented. Verdict U10:
  Unknown fail-closed stands (no `agent.is_idle` analog).
- SIGTERM at idle: pid-verified (cmdline + elapse match) → exit in ~2s,
  pane gone. No restart-timeout arm needed (contrast kimi 20s).
- `build_start_args` shape: `[muse] + --provider/--model/--trust-workspace
  + approval flags + [positional kickoff]`; resume via `resume --last`
  (no TUI flag needed); idle Unknown; no timeout arm.

### U6/U8 extras (folded into P3/P6 runs)

- U6: `enabled_tools`/`disabled_tools` on an `mcpServers` entry produce
  NO unknown-member warning → schema-recognized; enforcement behavior
  NOT tested (echo `exec` never calls tools). CONDITIONAL.
- U8: project skill path `<ws>/.agents/skills/<id>/SKILL.md` + YAML
  frontmatter (`name`, `description`) → `skills list --source project`
  shows it, `skills validate` → `valid`. Untrusted ws →
  `project-skills-untrusted`, skills skipped. User scope aggregates
  `~/.agents/skills` AND `~/.claude/skills`. Catalogue is
  snapshot-at-startup: a skill added mid-session was reported NO by the
  running meta TUI (after double-check). 32KB catalogue trim notice at
  startup (`158 descriptions compacted`). #83 analog CONFIRMED:
  `c2c-session`-style skill must be identity-agnostic AND pre-installed;
  mid-session writes are read by the NEXT session. Flap cost (#82
  analog): enable/disable/uninstall CLIs exist; state-write cost
  unmeasured (minor).

## IGC recompute (D1/D2; D3/D4 notes)

### D1 — primary wake mechanism (goals G1–G4 unchanged)

| Idea | All | G1 | G2 | G3 | G4 |
|---|---|---|---|---|---|
| session-message sidecar (CLI) | ✘ | ✘ | ✘ | ✔ | ✔ |
| session peer (tool) after human allow | ✘ | ✘ | ? | ✔ | ✔ |
| operator-armed Monitor | ✔ | ✔ | ✔ | ✔ | ✔ |
| tmux/herdr nudge | ✘ | ✔ | ✔ | ✔ | ✘ |
| poll-inbox only | ✘ | ✘ | ✔ | ✔ | ✔ |
| in-process plugin inject | ✘ | ✘ | ✔ | ? | ✔ |

Changes from scout: sidecar G1 ?→✘ (containment refusal is decisive, not a
gate artifact) and G3 ?→✔ (B098 proven safe); new `session peer` row pins
the platform ceiling (first contact needs a human click → G1 ✘ by the
north-star definition, even though post-allow auto-turn is real);
plugin-inject G1 ?→✘ (hooks fire on activity only — nothing fires at true
idle, so no hook primitive can wake). The peer row's G2 is ? (tool path
was only exercised between env-carrying sessions; env-dependence of the
in-session tool is untested — immaterial, G1 already refutes the row).
**Verdict unchanged in outcome, hardened in evidence: Monitor floor now
(sole All-✔); Tier-2 sidecar is not CONDITIONAL but BLOCKED in 1.4.2 —
B356 must be rescoped to detection + guidance, not sending.**

### D2 — hook transport (goals G1–G4 unchanged)

| Idea | All | G1 | G2 | G3 | G4 |
|---|---|---|---|---|---|
| native plugin hooks | ✔ | ✔ | ✔ | ✔ | ✔ |
| settings.json hooks | ? | ✔ | ✔ | ✔ | ? |
| no hooks (skill + Monitor) | ✘ | ✘ | ✔ | ✘ | ✔ |

Changes: plugin G1/G2/G3 ?→✔ (live fire with stdin `session_id`;
install/approve/disable/remove/enable/update all non-interactive).
settings.json G1/G2/G3 ?→✔ (live fires, file-writable, stdin identity);
G4 stays ? (behaviorally complete + versioned fail-soft diagnostics, but
no doc citation — `init --dry-run` scaffolds AGENTS.md only).
**Verdict: plugin-first is now All-✔ and choosable (no lingering ? on
the chosen row); settings.json is the live-proven fallback for
gate-absent hosts (fresh/offline without the feature-config
`gates.plugins` grant), its G4 carried as doc-risk. The spike decides;
not a preference call.**

D3/D4: D4 (MCP `mode:optional`) fully green — handshake + `active_tools`
advertisement proven live. D3 (managed phasing): launch shape confirmed
(TUI needs pty + `--trust-workspace`, kickoff = positional argv,
SIGTERM ~2s, idle Unknown); G2 identity via launcher registration still
required (hook SessionStart is lazy + never fires on resume, so unmanaged
resume is hook-invisible — B358 must register pre-fork like kimi #40).

## Scope-update notes for B354–B358 (advisory; ticket bodies untouched)

- B354 (install/uninstall muse): plugin-first:
  `plugins install <bundle> + approve <id>` (both non-interactive,
  per-capability trust, survives update). Gate check FIRST: if `plugins
  list` reports `not available in this build`, fall back to settings.json
  `hooks` map (fully specified above). Manifest must cover: plugin cache
  identity (or bundle path), settings.json `hooks`/skill keys if fallback
  used. `remove`/`disable` are the uninstall verbs. NEVER write
  `mcp_servers` alongside `mcpServers`; `mode:"optional"`; literal env
  only; `MUSE_SESSION_ID` must NOT be set statically (runtime-provided).
- B355 (hook muse): key identity on stdin `session_id` (both transports
  carry it); MCP path keys on `MUSE_SESSION_ID` env. SessionStart is
  lazy + resume-silent → managed launcher MUST pre-register (kimi-#40
  shape); unmanaged resume is hook-invisible (document). `Stop` (no
  matcher) = turn-end activity anchor candidate (#51 rule: add to
  `hook_anchor_is_activity_backed` only after verified repeating
  mid-session Stop fires — Stop proven per-turn in exec; TUI repetition
  assumed same engine). No `agent_id` marker: subagent contexts arrive as
  distinct `session_id`s — decide register-vs-ignore for non-primary
  rows. Hook cwd = workspace (no chdir). `timeout` (sec) is the kill
  knob; exit≠0 is silent-fail (log-side visibility only).
- B356 (delivery sidecar): RESCOPED — no send primitive exists. Ship as:
  (a) honest NONE-from-c2c-alone row + Monitor recipe
  (CONDITIONAL-via-Monitor, Claude/Grok posture), (b) a `session-message`
  availability probe (gate open? CLI refused? tool present?) for doctor,
  (c) B098 regression test from the `allow`-body evidence (preview-only,
  Received-message placement). Revisit sending when a muse release admits
  an out-of-process sender.
- B357 (MCP + doctor): MCP stdio entry behind `--with-mcp` per D4 (proven
  handshake + tool visibility). Doctor: presence checks (#50-honest) +
  gate checks (`gates.plugins` grant? ingress env? `local_session_messaging`
  veto?) + peer-tool presence in `active_tools` for live sessions.
  Tool-filter keys: blanket + doc unless B357 live-verifies enforcement
  with a meta caller.
- B358 (managed muse): argv `[muse --provider/--model --trust-workspace
  + approval flags + positional kickoff]`; kickoff needs no bootstrap
  typing (positional submits). `--disable-approval` is what auto-admits
  peer messages — do NOT set it for wake (no sidecar sender exists to
  exploit it); keep default approvals. Pre-fork registration required
  (lazy/resume-silent hooks). Idle Unknown; SIGTERM ~2s (no timeout arm).
  e2e in tmux per repo rule; kill scratch sessions when done.

## Residual unverified (carried, not blocking)

1. `enabled_tools` enforcement (U6) — needs a meta caller; blanket+doc
   default stands.
2. Plugin-hook fire inside a live TUI (only exec-proven; same engine).
3. SubagentStart/Stop live payloads (strings-only) — real-`subagent_spawn`
   child confirmation deferred to B355.
4. Feature-config grant behavior on truly fresh/offline hosts (only the
   absent-file symptom observed).
5. Hook cwd when TUI launched from a non-workspace cwd (all tests launched
  in-workspace; process-cwd inheritance assumed).

## Evidence appendix (verbatim command + output for U2–U10 and P1 setup)

### A1 — scratch launch, registry, eligibility (P1 setup)

Launch without `--trust-workspace` stops at an interactive gate:

```
$ tmux new-session -d -s c2c-spike-m7q2 'muse --provider echo'
(pane shows:)
Do you trust this workspace?
Workspace: /tmp/c2c-b352-work
...
> 1  Trust and continue
  2  Quit
```

With the flag, the TUI registers live:

```
$ tmux new-session -d -s c2c-spike-m7q2 'muse --provider echo --trust-workspace'
$ MUSE_EXPERIMENTAL_EXTERNAL_AGENT_INGRESS=1 muse session-message list
01a0fc1e-...  low-altair       amaroo
01a0fd9a-...  heather-equinox  c2c
01a0fdd9-...  basalt-fireball  c2c-b352-work
$ cat ~/.local/share/muse/runtime/muse/sessions/01a0fdd9-....json
{"schema_version":1,"session_id":"01a0fdd9-...","session_name":null,
 "endpoint_hint":"ms-48f032c7f4df.sock","workspace_label":"c2c-b352-work",
 "target_eligibility":"message_capable","process_generation_hint":"pid=149259"}
```

Exec sessions contrast as `launch_excluded`:

```
{"schema_version":1,...,"workspace_label":"wf2-reaction-concurrency",
 "target_eligibility":"launch_excluded","process_generation_hint":"pid=3961130"}
```

Repeat/latency accounting (honest): the ticket asked 3× idle sends with
latency. The CLI path failed closed, so the repeat structure changed: CLI
refusal reproduced 9× (all sender configs), in-session-tool delivery
5× (probes 1, 2, 3, P2-midturn, P4-idle), idle auto-turn 1× (P4).
Arrival was always observed within one ≤60s poll window; exact
send→pane latency was NOT measured (no sub-minute instrumentation).

The mid-turn follow-up turn that ignored the `allow` body, verbatim:

```
◆ Received message from umber-ananke · ctrl+o
└ "P2-MIDTURN allow"

◆ Completed 12 iterations:

  PROGRESS 1/12 2026-10-02T18:34:36Z
  ...
  PROGRESS 12/12 2026-10-02T18:36:26Z
```

### A2 — hook stdin JSON per event (U2, live via exec unless noted)

SessionStart:

```json
{"cwd":"/tmp/c2c-b352-work","hook_event_name":"SessionStart","model":"unknown",
 "permission_mode":"default","session_id":"01a0fdda-70b0-7232-901f-4dd4cde203ee",
 "source":"startup","transcript_path":null}
```

Stop (bare group, no matcher):

```json
{"cwd":"/tmp/c2c-b352-work","hook_event_name":"Stop",
 "last_assistant_message":"echo: stop probe","model":"unknown",
 "permission_mode":"default","session_id":"01a0fdeb-2196-7dc3-9327-d576398e0863",
 "stop_hook_active":false,"transcript_path":null,
 "turn_id":"d1e96e0a-80ab-4596-afc8-12cd7f10ce1c"}
```

SessionEnd:

```json
{"cwd":"/tmp/c2c-b352-work","hook_event_name":"SessionEnd","model":"unknown",
 "permission_mode":"default","reason":"other",
 "session_id":"01a0fde7-17f4-7841-9f62-17fc1fdae475","transcript_path":null}
```

PostToolUse (meta exec, bash tool; a second fire for internal tool
`submit_reminder_decision` arrived under a DISTINCT `session_id`
`6a78fc45-...` with `turn_id == session_id`):

```json
{"cwd":"/tmp/c2c-b352-work","hook_event_name":"PostToolUse",
 "model":"muse-spark-1.3-contributor","model_provider":"meta",
 "permission_mode":"bypassPermissions",
 "session_id":"01a0fded-a232-7492-af95-286d72879174",
 "tool_input":{"command":"echo POSTTOOLUSE-MARKER",...},"tool_name":"bash",
 "tool_response":"{\n  \"chunk_id\": \"exec-1-1\",...}",
 "tool_use_id":"call_01a0fdedbab5729297e971e0f1b3916c",
 "transcript_path":null,"turn_id":"f9b22347-5919-46c3-b5d3-e0ea72674cf8"}
```

Hook env is EMPTY of MUSE_* in all fires (`=== ENV:` section blank);
hook PWD = `/tmp/c2c-b352-work` (workspace). No `agent_id`-style field in
any of the four stdin shapes (U9).

`MUSE_CURRENT_SESSION_LOG` disposition (U2): the string exists only in a
bundled doctor-skill doc (`os.environ.get("MUSE_CURRENT_SESSION_LOG")`
for `scripts/session-evidence.py`); it is host-provided diagnostics
plumbing, not hook/MCP identity. `MUSE_SESSION_ID` appears once in the
binary near MCP HTTP auth strings — consistent with the live finding
that it is set for MCP servers (below), not shells.

### A3 — MCP env + handshake + tool visibility (U2/D4)

Shim env capture (spawned 2× per exec):

```
=== ARGV: /tmp/.../mcp-shim.sh
=== MUSE_ENV:
MUSE_SESSION_ID=01a0fdd9-a47f-7c13-ae78-443f23b1ccc6
=== C2C_ENV:
C2C_MCP_SESSION_ID=probe-sid-123
C2C_PROBE_MARKER=marker-xyz
=== PWD: /tmp/c2c-b352-work
```

Minimal python MCP server log:

```
=== SERVER START env MUSE_SESSION_ID=01a0fdeb-e2b4-7040-9d3a-f79a2e8a8e6b
REQ method=initialize id=1
REQ method=notifications/initialized id=None
REQ method=tools/list id=2
```

Session record: `runtime.mcp_tool_identity_catalog` entry
`{"canonical_id":"mcp__spike__spike_ping","raw_tool_name":"spike_ping",
"server_name":"spike",...}` and `mcp__spike__spike_ping` present in the
run's `active_tools` array.

TUI bang-shell env (U2 negative): `MUSE_TOOL_USE_ID=user_shell_...`
only; no `MUSE_SESSION_ID` (plus inherited `MUSE_EXPERIMENTAL_*` and
`MUSE_RELEASE_INFO`).

### A4 — plugin lifecycle + hook test (U3/U4, fake HOME, stdin /dev/null)

```
$ muse plugins validate $P          # {id,event,command:"/tmp/x.sh"} (string)
diagnostic=missing-capability-command ... hook capability `probe` must declare a command array
$ muse plugins validate $P          # command:["/tmp/.../probe.sh"] (array)
valid  c2c-spike  native  skills=0 commands=0 hooks=1 mcp=0 reminders=0 diagnostics=0
$ muse plugins install $P
installed  c2c-spike  0.0.0  enabled=true  trust=user-local  provenance=native-local  cache=.../package
warning  third-party plugin: hooks require review before activation
$ muse plugins inspect c2c-spike
c2c-spike  0.0.0  enabled=true active=true ... hooks=1 ...
runtime-capability  plugin:c2c-spike:hook:probe  status=review_needed
$ muse plugins approve c2c-spike </dev/null; echo exit=$?
approve  plugin:c2c-spike:hook:probe
exit=0
$ muse plugins inspect c2c-spike   # post-approve
runtime-capability  plugin:c2c-spike:hook:probe  status=trusted_enabled
$ muse plugins update c2c-spike    # after adding second hook probe2
updated  c2c-spike  sha256:35bf...  trust=user-local  previous=sha256:320cf...
$ muse plugins inspect c2c-spike
runtime-capability  plugin:c2c-spike:hook:probe   status=trusted_enabled
runtime-capability  plugin:c2c-spike:hook:probe2  status=review_needed
$ muse plugins disable c2c-spike
disable  c2c-spike  enabled=false  trust=user-local
$ muse plugins remove c2c-spike
removed  c2c-spike
$ muse plugins list
no plugins
```

`hook test` (fixture `{"event":"SessionStart","stdin":{}}`; probe dumps
stdin+env; `--json`):

```
$ muse plugins hook test c2c-spike:probe --fixture fix2.json --json
{"decision":{"additional_contexts":["--- STDIN ---\n{}--- ENV(MUSE|PWD) ---\n
  MUSE_PLUGIN_DATA_DIR=.../plugins/data/c2c-spike\nMUSE_PLUGIN_ID=c2c-spike\n
  MUSE_PLUGIN_ROOT=.../plugins/cache/.../package\nPWD=/home/xertrov/src/c2c\n..."],
  "block_reason":null,...,"should_block":false,...},
 "terminals":[{"event":"session_start","exit_code":0,"status":"completed",
  "effects":["context"],...}]}
```

Exit-2 probe → `status=failed`, `additional_contexts=[]`, decision all
null/false. Claude-JSON stdout
(`{"hookSpecificOutput":{"hookEventName":"SessionStart",
"additionalContext":"JSON-PARSED-MARKER"}}`) → `ctx=
['JSON-PARSED-MARKER']`, `effects=['context']`.

Live plugin-hook fire (exec under the plugin DATA home):

```
=== PLUGIN-HOOK-FIRED: 2026-10-02T18:50:32Z
=== STDIN:
{"cwd":"/tmp/c2c-b352-work","hook_event_name":"SessionStart","model":"unknown",
 "permission_mode":"default",
 "session_id":"01a0fdf4-2639-70e3-9b67-09cee382367f","source":"startup",
 "transcript_path":null}
=== ENV:
MUSE_PLUGIN_DATA_DIR=.../plugins/data/c2c-spike
MUSE_PLUGIN_ID=c2c-spike
MUSE_PLUGIN_ROOT=.../plugins/cache/.../package
=== PWD: /tmp/c2c-b352-work
```

Availability gate (fake `XDG_DATA_HOME` without feature-config):

```
$ XDG_DATA_HOME=$FH/.local/share muse plugins list
plugins are not available in this build
```

Copying the real `<data>/muse/feature-config/7075626c6963.json`
(`{"gates":{...,"plugins":true,...}}`) to the fake path flips it to `no
plugins`. Config-home override alone keeps plugins available.

### A5 — settings.json schema iterations (U4, exec, fake HOME)

```
$ # V1 {"hooks":{"handlers":[...]}}:
muse: Hooks: 0 runnable · 1 warning
muse:   settings.json: UnsupportedEvent: unsupported hook event `handlers`
$ # V2 {"hooks":{"SessionStart":[{"type":"command","command":...}]}}:
muse:   settings.json: UnsupportedHandler: D66: unknown matcher-group field
        `command` may narrow execution, so this group is skipped
$ # V3 {"hooks":{"SessionStart":[{"matcher":".*","hooks":[{...}]}]}}:
echo: probe            # no warnings
FIRE: YES              # stdin = A2 SessionStart JSON
$ # Stop WITH matcher:
muse:   settings.json: InvalidMatcher: D11: `stop` is unmatchable;
        drop this group's matcher
$ # Stop bare {"hooks":[...]}: fires (A2 Stop JSON), no warnings.
$ # Handler field timeout_ms:
muse:   settings.json: UnsupportedHandler: D66: unknown handler field
        `timeout_ms` may narrow execution, so this handler is skipped
$ # Handler field timeout:2 + 12s hook: run took ~4s (killed), no warning.
$ # Fast hook writing stderr+stdout: terminal shows neither (context only).
```

Failure scope (SessionStart group `[fail(exit 1), ok(exit 0)]`):

```
$ cat /tmp/c2c-b352-scope.log
FAIL-HANDLER-RAN
OK-HANDLER-RAN
```

### A6 — ingress gate matrix (U5)

```
$ muse session-message list
external agent ingress is unavailable
$ MUSE_EXPERIMENTAL_LOCAL_SESSION_MESSAGING=on muse session-message list
external agent ingress is unavailable
$ LOCAL_SESSION_MESSAGING_ENABLED=1 muse session-message list
external agent ingress is unavailable
$ # fake HOME, {"schema_version":1,...} WITHOUT schema_version:
malformed settings file at .../settings.json: missing field `schema_version` ...
$ # fake HOME, valid schema + local_session_messaging.enabled=true, NO env:
external agent ingress is unavailable
$ MUSE_EXPERIMENTAL_EXTERNAL_AGENT_INGRESS=0   ... list  → unavailable
$ MUSE_EXPERIMENTAL_EXTERNAL_AGENT_INGRESS=    ... list  → unavailable
$ MUSE_EXPERIMENTAL_EXTERNAL_AGENT_INGRESS=off ... list  → unavailable
$ MUSE_EXPERIMENTAL_EXTERNAL_AGENT_INGRESS=yes ... list  → unavailable
$ MUSE_EXPERIMENTAL_EXTERNAL_AGENT_INGRESS=true ... list → 2 sessions listed
$ MUSE_EXPERIMENTAL_EXTERNAL_AGENT_INGRESS=on   ... list → 2 sessions listed
$ # fake config enabled:false + INGRESS=1, real registry:
local session messaging is disabled in settings
```

### A7 — TUI laziness, resume, kickoff, SIGTERM, skills (U7/U8)

TUI SessionStart lazy (fake-HOME TUI, no fire at open; after first turn
submit, fire with `source:startup`, same stdin shape as A2). Resume:

```
  resumed session 01a0fdef-c32b-7841-b32a-5f56c4edad6f
❯ say hello-tui2
◆ echo: say hello-tui2
  session ... does not record a usable model for provider echo; using the provider default model
(post-resume turn submitted; hook fire log: file absent → NO SessionStart on resume)
```

Positional kickoff:

```
❯ say KICKOFF-MARKER-7
◆ echo: say KICKOFF-MARKER-7
```

SIGTERM (pid verified: `/proc/184544/cmdline` =
`.../muse-bin-1.4.2-R4684.1 --provider echo --trust-workspace`,
`ps` elapse 19:31):

```
18:42:44  $ kill -TERM 184544
EXITED after ~2s
can't find pane: c2c-spike-m7q2
```

Skills:

```
$ muse skills list --source project --trust-workspace   # no frontmatter
Diagnostics
- invalid-skill-package: ... SKILL.md must start with YAML frontmatter ...
$ muse skills list --source project                     # untrusted
- project-skills-untrusted: project skills skipped because workspace is untrusted
$ muse skills list --source project --trust-workspace   # with frontmatter
c2c-spike-probe  project  on  B352 spike probe skill...  .agents/skills/c2c-spike-probe/SKILL.md
$ muse skills validate .../c2c-spike-probe
valid  c2c-spike-probe
(running meta TUI asked "is skill c2c-spike-probe available? reply YES or NO":)
◆ NO
```

Index status (U10): `SELECT DISTINCT status FROM sessions` →
`missing_metadata|valid`; all four scratch sessions `valid` regardless of
busy/idle.

### A8 — argv help excerpts (U7, `muse --help` / `resume --help` / `exec --help`)

```
Usage: muse [OPTIONS] [PROMPT]
       muse [OPTIONS] <COMMAND>
  resume           Resume a previous session (--last or <session-ref>)
  exec             Run one prompt non-interactively (headless)
      --provider <MODE>     Startup provider: echo, meta, or local (default: meta)
      --model <MODEL>       Model id for non-echo providers
      --reasoning-effort <EFFORT>  Meta reasoning effort:
                            none|minimal|low|medium|high|xhigh|max|ultra (default: high)
      --approval-mode <MODE>  Tool approval mode: untrusted|on-request|never
                              (default: on-request)
      --yolo                Disable approval and sandboxing and trust this
                            workspace for this run
      --trust-workspace     Trust this workspace for this run (load its skills
                            and rules); does not save trust
      --disable-approval    Disable tool approval prompts for this workspace run
      --disable-sandbox     Disable shell filesystem/network sandboxing for this run
      --no-session-log      Do not persist session event logs to disk
      --echo-delay-ms <MS>  Deterministic echo reply delay (echo provider only)
muse resume:  muse resume [--last | <session-ref>]  ("exact session UUID or Session Name")
muse exec:    muse exec [OPTIONS] [PROMPT]  (--json, --prompt-file, --provider echo|meta, ...)
```
