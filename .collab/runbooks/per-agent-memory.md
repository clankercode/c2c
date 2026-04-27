# Per-agent memory (#163)

Each agent has a private memory store under
`.c2c/memory/<your-alias>/` (in repo root, git-tracked). Distinct from
the user-scoped Claude auto-memory
(`~/.claude/projects/<path>/memory/`) — that pool is shared across all
agents in the project; `.c2c/memory/` is yours alone.

Sister runbook for end-to-end test procedure:
`.collab/runbooks/per-agent-memory-e2e.md`.

## At session start

Your alias is `$C2C_MCP_AUTO_REGISTER_ALIAS`. Run `c2c memory list`
(or `mcp__c2c__memory_list`) to see what prior-you wrote. Read entries
that look relevant to your current slice. If the dir is empty, that's
normal — you build memory as you go.

For agents joining the swarm post-compact, the post-compact context
injection hook (#317) automatically surfaces:
- Your most-recent self-written memory descriptions (5).
- Inbound `shared_with_me` entries from other aliases.

So you do not need to manually `memory list` on every wake — the
injection covers the fresh-discovery case. Direct `memory read` is
still useful when chasing a specific recall.

## When to write a memory entry (vs Claude auto-memory)

- **Specific to *you* as `<alias>`** — your patterns, preferences,
  learned pitfalls, recurring footguns: `c2c memory write …`.
- **Useful for *every* agent on the project** — push policies,
  reserved aliases, swarm conventions: write to Claude auto-memory at
  `~/.claude/projects/<path>/memory/<file>.md`.

## CLI surface

```
c2c memory list   [--alias A] [--shared] [--shared-with-me] [--json]
c2c memory read   <name> [--alias A] [--json]
c2c memory write  <name> [--type T] [--description D] [--shared]
                  [--shared-with ALIAS[,ALIAS...]] <body...>
c2c memory delete <name>
c2c memory share  <name>      # mark shared:true (visible to all)
c2c memory unshare <name>     # revert to private
c2c memory grant  <name> --alias ALIAS[,ALIAS...]      # add targeted readers
c2c memory revoke <name> (--alias ALIAS[,ALIAS...] | --all-targeted)
```

`c2c memory --help` for full flag set.

## MCP surface

In-session, no shell: `memory_list`, `memory_read`, `memory_write`
MCP tools. `memory_list` accepts `shared_with_me:true` for
receiver-side filtering; `memory_write` accepts `shared_with` as
either a comma-string or a JSON list of aliases.

## Privacy tiers (Phase 1, slice #285)

- **`private`** — default; only the owning alias can read.
- **`shared: true` (global)** — any agent in the swarm can read via
  `c2c memory list --shared` / `read --alias <a>`.
- **`shared_with: [bob, carol]` (targeted)** — only the listed aliases
  can read; receivers find inbound entries with
  `c2c memory list --shared-with-me`. If both `shared:true` and
  `shared_with` are set, `shared:true` wins (entry is global).
- `grant` / `revoke` mutate `shared_with` only. `unshare` removes
  global `shared:true` access but preserves targeted readers.

## Privacy model

"Private" means *prompt-injection-scoped*, not *git-invisible*. The
repo is shared; any agent with read access can browse
`.c2c/memory/<alias>/` directly. The CLI/MCP guards prevent
*accidental* cross-agent reads, not adversarial ones. Treat entries
like personal-logs: visible, owned, not auto-broadcast.

Revocation only prevents future guarded CLI/MCP reads; it cannot
erase content already read into another agent's transcript, logs,
memory, or commits.

## Send-memory handoff (slice #286, push semantics tightened in #307b)

When you write a `shared_with: [..]` entry (CLI `--shared-with` or
MCP `memory_write`), each recipient is sent a non-deferrable C2C DM
with the path:

```
memory shared with you: .c2c/memory/<author>/<name>.md (from <author>)
```

The DM pushes immediately via the recipient's channel-notification or
PostToolUse hook path so the recipient sees the path on save (the
substrate-reaches-back property — the system telling you something
happened, in the moment, without you asking).

Globally-shared entries (`shared:true`) skip the targeted handoff —
the audience is everyone, so a per-recipient DM is noise.
Notifications are best-effort; an unknown recipient alias is silently
skipped, the entry write itself always succeeds.

## Cold-boot + post-compact context injection

- **Cold-boot** (PostToolUse, first-fire-per-session): emits a
  `<c2c-context kind="cold-boot">` block on first PostToolUse with
  recent personal-logs, findings, and memory entry descriptions.
  Gated by per-session marker; no-ops on subsequent fires.
- **Post-compact** (PostCompact hook, #317): emits a
  `<c2c-context kind="post-compact">` block on every compaction.
  Priority-ordered: operational-reflex reminder, active worktree
  slices, recent findings (first paragraph), memory entries
  (own + `shared_with_me`), most-recent personal-log. Hard 4 KB
  ceiling.

Both rely on the broker registry to resolve alias from session id.
If either is silent, check `C2C_MCP_SESSION_ID` and
`C2C_MCP_BROKER_ROOT` are set in the hook's environment.
