# `c2c agent new/refine` test session — bug log

Filed 2026-04-23 by coordinator1 (Cairn-Vigil). Logging bugs as I hit them during dogfood test of `c2c agent new tundra-coder` → `c2c agent refine tundra-coder` → launch cc-mm coder.

## Bugs

### 1. [KNOWN/FILED] `c2c agent new <name>` rejects positional arg

Already in todo.txt. Confirmed still present today: `c2c agent new tundra-coder` → `Usage: c2c agent new [--help] [OPTION]…  c2c: too many arguments, don't know what to do with tundra-coder`.

Workaround used: `c2c agent new` with no args, then type at `Role name:` prompt.

### 2. [HIGH, NEW] `c2c agent new` writes snippet names with `.md` extension → silent-drop by resolver

`c2c agent new` interactive flow writes frontmatter like:
```yaml
include: [c2c-basics.md, monitors-setup.md]
```

But `c2c_role.ml:load_snippet` appends `.md` itself:
```
let path = Filename.concat snippets_dir (name ^ ".md") in
```

So it tries to load `.c2c/snippets/c2c-basics.md.md` — doesn't exist — returns empty body — included snippets silently drop from compiled output.

Confirmed: `galaxy-coder.md` uses `include: [recovery]` (bare name) and its snippet body DOES appear in compile output. My `tundra-coder.md` uses `include: [c2c-basics.md, monitors-setup.md]` and the snippets are nowhere to be found post-compile.

**Severity: HIGH** — agents created via `c2c agent new` are missing the c2c-basics primer that teaches them how to DM peers. Exactly the Max-observed pain point: "agents need to be told about using c2c tools". The wizard PROMISES snippets get included; parser says OK; resolver silently drops them because the wizard's output format disagrees with the resolver's expectation.

**Fix**: either the wizard strips `.md` when writing include entries, OR `load_snippet` accepts both `foo` and `foo.md`. I'd go with both — defense in depth.

**Secondary consequence**: the pre-existing indent bug I flagged as Bug 2 (compatible_clients inlining the include) is actually downstream of this — both are silent in practice because include gets dropped anyway. Promoted this one to HIGH; indent is MEDIUM but strictly speaking a co-bug.

### 3. YAML indent bug — `include:` nested under `compatible_clients:` list

Scaffold output in `.c2c/roles/tundra-coder.md` (and observed previously on `review-bot.md`):
```yaml
compatible_clients: [claude]
  include: [c2c-basics.md, monitors-setup.md]
```

The 2-space indent makes `include:` look like a sub-field. After my manual fix to un-indent, Bug 2 above still fires. Still worth fixing separately — otherwise any user who does fix the extension will hit this next.

### 4. Post-creation nano prompt UX

`Open in nano now? [0=yes, 1=skip]:` — inverting the yes/no convention. Minor nit.

### 5. [FROM MAX 2026-04-23] `c2c agent refine` has no "called by agent" mode

When refine is invoked by a peer agent rather than a human, it should:
- Not inject human-TUI-oriented prompts ("let's discuss the role together")
- Emit structured outputs the caller can parse (the caller may be another LLM)
- Use c2c DMs for clarifying questions (not interactive TUI prompts)
- Terminate cleanly via `c2c_stop_self` equivalent

Proposed: `c2c agent refine <name> [--agent-mode]` or env var `C2C_AGENT_REFINE_MODE=agent`. When set:
- Prompt template tells the refine-agent: "You are being called by peer \${caller}; use c2c DM to them for any clarification; emit final role file as your only tangible artifact."
- Skip the nano-prompt / human-confirmation steps
- On completion, call `c2c_stop_self` or exit cleanly

Aligns with the ephemeral-agent design (#98). May be cleanly subsumed when ephemeral-agents lands, but refine already exists so worth a flag in the meantime.

### 6. [HIGH, NEW] HTML comment before frontmatter breaks `split_frontmatter`

Role-Designer (MiniMax, invoked via `c2c agent refine`) added a helpful `<!-- NOTE: ... -->` comment at the TOP of the committed role file — before the `---` delimiter. This causes `split_frontmatter` to treat the entire file as body, so:
- description falls back to `""`
- role falls back to `"subagent"` (even though source said primary)
- include doesn't parse → snippets never resolved
- All YAML-frontmatter intent is silently discarded

Diagnosed by running `c2c roles compile --dry-run --client claude tundra-coder` and seeing the output start with `description: ""`, `role: subagent` instead of the file's declared values.

**Severity: HIGH**. Agent-generated roles are systematically broken because any leading comment (which agents naturally add as a "here's why" preamble) blows up the parser.

**Fix**: make `split_frontmatter` tolerant of leading HTML comments / blank lines / shebangs before the first `---`. Skip those, then find the delimiter. Or document in the refine prompt template "no content before the frontmatter `---` — if you want a note, put it after the closing `---`."

Combined with Bug #2 (.md suffix) this explains why snippets never show up for wizard-created roles even after manual re-opens.

**Manual workaround for this session**: moved the comment after the closing `---` delimiter. Compile now correctly emits snippet bodies + full frontmatter.

### (more as I hit them)

Scaffold output in `.c2c/roles/tundra-coder.md` (and observed previously on `review-bot.md`):
```yaml
compatible_clients: [claude]
  include: [c2c-basics.md, monitors-setup.md]
```

The 2-space indent makes `include:` look like a sub-field of `compatible_clients` when the parser almost certainly expects them to be siblings at frontmatter top level. Either the parser is silently handling mis-indentation or the snippets never actually include in the rendered agent file. Verifying via `c2c roles compile --dry-run tundra-coder` would show which.

Expected:
```yaml
compatible_clients: [claude]
include: [c2c-basics.md, monitors-setup.md]
```

Severity: medium — silent bug, causes snippets to not include, which is how agents learn about c2c tools. Combined with Max's observation that "agents need to be told about using c2c tools etc" — if include: is being dropped, new roles are MISSING the c2c basics that tell them how to DM peers. That's a system-level bug, not just cosmetic.

### 3. Post-creation nano prompt UX

`Open in nano now? [0=yes, 1=skip]:` — inverting the yes/no convention (0=no normally). Picked 1=skip as intended. Minor nit.

### (more as I hit them)
