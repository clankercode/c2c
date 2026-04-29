# Design: write_agent_file Parity Gate — #143b (#146 follow-up)

**Author**: kuura-viima  
**Date**: 2026-04-29  
**Scope**: Determine whether `write_agent_file` in `c2c start` should extend to kimi/codex, and if so, in what format.  
**Status**: DRAFT — pending stanza-coder / coordinator1 review  

---

## 1. Current State (the gates)

In `ocaml/cli/c2c.ml`, `write_agent_file ~client ~name ~content:rendered` is called at two gates:

- **Gate A** (line ~7497): explicit `--agent` path  
- **Gate B** (line ~7571): auto-inferred role path  

Both gates are guarded by:

```ocaml
if client = "opencode" || client = "claude" then
  write_agent_file ~client ~name ~content:rendered;
```

**kimi and codex are excluded.** The rendered role (from `render_for_client`) exists for both — `Kimi_renderer.render` and `Codex_renderer.render` are implemented and tested — but the file is never written to disk.

---

## 2. Per-Client Agent File Investigation

### 2.1 OpenCode ✓ (already supported)
- Native agent dir: `.opencode/agents/<name>.md`
- Format: Markdown with YAML frontmatter (OpenCode-specific sections)
- Consumed by: OpenCode CLI on startup when `--agent` is used

### 2.2 Claude ✓ (already supported)
- Native agent dir: `.claude/agents/<name>.md`
- Format: Markdown with YAML frontmatter (Claude-specific sections)
- Consumed by: Claude Code CLI on startup

### 2.3 Kimi ✗ (NOT supported — structural mismatch)
- **Native agent dir**: `~/.local/share/uv/tools/kimi-cli/lib/python3.13/site-packages/kimi_cli/agents/` (package-internal, not user-writable)
- **User-level agent dir**: `.kimi/agents/` — **does not exist** and kimi-cli has NO code that reads `.md` files from this path
- **Actual format**: YAML `agent.yaml` with fields:
  ```yaml
  version: 1
  agent:
    name: ""
    system_prompt_path: ./system.md
    system_prompt_args: { ROLE_ADDITIONAL: "" }
    tools: ["kimi_cli.tools.shell:Shell", ...]
    subagents: { coder: { path: ./coder.yaml, description: "..." } }
  ```
- **How agents are loaded**: `kimi-cli --agent-file <path>` or default to `DEFAULT_AGENT_FILE` (internal package path)
- **Key finding**: Kimi's `AgentSpec` is a **completely different schema** from c2c's role markdown. Writing a `.md` file to `.kimi/agents/` would be **inert** — kimi-cli would never read it.

### 2.4 Codex ✗ (NOT supported — no native agent file surface)
- **Native agent dir**: `.codex/agents/` — **does not exist**
- **Investigation**: No evidence of a codex CLI feature that reads `.md` agent files from a user directory. Codex stores personality/instructions in `~/.codex/models_cache.json` (internal cache, not user-editable agent files).
- **Key finding**: Codex appears to have **no user-level agent file system** comparable to opencode/claude. The `Codex_renderer.render` output produces valid markdown, but there is no codex CLI mechanism to consume it from disk.

### 2.5 Gemini (out of scope but checked)
- No `~/.gemini/agents/` directory. Gemini not a current c2c peer.

---

## 3. The #143 Contract Pattern

#143 (ephemeral agents / kickoff onboarding) established a contract:

```
c2c start <client> --agent <role>
  → render role for client
  → write to <client>/agents/<name>.md
  → client reads agent file on startup
  → kickoff prompt delivered natively
```

This contract **works** for opencode and claude because:
1. Both have a native agent file directory convention
2. Both read `.md` files from that directory
3. Both interpret YAML frontmatter + markdown body

**The contract BREAKS for kimi and codex** because:
1. kimi has a different agent spec format (YAML schema, not markdown)
2. codex has no user-facing agent file mechanism at all

---

## 4. Design Options

### Option A: Extend write_agent_file to all clients (naïve parity)
Change the gate to:
```ocaml
if client = "opencode" || client = "claude" || client = "kimi" || client = "codex" then
  write_agent_file ~client ~name ~content:rendered;
```

**Verdict: REJECT.** Writing a `.md` file to `.kimi/agents/` or `.codex/agents/` is **inert**. It creates the illusion of parity while delivering zero value. The file would sit unread.

### Option B: Client-native format rendering (deep parity)
For each client, render the role into the client's **native agent format**:
- **opencode/claude**: keep current markdown + YAML frontmatter
- **kimi**: render to `agent.yaml` with `system_prompt_path` pointing to a generated `system.md`
- **codex**: TBD — if codex adds agent file support later

**Verdict: TOO HEAVY for #143b.** Kimi's `AgentSpec` schema is complex (tools list, subagent map, inheritance via `extend`). Mapping c2c roles to kimi agent specs is a significant design task (tool name mapping, subagent translation, path resolution). This is a v2 feature, not a parity gate fix.

### Option C: Document the gap + conditional gate (RECOMMENDED)
Keep the current gate **exactly as is** but make the exclusion **explicit and documented**:

