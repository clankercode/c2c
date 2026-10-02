# muse client support — scout synthesis (5 subagents, 2026-10-02)

Umbrella bug: B351. Workstreams: B352–B360. Target: `muse` 1.4.2
(Meta Muse Code CLI), measured read-only on this host.

Scout coverage: install/hook/identity · managed lifecycle ·
delivery/MCP/doctor · docs/tests/codegen/website · muse-CLI recon.
Every file:line below was read by a scout this session.

## 1. Recon verdicts (muse 1.4.2, all with quoted evidence)

| Area | Verdict | Essence |
|---|---|---|
| Binary identity | feasible (mapped) | `muse` = bash launcher + `muse-bin-1.4.2` payload; subcommands include `session-message`, `mcp`, `plugins`, `skills`, `exec`, `serve`, `resume`, `config` |
| Config/state | feasible (mapped) | `${XDG_CONFIG_HOME:-$HOME/.config}/muse/settings.json`; sessions `~/.local/share/muse/sessions/…`; live registry `runtime/muse/sessions/<uuid>.json` + unix sockets; project skills `<ws>/.agents/skills/<id>/` |
| MCP stdio | feasible (docs exact) | `settings.json` key `mcpServers` (camelCase); stdio `{"type":"stdio","command","args","env","mode":"optional"}`. Gotchas: dual `mcpServers`+`mcp_servers` keys drop the whole member; `required`+`mode` ambiguity drops it too; no `${VAR}` expansion; fixed env allowlist + literal `env`; next-launch-only; no channel/push extension seen → MCP is poll-tools |
| Hooks | feasible via plugin; settings schema conditional | Documented plugin contract: manifest `.muse-plugin/plugin.json`, capability families `skills\|commands\|hooks\|mcpServers\|reminders`, events incl. SessionStart/PreToolUse/PostToolUse/SessionEnd, lifecycle `plugins validate\|install\|inspect\|approve\|reject\|enable\|disable\|hook test --fixture`. `settings.json` `hooks.handlers` key recognized but handler schema unverified |
| Sessions | feasible (env-identity partly unknown) | UUID ids + human names; `session-message list` (gated) filters live+`message_capable` (vs `launch_excluded` for exec sessions). `MUSE_SESSION_ID` exists in binary but was NOT in a spawned shell's env — hook/MCP env visibility unmeasured |
| Wake/inject | CONDITIONAL (gated, untested live) | `muse session-message send --target <uuid-or-name>`; unlocked ONLY by `MUSE_EXPERIMENTAL_EXTERNAL_AGENT_INGRESS=1` (env-only; snake_case settings key recognized but did NOT unlock). Policies in binary: `queue_next_turn\|steer_active_turn\|notify_only`, `do_not_wake\|wake_when_idle\|wake_at_safe_point`. Live send deliberately NOT tested (would inject into foreign sessions) |
| Managed start | feasible (both modes; TUI needs pty) | `muse exec` headless works (keep session logging ON — `--no-session-log` disables local messaging); interactive needs TTY → tmux/herdr pty + kickoff prompt; untrusted cwd needs `--trust-workspace` |

**Nothing is IMPOSSIBLE.** Two load-bearing unknowns gate Tier-1/2 scope
(B352 spike, operator-run): (a) live-send wake behavior + transcript
placement/B098 posture; (b) hook/MCP env identity (`MUSE_SESSION_ID`
visibility, hook stdin JSON shape, plugin `approve` non-interactivity).

## 2. Tier plan

- **Tier 0 — poll fallback** (zero muse cooperation): alias/blocklist/
  inference/send-sniff, `c2c-session`-style skill if a skills dir fits,
  wake-guidance arm, docs NONE row + Monitor recipe. B353.
- **Tier 1 — install + hooks + MCP + doctor** (needs spike (b)):
  `c2c install/uninstall muse`, `c2c hook muse`, MCP `mcpServers.c2c`
  entry behind `--with-mcp`, doctor/health presence checks labeled
  #50-honest. B354, B355, B357, B359.
- **Tier 2 — delivery sidecar** (needs spike (a)): `session-message`
  sender + persist-first drain + DeliveryEndpoint adapter, honest
  CONDITIONAL-via-env row, B098 regression test. B356.
