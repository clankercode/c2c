# DRAFT-per-agent-memory.md

## #163 — Per-Agent Memory System

**Author**: stanza-coder  
**Date**: 2026-04-25  
**Status**: DRAFT (coordinator-PASS received; notes folded in; ready for Phase 1)

---

### Context

The c2c swarm currently has two memory mechanisms, both with gaps:

1. **Claude auto-memory** (`~/.claude/projects/<path>/memory/`): Injected into every Claude Code session via `MEMORY.md` excerpt in the system prompt. Problem: *user-scoped* — all agents sharing the same project directory share the same memory pool. coordinator1's memories about push-batching become stanza-coder's context. coordinator1's preferences silently override stanza-coder's in the same index.

2. **Personal logs** (`.c2c/personal-logs/<alias>/`): Tracked in git, per-agent, freeform. No auto-injection — agents have to explicitly read them. Not useful as context unless you remember to `Read` them on startup.

Neither gives agents a private, auto-injected, cross-client-parity memory surface. This is what #163 designs.

---

### Goals

- Each agent has a private memory store that auto-injects into their sessions
- Claude Code, Codex, and OpenCode agents get comparable (not necessarily identical) experiences
- Private by default; explicit opt-in to share entries with other agents or the swarm
- Coexists with Claude auto-memory without stepping on it
- CLI surface for operators and agents to manage entries
- MCP tool surface for agents to read/write their own memory mid-session

---

### Design Decisions

#### 1. Storage Location

**Decision**: `.c2c/memory/<alias>/` in the repo root, tracked by git.

Rationale:
- In-repo means all client types can access it without path magic
- Per-alias subdirectory is the same pattern as personal-logs (familiar)
- Git-tracked = auditable, diffable, shareable when desired
- `~/.c2c/memory/<alias>/` (user-local) was considered but breaks cross-machine/cross-worktree use; agents running in different worktrees need the same memory

File format: same as Claude auto-memory — markdown with YAML frontmatter:
```markdown
---
name: Branch-first discipline
description: Always create a feature branch before committing; never commit directly to master for a new slice
type: feedback
---
...content...
```

Index file: `.c2c/memory/<alias>/MEMORY.md` — same role as the Claude auto-memory MEMORY.md (one-line entry per file, under 200 lines, truncated after that).

**Sharing**: Entries with `shared: true` in frontmatter are visible to other agents via `c2c memory list --shared`. Default is private.

**Privacy model clarification**: "private" here means *prompt-injection-scoped*, not *git-invisible*. The repo is shared; any agent with read access can browse `.c2c/memory/<alias>/` via `git` or `Read`. "Private" means the entry is not automatically injected into other agents' sessions. Agents should write memories knowing they are journaled, not secret — treat them like personal-logs (visible, owned, not broadcast).

---

#### 2. How Claude Code Injects It

**Decision**: CLAUDE.md directive + PostToolUse hook.

Claude Code already loads `CLAUDE.md` at session start. We add a standard block at the bottom of `.claude/settings.json` (or CLAUDE.md) that instructs the agent to read its alias-specific MEMORY.md on startup:

```
At session start: your alias is $C2C_MCP_AUTO_REGISTER_ALIAS. Read
.c2c/memory/<your-alias>/MEMORY.md and load any linked files that seem
relevant to the current task. This is YOUR memory — treat it as prior
context. If this file doesn't exist, that's normal for new agents; the
memory system starts empty and you build it as you go.
```

For auto-injection without manual reads: the PostToolUse hook that already runs `c2c-inbox-hook-ocaml` could be extended to inject a memory summary into the conversation on first invocation. This requires the hook to:
1. Check if it's the first hook call this session (via a temp file)
2. Read `.c2c/memory/<alias>/MEMORY.md`
3. Output a `<c2c-memory>` block that surfaces in the transcript

This is the highest-fidelity path but requires hook extension work.

**Near-term shortcut**: Add a standard CLAUDE.md section that agents are instructed to follow on session start (already in the "agent wake-up setup" runbook pattern). This gives roughly the same result without hook plumbing.

---

#### 3. How Codex Gets It

Codex reads `AGENTS.md` and `CLAUDE.md` at startup. Same CLAUDE.md directive works. The `C2C_MCP_AUTO_REGISTER_ALIAS` env var is available if Codex is launched via `c2c start codex`.

Limitation: Codex doesn't run hooks the same way. For now, CLAUDE.md directive + manual `c2c memory read` at startup (via MCP tool) is the path.

---

#### 4. How OpenCode Gets It

The c2c TypeScript plugin (`c2c.ts`) runs at OpenCode startup and has access to the broker. It can:
1. Resolve alias from env (`C2C_MCP_AUTO_REGISTER_ALIAS`)
2. Read `.c2c/memory/<alias>/MEMORY.md` via `fs.readFileSync`
3. Prepend a memory summary to the first `promptAsync` call or emit it as a system message

This mirrors how the nudge system receives messages — reuse the same delivery path, just at cold-boot.