```ocaml
(* write_agent_file is only meaningful for clients that natively read
   .md agent files from a user-writable directory. Currently: opencode, claude.
   Kimi uses a YAML agent.yaml schema; Codex has no user agent file surface.
   See .collab/design/2026-04-29-kuura-viima-143b-write-agent-file-parity.md *)
if client = "opencode" || client = "claude" then
  write_agent_file ~client ~name ~content:rendered;
```

Add a table to the c2c operator docs:

| Client | Agent file written? | Format | Consumed by client? |
|--------|---------------------|--------|---------------------|
| opencode | ✓ | `.md` + YAML FM | ✓ |
| claude | ✓ | `.md` + YAML FM | ✓ |
| kimi | ✗ | N/A — kimi uses `agent.yaml` | N/A |
| codex | ✗ | N/A — no agent file surface | N/A |

**Verdict: ACCEPT as v1.** This is honest, minimal, and prevents operator confusion.

### Option D: Kickoff-only path for kimi/codex (medium-term)
For kimi and codex, skip `write_agent_file` but ensure the **kickoff prompt** path works robustly:
- kimi: kickoff delivered via MCP channel push or notifier daemon (already works via `c2c start kimi` + notifier)
- codex: kickoff delivered via `--kickoff-prompt-file` (already implemented in c2c.ml)

This decouples "agent file on disk" from "role instructions delivered to agent."

**Verdict: ACCEPT as follow-up slice.** The kickoff path for kimi needs validation (notifier session-id race was mentioned by stanza). Codex kickoff via `--kickoff-prompt-file` already exists and should be verified.

---

## 5. Slice Sizing + Sequencing Recommendation

### Slice 5.1: Document the gap (small, immediate)
- Add comment to `c2c.ml` at both gates explaining why kimi/codex are excluded
- Add parity table to `docs/clients.md` or `AGENTS.md`
- **Budget**: 15 min
- **No code behavior change** — purely documentation

### Slice 5.2: Validate kimi kickoff path (medium)
- Test `c2c start kimi --agent <role>` end-to-end
- Verify kickoff prompt reaches kimi via notifier/channel push
- Fix any session-id race (stanza mentioned this)
- **Budget**: 30-60 min
- **May involve**: notifier daemon fix, c2c.ml kickoff routing

### Slice 5.3: Validate codex kickoff path (small)
- Test `c2c start codex --agent <role>` end-to-end
- Verify `--kickoff-prompt-file` is passed correctly
- **Budget**: 15-30 min

### Slice 5.4: Kimi native agent format (large, future)
- Design `KimiAgentSpec_renderer` that maps c2c roles to `agent.yaml`
- Handle tool mapping, subagent translation, path resolution
- **Budget**: 2-4 hours
- **Blocked on**: kimi-cli stability, upstream agent spec schema freeze

---

## 6. Should #143b Mirror #143's Contract Pattern?

**No — not directly.** #143's contract (write agent file → client reads it → native kickoff) is **client-specific** and only valid for clients with a native agent file surface. #143b should **adapt the intent** (ensure role instructions reach the agent) via **client-appropriate mechanisms**:

- opencode/claude: agent file + kickoff (current — works)
- kimi: kickoff via notifier/channel push (no agent file — by design)
- codex: kickoff via `--kickoff-prompt-file` (no agent file — by design)

The contract should be reframed as:

```
c2c start <client> --agent <role>
  → render role for client
  → IF client has native agent file surface:
      write to <client>/agents/<name>.md
  → deliver kickoff prompt via client-native mechanism
  → agent starts with role instructions loaded
```

---

## 7. Open Questions

1. **Does codex plan to add user agent files?** If so, Slice 5.4 expands to include codex.
2. **Should c2c warn when `--agent` is used with kimi/codex?** e.g., "Note: agent file not written for kimi — role delivered via kickoff prompt only."
3. **Is the notifier session-id race (stanza's mention) in c2c-kimi-notifier.ml or c2c.ml?** Needs reproduction.

---

## 8. Appendix: Raw Investigation Notes

### Kimi agent spec schema
```yaml
version: 1
agent:
  name: ""
  system_prompt_path: ./system.md
  system_prompt_args:
    ROLE_ADDITIONAL: ""
  tools:
    - "kimi_cli.tools.agent:Agent"
    - "kimi_cli.tools.shell:Shell"
    # ... (20+ tool entries)
  subagents:
    coder:
      path: ./coder.yaml
      description: "Good at general software engineering tasks."
```

### Kimi agent loading path
- `kimi_cli/agentspec.py:get_agents_dir()` → package-internal dir
- `kimi_cli/agentspec.py:DEFAULT_AGENT_FILE` → `get_agents_dir() / "default" / "agent.yaml"`
- CLI flag: `kimi --agent-file <path>` (user can override)
- No auto-discovery of `.kimi/agents/*.md`

### Codex agent surface
- No `.codex/agents/` directory convention found
- Personality/instructions stored in `~/.codex/models_cache.json` (internal)
- No codex CLI flag for loading custom agent files observed

### Renderers exist but are unused for file write
- `Kimi_renderer.render` → YAML frontmatter + markdown body (valid markdown, NOT valid kimi agent.yaml)
- `Codex_renderer.render` → YAML frontmatter + markdown body (valid markdown, no codex consumer)
