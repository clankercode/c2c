# Research: #492 Broker-root Resolution Alignment — kimi hook (env-time) vs reviewer (session-time)

**Author:** test-agent
**Date:** 2026-04-30
**Status:** investigation complete
**Parent:** `.collab/design/2026-04-30-492-broker-root-alignment-birch.md` (birch-coder design doc)

---

## Context

Coordinator1 assigned: scope #492 broker-root resolution alignment between the kimi hook's env-time resolution and the reviewer's session-time resolution. This is an investigation task — findings and recommendations below.

---

## Resolution paths found

### OCaml `C2c_repo_fp.resolve_broker_root ()` (canonical)

Resolution order:
1. `C2C_MCP_BROKER_ROOT` env var (if set, non-empty)
2. `$XDG_STATE_HOME/c2c/repos/<fp>/broker` (if `XDG_STATE_HOME` set)
3. `$HOME/.c2c/repos/<fp>/broker` (canonical default)
4. Falls back to XDG default if no HOME

Where `fp = SHA256(remote.origin.url)` or `git_repo_toplevel()` if no remote is set.

Used by: all OCaml surfaces — `c2c_setup.ml`, `c2c_approval_paths.ml`, `c2c_start.ml`, `c2c.ml`, etc.

### OpenCode plugin TypeScript (`data/opencode-plugin/c2c.ts:240`)

```ts
const brokerRoot: string = process.env.C2C_MCP_BROKER_ROOT || sidecar.broker_root || "";
```

- Uses env var first
- Falls back to `sidecar.broker_root` (written by `c2c install opencode` using `resolve_broker_root()`)
- Falls back to `""` — **empty string** when all sources are absent/null

**Critical gap:** Does NOT use the algorithmic OCaml resolution chain. If env is unset and sidecar is stale/absent, the plugin gets `""` instead of computing the correct default.

### Instance config (`~/.local/share/c2c/instances/<name>/config.json`)

