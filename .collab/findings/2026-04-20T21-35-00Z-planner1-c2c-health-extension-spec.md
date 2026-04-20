---
author: planner1
ts: 2026-04-20T21:35:00Z
severity: info
status: spec — ready for coder2-expert implementation
---

# c2c health Extension Spec: Supervisor Config, Relay Probe, Plugin Install

## Background

`c2c health` currently checks broker root, registry, rooms, PostToolUse hook,
outer loops, relay connectivity. Three new subsystems need checks:

(a) **Supervisor config presence** — is a supervisor alias configured?
(b) **Relay reachability probe** — can we reach relay.c2c.im?
(c) **Plugin install check** — is the c2c plugin installed for each client?

---

## (a) Supervisor Config Presence

**Check**: Is there a configured supervisor for permission notifications?

**Sources** (in priority order):
1. `C2C_PERMISSION_SUPERVISOR` env var
2. `C2C_SUPERVISORS` env var  
3. `.opencode/c2c-plugin.json` → `supervisors` key
4. Default fallback: `coordinator1`

**Output**:
- Green `✓ supervisor: coordinator1 (default)` — no config, using default
- Green `✓ supervisor: [coordinator1, planner1] (from sidecar)` — configured
- Yellow `⚠ supervisor: coordinator1 (default) — consider explicit config` — only when default

**Implementation** (Python, `c2c_health.py`):
```python
def check_supervisor_config():
    env_sup = os.environ.get("C2C_PERMISSION_SUPERVISOR") or os.environ.get("C2C_SUPERVISORS")
    sidecar_path = os.path.join(os.getcwd(), ".opencode", "c2c-plugin.json")
    sidecar_sups = None
    try:
        with open(sidecar_path) as f:
            sidecar = json.load(f)
            sidecar_sups = sidecar.get("supervisors") or sidecar.get("permission_supervisor")
    except Exception:
        pass
    if env_sup:
        return "green", f"supervisor: {env_sup} (from env)"
    elif sidecar_sups:
        names = sidecar_sups if isinstance(sidecar_sups, list) else [sidecar_sups]
        return "green", f"supervisor: {', '.join(names)} (from sidecar)"
    else:
        return "yellow", "supervisor: coordinator1 (default — consider c2c init --supervisor)"
```

---

## (b) Relay Reachability Probe

**Check**: HTTP GET `https://relay.c2c.im/health` with 5s timeout.

**Output**:
- Green `✓ relay: reachable — 0.6.10 @ f21b3bc`  
- Yellow `⚠ relay: reachable but version mismatch (expected 0.6.10, got 0.6.9)`
- Red `✗ relay: unreachable (connection timeout)`
- Gray `– relay: not configured (no C2C_RELAY_URL set)` — if relay not used

**Implementation**:
```python
def check_relay_reachability():
    relay_url = os.environ.get("C2C_RELAY_URL", "https://relay.c2c.im")
    try:
        import urllib.request, urllib.error, json as _json
        req = urllib.request.Request(f"{relay_url}/health", headers={"User-Agent": "c2c-health/1"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = _json.loads(resp.read())
            version = data.get("version", "?")
            git_hash = data.get("git_hash", "?")
            return "green", f"relay: reachable — {version} @ {git_hash}"
    except urllib.error.URLError as e:
        return "red", f"relay: unreachable ({e.reason})"
    except Exception as e:
        return "red", f"relay: probe error ({e})"
```

---

## (c) Plugin Install Check Per Client

**Check**: For each supported client, is the c2c plugin installed?

**Clients and plugin paths**:

| Client | Plugin path | Type |
|--------|-------------|------|
| Claude Code | `~/.claude/settings.json` → `hooks.PostToolUse` contains `c2c poll-inbox` | JSON hook |
| OpenCode | `.opencode/plugins/c2c.ts` (project) or `~/.config/opencode/plugins/c2c.ts` (global) | TS file |
| Codex | `~/.codex/config.toml` → `[mcp_servers.c2c]` | TOML |
| Kimi | `~/.kimi/mcp.json` → `servers.c2c` | JSON |
| Crush | `~/.config/crush/crush.json` → `servers.c2c` | JSON |

**Output** (per client):
- Green `✓ claude-code: PostToolUse hook configured`
- Green `✓ opencode: plugin installed (project-level)`
- Yellow `⚠ opencode: plugin not installed (run: c2c install opencode)`
- Gray `– kimi: not installed (run: c2c install kimi if using Kimi)`

**Implementation sketch**:
```python
def check_plugin_installs():
    results = []
    
    # Claude Code
    settings_path = os.path.expanduser("~/.claude/settings.json")
    try:
        with open(settings_path) as f:
            settings = json.load(f)
        hooks = settings.get("hooks", {}).get("PostToolUse", [])
        has_hook = any("c2c" in str(h) for h in hooks)
        results.append(("green" if has_hook else "yellow",
            "claude-code: PostToolUse hook configured" if has_hook
            else "claude-code: no PostToolUse hook (run: c2c install claude)"))
    except Exception:
        results.append(("gray", "claude-code: settings.json not found"))
    
    # OpenCode
    project_plugin = os.path.join(os.getcwd(), ".opencode", "plugins", "c2c.ts")
    global_plugin = os.path.expanduser("~/.config/opencode/plugins/c2c.ts")
    if os.path.exists(project_plugin):
        results.append(("green", "opencode: plugin installed (project-level)"))
    elif os.path.exists(global_plugin):
        results.append(("green", "opencode: plugin installed (global)"))
    else:
        results.append(("yellow", "opencode: plugin not installed (run: c2c install opencode)"))
    
    return results
```

---

## Output Format

```
c2c health
──────────
✓ broker root:   .git/c2c/mcp
✓ registry:      3 sessions (2 alive)
✓ rooms:         swarm-lounge (3 members)
✓ hook:          PostToolUse configured
✓ relay:         reachable — 0.6.10 @ f21b3bc
⚠ supervisor:    coordinator1 (default — consider c2c init --supervisor)
✓ plugin:        opencode (project-level), claude-code (hook)
⚠ plugin:        kimi not installed (run: c2c install kimi)
```

**Color codes**: green=✓, yellow=⚠, red=✗, gray=–

---

## Acceptance Criteria

1. `c2c health` output includes supervisor config, relay probe, plugin checks
2. Each check has a clear green/yellow/red/gray status
3. Actionable suggestion on yellow (e.g. `run: c2c install opencode`)
4. Relay probe uses 5s timeout; failure → red, not exception
5. `c2c health --json` includes `supervisor`, `relay`, `plugins` keys in output

## Related

- `c2c_health.py` (current implementation)
- `.collab/findings/2026-04-20T21-05-00Z-planner1-c2c-init-supervisor-spec.md`
- `.collab/findings/2026-04-20T21-30-00Z-planner1-supervisor-liveness-spec.md`