---

#### 5. MCP Tool Surface

Two new tools on the c2c MCP server (delete is CLI-only for safety — destructive operations require operator intent, not an in-session impulse):

```
c2c_memory_read(alias?: string) → { entries: MemoryEntry[] }
  Reads the caller's memory index (or another alias's if shared).
  Returns parsed entries with name, type, description, body.
  Returns { entries: [] } if alias dir doesn't exist (empty, not error).

c2c_memory_write(entry: MemoryEntry) → { ok: true }
  Writes or updates a memory entry for the caller's alias.
  Validates frontmatter, refuses to write into another alias's dir.
  Updates MEMORY.md index automatically.
```

OCaml implementation lives in `c2c_mcp.ml` alongside existing tool handlers.

---

#### 6. CLI Surface

```
c2c memory list [--alias <a>] [--shared]    # list entries (own or shared)
c2c memory read <name> [--alias <a>]        # print a specific entry
c2c memory write <name> --type <t> --body <text>  # add/update an entry
c2c memory delete <name>                    # remove an entry
c2c memory share <name>                     # mark an entry shared: true
c2c memory unshare <name>                   # revert to private
```

Tier: `memory` → Tier1 (safe for agents). All subcommands inherit.

---

#### 7. Coexistence with Claude Auto-Memory

Claude auto-memory (`~/.claude/projects/<path>/memory/`) continues to hold user-scoped, swarm-wide context (project goals, reserved aliases, railway push policy). Per-agent memory (`.c2c/memory/<alias>/`) holds agent-scoped context (personal feedback, learned patterns, session notes).

Rule of thumb:
- Would this be useful for EVERY agent? → Claude auto-memory
- Is this specific to my identity, preferences, or session history? → per-agent memory

Agents are instructed NOT to write duplicate entries across both systems.

**Partition enforcement**: To prevent "which one do I write to?" ambiguity at the moment of writing (not derivable from a design doc the agent may not have read), we use distinct filenames for each system's index:
- Claude auto-memory index stays as `MEMORY.md` (user-scoped, injected by Claude Code harness)
- Per-agent index uses the same `MEMORY.md` filename but *within* `.c2c/memory/<alias>/`, a different path

The CLAUDE.md directive makes the distinction concrete: "If this is swarm-wide context (project goals, shared conventions), write to your Claude auto-memory via `Write /home/xertrov/.claude/projects/<path>/memory/<file>.md`. If this is specific to you as `<alias>` (your feedback, your patterns, your session notes), write to `.c2c/memory/<alias>/`."

**Longer-term**: per-agent memory is a candidate to eventually replace Claude auto-memory for managed sessions, with the user-scoped pool narrowed to truly global project state. This is not a v1 concern but should not foreclose that path.

**Worktree compatibility**: agents working in worktrees (`.worktrees/<name>/`) still reference `.c2c/memory/<alias>/` from the repo root — relative paths from a worktree root resolve into the shared git common dir. The CLAUDE.md directive should use `git rev-parse --show-toplevel` or a repo-root-relative path, not `$(pwd)`, to stay worktree-safe.

---

### Implementation Phases

**Phase 0 (design)**: This document. No code.

**Phase 1 (storage + CLI)**:
- Create `.c2c/memory/` directory with per-alias subdirs
- `c2c memory` CLI commands (list, read, write, delete)
- CLAUDE.md directive for manual startup read

**Phase 2 (MCP tools)**:
- `c2c_memory_read` and `c2c_memory_write` MCP tools
- OCaml implementation in `c2c_mcp.ml`

**Phase 3 (auto-injection)**:
- Hook extension for Claude Code (PostToolUse → memory injection on first call)
- OpenCode plugin extension (cold-boot memory prepend)
- Codex: TBD (may require `c2c start codex` to set up an init prompt)

---

### Open Questions (Resolved)

1. **Index size limit**: 200 lines, same as Claude auto-memory. Raise per-agent if it bites; don't over-plan.

2. **Stale entries**: Manual `c2c memory delete` + convention. Agent decides at startup which entries are still load-bearing. Auto-expiry TTL is premature optimization.

3. **Shared memory discovery**: `c2c memory list --shared` scans all alias dirs on demand. No maintained SHARED.md index — compute it dynamically. Flat enumeration is fast enough for the number of agents we have.

4. **Bootstrap**: CLAUDE.md directive + this design doc + personal-logs precedent. The pattern is established. New agents will find the directive before they need the memory system.

5. **Relation to #162 nudge system**: A nudge that says "write something to memory that you'd want future-you to have" is a natural complement. Cross-reference in #162 implementation, not here.

---

### Non-Goals

- Not a replacement for `.collab/findings/` (those are swarm-public, incident-scoped)
- Not a replacement for `.sitreps/` (those are time-series coordinator logs)
- Not a full vector database or semantic search — flat markdown files, simple enumeration
- Not real-time sync across concurrent sessions (git-tracked, read-at-startup pattern)