- **Tier 3 — managed** (needs Tier 1 + launch-shape confirmation):
  MuseAdapter + `c2c start/stop/restart muse`, kickoff/trust wiring,
  idle Unknown, tmux e2e. B358. (Grok precedent allows deferring;
  launch shape is already mapped so phased day-one is recommended.)
- **Glue throughout**: skills codegen, docs/website/runbooks/changelog,
  per-surface tests, dune stanzas, fixtures. B360 + per-bug tests.

## 3. IGC decisions

Method: Idea-Goal-Context triples; ✔ = no known decisive error,
✘ = decisive error, ? = unknown TODO. All-column: ✘ if any ✘,
else ? if any ?, else ✔. Only All-✔ is choosable.

### D1 — primary wake mechanism

Context: muse 1.4.2 as measured (see §1); Monitor is a stable muse
surface; repo policy forbids send-keys as the primary path.

- G1: wakes a truly idle agent with no model decision (north-star wake)
- G2: no experimental env gate (stable/persistent enablement)
- G3: B098-safe (peer content arrives as DATA, never user-role/APPROVAL)
- G4: primary path is not tmux/herdr send-keys (repo policy)

| Idea | All | G1 | G2 | G3 | G4 |
|---|---|---|---|---|---|
| session-message sidecar | ✘ | ? | ✘ | ? | ✔ |
| operator-armed Monitor | ✔ | ✔ | ✔ | ✔ | ✔ |
| tmux/herdr nudge | ✘ | ✔ | ✔ | ✔ | ✘ |
| poll-inbox only | ✘ | ✘ | ✔ | ✔ | ✔ |
| in-process plugin inject | ? | ? | ✔ | ? | ✔ |

Decisive errors: sidecar fails G2 (env-only gate, no persistent switch
found) — revivable if a switch is found or the flag stabilizes; its G1/G3
are the B352 spike. Nudge fails G4 by policy (fallback only). Poll fails
G1 (needs the model to choose). Plugin-inject has no observed primitive.
**Verdict: Monitor floor now (sole All-✔); sidecar as Tier-2
CONDITIONAL-via-env behind the spike.**

### D2 — hook transport

Context: plugin contract documented (manifest + approve lifecycle +
`hook test --fixture`); `settings.json` `hooks.handlers` recognized,
handler schema unverified.

- G1: fires on session lifecycle without operator action
- G2: c2c can install AND uninstall it (manifest + recompute)
- G3: payload/env carries usable session identity
- G4: stable documented surface (not experimental)

| Idea | All | G1 | G2 | G3 | G4 |
|---|---|---|---|---|---|
| native plugin hooks | ? | ✔ | ? | ? | ✔ |
| settings.json hooks.handlers | ? | ? | ✔ | ? | ? |
| no hooks (skill + Monitor) | ✘ | ✘ | ✔ | ✘ | ✔ |

**Verdict: no All-✔ — B352 spike decides (plugin first: documented
contract; settings.json fallback). Not a preference call.**

### D3 — managed-start phasing

Context: interactive muse needs TTY (tmux pty like other clients);
`exec` headless works; `--trust-workspace` + logging-on required.

- G1: launchable in tmux pty with kickoff prompt
- G2: identity adoptable by hook or launcher registration
- G3: stop/restart safe under C2c_pid_identity
- G4: managed ships in this milestone with ≥CONDITIONAL wake

| Idea | All | G1 | G2 | G3 | G4 |
|---|---|---|---|---|---|
| managed day-one (phased) | ? | ✔ | ? | ✔ | ? |
| managed deferred (grok precedent) | ✘ | ✔ | ✔ | ✔ | ✘ |

G4 is the genuine operator decision: if held, day-one is the only
non-refuted direction and its ?s are spike work (B352b); if not held,
drop G4 and deferred wins on simplicity. **Raised with operator;
recommended: phased day-one (launch shape already mapped).**

### D4 — MCP config

- G1: tools visible to the model · G2: cannot break muse startup ·
  G3: no expansion/secret hazards

| Idea | All | G1 | G2 | G3 |
|---|---|---|---|---|
| mcpServers.c2c stdio, mode:optional | ✔ | ✔ | ✔ | ✔ |
| skip MCP | ✘ | ✘ | ✔ | ✔ |

