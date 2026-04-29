# #159: Statefile parity audit — per-client coverage of c2c instance config

## 1. Schema inventory

Source: `ocaml/c2c_start.ml:type instance_config` (lines 2053–2067)

| Field | Type | Written at | Read by | Mutable at runtime |
|-------|------|------------|---------|-------------------|
| `name` | `string` | `run_outer_loop` spawn | `load_config_opt`, broker registry | ❌ Never |
| `client` | `string` | `run_outer_loop` spawn | `load_config_opt`, restart argv | ❌ Never |
| `session_id` | `string` | `run_outer_loop` spawn | `load_config_opt` | ❌ Never |
| `resume_session_id` | `string` | `run_outer_loop` spawn, `cmd_restart`, `cmd_reset_thread`, `persist_headless_thread_id` | `prepare_launch_args` (all clients), `build_start_argv` | ✅ Yes |
| `codex_resume_target` | `string option` | `run_outer_loop` spawn, `cmd_restart`, `cmd_reset_thread` | `prepare_launch_args` (codex only) | ✅ Yes |
| `alias` | `string` | `run_outer_loop` spawn | `load_config_opt`, kickoff rendering | ❌ Never |
| `extra_args` | `string list` | `run_outer_loop` spawn | `prepare_launch_args`, `build_start_argv` | ⚠️ Cleared on plain relaunch (#471) |
| `created_at` | `float` | `run_outer_loop` spawn (preserved on restart) | `load_config_opt`, `c2c instances` | ❌ Never |
| `broker_root` | `string` | `run_outer_loop` spawn | `load_config_opt`, broker init | ❌ Never |
| `auto_join_rooms` | `string` | `run_outer_loop` spawn | `load_config_opt`, `build_start_argv` | ❌ Never |
| `binary_override` | `string option` | `run_outer_loop` spawn | `prepare_launch_args` | ❌ Never |
| `model_override` | `string option` | `run_outer_loop` spawn | `prepare_launch_args` | ❌ Never |
| `agent_name` | `string option` | `run_outer_loop` spawn | `prepare_launch_args`, role rendering | ❌ Never |

**JSON serialization**: `write_config` uses `Yojson.Safe.pretty_to_channel`. Optional fields (`codex_resume_target`, `binary_override`, `model_override`, `agent_name`) are omitted when `None`.

## 2. Per-client matrix

| Field | claude | opencode | codex | codex-headless | kimi | gemini |
|-------|--------|----------|-------|----------------|------|--------|
| `resume_session_id` | ✅ Used (`--resume`) | ✅ Used (`--resume`) | ✅ Used (`--resume` via `codex_resume_target`) | ✅ Used (`--thread-id-fd` + persisted) | ✅ Used (`--session`) | ✅ Used (`--resume`) |
| `codex_resume_target` | ❌ N/A | ❌ N/A | ✅ Written | ❌ N/A | ❌ N/A | ❌ N/A |
| `alias` | ✅ Used (broker registration) | ✅ Used (broker registration) | ✅ Used | ✅ Used | ✅ Used | ✅ Used |
| `extra_args` | ✅ Passed | ✅ Passed | ✅ Passed | ✅ Passed | ✅ Passed | ✅ Passed |
| `broker_root` | ✅ Used (MCP config) | ✅ Used (MCP config) | ✅ Used | ✅ Used | ✅ Used | ✅ Used |
| `auto_join_rooms` | ✅ Used (`--auto-join`) | ✅ Used (`--auto-join`) | ✅ Used | ✅ Used | ✅ Used | ✅ Used |
| `binary_override` | ✅ Used (`--bin`) | ✅ Used (`--bin`) | ✅ Used | ✅ Used | ✅ Used | ✅ Used |
| `model_override` | ✅ Used (`--model`) | ✅ Used (`--model`) | ✅ Used | ✅ Used | ✅ Used | ✅ Used |
| `agent_name` | ✅ Used (`--agent`) | ✅ Used (`--agent`) | ❌ No agent file | ❌ No agent file | ✅ Used (`--agent-file`) | ❌ No agent file |

## 3. Drift surface — stale fields + missing writeback

### 3.1 Dead code
- **`persist_codex_resume_target`** (line 2157): defined but **never called**. Codex resume target is only written by `cmd_reset_thread` and `cmd_restart` with explicit `session_id_override`. The bridge-driven lazy persistence path exists in the type system but has no call site.

### 3.2 Write-once fields (correctly immutable)
- `name`, `client`, `session_id`, `created_at` — these should never change after creation.

### 3.3 Stale-without-writeback fields
| Field | Why it drifts | Impact |
|-------|--------------|--------|
| `alias` | If operator changes alias via `c2c register --alias`, instance config still holds old value. Restart uses stale alias. | Moderate — identity mismatch |
| `broker_root` | If `c2c migrate-broker` is run, old instances still point to legacy broker root. | Moderate — messages route to wrong broker |
| `auto_join_rooms` | No CLI to update post-creation. Operator must edit JSON by hand. | Low — usually set once |
| `binary_override` | If operator upgrades binary path, old instances use stale path. | Low — usually set once |
| `model_override` | If operator switches model, old instances use stale model. | Low — can override at restart |
| `agent_name` | If operator switches role, old instances use stale role. | Low — can override at restart |

### 3.4 Missing fields (not in schema but useful)
| Desired field | Use case | Where it could live |
|--------------|----------|-------------------|
| `last_launch_at` | Detect dormant instances | `instance_config` |
| `last_registration_at` | Broker liveness audit | `instance_config` or broker registry |
| `last_seen_at` | Idle detection for nudge scheduler | `instance_config` or broker registry |
| `afk_mode` | Know if session was started with `--afk` | `instance_config` (kimi/gemini) |
| `last_model_used` | Audit trail for model switching | `instance_config` |
| `last_kickoff_sha` | Detect if kickoff changed (re-kickoff on update) | `instance_config` |
| `exit_code` | Last session exit status | `instance_config` |
| `exit_reason` | Why the session ended (SIGTERM, natural exit, crash) | `instance_config` |

## 4. Writeback points — expected lifecycle

```
run_outer_loop (creation)
  └── write_config (full schema, once)

Runtime writebacks:
  cmd_restart (with --session-id)
    ├── codex: write_config { codex_resume_target }
    ├── codex-headless: write_config { resume_session_id }
    └── others: write_config { resume_session_id }

  cmd_reset_thread
    ├── codex: write_config { codex_resume_target }
    └── codex-headless: write_config { resume_session_id }

  codex-headless bridge (lazy thread-id handoff)
    └── persist_headless_thread_id
        └── write_config { resume_session_id }

  #471 plain relaunch (no -- ARGS)
    └── extra_args cleared implicitly (not written back)
```

**Gap**: No writeback for alias, broker_root, auto_join_rooms, binary_override, model_override, agent_name after creation.

## 5. Recommendations + prioritized follow-up slices

### Slice A: `last_launch_at` timestamp (XS, ~5 LoC)
Add `last_launch_at: float` to `instance_config`. Update in `run_outer_loop` before `write_config`. Enables `c2c instances` to show "last launched" column and nudge scheduler to skip recently-launched sessions.

### Slice B: `persist_codex_resume_target` dead-code audit (XS, ~10 LoC)
Either wire the call site (codex bridge needs to hand off thread-id like headless does) or delete the function and update the mli docstring. Current state is misleading — the function looks like it should be called but isn't.

### Slice C: Alias writeback on `c2c register --alias` (S, ~30 LoC)
When operator runs `c2c register --alias NEW_ALIAS`, scan `~/.local/share/c2c/instances/` and update any configs where `cfg.alias = old_alias` to `NEW_ALIAS`. Prevents identity drift on restart.

### Slice D: Exit-code + exit-reason capture (S, ~40 LoC)
Add `exit_code: int option` and `exit_reason: string option` to `instance_config`. Write them in `run_outer_loop` when the inner client exits (before outer loop relaunches). Enables `c2c instances` to show "crashed" or "clean exit" status.

### Slice E: Full statefile writeback CLI (`c2c instance edit`) (M, ~100 LoC)
New subcommand: `c2c instance edit <name>` opens `$EDITOR` on the JSON, validates schema on save. Addresses all mutable fields at once rather than one-off slices per field. Risk: operators can corrupt JSON; need validation.

## 6. Cross-cutting themes

- **Schema evolution**: Adding fields requires updating `type instance_config`, `write_config`, `load_config_opt`, and any tests. This is 4-touch maintenance. Consider a codegen or ppx approach if schema grows beyond ~15 fields.
- **Backward compat**: `load_config_opt` uses `gso`/`gl`/`gf` helpers that default/fail gracefully on missing fields. Adding new fields is safe; removing old fields breaks existing configs.
- **Security**: `instance_config` lives in `~/.local/share/c2c/instances/` which is user-owned. No privilege escalation risk, but other users on the same machine can read aliases and broker roots.

---

*Audit completed 2026-04-30. Full source references in `ocaml/c2c_start.ml` lines 2053–2161, 4830–4861, 5005–5022, 5077–5086, 3528–3530.*
