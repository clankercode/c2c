# #492 Broker-root alignment for approval side-channel

- **Author:** birch-coder
- **Date:** 2026-04-30
- **Status:** DESIGN — propose options, seek coord direction
- **Parent / cross-references:**
  - CLAUDE.md "Broker root" section (line 228)
  - `#284` — ephemeral DMs (unrelated but same number domain)
  - `#422` — OpenCode plugin broker-root resolution (plugin ignores env in some paths)
  - `#490` — approval side-channel (parent design: `.collab/design/2026-04-30-142-approval-side-channel-stanza.md`)
  - `#490 slice 5a/b/c` — verdict-file + pending-file + TTL cleanup
  - `.collab/findings/2026-04-30T20-50-birch-coder-461-diagnostic-sweep.md` — adjacent finding (unrelated root cause)
  - Stanza's `#490 e2e finding` (the trigger for this design)

---

## Problem statement

`c2c approval-reply` (reviewer) and `c2c await-reply` / verdict-file polling (hook agent) MUST agree on the broker root so the side-channel verdict file (`<broker_root>/approval-verdict/<token>.json`) lands in a directory the hook can read.

**Today's accidental success** (coord): both ran from the main working directory → same `git rev-parse --show-toplevel` → same fingerprint → same `~/.c2c/repos/<fp>/broker`. The side-channel worked.

**The failure case**: when either party runs from a **worktree** (`.worktrees/<slice>/`), the two processes may resolve **different broker roots**:

1. **Worktree vs main-repo `show-toplevel` divergence**: `git rev-parse --show-toplevel` in a worktree returns the **worktree path**, not the main repo. If `remote.origin.url` is not set, `repo_fingerprint ()` falls back to `git_repo_toplevel ()` → worktree path ≠ main-repo path → **different fingerprints → different broker roots**.

2. **OpenCode plugin bypass** (relevant to `#422`): The TypeScript plugin (`data/opencode-plugin/c2c.ts`) resolves broker root as:
   ```ts
   const brokerRoot: string = process.env.C2C_MCP_BROKER_ROOT || sidecar.broker_root || "";
   ```
   If `C2C_MCP_BROKER_ROOT` is unset AND `sidecar.broker_root` is absent or stale, `brokerRoot` is empty. The plugin then falls back to **reading the broker root from `.opencode/c2c-plugin.json`** (the sidecar config written by `c2c install`). The OCaml side (`c2c approval-reply`, `c2c await-reply`) uses `C2c_repo_fp.resolve_broker_root ()` which computes it algorithmically. These two paths can produce **different results** when the env var is absent and the sidecar is stale or points to a legacy path.

3. **Instance-config override divergence** (historical `#422/#424`): An older bug had `c2c start` preferring persisted instance-config over `C2C_MCP_BROKER_ROOT` env var. While `#424` reportedly fixed this, the pattern of "multiple broker-root resolution paths" is the underlying issue.

---

## Affected surfaces

| Surface | Resolver used | Can diverge from OCaml `resolve_broker_root`? |
|---|---|---|
| `c2c approval-reply` (reviewer OCaml CLI) | `C2c_repo_fp.resolve_broker_root ()` | No — canonical |
| `c2c await-reply` (hook OCaml CLI) | `C2c_repo_fp.resolve_broker_root ()` | No — canonical |
| `c2c approval-list` (OCaml CLI) | `C2c_repo_fp.resolve_broker_root ()` | No — canonical |
| OpenCode plugin `peekInboxForPermission` | `process.env.C2C_MCP_BROKER_ROOT \|\| sidecar.broker_root \|\| ""` | **YES** — if env unset + sidecar stale/absent |
| OpenCode plugin `approval-list` equivalent | same as above | **YES** |

The side-channel write path (reviewer → `approval-reply`) and read path (hook → `await-reply`) are both OCaml and agree. The failure mode is specifically when the **reviewer** runs in OpenCode (TS plugin reads sidecar) while the **hook agent** runs in OCaml (algorithmically computed root). Or vice-versa.

---

## Options

### Option A — Hook embeds `broker_root` in pending JSON; reviewer reads and uses it for verdict write

**Mechanism:**
1. Hook's `c2c approval-pending-write` (called before the awareness DM) embeds `broker_root` as a field in the pending JSON:
   ```json
   {
     "token": "ka_xxx",
     "broker_root": "/home/xertrov/.c2c/repos/abc123/broker",
     ...
   }
   ```
