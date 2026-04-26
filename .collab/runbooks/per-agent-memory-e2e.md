# Per-agent memory: alice/bob E2E runbook

**Author:** stanza-coder · **Created:** 2026-04-26 · **Status:** initial draft
(see "Changelog" at bottom).

This runbook is a hands-on smoke test for the per-agent memory system
(#163 / #266 Phase 1). It walks two agents — `alice` and `bob` — through
the cross-agent visibility model end-to-end:

1. alice writes a private entry and a shared entry
2. bob enumerates shared entries via global discovery
3. bob reads alice's shared entry → succeeds
4. bob tries to read alice's private entry → refused with explanatory error
5. bob writes their own entries; alice's view is symmetric
6. share/unshare round-trip toggles visibility live

Run this after any change to the memory CLI (`ocaml/cli/c2c_memory.ml`)
or the privacy guard (`cross_agent_read_allowed` in
`ocaml/cli/c2c_memory.ml`, `memory_read` in `ocaml/c2c_mcp.ml`).

Single shell on a workstation is enough — no tmux peers required. The
runbook uses `C2C_MEMORY_ROOT_OVERRIDE` (a test hook) to scope the
exercise to a temp dir, so it can't pollute real per-agent memory and
can be re-run without cleanup gymnastics.

---

## §0. Pre-flight

```bash
# 1. CLI is fresh
~/.local/bin/c2c --version
# If stale: cd /home/xertrov/src/c2c && just install-all

# 2. Memory subcommand is registered
~/.local/bin/c2c memory --help | head -5
# Expect: "Manage per-agent memory entries." with list/read/write/delete/share/unshare

# 3. Pick a temp memory root for this run
export C2C_MEMORY_ROOT_OVERRIDE=$(mktemp -d /tmp/c2c-memory-e2e-XXXXXX)
echo "memory root: $C2C_MEMORY_ROOT_OVERRIDE"
```

If any step fails, file a finding in
`.collab/findings/<UTC>-<alias>-memory-e2e-<symptom>.md` and bail.

---

## §1. alice writes a private + shared entry

```bash
export C2C_MCP_AUTO_REGISTER_ALIAS=alice

c2c memory write priv-note \
  --type note --description "alice's private journal entry" \
  "personal: I broke staging on a friday once and felt seen"

c2c memory write team-tip \
  --type reference --description "shareable tip for the swarm" --shared \
  "tip: just install-all atomically replaces busy binaries"

c2c memory list
```

Expected `c2c memory list` output:

```
alice/priv-note.md — priv-note
  alice's private journal entry
  type: note

alice/team-tip.md — team-tip
  shareable tip for the swarm
  type: reference
  [shared]
```

Note the `[shared]` marker on `team-tip` only.

---

## §2. bob enumerates shared entries (global scan)

Switch identity:

```bash
export C2C_MCP_AUTO_REGISTER_ALIAS=bob
```

Now `c2c memory list --shared` (no `--alias`) should scan every alias dir
under `$C2C_MEMORY_ROOT_OVERRIDE` and return shared entries from across
the swarm:

```bash
c2c memory list --shared --json | jq .
```

Expected:

```json
[
  {
    "alias": "alice",
    "file": "team-tip.md",
    "name": "team-tip",
    "description": "shareable tip for the swarm",
    "type": "reference",
    "shared": true
  }
]
```

The `priv-note` entry is **absent** — global scan filters out
`shared: false` entries even though it has read access to the directory.

Plaintext form (`c2c memory list --shared`) shows the alias-prefixed
filename:

```
alice/team-tip.md — team-tip
  shareable tip for the swarm
  type: reference
  [shared]
```

---

## §3. bob reads alice's shared entry

```bash
c2c memory read team-tip --alias alice
```

Expected: full markdown frontmatter + body printed verbatim.

Or as JSON:

```bash
c2c memory read team-tip --alias alice --json | jq .
```

---

## §4. bob attempts to read alice's private entry — refused

This is the load-bearing privacy assertion. The cross-agent read of a
`shared: false` entry MUST be refused with a non-zero exit code.

```bash
c2c memory read priv-note --alias alice
echo "exit: $?"
```

Expected on stderr:

```
error: memory entry 'priv-note' in alias 'alice' is private (shared: false). Cross-agent reads require shared:true. Owner can run `c2c memory share priv-note` to allow this.
```

Exit code: `1`.

If the body of the private entry is printed at all — that's a privacy
regression. File `.collab/findings/<UTC>-<alias>-memory-privacy-leak.md`
immediately and DM coordinator1.

---

## §5. bob writes their own; alice's view is symmetric

```bash
c2c memory write bob-note \
  --type feedback --description "bob's debugging style" \
  "I narrate the stacktrace out loud; it helps."

c2c memory list
```

Expected: only `bob/bob-note.md` (alice's entries are not in bob's list
unless --alias alice is passed).

Switch back to alice:

```bash
export C2C_MCP_AUTO_REGISTER_ALIAS=alice
c2c memory list --shared
# bob hasn't shared anything; only alice's team-tip should appear.

c2c memory read bob-note --alias bob
# Refused — bob-note is shared: false.
```

---

## §6. share / unshare round-trip

bob shares their entry, alice can now read it; bob unshares, refusal
returns:

```bash
export C2C_MCP_AUTO_REGISTER_ALIAS=bob
c2c memory share bob-note
# saved with shared: true

export C2C_MCP_AUTO_REGISTER_ALIAS=alice
c2c memory list --shared --json | jq -r '.[].file'
# Should now include "bob-note.md"

c2c memory read bob-note --alias bob
# Succeeds — body printed.

# bob revokes:
export C2C_MCP_AUTO_REGISTER_ALIAS=bob
c2c memory unshare bob-note

export C2C_MCP_AUTO_REGISTER_ALIAS=alice
c2c memory read bob-note --alias bob
echo "exit: $?"
# Refused, exit 1.
```

The toggle is in-place: body and frontmatter survive untouched, only
the `shared:` field flips.

---

## §7. self-read bypass

The privacy guard is for cross-agent reads only. Self-reads ALWAYS
succeed regardless of the shared flag:

```bash
export C2C_MCP_AUTO_REGISTER_ALIAS=alice
c2c memory read priv-note          # no --alias ⇒ defaults to current alias
# Succeeds — alice can always read alice's private entries.
```

---

## §8. cleanup

```bash
rm -rf "$C2C_MEMORY_ROOT_OVERRIDE"
unset C2C_MEMORY_ROOT_OVERRIDE
unset C2C_MCP_AUTO_REGISTER_ALIAS
```

---

## What success looks like

All eight sections complete without surprises. The privacy refusal in
§4 is the load-bearing one; if anything else fails (a list returns
unexpected entries, share/unshare doesn't toggle, JSON shape drifts),
file a finding before continuing.

## Related reading

- `.collab/design/DRAFT-per-agent-memory.md` — design doc that this
  implements (§"Open Questions" #3 covers global shared discovery)
- `docs/commands.md` — public-facing CLI reference for the memory
  subcommand (privacy + global-scan semantics documented there)
- `ocaml/cli/c2c_memory.ml` — implementation
- `ocaml/cli/test_c2c_memory.ml` — unit tests (17 cases including
  privacy guard + global scan)
- `ocaml/c2c_mcp.ml` (`memory_read` / `memory_write` / `memory_list`
  handlers) — the MCP-tool surface, which uses the same privacy guard

## Changelog

- **2026-04-26 (stanza-coder)** — initial draft for #275, doc-only
  follow-up to the #266 Phase 1 closeout (4cac8a5b on master).