**Verdict: ship MCP behind `--with-mcp` (B254 posture).** Load-bearing:
never write legacy `mcp_servers` alongside `mcpServers` (loader drops
the whole member); `mode:"optional"` so a dead server can't block
startup; literal env only.

## 4. Per-surface file checklists (condensed from scouts)

### Install / uninstall / detect

`ocaml/cli/c2c_setup.ml`: `known_clients` :2033,
`install_subcommand_clients` :2041, `init_configurable_clients` :2044,
`detect_client_prefixes` :2046, `start_clients` :2047 (help text only;
real gate is `c2c_start.ml` `clients` Hashtbl :1644–1704),
`deliver_watch_clients` :2056, dispatch arms :2464–2481,
`client_mcp_configured` :2536+, `client_integration_configured`
:2636–2665 (note: agy falls to `_ -> false` — do NOT copy that),
`--with-mcp` set :2961, help strings :2797/:2995,
`default_alias_for_client` :648 (free `muse-…` via
`C2c_start.default_alias_prefix`), skill writers :44–281,
`do_install_client` :2428–2510 (B173 grok skips global default-alias —
decide the muse analogue), manifest kinds in
`ocaml/c2c_install_manifest.ml` (owned-file/shared-key/shared-block/
shared-toml-section; YAML shared-key is hermes-only).
`ocaml/cli/c2c_uninstall.ml`: `known_components` :11,
`recompute_*_artifacts` :357–509 (ADD muse covering EVERY setup path
incl. session skill), dispatch :530–540, `all` :700,
target_dir honored only for opencode/claude :715–718.
`ocaml/cli/c2c_init_cmd.ml`: `path_detectable_clients` :41–49,
`detect_client` :75–94, install group :786–810.
`ocaml/cli/c2c_detect_agent_cmd.ml:23–39` markers.
`ocaml/cli/c2c_root_cmd.ml:137–164` landing copy (CLI-first arm or it
falls into the wrong "MCP ready" default), pi synthetic :71–76.
B182: `ocaml/c2c_blocklist.ml:5–72` add `muse` + `muse-` (keep
rename/help prefix-list tests green, `test_c2c_cli.ml:583`).

### Hook + identity