2. Reviewer runs `c2c approval-list` or `c2c approval-show <token>` — both read from the hook's broker root (same process, same resolution), so the pending JSON is readable.
3. Reviewer calls `c2c approval-reply --broker-root <path> <token> allow` — the `--broker-root` flag overrides `resolve_broker_root ()` for the verdict write only.
4. Hook's `await-reply` continues to use its own `resolve_broker_root ()` to read the verdict file — which matches because it would have written the pending file to the same location.

**Tradeoffs:**
- ✅ Minimal: only adds one field to pending JSON + one CLI flag
- ✅ Self-contained: no external coordination needed
- ✅ Backward-compatible: existing pending files without `broker_root` field are read with the caller's own resolution (legacy path)
- ❌ Requires reviewer to pass `--broker-root` explicitly — human error risk
- ❌ Doesn't solve the OpenCode plugin's own broker-root divergence (plugin still ignores env)

**What code changes:**
- `c2c_approval_paths.ml`: `write_pending` injects `resolve_broker_root ()` as `broker_root` in the JSON payload
- `c2c approval-reply`: new `--broker-root` flag that threads through to `C2c_approval_paths.write_verdict ~override_root`
- `c2c approval-show`: reads `broker_root` from pending JSON and prints it (for reviewer convenience)
- OpenCode plugin: **no change** — plugin doesn't write pending files, it just reads them

**Blast radius:** Low. Only affects the pending JSON schema (additive field) and adds an optional CLI flag.

---

### Option B — Single canonical resolution at install/start time, persisted to instance config, both sides MUST use that exact path

**Mechanism:**
1. At `c2c install <client>` or `c2c start <client>`, the canonical broker root is computed once via `C2c_repo_fp.resolve_broker_root ()` and written to the instance config (`~/.local/share/c2c/instances/<name>/config.json`) as `broker_root`.
2. `C2c_repo_fp.resolve_broker_root ()` is updated to **prefer the instance-config value** over recomputation when available (i.e., instance config is treated as the authoritative override, above env var).
3. Both OCaml CLI and OpenCode plugin read from the **same instance config** — they always agree.
4. `c2c migrate-broker` gains a `--sync-config` flag that propagates the new broker root back into all instance configs that pointed to the old path.

