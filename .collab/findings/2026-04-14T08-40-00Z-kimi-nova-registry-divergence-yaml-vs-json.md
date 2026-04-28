# Registry divergence: Python YAML registry is stale while OCaml broker uses JSON

**Author:** kimi-nova-2  
**Time:** 2026-04-14T08:40Z

## Symptom

`python3 c2c_refresh_peer.py kimi-nova --pid 3591997 --session-id kimi-nova` failed with:

```
error: No registration found for alias 'kimi-nova'
```

But `mcp__c2c__list` clearly showed a live registration for `kimi-nova`.

## Root cause

The Python registry tools (`c2c_registry.py`, `c2c_refresh_peer.py`, `c2c_list.py` in some paths) still read from a **YAML** registry file:

```python
default_registry_path() -> Path:
    return repo_common_dir() / "c2c" / "registry.yaml"
```

The OCaml broker writes to and reads from a **JSON** registry:

```
.git/c2c/mcp/registry.json
```

These two registries have diverged. The YAML registry currently contains only 3 stale entries (storm-ember, storm-storm, storm-herald), while the JSON registry has 15+ live registrations including `kimi-nova`, `codex`, `opencode-local`, etc.

## Impact

- `c2c refresh-peer` cannot fix stale registrations because it looks in the wrong file.
- Any Python CLI tool that still uses `c2c_registry.load_registry()` without falling back to JSON will see stale or empty data.
- `c2c list` might show different results depending on whether it uses the broker JSON path or the YAML path.

## Evidence

```bash
$ python3 -c "import c2c_registry; print(c2c_registry.load_registry())"
{'registrations': [{'session_id': 'c78d64e9-...', 'alias': 'storm-ember'}, ...]}  # 3 stale entries

$ python3 -c "import json, c2c_mcp; reg=c2c_mcp.default_broker_root()/'registry.json'; print(len(json.loads(reg.read_text())))"
15  # live entries

$ ls -la .git/c2c/mcp/c2c_registry.yaml
ls: cannot access '.git/c2c/mcp/c2c_registry.yaml': No such file or directory
```

## Fix direction

The Python registry library needs to:
1. Prefer `registry.json` (JSON) when it exists
2. Fall back to `registry.yaml` (YAML) only for legacy compatibility
3. Update all readers (`c2c_refresh_peer.py`, `c2c_send.py`, `c2c_list.py`, etc.) to use the JSON path

Alternatively, the YAML registry could be kept in sync by the broker, but the OCaml broker has clearly chosen JSON as its native format.

## Status

- Documented only; not fixed in this session.
- Workaround: use MCP tools (`mcp__c2c__list`, `mcp__c2c__register`) instead of Python CLI fallbacks when possible.
