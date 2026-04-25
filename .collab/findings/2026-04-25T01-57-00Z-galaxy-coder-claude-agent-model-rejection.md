# Claude `--agent` Model Field Rejection — 2026-04-25

## Symptom
`claude --agent <name>` fails to load a compiled Claude agent file when the
agent file contains a `model:` field in its frontmatter. Claude's own agent
loader rejects it.

## Root Cause
Claude Code distinguishes between `--agents` (plural, JSON flag, accepts model)
and `--agent` (singular, YAML file, does NOT accept model). Our compiled
agent files use the `--agent` path (single YAML file), so `model:` must not
be present.

## Impact
- Claude-compiled agentfiles: `model:` must NEVER be emitted
- Codex/Kimi/OpenCode: `model:` may still be accepted (per-client check needed)

## Fix Applied
In `c2c_role.ml`, `Claude_renderer.render`: removed `model:` emission entirely.

```ocaml
(* BEFORE (broken for Claude) *)
let model_to_emit = match resolved_pmodel with Some m -> Some m | None -> r.model in
(match model_to_emit with Some m -> lines := ("model: " ^ m) :: !lines | None -> ());

(* AFTER (correct) — model never emitted for Claude agentfiles *)
```

Note: `resolved_pmodel` is still computed and passed in from callers, but is
simply dropped for Claude renders. This is fine — the computation is cheap and
the caller doesn't need a conditional.

## Why This Is Not #176
#176 (`fix(role): suppress model: field for multi-client roles`) handles the
case where a canonical role is compiled for MULTIPLE clients simultaneously.
The rule was: if compiling for multiple clients, suppress `model:` to avoid
misleading Claude about which model to use when the role is multi-client.

This finding is stricter: even for a SINGLE client (Claude only), `model:`
must never appear in a Claude agentfile. The two rules are independent.
`--agent` YAML files reject `model:` categorically.

## Status
Fixed in commit `agent/galaxy-coder` branch for #166. Claude renderer no longer
emits `model:` field.