**Tradeoffs:**
- ✅ Single source of truth — both OCaml and TypeScript (if TS reads instance config) converge automatically
- ✅ Handles worktree vs main-repo divergence transparently
- ✅ Solves the OpenCode plugin broker-root divergence (#422) at the root
- ❌ Requires updating `c2c_repo_fp.resolve_broker_root` precedence — could break other callers that depend on env-var-winning behavior
- ❌ Migration: existing instances need their config updated when broker root changes (e.g., after `migrate-broker`)
- ❌ The OpenCode plugin would still need to read instance config instead of (or in addition to) sidecar — TS change required

**What code changes:**
- `c2c_repo_fp.ml` or `c2c_utils.ml`: `resolve_broker_root ()` checks instance config first
- `c2c install` / `c2c start`: explicitly persist broker root to instance config (deferred-write pattern: compute once, store)
- `c2c migrate-broker`: `--sync-config` flag to rewrite instance configs
- OpenCode plugin (`c2c.ts`): read broker root from instance config JSON (`~/.local/share/c2c/instances/<name>/config.json`) in addition to or instead of sidecar
- All OCaml callers of `resolve_broker_root` benefit automatically

**Blast radius:** Medium. Changes the precedence of `resolve_broker_root` (env was previously the top priority). Backward compat needs careful handling: if `C2C_MCP_BROKER_ROOT` is set, it should still win over instance config (explicit override semantics).

---

### Option C — Sidecar/plugin JSON becomes the canonical broker-root store for all local clients; install/start writes it, env var is deprecated

**Mechanism:**
1. `c2c install <client>` and `c2c start <client>` both write the resolved broker root to the per-client sidecar file (`.opencode/c2c-plugin.json` for OpenCode, analogous file for other clients).
2. All clients (OCaml CLI and OpenCode plugin) read broker root from their sidecar as the **first priority**.
3. `C2C_MCP_BROKER_ROOT` env var is retained as a **deprecated override** (print warning when used, but still honor it for back-compat).
4. The OCaml sidecar path for non-OpenCode clients would be e.g. `~/.claude/c2c-sidecar.json` or similar — a generic client-agnostic file.
5. `c2c approval-reply` and `c2c await-reply` both read from the sidecar first, falling back to algorithmic resolution.

**Tradeoffs:**
- ✅ Unified: all clients share the same resolution source
- ✅ Handles worktree divergence: the sidecar path is absolute, written at install/start time from the correct CWD
- ✅ Deprecating env var reduces future confusion
- ❌ Requires defining a sidecar format for non-OpenCode clients (Claude Code, Codex, etc.)
- ❌ Complex: introduces a new file to maintain across clients
- ❌ If sidecar and algorithmic resolution diverge post-install (e.g., after git remote change), the sidecar becomes stale with no self-healing
- ❌ Larger change surface than Option A

**What code changes:**
- New sidecar format + reader in OCaml (`C2c_sidecar` module?)
- Update `c2c install` / `c2c start` to write sidecar
- Update `c2c_repo_fp.resolve_broker_root` to check sidecar first
- OpenCode plugin: already reads sidecar — just needs sidecar to be written by install/start
- Deprecation warning when `C2C_MCP_BROKER_ROOT` is set

**Blast radius:** High. Touches install/start, OCaml resolution chain, and introduces a new cross-client file format.

---

## Recommendation

**Option A** is the right immediate fix for `#490 side-channel reliability`.

Rationale:
- The side-channel write/read pair (`approval-reply` / `await-reply`) are both OCaml and already use `C2c_repo_fp.resolve_broker_root ()` — they agree by construction.
- The divergence only matters when the **reviewer** is a human or OpenCode agent using the TS plugin (which bypasses the algorithmic resolution).
- Option A addresses exactly this case with minimal changes.
- Option B/C solve a broader infrastructure problem (broker-root as universal coordination point) that is worth solving but belongs in a separate slice.

**Option A slice plan:**

1. **Doc**: Add `broker_root` field to the pending JSON schema in the `#490 slice 5b` design doc.
2. **OCaml**: `c2c_approval_paths.write_pending` injects `resolve_broker_root ()` as `broker_root` in the JSON.
3. **OCaml CLI**: `c2c approval-reply` gets `--broker-root <path>` flag; `c2c approval-show` displays the embedded broker_root.
4. **OCaml tests**: Update alcotest to verify round-trip with explicit `--broker-root` override.
5. **OpenCode plugin** (separate slice, owner TBD): The plugin's `approval-list` equivalent (if any) should also read the sidecar's broker_root and use it when displaying tokens. The plugin does NOT write pending files, so no change needed there.

**Follow-up (Option B territory, not this slice):** `#422` follow-up to make OpenCode plugin read instance config as broker root source-of-truth, so all clients converge on the same path without requiring `--broker-root` flags.

---

## Open questions

1. **Does the OpenCode plugin currently have any `approval-list` equivalent?** If so, does it read from the OCaml-computed broker root or its own sidecar-derived root? (The plugin has `peekInboxForPermission` which uses the sidecar broker root — it may already be broken in worktree scenarios when env is unset.)
2. **Should `approval-pending-write` be callable from the OpenCode plugin hook (TS)?** The current design has the OCaml hook calling it. If TS hooks also need to write pending files, Option A needs a TS-side `approval-pending-write` equivalent.
3. **What is the `sidecar.broker_root` default when neither env nor sidecar is set?** The TS code shows `|| ""` — an empty string would break all broker operations. This may be the actual #422 footgun (fixed separately as #496).

---

*Cross-links:*
- CLAUDE.md line 228: broker root resolution order
- `.collab/design/2026-04-30-142-approval-side-channel-stanza.md`: parent design for #490
- `.collab/design/2026-04-30-490-slice-5b-plan.md`: pending-file writer + approval-list spec
- `.collab/design/2026-04-30-490-slice-5c-plan.md`: TTL cleanup
- `#422` (OpenCode plugin broker-env theory — see `.collab/runbooks/worktree-discipline-for-subagents.md` Pattern 17 cross-ref)
- `#284` ephemeral DMs runbook: `.collab/runbooks/ephemeral-dms.md`
- `#496` finding: `.collab/findings/2026-04-30T22-00-birch-coder-496-opencode-plugin-empty-broker-root.md`
