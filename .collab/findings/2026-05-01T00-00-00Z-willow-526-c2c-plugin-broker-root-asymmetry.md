# Finding: c2c-plugin.json broker_root setup-vs-start asymmetry (#526)

**Severity:** LOW (cosmetic asymmetry; TypeScript plugin ignores the field anyway)
**Date:** 2026-05-01
**Author:** willow-coder

## Summary

`c2c setup` and `c2c start` write `broker_root` to `c2c-plugin.json` sidecar files
with different policies. Additionally, the TypeScript plugin never reads the
`broker_root` field from either sidecar — it always resolves via env var or
git-fingerprint. The asymmetry is therefore cosmetic in practice, but should
be documented for operators who inspect sidecar files.

Companion to #527 (birch — TypeScript plugin sidecar reader).

## Asymmetry

| Caller | File:Line | broker_root written? | fingerprint written? | Sidecar location |
|--------|-----------|----------------------|---------------------|-----------------|
| `c2c setup opencode` | `c2c_setup.ml:617-618` | Always (`broker_root`, `broker_root_fingerprint`) | Yes | `<cwd>/.opencode/c2c-plugin.json` (project-level) |
| `c2c start opencode` | `c2c_start.ml:1403-1406` | Only when ≠ resolver default | No | `<instances>/<name>/c2c-plugin.json` (per-instance) |

## Why the asymmetry exists

`c2c start`'s sidecar write uses the same skip-when-default policy as the
instance `config.json` write (#504). `c2c setup` was changed in #507 to
always write `broker_root` (and added `broker_root_fingerprint`), which is a
separate design decision with its own rationale.

The plugin never reads `broker_root` from either sidecar location. Its
`resolveBrokerRoot()` (`data/opencode-plugin/c2c.ts:244`) uses:
1. `C2C_MCP_BROKER_ROOT` env var (if set and non-empty)
2. Canonical resolver: `$XDG_STATE_HOME/c2c/repos/<fp>/broker` or `$HOME/.c2c/repos/<fp>/broker`

Neither project-level nor per-instance sidecar `broker_root` fields are consulted.

## Implications for operators

- Inspecting `c2c-plugin.json` after `c2c setup` shows `broker_root` even when
  it matches the resolver default; after `c2c start` it may be absent.
- This is expected and does not indicate a problem.
- If you need to verify which broker a plugin is using, check `C2C_MCP_BROKER_ROOT`
  in the environment, not the sidecar file.

## Code references

| What | File:Line |
|------|-----------|
| `c2c setup` writes broker_root + fingerprint always | `ocaml/cli/c2c_setup.ml:611-612` |
| `c2c start` writes broker_root only when ≠ default | `ocaml/c2c_start.ml:1379-1382` |
| TypeScript plugin resolveBrokerRoot() (never reads sidecar) | `data/opencode-plugin/c2c.ts:244-268` |
| #507 change (setup always writes) | commit `509a1ef1` |
| #504 fix (skip-when-default on config.json) | `c2c_start.ml:2176-2235` |

## Status: CLOSED (2026-05-04)

Documented (#526). No code change needed — asymmetry is cosmetic since the
TypeScript plugin never reads `broker_root` from sidecar files. The broader
broker-root split-brain class is now mitigated by `resolve_broker_root`
rejecting legacy `.git/c2c/mcp` paths (e7686142). #527 addresses the
plugin-reader gap independently.
