---
name: session_resume_research
description: Research findings for BUG #114 - session resume for custom-profile Claude
type: project
---

## BUG #114: Session Resume for Custom-Profile Claude

### Root Cause Found

**File**: `ocaml/c2c_start.ml`, lines 982-991

**Problem**: `claude_session_exists` hardcodes `~/.claude/projects`:
```ocaml
let root = home_dir () // ".claude" // "projects" in
```

When using a custom profile (`CLAUDE_CONFIG_DIR=/path/to/profile`), Claude stores sessions at:
```
<CLAUDE_CONFIG_DIR>/.claude/projects/<slug>/<uuid>.jsonl
```

c2c looks in `~/.claude/projects/`, finds nothing, returns `false`.

### Failure Chain
1. `c2c start claude -n dev` (with custom profile)
2. Generates resume_session_id, stores in instance config
3. On restart, `claude_session_exists` probes `~/.claude/projects/*/<uuid>.jsonl`
4. Session files are actually in `$CLAUDE_CONFIG_DIR/.claude/projects/`
5. Returns `false` → c2c uses `--session-id <uuid>` instead of `--resume <uuid>`
6. Creates new session instead of resuming

### Fix
`claude_session_exists` needs to check both:
1. `~/.claude/projects/*/<uuid>.jsonl` (default)
2. `<CLAUDE_CONFIG_DIR>/.claude/projects/*/<uuid>.jsonl` (custom profile)

Also check `CLAUDE_DATA_DIR` if set.

### Next Steps
1. File finding doc
2. Implement fix in `c2c_start.ml`
3. Add unit test
4. Peer review
