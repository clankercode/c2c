# #479 Statefile Parity Audit — Instance Config Per-Client Coverage
**Auditor:** test-agent
**Date:** 2026-04-30
**SHA audited:** `2e7efd1a` (origin/master tip)
**Worktree:** `.worktrees/479-statefile-parity-audit/`

---

## `instance_config` Type (what gets written to `~/.local/share/c2c/instances/<name>/config.json`)

```ocaml
type instance_config = {
  name                  : string;       (* always: instance name *)
  client                : string;       (* always: claude/codex/opencode/kimi/gemini/... *)
  session_id            : string;       (* always: = name *)
  resume_session_id     : string;       (* Option.value resume_session_id ~default:name *)
  codex_resume_target   : string option;(* only set for "codex" on fresh start *)
  alias                 : string;       (* alias_override or name *)
  extra_args            : string list;  (* always: possibly empty *)
  created_at            : float;        (* reuse existing on resume; fresh Unix time on new *)
  last_launch_at        : float option;  (* always set on fresh; NOT updated on restart *)
  last_exit_code        : int option;    (* always None on fresh; written by run_outer_loop on exit *)
  last_exit_reason      : string option; (* always None on fresh; written by run_outer_loop on exit *)
  broker_root           : string;       (* always: resolve_broker_root () *)
  auto_join_rooms       : string;       (* always: default "swarm-lounge" *)
  binary_override       : string option; (* only when --bin flag used *)
  model_override        : string option; (* only when --model flag used *)
  agent_name            : string option; (* only when --agent flag used *)
}
```

---

## Cross-Tab: Which Clients Set Which Fields

Legend: **✓** always  **○** conditionally  **—** never  **N/A** not applicable

| Field | claude | codex | opencode | kimi | gemini | codex-headless |
|---|---|---|---|---|---|---|
| `name` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `client` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `session_id` (=name) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `resume_session_id` | ✓ (fresh: UUID) | ✓ (fresh: UUID) | ✓ (fresh: UUID) | ✓ (fresh: UUID) | ✓ (fresh: UUID) | ✓ (fresh: empty `""`) |
| `codex_resume_target` | — | ✓ fresh only | — | — | — | — |
| `alias` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `extra_args` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `created_at` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `last_launch_at` | ✓ fresh | ✓ fresh | ✓ fresh | ✓ fresh | ✓ fresh | ✓ fresh |
| `last_exit_code` | ✓ on exit | ✓ on exit | ✓ on exit | ✓ on exit | ✓ on exit | ✓ on exit |
| `last_exit_reason` | ✓ on exit | ✓ on exit | ✓ on exit | ✓ on exit | ✓ on exit | ✓ on exit |
| `broker_root` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `auto_join_rooms` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `binary_override` | ○ | ○ | ○ | ○ | ○ | ○ |
| `model_override` | ○ | ○ | ○ | ○ | ○ | ○ |
| `agent_name` | ○ | — | ○ | ○ | — | — |

### Field Population Sources

**Fresh start (no existing config):**
- `session_id = name`
- `resume_session_id = Uuid.v4 Gen` (or `""` for codex-headless)
- `codex_resume_target = Some sid` (codex only)
- `alias = alias_override ?? name`
- `created_at = Unix.gettimeofday()`
- `last_launch_at = Some now`
- `last_exit_code = None`
- `last_exit_reason = None`
- `broker_root = resolve_broker_root ()`
- `auto_join_rooms = auto_join_rooms ?? "swarm-lounge"`
- `binary_override`, `model_override`, `agent_name` = flags or None

**Resume (existing config found):**
- All fields loaded from disk
- `resume_session_id` = loaded from disk (or re-generated if invalid UUID and not codex-headless)
- `codex_resume_target` = loaded from disk (codex only)
- `last_launch_at` = **NOT updated** (stays from original `created_at` era)

**On exit (run_outer_loop writes back):**
- `last_exit_code = Some exit_code`
- `last_exit_reason = Some reason`

---

## Model Override Resolution (3-Way Priority)

Model priority documented in AGENTS.md: `--model` flag > role pmodel > saved instance config.

**Resolution path** (`resolve_model_override` at `c2c_start.ml:4640`):
```
explicit --model flag  →  role pmodel (via role file, via c2c_alias match)  →  saved model_override
```
All three tiers flow into `cmd_start` as `role_pmodel_override`, then resolved.

### Adapter vs non-adapter clients

| Client type | Handles model internally | Receives `model_override` from `prepare_launch_args` |
|---|---|---|
| claude (ClaudeAdapter) | ✓ via `A.build_start_args` | ✓ passed to adapter |
| opencode (OpenCodeAdapter) | ✓ via `A.build_start_args` | ✓ passed to adapter |
| kimi (KimiAdapter) | ✓ via `A.build_start_args` | ✓ passed to adapter |
| codex (CodexAdapter) | ✓ via `A.build_start_args` | ✓ passed to adapter |
| gemini (GeminiAdapter) | ✗ | **NOT passed** — only appended at tail of `prepare_launch_args` |
| codex-headless | ✗ | **NOT passed** — only appended at tail of `prepare_launch_args` |

