# Broker-fingerprint split-brain — full-day post-mortem

- **UTC:** 2026-04-30 (morning to evening, ~07:00 → ~13:30 AEST window)
- **Filed by:** stanza-coder
- **Severity:** HIGH (silent split-brain across the swarm)
- **Status:** CLOSED — resolver fix #503 + plugin-config strip + #504
  drift-prevention slice landed end-to-end
- **Related findings (now archived):**
  - `2026-04-30T10-29-14Z-stanza-coder-broker-root-fallthrough.md`
  - `2026-04-30T10-48-00Z-stanza-coder-runbook-broker-path-drift-sweep.md`
- **Related commits:** `739485ee` (fix #503 resolver fall-through),
  `e3b0d76b` (fix #501 empty-broker_root crash), today's #504
  (`fix(#504): write_config skips persisting broker_root when ==
  resolver default`).

## TL;DR

A swarm-wide migration earlier in the day (morning) intended to move
all broker state from the legacy `<git-common-dir>/c2c/mcp/` path to
the canonical `~/.c2c/repos/<fp>/broker/` path. The migration ran and
appeared successful. Through the rest of the day the swarm started
exhibiting broken cross-talk: aliases visible in `c2c list` but DMs
landing in inboxes nobody was reading. This post-mortem covers all
three layers of why, and what shipped to keep it from recurring.

## The three layers

### Layer 1: legacy resolver fall-through (#503)

After the migration, several MCP servers — launched without
`C2C_MCP_BROKER_ROOT` set — kept landing on the legacy
`<git-common-dir>/c2c/mcp/` path because the resolver had a "use this
dir if it already exists" fallback that fired before the canonical
`$HOME/.c2c/repos/<fp>/broker` default. The migration left the legacy
directory intact (data preservation), so the existence check kept
matching.

**Fix:** `739485ee fix(#503): MCP servers fall through to legacy
.git/c2c/mcp instead of canonical` — landed earlier today.

### Layer 2: `.mcp.json` injecting legacy env per-process

Even after the resolver fix, new `c2c-mcp-server` children launched
from a Claude Code session were *still* writing to legacy. Discovery
came from auditing `/proc/<pid>/environ`: every child had
`C2C_MCP_BROKER_ROOT=…/.git/c2c/mcp` baked in.

Source: the project-level `.mcp.json` at the repo root had a
hard-coded env block injecting that variable into every spawned
`c2c-mcp-server`. `.mcp.json` is loaded from disk on every launch, so
this overrode whatever wrapper-level fixes we'd applied.

**Fix:** Cairn-Vigil removed the `C2C_MCP_BROKER_ROOT` line from
`.mcp.json`. After this, fresh children resolved correctly via env →
default chain.

### Layer 3 (the killer): saved instance configs persisting `broker_root`

This is the layer that turned what should have been a clean cleanup
into an evening-long debugging session.

`c2c_start.ml`'s `write_config` writes a JSON instance config every
time `c2c start <client> -n <name>` runs. The `broker_root` field was
written verbatim from the in-flight value, regardless of whether that
value was the resolver default. On the next `c2c restart`, the resume
path re-read the saved config and re-injected `C2C_MCP_BROKER_ROOT`
into the spawned child's env — *overriding the now-fixed resolver and
the now-fixed `.mcp.json`*.

So even after fixes (1) and (2) landed, every managed peer that had
ever been started would re-inject its old broker_root on restart. The
"silently re-pin to stale value" behaviour was indistinguishable from
"the fix didn't work" without a `/proc/<pid>/environ` audit.

**Compounding factor:** the fingerprint resolver had two competing
paths in different parts of the codebase:

- `sha256(remote.origin.url)` → `8fef2c369975` (the canonical/correct
  fingerprint per CLAUDE.md's documented order).
- `sha256(git rev-parse --show-toplevel)` (or some closely-related
  fallback) → `91816a939438`.

Both directories existed under `~/.c2c/repos/`. Different processes
landed on different fingerprints depending on which code path
resolved them and what env they were launched with. Cairn's morning
migration had targeted `91816a` as "canonical"; my evening session
landed on `91816a` because my saved instance config pinned it; her
session landed on `8fef` because her saved config pinned that. We had
the canonical/artifact assignment backward in our heads for hours.

The discriminator was finally `git config --get remote.origin.url |
tr -d '\n' | sha256sum | cut -c1-12` → `8fef2c369975`. **8fef is
canonical; 91816a is the toplevel-fallback artifact.**

**Concrete count of pinned configs hand-stripped today:**

- `~/.local/share/c2c/instances/<alias>/config.json` (claude/coord) — 5 instances:
  `coordinator1`, `galaxy-coder`, `jungle-coder`, `test-agent-oc`,
  `stanza-coder`.
- `~/.local/share/c2c/instances/<alias>/c2c-plugin.json` (opencode plugin) — 4 instances:
  `birch-coder`, `cedar-coder`, `fern-coder`, `willow-coder`.
  All four were pinned to `/home/xertrov/src/c2c/.git/c2c/mcp`
  (legacy, pre-migration) — *six* days after the migration was supposed
  to be complete.
- `~/.local/share/c2c/instances/<alias>/kimi-mcp.json` (kimi MCP) — 2 instances:
  `kuura-viima`, `lumi-tyyni`. Same legacy path. (Side bug: these
  configs also pointed `command: python3 + args: [c2c_mcp.py]`,
  the deprecated python MCP path; canonical is `c2c-mcp-server`.
  Filed as separate finding.)
- 2 stale-canonical configs (`galaxy-coder/c2c-plugin.json`,
  `jungle-coder/c2c-plugin.json`) — these pinned `8fef` (the
  *correct* path), but pinning at all is the bug class.

**Fix landing in this slice (#504):** `write_config` now skips
persisting `broker_root` when its value equals the resolver default.
`load_config_opt` treats the field as optional and falls back to the
resolver. Tests in `ocaml/test/test_c2c_start.ml`:
`write_config_omits_broker_root_when_default` and
`write_config_persists_broker_root_when_overridden`.

The fix only covers `config.json`. The opencode `c2c-plugin.json` and
kimi `kimi-mcp.json` writers are separate code paths that need the
same treatment (follow-up).

## Discovery sequence (rough)

1. Coord1 reports broken cross-talk; my DMs to her land but she
   doesn't see them.
2. Audit `c2c list` — both of us register-visible. Audit `mcp__c2c__list`
   from her side and from mine — different `canonical_alias` suffixes
   (`#.c2c@cachyos-x8664` vs `#c2c@cachyos-x8664`), hint that the
   fingerprint resolution is computing differently in our two
   processes.
3. Audit `/proc/<pid>/environ` of every alive `c2c-mcp-server`. Confirm
   her MCP env has the legacy path, mine has canonical (different
   one). Decide we're split-brained.
4. Strip `C2C_MCP_BROKER_ROOT` from `.mcp.json`. Restart her. She
   *still* lands on legacy because her saved config re-injects it.
5. Realize: `~/.local/share/c2c/instances/<alias>/config.json` is the
   re-injection source. Strip via `jq 'del(.broker_root)'`.
6. Restart everyone. They land on the actual default.
7. Discover the cross-call: Max checks the toplevel hash vs URL hash
   and surfaces that **8fef** is the URL fingerprint (per
   CLAUDE.md's documented order), so 91816a is the artifact, and
   "canonical" is the opposite of what we'd been calling it for two
   hours.
8. Audit other instance files. Find pixie `c2c-plugin.json` (4
   files) and Finn `kimi-mcp.json` (2 files) all on the legacy path.
   Strip those too.
9. Restart Max-side. Pixies + Finns now resolve to default = 8fef.

## Lessons / future patterns

1. **Don't persist resolver outputs verbatim into config.** For any
   value whose resolution chain is `env → XDG_* → default`, persist
   only when the user *explicitly* overrode the default. Otherwise
   you turn future migrations into footguns. (#504 codifies this
   for `broker_root` in `c2c_start.ml`. The same pattern applies to
   any other resolver-driven config value we might persist —
   `model_override` already gets this right; `agent_name` looks
   similar; the plugin/kimi sidecars do not yet.)

2. **Migrations need a fail-loud completion gate.** Renaming the
   legacy directory after data has been moved means any process that
   *still* resolves to the old path fails-loud rather than silently
   continuing to write next to the canonical store. Without that
   gate, today's incident was invisible until cross-talk failed.

3. **`c2c doctor` should detect split-brain.** Walk all candidate
   broker roots, report any with recent writes, and FAIL-loud if
   more than one is live. Filed as a follow-up earlier
   (`2026-04-30T10-29-14Z-…-broker-root-fallthrough.md`).

4. **Fingerprint resolution must be canonical and tested.**
   `sha256(remote.origin.url)` is what CLAUDE.md documents; that
   should be the only path. Any rev-parse-toplevel fallback should
   be a fail-loud sentinel (e.g., refuse to start) rather than a
   silent secondary fingerprint, because it produces a different
   `<fp>` directory and silently splits the swarm.

5. **`/proc/<pid>/environ` is the discriminator.** When multiple
   layers of config can pin a value (saved config, `.mcp.json`,
   wrapper env, resolver default), the only ground truth is what's
   in the live process's environment. `c2c doctor` and any future
   diagnostic tooling should surface this directly rather than
   relying on registry state, which lies when the registries
   themselves are split.

## Follow-ups (open)

- Apply the same "skip-when-default" rule to:
  - opencode `c2c-plugin.json` writer (writes `broker_root` field).
  - kimi `kimi-mcp.json` env writer (writes `C2C_MCP_BROKER_ROOT` env
    in the `mcpServers.c2c.env` block).
- File the kimi-mcp.json deprecation finding (uses `python3
  c2c_mcp.py`, should be `c2c-mcp-server`).
- `c2c doctor` split-brain check.
- Migration completion gate (rename legacy dir to `.migrated-<ts>`).
- Reconcile the rev-parse-toplevel fallback path with the documented
  resolver order, or remove it entirely.

— stanza-coder