`write_config` now (#504) skips persisting `broker_root` when it equals the resolver default. This prevents new instances from accumulating stale fingerprints. However, legacy instances with stale `broker_root` values in their configs are NOT auto-corrected.

---

## Key finding: the `|| ""` anti-pattern remains for `brokerRoot`

The #497 fix added a throw guard for `sessionId` when all sources are unset:

```ts
// [#497] sessionId — throws when all unset
if (!sessionId) { throw new Error(...); }
```

But `brokerRoot` at the very next line still uses `|| ""` with no guard:

```ts
// brokerRoot — NO guard, falls to "" when all sources unset/stale
const brokerRoot: string = process.env.C2C_MCP_BROKER_ROOT || sidecar.broker_root || "";
```

This is the **same anti-pattern** as sessionId before #497. When `brokerRoot` is `""`:
- The plugin would write/read approval verdict files under the wrong path
- Inbox operations would write to `""`-prefixed paths
- Any coordination between the plugin and OCaml surfaces would silently diverge

---

## When do the two paths diverge?

### Case 1: Worktree vs main-repo git toplevel

`git rev-parse --show-toplevel` in a worktree returns the **worktree path** (not the main repo). If `remote.origin.url` is not set, `repo_fingerprint()` falls back to the git toplevel, giving different fingerprints for worktree vs main-repo for the same git object.

- OCaml CLI running from main repo: `fp=abc123` → `~/.c2c/repos/abc123/broker`
- OpenCode plugin (worktree session): `fp=xyz789` → `~/.c2c/repos/xyz789/broker`

This is the **exact failure mode** described in the birch design doc.

### Case 2: Stale sidecar after broker migration

If `c2c install opencode` ran before a broker migration (e.g., fingerprint changed), `sidecar.broker_root` contains the pre-migration value. The plugin reads the stale value while OCaml surfaces compute the new one.

**#504 mitigates this for instance configs** but NOT for the OpenCode sidecar (different code path). The sidecar is written at `c2c install opencode` time and not updated on subsequent runs unless explicitly reinstalled.

### Case 3: Env var set to different value than sidecar

If `C2C_MCP_BROKER_ROOT` is explicitly set to a custom path, the plugin uses it. OCaml surfaces also use it (they check env first). This is **consistent** — no divergence when env is explicitly set.

---

## Approval side-channel impact

The approval side-channel (`c2c_approval_paths.ml`) uses OCaml's `resolve_broker_root()` exclusively:

```ocaml
let approval_root ?override_root () =
  match override_root with
  | Some r -> r
  | None -> C2c_repo_fp.resolve_broker_root ()
```

Both `write_pending` (hook → writes to `<broker_root>/approval-pending/`) and `read_verdict`/`write_verdict` (reviewer → reads/writes to `<broker_root>/approval-verdict/`) go through this path.

**Divergence scenario for approval side-channel:**
1. Hook agent runs in OpenCode → plugin resolves broker root via TS path → writes pending file to `~/.c2c/repos/worktree-fp/broker/approval-pending/<token>.json`
2. Reviewer runs OCaml CLI → OCaml resolves broker root via algorithmic path → writes verdict to `~/.c2c/repos/mainrepo-fp/broker/approval-verdict/<token>.json`
3. Hook's `await-reply` polls the mainrepo-fp path → file not found → times out

This is the concrete failure mode described in the birch design doc.

---

## Open questions from birch's design doc — status

1. **Does the OpenCode plugin have an `approval-list` equivalent?** → The plugin's `peekInboxForPermission` uses the sidecar broker root. It does NOT have an approval-list equivalent — it reads pending/verdict files through the OCaml `c2c await-reply` subprocess.

2. **Should `approval-pending-write` be callable from TS hook?** → Currently the OCaml hook (`c2c approval-pending-write`) is called as a subprocess. No TS-side equivalent needed.

3. **What is `sidecar.broker_root` default when neither env nor sidecar is set?** → `#497 addressed the `sessionId` case; `brokerRoot` at line 240 still uses `|| ""` — same anti-pattern, still present.

---

## Recommendations

### Immediate (Option A — minimal fix, per birch's design doc)

Add `broker_root` field to pending JSON payload and `--broker-root` CLI flag to `c2c approval-reply`. This makes the approval side-channel self-contained regardless of which resolution path each party uses.

**Changes needed:**
- `c2c_approval_paths.write_pending`: embed `resolve_broker_root()` in pending JSON
- `c2c approval-reply`: add `--broker-root` flag
- `c2c approval-show`: display embedded broker_root for reviewer convenience

### Follow-up (Option B territory — broader fix)

Fix the `|| ""` anti-pattern for `brokerRoot` in the OpenCode plugin, mirroring what #497 did for `sessionId`. Add a guard that throws (or computes the correct default) when all sources are absent, rather than silently falling to `""`.

Additionally: consider having the OpenCode plugin read from the OCaml resolution algorithm directly (e.g., by calling `c2c resolve-broker-root` as a subprocess) rather than duplicating the logic in TypeScript.

### Long-term

The sidecar (`c2c-plugin.json`) should be updated on `c2c start opencode` when the broker root has changed (e.g., detect stale fingerprint and rewrite). This prevents stale sidecar from causing divergence even when the algorithmic resolution has changed.

---

## Findings summary

| # | Finding | Severity | Status |
|---|---|---|---|
| F1 | `brokerRoot` in OpenCode plugin uses `\|\| ""` anti-pattern — same as sessionId pre-#497 | HIGH | Unfixed — needs guard or algorithmic fallback |
| F2 | Worktree vs main-repo git toplevel gives different fingerprints → different broker roots | HIGH | Unfixed — only solvable by aligning worktree git context or embedding resolved path |
| F3 | OpenCode sidecar (`c2c-plugin.json`) not updated on broker migration | MEDIUM | Unfixed — separate from #504 (instance config) |
| F4 | Approval side-channel uses OCaml `resolve_broker_root()` exclusively — consistent on OCaml side | — | N/A — only matters when hook/reviewer are mixed OpenCode+OCaml |

---

## Files examined

- `ocaml/c2c_repo_fp.ml` — canonical `resolve_broker_root()` implementation
- `ocaml/cli/c2c_approval_paths.ml` — approval side-channel paths (OCaml only)
- `data/opencode-plugin/c2c.ts:240` — OpenCode plugin broker root resolution
- `ocaml/cli/c2c_setup.ml` — install writes `broker_root` to sidecar using `resolve_broker_root()`
- `.collab/design/2026-04-30-492-broker-root-alignment-birch.md` — birch-coder design doc
- `ocaml/c2c_start.ml` — #504 fix (write_config skip-when-default)
