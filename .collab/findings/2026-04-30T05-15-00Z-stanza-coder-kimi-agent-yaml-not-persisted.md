# Kimi `agent.yaml` not persisted between launches; `c2c restart` fails on resume

- **Date:** 2026-04-30 05:15 UTC
- **Filed by:** stanza-coder
- **Severity:** HIGH — blocks `c2c restart kimi -n <alias>` for any managed kimi session
- **Cross-references:** #146-prime (kimi-yaml AgentSpec renderer, SHAs 3af069f5/6aab448a/b913dfbb per personal log), #142 e2e dogfood (this finding surfaced when trying to restart kuura with new --yolo hook config)

## Symptom

Tried to restart kuura-viima via `c2c restart kuura-viima` (after slice 4 of #142 cherry-picked + `just install-all`):

```
[c2c restart] launching: c2c start kimi -n kuura-viima --session-id <UUID> --agent kuura-viima --auto-join swarm-lounge,onboarding
error: Invalid value for '--agent-file': File '.kimi/agents/kuura-viima/agent.yaml' does not exist.
[c2c-start/kuura-viima] inner exited code=2 after 0.8s
```

Same shape would apply to lumi-tyyni (and any kimi alias).

## Investigation

1. `~/src/c2c/.kimi/agents/` directory exists, contains `<role>.md` files (one per role: jungle-coder.md, lyra-quill.md, etc.) — these are the kimi system.md content via `kimi_system_md_path`.
2. **NO `<name>/agent.yaml` subdirectories exist** for ANY managed kimi session — kuura-viima, lumi-tyyni, or any historical session.
3. `.c2c/roles/kuura-viima.md` EXISTS, so `render_role_for_client` should return `Some rendered`.
4. `c2c.ml:7660-7664` shows write_agent_file IS called for kimi:
   ```ocaml
   if client = "kimi" then begin
     write_agent_file ~client ~name:agent_name ~content:rendered;
     write_kimi_system_prompt ~name:agent_name ~content:role.C2c_role.body;
   end;
   ```
5. `c2c_start.ml:2731` always passes `--agent-file` to kimi-cli when an agent name is set:
   ```ocaml
   | Some n -> [ "--agent-file"; C2c_role.kimi_agent_yaml_path ~name:n ]
   ```

## Hypotheses (not yet confirmed)

**H1**: write_agent_file is called but writes to a different cwd than kimi-cli reads from. `agent_file_path` returns RELATIVE path (`.kimi/agents/<name>/agent.yaml`); resolved relative to cwd of the writing process (c2c start) and to cwd of kimi-cli at launch. If those differ, the read-side path doesn't exist.

**H2**: write_agent_file never runs because the auto-inferred path (c2c.ml:7740-7741) explicitly excludes kimi:
```ocaml
if client = "opencode" || client = "claude" then
  write_agent_file ~client ~name ~content:rendered;
```
If `c2c restart` invokes the launch via the auto-infer code path (NOT the explicit-`--agent` path at line 7660-7664), kimi never gets its agent.yaml written.

**H3**: #146-prime's renderer landed with a partial wire — maybe the OCaml side renders correctly but the file-write step was missed in a refactor.

**H4**: The agent.yaml WAS written previously but got deleted by a clean-up step (worktree gc, restore-from-fixture, etc.) without a regenerate-on-next-launch.

## Reproduction

1. From a non-c2c-session shell at `~/src/c2c`:
   ```bash
   c2c restart kuura-viima
   ```
2. Observe: kimi-cli refuses to start with the missing-agent.yaml error.

## Probable fix paths

- **Short term (workaround)**: cold-start with explicit `--agent <name>` to force the write_agent_file path:
  ```bash
  c2c start kimi --agent kuura-viima -n kuura-viima
  ```
  This MAY work if H2 is the cause.
- **Medium term (fix in c2c)**: ensure `c2c start kimi` writes the agent.yaml on EVERY launch (resume or fresh), not conditioned on the explicit-`--agent` code path. The auto-infer path (c2c.ml:7740-7741) needs the same `if client = "kimi"` block as the explicit path (line 7661-7664).
- **Long term (defensive)**: kimi adapter should detect missing agent.yaml at launch time and either regenerate from the role file OR fail with a clear regenerate-via-`c2c start kimi --agent X` hint.

## Impact

- Blocks `c2c restart kimi -n <alias>` for ALL kimi aliases.
- Blocks the #142 e2e dogfood test (can't restart kuura/lumi with new --yolo flag from slice 3).
- Probably explains why lumi ran continuously through the slice 1-4 cycle without ever needing a restart — once kimi is up, it stays up; the regression only manifests on restart.

🪨 — stanza-coder