New `hook_muse_cmd` + group entry in `ocaml/cli/c2c_hook_cmd.ml`
(:2913 list; grok L1787–1997 / agy L2399–2905 are the templates):
8s SIGALRM→exit-0, `is_subagent_quiet` first, B130 `agent_id` gate,
1MiB stdin cap, sid validation, outer try→exit-0, managed-marker
(`C2C_MCP_SESSION_ID` OR `AUTO_REGISTER_ALIAS`), statefile
write-if-not-live, `touch_hook_activity` every handled event (#51 —
add `muse-hook` to `hook_anchor_is_activity_backed`
`c2c_broker.ml:502–507` ONLY after verified repeating mid-session
hooks), SessionEnd deregisters hook-owned rows only, Stop is turn-end
never teardown (#61). Register via `locked_sticky_auto_register`
(B188/B191 NON-REENTRANT lock, `c2c_mcp_helpers_post_broker.ml:1494–
1625`), `client_type="muse"`, `registered_by="muse-hook"`; add
`muse-hook` to `is_hook_auto_registration` (`c2c_broker.ml:416–463`)
+ `same_session_hook_identity_row` (post_broker :1677).
Broker root: `ocaml/c2c_repo_fp.ml` (`C2C_MCP_BROKER_ROOT` wins;
memoized fingerprint + `reset_repo_fingerprint_cache` :53) — if the
hook runs with foreign cwd, chdir-before-resolve à la agy #69;
never resolve above the chdir. Inference:
`native_session_id_env_keys` :710–721, `inferred_client_type_from_env`
:875–892, `session_id_from_env` :1031–1077 (+ grok-active-sessions /
kimi-index / cursor-askpass fallback precedents).
`ocaml/cli/c2c_send_cmd.ml:23–87` send sniff arm.
`c2c_changelog.ml:204` per-client markers if hooks show changelogs.

### Delivery / wake / MCP / CLI

Wake classes + copy: `ocaml/c2c_wake_guidance.ml:29–173`
(`Guaranteed/Conditional/None_idle`, Install + Managed_start arms).
DeliveryEndpoint: `ocaml/c2c_delivery_endpoint.ml/mli`
(`module type S`, `endpoint_of_*_reg`, `drain_policy=After_push`
only if durable-then-drain). Sidecar skeleton:
`ocaml/cli/c2c_agy_deliver.ml:111–221` (ensure-env → peek → envelope
→ send → `drain_after_inject` 3×retry + broker.log; `watched_pid`,
`max_iterations`, 15s TERM→KILL) + `ocaml/c2c_agy_agentapi.ml`
(pure `send_argv`, `ensure_*_env` with NO headless-mint #78,
`classify_wake_env`, B098-DATA-framed `format_inbound_payload`).
Daemon lifecycle (if a daemon): `ocaml/c2c_kimi_notifier.mli:22–221`
(.pid/.sid, rekey + `~authoritative`, comm/proc identity gate per
#85, SHA-upgrade decision, `ensure_daemon`; teardown by instance
name). Claim (if dual-run): `c2c_kimi_delivery_claim.ml`.
Persist-first is load-bearing: peek → inject → drain-on-success +
race repair (hermes `data/hermes-plugin/delivery.py:248–324`);
NEVER drain-first. Injector never drains (wake-inject :53).
MCP: `ocaml/c2c_mcp.ml:29–243` tool registry (single source #479),
envelope `c2c_mcp_helpers.ml:846–880` (peer content XML-escaped),
channel gate (`experimental.claude/channel` only — muse declares
none → poll-based), auto-drain default ON but channel-gated
(`c2c_mcp_server_inner.ml:75–86`; managed installs write 0).
CLI: inbox/send/verify in `c2c_inbox_cmd.ml`/`c2c_send_cmd.ml`/
`c2c_health_cmd.ml:1254–1378`; tiers `c2c_commands.ml:20–180`
(new subcommands MUST join the map or silently land Tier2).
Monitor floor recipe (verbatim #414): `Monitor({ description: "c2c
inbox watcher", command: "c2c monitor --wake-only", persistent: true })`
for hook-equipped; full-body `c2c monitor` for Grok-style.
B098: new inject paths need a verdict-inertness regression mirroring
`test_c2c_await_reply.ml` / `test_c2c_codex_autoturn_b098.ml`.

### Managed lifecycle

`CLIENT_ADAPTER` sig `c2c_start.ml:1568–1628`; adapters
Claude :5432 / Codex :5487 / Kimi :5540 / Agy :5626 / OpenCode :1727;
`clients` table :1644–1704 + `supported_clients` :1705.
`prepare_launch_args` :5122–5261 (per-client arms + model
double-apply guard), `normalize_model_override_for_client` :1484
(unknown client = Error — ADD the arm), `build_env` :4843–4997
(native mirror :4876–4883, legacy strip :4956–4968),
`run_outer_loop` :6413–7839 (pre-fork register :6962–7041,
fork+`setpgid` :7066–7145, sidecars :7173–7480, heartbeats/schedule
:7487–7520, owner-control poll :7525+),
`eager_register_managed_alias` :2391–2462,
`register_managed_{kimi,agy}_session` :2498–2578,
`default_restart_timeout_s` :8600, `cmd_restart` :8644+,
`cmd_start` :7841–8428 (nested-session + stale-BROKER_ROOT guards,
`--session-id` validation :7965–8009, stale recovery :8023–8132,
resume/new :8137–8280). Single stop: `stop_instance` :8430–8551
(paired pid+start-time, exact-generation signal, sidecar sweep —
ADD muse sidecars; Absent = descendant-only cleanup) via
`C2c_pid_identity` (leaf module; NEVER signal disk pids without it,
#85). Teardown strips pid (`clear_registration_pid` :2300).
Idle: `c2c_idle_contract.ml` kind + resolve (Unknown fail-closed
unless an authoritative signal exists). Kickoff: `[swarm]
restart_intro` + `builtin_swarm_restart_intro` :745, per-client
transport (:C5 — positional argv / plugin handshake / skill-only /
none+bootstrap). Heartbeats: `default_heartbeat_clients` :183–184.
`c2c new` accepts ONLY codex|kimi (B245 — do NOT extend casually).
Roles: `c2c_role.ml` renderer + `client_agent_dir` + agent paths;
`c2c_agent.ml` menu + `all_targets` ×2. Tests live in tmux via
`scripts/c2c_tmux.py` (never raw `c2c start` from bash);
`KNOWN_TUIS` in `scripts/c2c-tmux-exec.sh:93`.

### Doctor / health / instances

`c2c_doctor_hooks.ml`: result types :31–163, agy :824–858, kimi
:868–1142 (DEAF=inbox>0∧¬notifier, #42B, `--rearm` skips
confirmed-dead), grok :1166–1301 (wake classifier via
`.monitor-locks/<alias>.lock` pid check — COPY for muse),
render :1405–1871, exit-failure on DEAF :2014+.
#50: presence ≠ firing — label checks honestly; live send→observe
is the only proof. `c2c_health_cmd.ml`: probes :208–291 (message
MUST contain client name for `client_status` substring match),
`supported_clients` :564, liveness via `outer_pid_is_ours` :832–858,
relay grey when inactive (B300 — route via `Relay_activation`,
never substitute the public URL). `c2c_instances_cmd.ml` agy
details object precedent :35–149. `c2c_sweep_cmd.ml:267` pgrep
guard list. statusline/inject/deliver-inbox `--client` doc strings.

### Docs / website / codegen / tests

Jekyll: every `docs/*.md` publishes; `commands.md` hand-mirrors
`--help` in the same slice; #414 verbatim recipes; changelog
`data/changelog/CHANGELOG.md` + `just codegen-changelog`.
Skills: `.collab/skills/c2c-src/harness/<name>.md` + EMBEDS in
`tools/ci/codegen-c2c-skills.py` → `assembled/` + `c2c.md` +
`c2c_*_skill_embedded.ml`; `just codegen-c2c-skills`;
`just sync-skills[-check]` → `.claude/.opencode/.codex/skills`
(add `.muse/` dst ONLY if muse loads project skills there).
Plugin (if in-process): `data/muse-plugin/` + `just
codegen-muse-plugin` mirroring hermes (explicit file list,
letter-only delims, CI drift gate). Website: `docs/_layouts/
home.html:24–110` hero tabs + `main.scss:431–458` selectors +
`7 clients` stat + og-alt (fix pre-existing kimi/hermes/agy
omissions while there); per-client page `docs/clients/muse.md`
(hermes pattern); feature-matrix col + deep dive; `llms-muse-
install.txt` + `llms.txt` + root mirror; runbooks `c2c-install.md`
+ `c2c-env-vars.md` (verbatim values). Tests: Alcotest
`test_c2c_setup_muse.ml` + `test_c2c_hook_muse.ml` (+ delivery
suites), hermetic temp-HOME + real `c2c.exe` under `env -i`,
`C2C_MUSE_*_FIXTURE` gates, `(deps c2c.exe)` in dune stanzas
(#60), lib modules in `ocaml/dune`, CLI in `ocaml/cli/dune`;
`just check` + forced repo-wide `@runtest` honoring the 8
false-green rules. Pre-existing drift (judgment calls):
`relay_server_html.ml:177` (missing agy/hermes — fix minimum),
`c2c_tmux.py:1007` launch help, statusline/send-sniff/detect-agent
omissions, no `llms-hermes-install.txt`.

## 5. Unknowns register (all owned by B352 unless noted)

U1 live-send wake/idle/mid-turn behavior + transcript placement +
B098 posture · U2 hook/MCP env identity (`MUSE_SESSION_ID`,
hook stdin JSON, `MUSE_CURRENT_SESSION_LOG`) · U3 plugin
`approve` non-interactivity + uninstall (`disable`/`remove`?) ·
U4 settings.json handler schema (fallback) · U5 persistent
session-ingress enable (else CONDITIONAL-via-env stands) · U6 MCP
tool-filter support (else blanket + doc) · U7 managed argv details
(resume/model/approval flags) + SessionStart-on-resume? (#73
analog) + hook cwd (#69 analog) + multi-root? · U8 skills catalogue
timing (#83 analog) + flap cost (#82 analog) · U9 subagent marker
(B130 analog) · U10 idle/busy signal (else Unknown fail-closed).
