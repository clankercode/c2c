# #496 OpenCode plugin: empty-string broker_root fallthrough

## Found by: birch-coder (during #492 investigation)
## Date: 2026-04-30
## Status: FIXED — impl at `0efea77b` (worktree `slice/496-opencode-empty-broker-root`)

## Fix

Commit `0efea77b`: `data/opencode-plugin/c2c.ts` now throws an explicit
`Error` at plugin boot if both `C2C_MCP_BROKER_ROOT` env var and
`sidecar.broker_root` are absent or null. The error message includes
recovery steps. This replaces the silent `|| ""` fallthrough.

The OpenCode TypeScript plugin (`data/opencode-plugin/c2c.ts`) resolves broker root as:

```ts
const brokerRoot: string = process.env.C2C_MCP_BROKER_ROOT || sidecar.broker_root || "";
```

When both `C2C_MCP_BROKER_ROOT` env var is unset AND `sidecar.broker_root` is absent or null, `brokerRoot` resolves to `""` (empty string).

This empty string is then used as the broker root path for all subsequent operations (inbox reads, spool checks, etc.), which will fail silently or produce nonsensical paths.

## Contrast with OCaml side

The OCaml `C2c_repo_fp.resolve_broker_root ()` algorithm:
1. `C2C_MCP_BROKER_ROOT` env var if set → use it
2. `$XDG_STATE_HOME/c2c/repos/<fp>/broker` if `XDG_STATE_HOME` set
3. `$HOME/.c2c/repos/<fp>/broker` (canonical default)
4. `~/.local/state/c2c/repos/<fp>/broker` (XDG default fallback)

The OCaml side **never** falls back to empty string — it always produces a real path.

## When this bites

- Fresh `c2c install opencode` without env vars set, and the sidecar config is absent or missing the `broker_root` field
- After a broker migration where the sidecar still points to the old path
- Worktree scenarios where algorithmic resolution diverges from sidecar (the #492 failure mode), and the sidecar is stale

## What likely happens with empty `brokerRoot`

All broker operations in the plugin (`resolve_session_id_for_inbox`, `read_inbox`, `readSpool`, etc.) would use `""` as the path prefix. Most filesystem operations would either:
- Fail silently (path = `""`, no files found)
- Create files in the current working directory under a literal `""` path component
- Fail with cryptic errors

## Fix options

**A** (minimal): Change the empty-string fallback to call the algorithmic resolution or read from instance config:
```ts
const brokerRoot: string = process.env.C2C_MCP_BROKER_ROOT || sidecar.broker_root || compute_broker_root_algorithmically() || "";
```

**B** (preferred, matches Option B of #492): The OpenCode plugin should read broker root from the instance config (`~/.local/share/c2c/instances/<name>/config.json`) as the authoritative source, not from the sidecar. The sidecar would be written by `c2c install` / `c2c start` and kept in sync.

## Relationship to #422

#422 was originally filed as "OpenCode plugin ignores env" — the algorithmic divergence is one aspect. The empty-string fallthrough is the other, more severe aspect: even if the plugin DID respect env, a missing env would still produce empty string.

## Relationship to #492

#492 Option A (hook embeds broker_root in pending JSON, reviewer passes `--broker-root`) mitigates the symptom for the approval side-channel. #496 fixes the root cause in the plugin.

## Status

CLOSED (2026-05-03 triage by stanza-coder). Fix landed at `0efea77b` — TS plugin now throws explicit Error on empty broker_root. Additionally, the OCaml-side broker-root fallthrough fix (e7686142 / 08b3ceaa) prevents `C2C_MCP_BROKER_ROOT` from silently pointing to the legacy `.git/c2c/mcp` path, and the `c2c start` sidecar write (#504) omits broker_root when it matches the resolver default, preventing stale-path drift. Both sides now fail-loud or self-correct instead of silently falling through to empty/legacy paths.

## References

- `data/opencode-plugin/c2c.ts` line 230
- `#422` — original OpenCode plugin broker-env theory
- `#492` — broker-root alignment design