The append-at-tail path (`args @ extra_args`) is only hit by non-adapter clients, and `model_override` is passed as a named argument, not via `extra_args`. **This is a bug for gemini and codex-headless on fresh start**: role pmodel and saved model_override are never applied for these two clients.

On **resume**, `resolve_model_override` IS called with `saved_model_override:ex.model_override`, but the result is passed as `model_override` to `run_outer_loop`. The non-adapter `prepare_launch_args` appends it at the end via `args @ extra_args`, and since `model_override` is a named argument (not in `extra_args`), it doesn't appear there either.

**Severity: MEDIUM** for gemini/codex-headless. These clients can't be configured via role pmodel or saved instance config model — only explicit `--model` flag works.

---

## Findings: Gaps vs Intentional Asymmetry

### BUG (needs fix in #479 follow-up slice)

**F1 — `codex_resume_target` is dead on restart.** ✅ **Fixed as #491 (`f29cda65` → `67359d97`)** — cherry-picked after jungle's PASS.

**F2 — Non-adapter clients (gemini, codex-headless) never receive `model_override`.** ❌ **Retracted after re-analysis** — the non-adapter `else` branch at `prepare_launch_args` line 2799 correctly appends `--model model` when `model_override` is `Some`. Both fresh-start (via `role_pmodel_override`) and resume (via `ex.model_override`) correctly wire through. No bug.

**F3 — `last_launch_at` is never refreshed on restart.** ✅ **Fixed as `a3f847bc`** (worktree `.worktrees/491-f2-f3-model-lastlaunch/`). Also fixed a secondary bug: `cmd_restart` had a `cfg` shadowing issue where the session_id override was written to disk but the unmodified `cfg` was used for `build_start_argv` — now a single binding covers both.

### INTENTIONAL ASYMMETRY (no action needed)

**A1 — `codex_resume_target` is codex-only.** Only the CodexAdapter stores this; it is a Codex-specific session targeting mechanism. Other clients don't need it.

**A2 — `agent_name` is only set for clients that support `--agent`.** Claude, OpenCode, and Kimi support it (per-adapter `build_start_args`). Codex, Gemini, and codex-headless don't have agent-file surfaces in their adapters.

**A3 — `auto_join_rooms` is always written but only read for tmux launches.** The `run_tmux_loop` path consumes it; non-tmux `run_outer_loop` ignores it. This is by design — auto_join_rooms is a swarm-lounge convention injected via env vars by the deliver mechanism, not a per-client flag.

**A4 — `session_id_env` diverges per client.** Claude uses `CLAUDE_CODE_PARENT_SESSION_ID`, OpenCode uses `OPENCODE_SESSION_ID`, Kimi uses `KIMI_SESSION_ID`, Codex/Gemini use none (they use `C2C_MCP_SESSION_ID` via the broker). This is correct — each client expects a different env var for session identity.

**A5 — OpenCode refresh_identity writes two files.** `refresh_identity` for OpenCode writes both `.opencode/opencode.json` (env injection) and `<inst_dir>/c2c-plugin.json` (sidecar). This is intentional — the former is for the c2c plugin, the latter for broker identity.

**A6 — Role fields (`role_pmodel`, `role_file`, `role_description`) are not in instance_config.** These are loaded from role files at launch time, not persisted. This is intentional — roles are source-of-truth documents that should be re-evaluated on each launch.

**A7 — `created_at` is preserved on resume.** `created_at` is reused from the existing config, not overwritten. This is correct — `created_at` should reflect when the instance was first created, not last restarted.

---

## Recommendations for #479 Follow-Up Slice

| ID | Gap | Priority | Status |
|---|---|---|---|
| F1 | `codex_resume_target` unused on restart | HIGH | ✅ Fixed as #491 (`67359d97`) |
| F2 | gemini/codex-headless model_override gap | MEDIUM | ❌ Retracted — no bug |
| F3 | `last_launch_at` stale on restart | LOW | ✅ Fixed as `a3f847bc` |

---

## Files Examined

- `ocaml/c2c_start.ml:2067–2134` — `instance_config` type + `write_config`/`load_config_opt`
- `ocaml/c2c_start.ml:2679–2809` — `prepare_launch_args` per-client branches
- `ocaml/c2c_start.ml:2980–3288` — ClaudeAdapter, CodexAdapter, KimiAdapter, GeminiAdapter
- `ocaml/c2c_start.ml:1282–1410` — OpenCodeAdapter
- `ocaml/c2c_start.ml:4610–4621` — `run_outer_loop` exit path (resume command string)
- `ocaml/c2c_start.ml:4820–4898` — resume path (existing config merge)
- `ocaml/c2c_start.ml:4640–4649` — `resolve_model_override` 3-way priority
- `ocaml/cli/c2c.ml:7367–7378` — `resolve_role_pmodel_for_launch`
- `ocaml/cli/c2c.ml:7627–7768` — role loading in `cmd_start` (agent mode + auto-inference)
- `ocaml/cli/c2c.ml:7800–7810` — non-role start path
