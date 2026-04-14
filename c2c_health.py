#!/usr/bin/env python3
"""Health check for c2c broker and components.

Quick diagnostic to verify:
- Broker directory exists and is writable
- Registry is readable
- Current session is registered
- Inbox file exists and is writable
- Room directory exists (if rooms used)
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any

import c2c_mcp
import c2c_whoami


def check_broker_root(broker_root: Path) -> dict[str, Any]:
    """Check broker root directory health."""
    result = {
        "path": str(broker_root),
        "exists": broker_root.exists(),
        "is_dir": broker_root.is_dir() if broker_root.exists() else False,
        "writable": False,
    }

    if broker_root.exists():
        try:
            test_file = broker_root / ".health_check_write_test"
            test_file.write_text("test")
            test_file.unlink()
            result["writable"] = True
        except OSError:
            pass

    return result


def check_registry(broker_root: Path) -> dict[str, Any]:
    """Check registry file health."""
    registry_path = broker_root / "registry.json"
    result = {
        "path": str(registry_path),
        "exists": registry_path.exists(),
        "readable": False,
        "entry_count": 0,
        "duplicate_pids": [],
    }

    if registry_path.exists():
        try:
            registrations = c2c_mcp.load_broker_registrations(registry_path)
            result["readable"] = True
            result["entry_count"] = len(registrations)
            activity_counts = _archive_activity_counts(broker_root)
            pid_map: dict[int, list[dict[str, Any]]] = {}
            for reg in registrations:
                pid = reg.get("pid")
                if isinstance(pid, int):
                    pid_map.setdefault(pid, []).append(reg)
            result["duplicate_pids"] = [
                _duplicate_pid_entry(pid, regs, activity_counts)
                for pid, regs in pid_map.items()
                if len(regs) > 1
            ]
        except Exception:
            pass

    return result


def _registration_activity(reg: dict[str, Any], activity_counts: dict[str, int]) -> int:
    session_id = str(reg.get("session_id") or "")
    alias = str(reg.get("alias") or "")
    return activity_counts.get(session_id, 0) + activity_counts.get(alias, 0)


def _duplicate_pid_entry(
    pid: int,
    registrations: list[dict[str, Any]],
    activity_counts: dict[str, int],
) -> dict[str, Any]:
    aliases = [str(reg.get("alias", "")) for reg in registrations]
    activity_by_alias = {
        str(reg.get("alias", "")): _registration_activity(reg, activity_counts)
        for reg in registrations
    }
    sibling_has_activity = any(count > 0 for count in activity_by_alias.values())
    likely_stale_aliases = [
        alias
        for alias, count in activity_by_alias.items()
        if sibling_has_activity and count == 0
    ]
    return {
        "pid": pid,
        "aliases": aliases,
        "likely_stale_aliases": likely_stale_aliases,
    }


def _archive_activity_counts(broker_root: Path) -> dict[str, int]:
    """Return rough broker archive activity counts keyed by alias/session id."""
    counts: dict[str, int] = {}
    archive_dir = broker_root / "archive"
    if not archive_dir.exists():
        return counts
    for archive_file in archive_dir.glob("*.jsonl"):
        stem = archive_file.stem
        try:
            lines = archive_file.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for raw in lines:
            raw = raw.strip()
            if not raw:
                continue
            counts[stem] = counts.get(stem, 0) + 1
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            for key in ("from_alias", "to_alias"):
                value = str(entry.get(key) or "").split("@", 1)[0]
                if value and value != "c2c-system":
                    counts[value] = counts.get(value, 0) + 1
    return counts


def check_session(broker_root: Path, session_id: str | None = None) -> dict[str, Any]:
    """Check current session registration and inbox.

    If session_id is given, check that session directly without resolving
    the caller's identity from env vars.  Useful for operator health checks
    run outside an agent context.
    """
    result = {
        "resolved": False,
        "registered": False,
        "alias": None,
        "session_id": None,
        "inbox_exists": False,
        "inbox_writable": False,
        "inbox_pending": 0,
        "operator_check": session_id is not None,  # True when bypassing identity resolution
    }

    try:
        if session_id is not None:
            # Operator mode: look up this session in the registry directly
            registry_path = broker_root / "registry.json"
            registrations = c2c_mcp.load_broker_registrations(registry_path)
            registration = next(
                (r for r in registrations if r.get("session_id") == session_id),
                None,
            )
            result["resolved"] = True
            if registration:
                result["registered"] = True
                result["alias"] = registration.get("alias")
                result["session_id"] = registration.get("session_id")
        else:
            # Try C2C_MCP_SESSION_ID first (set by outer loops for managed sessions).
            # c2c_whoami.resolve_identity() doesn't check this env var, so we do it
            # explicitly before falling back to file-based session discovery.
            mcp_sid = os.environ.get("C2C_MCP_SESSION_ID", "").strip()
            registration = None
            if mcp_sid:
                registry_path = broker_root / "registry.json"
                registrations = c2c_mcp.load_broker_registrations(registry_path)
                registration = next(
                    (r for r in registrations if r.get("session_id") == mcp_sid), None
                )
            if registration is None:
                _, registration = c2c_whoami.resolve_identity(None)
            result["resolved"] = True

            if registration:
                result["registered"] = True
                result["alias"] = registration.get("alias")
                result["session_id"] = registration.get("session_id")

        # Check inbox
        sid = result["session_id"]
        if sid:
            inbox_path = broker_root / f"{sid}.inbox.json"
            result["inbox_exists"] = inbox_path.exists()

            if inbox_path.exists():
                try:
                    current = json.loads(inbox_path.read_text())
                    inbox_path.write_text(json.dumps(current))
                    result["inbox_writable"] = True
                    if isinstance(current, list):
                        result["inbox_pending"] = len(current)
                except Exception:
                    pass
    except Exception:
        pass

    return result


def check_rooms(broker_root: Path) -> dict[str, Any]:
    """Check rooms directory health."""
    rooms_dir = broker_root / "rooms"
    result = {
        "path": str(rooms_dir),
        "exists": rooms_dir.exists(),
        "room_count": 0,
    }

    if rooms_dir.exists():
        try:
            rooms = [d for d in rooms_dir.iterdir() if d.is_dir()]
            result["room_count"] = len(rooms)
        except Exception:
            pass

    return result


def check_swarm_lounge(broker_root: Path, alias: str | None) -> dict[str, Any]:
    """Check whether the current agent is a member of swarm-lounge."""
    lounge_dir = broker_root / "rooms" / "swarm-lounge"
    result: dict[str, Any] = {
        "room_exists": lounge_dir.exists(),
        "member": False,
        "alias": alias,
    }
    if not alias:
        return result
    if lounge_dir.exists():
        members_file = lounge_dir / "members.json"
        if members_file.exists():
            try:
                members = json.loads(members_file.read_text(encoding="utf-8"))
                result["member"] = any(m.get("alias") == alias for m in members)
            except Exception:
                pass
    return result


def check_claude_mcp(home: Path | None = None) -> dict[str, Any]:
    """Check whether Claude Code MCP config includes c2c server."""
    home = home or Path.home()
    claude_json = home / ".claude.json"
    result: dict[str, Any] = {
        "path": str(claude_json),
        "exists": claude_json.exists(),
        "has_c2c_server": False,
    }
    if claude_json.exists():
        try:
            data = json.loads(claude_json.read_text(encoding="utf-8"))
            result["has_c2c_server"] = "c2c" in data.get("mcpServers", {})
        except Exception:
            pass
    result["ok"] = result["exists"] and result["has_c2c_server"]
    return result


def check_claude_wake_daemon(session_id: str | None) -> dict[str, Any]:
    """Check whether a c2c_claude_wake_daemon is running for the session."""
    result: dict[str, Any] = {"checked": False, "running": False, "pid": None}
    if not session_id:
        return result
    result["checked"] = True
    try:
        proc = subprocess.run(
            ["pgrep", "-a", "-f", r"c2c_claude_wake_daemon.py"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        for line in proc.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            pid_str, cmdline = parts
            if session_id in cmdline:
                result["running"] = True
                result["pid"] = int(pid_str)
                break
    except (OSError, subprocess.TimeoutExpired):
        pass
    return result


def check_deliver_daemon(session_id: str | None) -> dict[str, Any]:
    """Check whether a c2c_deliver_inbox.py notify daemon is running for the session."""
    result: dict[str, Any] = {"checked": False, "running": False, "pid": None}
    if not session_id:
        return result
    result["checked"] = True
    try:
        proc = subprocess.run(
            ["pgrep", "-a", "-f", r"c2c_deliver_inbox.py"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        for line in proc.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            pid_str, cmdline = parts
            if session_id in cmdline:
                result["running"] = True
                result["pid"] = int(pid_str)
                break
    except (OSError, subprocess.TimeoutExpired):
        pass
    return result


def check_hook(home: Path | None = None) -> dict[str, Any]:
    """Check whether the Claude Code PostToolUse inbox hook is installed."""
    home = home or Path.home()
    hook_path = home / ".claude" / "hooks" / "c2c-inbox-check.sh"
    settings_path = home / ".claude" / "settings.json"
    result: dict[str, Any] = {
        "hook_exists": hook_path.exists(),
        "hook_executable": False,
        "hook_path": str(hook_path),
        "settings_registered": False,
        "settings_path": str(settings_path),
    }
    if hook_path.exists():
        result["hook_executable"] = os.access(hook_path, os.X_OK)
    if settings_path.exists():
        try:
            settings = json.loads(settings_path.read_text(encoding="utf-8"))
            hooks = settings.get("hooks", {})
            # Accept list or dict values per settings format
            post_tool = hooks.get("PostToolUse", [])
            if isinstance(post_tool, dict):
                post_tool = list(post_tool.values())
            result["settings_registered"] = any(
                "c2c" in str(h).lower() for h in post_tool
            )
        except Exception:
            pass
    result["ok"] = result["hook_exists"] and result["hook_executable"] and result["settings_registered"]
    return result


def check_dead_letter(broker_root: Path) -> dict[str, Any]:
    """Check dead-letter.jsonl for pending undelivered messages."""
    path = broker_root / "dead-letter.jsonl"
    result: dict[str, Any] = {
        "exists": path.exists(),
        "count": 0,
        "oldest_age_seconds": None,
        "sessions": [],
    }
    if not path.exists():
        return result
    now = time.time()
    oldest: float | None = None
    sessions: set[str] = set()
    count = 0
    try:
        with path.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                    count += 1
                    ts = record.get("deleted_at")
                    if isinstance(ts, (int, float)) and (oldest is None or ts < oldest):
                        oldest = ts
                    sid = record.get("from_session_id")
                    if sid:
                        sessions.add(sid)
                except (json.JSONDecodeError, KeyError):
                    pass
    except OSError:
        return result
    result["count"] = count
    result["sessions"] = sorted(sessions)
    if oldest is not None:
        result["oldest_age_seconds"] = now - oldest
    return result


def check_stale_inboxes(broker_root: Path, threshold: int = 5) -> dict[str, Any]:
    """Scan *.inbox.json files and report sessions with queued messages.

    Returns live registered inboxes with >= threshold messages in ``stale`` and
    dead/unregistered inbox artifacts in ``inactive_stale``. Both count toward
    ``total_pending`` so operators still see retained broker data, but only live
    sessions are treated as actionable wake targets.
    """
    mcp_dir = broker_root
    stale: list[dict] = []
    inactive_stale: list[dict] = []
    total_pending = 0
    inactive_pending = 0
    below_threshold_pending = 0
    below_threshold_inbox_count = 0

    # Build alias lookup from registry for friendlier output
    alias_by_sid: dict[str, str] = {}
    alive_by_sid: dict[str, bool | None] = {}
    duplicate_group_by_sid: dict[str, set[str]] = {}
    activity_counts = _archive_activity_counts(broker_root)
    registry_path = broker_root / "registry.json"
    registry_exists = registry_path.exists()
    if registry_exists:
        try:
            regs = json.loads(registry_path.read_text(encoding="utf-8"))
            pid_to_sids: dict[int, set[str]] = {}
            for reg in regs if isinstance(regs, list) else []:
                sid = reg.get("session_id") or ""
                alias = reg.get("alias") or ""
                if sid and alias:
                    alias_by_sid[sid] = alias
                    alive_by_sid[sid] = c2c_mcp.broker_registration_is_alive(reg)
                    pid = reg.get("pid")
                    if isinstance(pid, int):
                        pid_to_sids.setdefault(pid, set()).add(sid)
            for group in pid_to_sids.values():
                if len(group) > 1:
                    for sid in group:
                        duplicate_group_by_sid[sid] = group
        except (json.JSONDecodeError, OSError):
            pass

    for inbox_path in sorted(mcp_dir.glob("*.inbox.json")):
        # Strip ".inbox" from "session_id.inbox.json" → session_id
        name = inbox_path.name  # e.g. "abc.inbox.json"
        if name.endswith(".inbox.json"):
            session_id = name[: -len(".inbox.json")]
        else:
            session_id = inbox_path.stem
        try:
            msgs = json.loads(inbox_path.read_text(encoding="utf-8"))
            count = len(msgs) if isinstance(msgs, list) else 0
        except (json.JSONDecodeError, OSError):
            count = 0
        total_pending += count
        if 0 < count < threshold:
            below_threshold_pending += count
            below_threshold_inbox_count += 1
        elif count >= threshold:
            entry = {
                "session_id": session_id,
                "alias": alias_by_sid.get(session_id, session_id),
                "count": count,
                "alive": alive_by_sid.get(session_id),
            }
            duplicate_group = duplicate_group_by_sid.get(session_id, set())
            entry_activity = (
                activity_counts.get(session_id, 0)
                + activity_counts.get(entry["alias"], 0)
            )
            sibling_has_activity = any(
                activity_counts.get(sid, 0)
                + activity_counts.get(alias_by_sid.get(sid, sid), 0)
                > 0
                for sid in duplicate_group
                if sid != session_id
            )
            duplicate_zero_activity_ghost = (
                bool(duplicate_group)
                and entry_activity == 0
                and sibling_has_activity
            )
            # Isolated/legacy broker roots may have no registry file at all. In
            # that case preserve the old behavior and surface thresholded
            # inboxes as actionable stale work; once a registry exists, absent
            # or dead rows are inactive artifacts rather than wake targets.
            if (
                not duplicate_zero_activity_ghost
                and (entry["alive"] is True or (entry["alive"] is None and not registry_exists))
            ):
                stale.append(entry)
            else:
                inactive_stale.append(entry)
                inactive_pending += count

    return {
        "stale": stale,
        "inactive_stale": inactive_stale,
        "total_pending": total_pending,
        "inactive_pending": inactive_pending,
        "below_threshold_pending": below_threshold_pending,
        "below_threshold_inbox_count": below_threshold_inbox_count,
        "threshold": threshold,
    }


def check_outer_loops() -> dict[str, Any]:
    """Check which managed-harness outer restart loops are running.

    Outer loops run persistently and relaunch managed client sessions
    (kimi, codex, opencode, crush, claude) between iterations.  When a
    managed session's PID is dead but its outer loop is alive, the session
    will re-register in seconds — calling sweep now would be a footgun.

    Returns:
    - running: list of {client, pid, cmdline} for each live outer loop
    - safe_to_sweep: True only if no outer loops are running
    """
    result: dict[str, Any] = {"running": [], "safe_to_sweep": True}
    import re as _re
    _outer_pattern = _re.compile(r"run-(kimi|codex|opencode|crush|claude)-inst-outer")
    try:
        out = subprocess.run(
            ["pgrep", "-a", "-f", r"run-(kimi|codex|opencode|crush|claude)-inst-outer"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        for line in out.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            pid_str, cmdline = parts
            # Only count processes where the outer-loop script IS the Python
            # script being run (first non-python token), not child processes
            # that merely mention it in their resume prompt arguments.
            tokens = cmdline.split()
            script_token = ""
            for tok in tokens:
                if tok not in ("python3", "python", "python2"):
                    script_token = tok
                    break
            m = _outer_pattern.search(script_token)
            if not m:
                continue
            client = m.group(1)
            # Extract the instance name — first positional arg after the script
            script_idx = tokens.index(script_token) if script_token in tokens else -1
            instance = tokens[script_idx + 1] if script_idx >= 0 and script_idx + 1 < len(tokens) else ""
            result["running"].append({"client": client, "pid": int(pid_str), "instance": instance, "cmdline": cmdline})
    except (OSError, subprocess.TimeoutExpired):
        pass
    result["safe_to_sweep"] = len(result["running"]) == 0
    return result


def check_wire_daemon(session_id: str | None) -> dict[str, Any]:
    """Check if a wire bridge daemon is running for the given session."""
    result: dict[str, Any] = {"checked": False}
    if not session_id:
        return result

    result["checked"] = True
    result["session_id"] = session_id

    try:
        import c2c_wire_daemon as wd
        status = wd._daemon_status(session_id)
        result["running"] = status["running"]
        result["pid"] = status.get("pid")
        result["pidfile"] = status.get("pidfile")
    except Exception as exc:
        result["running"] = False
        result["error"] = str(exc)

    # Fallback: scan running processes for a wire bridge with this session_id
    # in its command line. This catches daemons started with legacy or
    # mismatched pidfile names (e.g. alias drift after a rename).
    if not result.get("running"):
        try:
            proc = subprocess.run(
                ["pgrep", "-a", "-f", r"c2c_kimi_wire_bridge.py"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            for line in proc.stdout.splitlines():
                parts = line.split(None, 1)
                if len(parts) < 2:
                    continue
                pid_str, cmdline = parts
                if f"--session-id {session_id}" in cmdline:
                    result["running"] = True
                    result["pid"] = int(pid_str)
                    result["fallback"] = "pgrep"
                    break
        except (OSError, subprocess.TimeoutExpired):
            pass

    return result


def check_broker_binary() -> dict[str, Any]:
    """Check OCaml MCP broker binary: existence, freshness, and source version."""
    import re

    result: dict[str, Any] = {"exists": False, "fresh": False}
    try:
        server_path = c2c_mcp.built_server_path()
        result["path"] = str(server_path)
        result["exists"] = server_path.exists()
        if result["exists"]:
            result["mtime"] = server_path.stat().st_mtime
            result["fresh"] = c2c_mcp.server_is_fresh(server_path)
    except Exception as exc:
        result["error"] = str(exc)
        return result

    # Read server_version from OCaml source (the source version, not necessarily
    # the running binary version — verify with binary freshness).
    try:
        ml_path = Path(__file__).resolve().parent / "ocaml" / "c2c_mcp.ml"
        if ml_path.exists():
            for line in ml_path.read_text(encoding="utf-8").splitlines():
                m = re.match(r'^let server_version = "(.+)"', line.strip())
                if m:
                    result["source_version"] = m.group(1)
                    break
    except Exception:
        pass

    return result


def check_relay(broker_root: Path) -> dict[str, Any]:
    """Check relay server connectivity (if configured)."""
    result: dict[str, Any] = {"configured": False}
    try:
        from c2c_relay_config import load_config
        cfg = load_config(broker_root / "relay.json")
        if not cfg.get("url"):
            cfg = load_config()  # fall back to user-level config
    except Exception:
        return result

    url = cfg.get("url", "").strip()
    if not url:
        return result

    result["configured"] = True
    result["url"] = url

    try:
        from c2c_relay_connector import RelayClient
        token = cfg.get("token") or None
        client = RelayClient(url, token=token, timeout=3.0)
        health = client.health()
        result["reachable"] = bool(health.get("ok"))
        if result["reachable"]:
            peers = client.list_peers()
            result["alive_peers"] = len(peers)
    except Exception as exc:
        result["reachable"] = False
        result["error"] = str(exc)

    return result


def check_tmp_space(tmp_dir: Path = Path("/tmp")) -> dict[str, Any]:
    """Check /tmp available space and count stale .fea*.so files.

    The .fea*.so files are fonttools temporary native-library extractions that
    accumulate in /tmp and can exhaust disk quota, breaking all shell commands.
    """
    import glob as _glob

    result: dict[str, Any] = {"checked": True, "tmp_dir": str(tmp_dir)}
    try:
        st = os.statvfs(tmp_dir)
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        used = total - free
        result["total_bytes"] = total
        result["free_bytes"] = free
        result["used_bytes"] = used
        result["free_gb"] = round(free / 1e9, 1)
        result["used_pct"] = round(used / total * 100, 1) if total > 0 else 0.0
        result["low"] = free < 2 * 1024 ** 3  # warn below 2 GB
    except OSError as exc:
        result["checked"] = False
        result["error"] = str(exc)
        return result

    # Count stale .fea*.so files (fonttools temporary shared-object extractions
    # are the primary source of /tmp quota exhaustion in this repo's environment).
    try:
        fea_files = _glob.glob(str(tmp_dir / ".fea*.so"))
        result["fea_so_count"] = len(fea_files)
        result["fea_so_bytes"] = sum(
            Path(f).stat().st_size for f in fea_files if Path(f).exists()
        )
    except OSError:
        result["fea_so_count"] = 0
        result["fea_so_bytes"] = 0

    return result


def check_instances() -> dict[str, Any]:
    """Check running c2c managed instances (via c2c_start.list_instances())."""
    result: dict[str, Any] = {"checked": True, "instances": [], "alive_count": 0}
    try:
        import c2c_start

        instances = c2c_start.list_instances()
        result["instances"] = instances
        result["alive_count"] = sum(1 for inst in instances if inst.get("outer_alive"))
        result["total_count"] = len(instances)
    except Exception as exc:
        result["checked"] = False
        result["error"] = str(exc)
    return result


def run_health_check(broker_root: Path, session_id: str | None = None) -> dict[str, Any]:
    """Run full health check."""
    session = check_session(broker_root, session_id=session_id)
    effective_session_id = session_id or session.get("session_id")
    return {
        "ok": True,
        "broker_root": check_broker_root(broker_root),
        "registry": check_registry(broker_root),
        "session": session,
        "rooms": check_rooms(broker_root),
        "hook": check_hook(),
        "claude_mcp": check_claude_mcp(),
        "claude_wake_daemon": check_claude_wake_daemon(effective_session_id),
        "deliver_daemon": check_deliver_daemon(effective_session_id),
        "swarm_lounge": check_swarm_lounge(broker_root, session.get("alias")),
        "dead_letter": check_dead_letter(broker_root),
        "stale_inboxes": check_stale_inboxes(broker_root),
        "outer_loops": check_outer_loops(),
        "wire_daemon": check_wire_daemon(effective_session_id),
        "relay": check_relay(broker_root),
        "broker_binary": check_broker_binary(),
        "tmp_space": check_tmp_space(),
        "instances": check_instances(),
    }


def print_health_report(report: dict[str, Any]) -> None:
    """Print human-readable health report."""
    print("c2c Health Check")
    print("=" * 50)

    # Broker root
    br = report["broker_root"]
    status = "✓" if br["exists"] and br["writable"] else "✗"
    print(f"{status} Broker root: {br['path']}")
    if not br["exists"]:
        print("    Directory does not exist (will be created on first use)")
    elif not br["writable"]:
        print("    ERROR: Directory not writable!")

    # Registry
    reg = report["registry"]
    status = "✓" if reg["readable"] else "✗"
    print(f"{status} Registry: {reg['entry_count']} peers registered")
    if not reg["exists"]:
        print("    Registry does not exist (will be created on first register)")
    for dup in reg.get("duplicate_pids", []):
        aliases_str = ", ".join(dup["aliases"])
        likely_stale = dup.get("likely_stale_aliases", [])
        suffix = (
            f" Likely stale: {', '.join(likely_stale)}."
            if likely_stale
            else " One may be a stale ghost registration."
        )
        print(f"~ Duplicate PID {dup['pid']}: {aliases_str} share the same process.{suffix}")

    # Session
    sess = report["session"]
    if sess["resolved"]:
        if sess["registered"]:
            print(f"✓ Session: {sess['alias']} ({sess['session_id'][:8]}...)")
            inbox_status = "✓" if sess["inbox_writable"] else "✗"
            pending = sess.get("inbox_pending", 0)
            pending_str = f" ({pending} pending)" if pending else " (empty)"
            print(
                f"{inbox_status} Inbox: {'writable' if sess['inbox_writable'] else 'NOT writable'}"
                + (pending_str if sess["inbox_writable"] else "")
            )
        else:
            if sess.get("operator_check"):
                print(f"✗ Session: session_id not found in registry")
            else:
                print("✗ Session: not registered")
                print("    Run: c2c register <session-id>")
    else:
        if sess.get("operator_check"):
            print("✗ Session: could not look up session")
        else:
            print("○ Session: no agent context (run inside Claude/Codex/OpenCode/Kimi for session check)")
            print("    Tip: c2c health --session-id <id>  to check a specific session")

    # Rooms
    rooms = report["rooms"]
    if rooms["exists"]:
        print(f"✓ Rooms: {rooms['room_count']} room(s) available")
    else:
        print("○ Rooms: directory not created yet")

    # swarm-lounge membership
    sl = report.get("swarm_lounge", {})
    if sl.get("member"):
        print("✓ swarm-lounge: member")
    elif sl.get("room_exists") and sl.get("alias"):
        alias_hint = sl.get("alias") or "your-alias"
        print(f"~ swarm-lounge: room exists but {alias_hint!r} is not a member")
        print(f'    Run: c2c room join swarm-lounge  (or call mcp__c2c__join_room {{room_id:swarm-lounge, alias:{alias_hint!r}}})')
    elif sl.get("room_exists"):
        print("~ swarm-lounge: room exists (register first to check membership)")
    else:
        print("○ swarm-lounge: room not created yet")
        print("    It will be created when the first agent joins")

    # PostToolUse hook (Claude Code only)
    hook = report.get("hook", {})
    if hook.get("hook_exists"):
        if hook.get("settings_registered"):
            print("✓ PostToolUse hook: installed and registered (Claude Code auto-delivery active)")
        else:
            print("~ PostToolUse hook: script found but not in settings.json")
            print(f"    Run: c2c setup claude-code")
    else:
        print("○ PostToolUse hook: not installed (Claude Code only, optional)")
        print(f"    Run: c2c setup claude-code  to enable auto-delivery")

    # Claude Code MCP config
    mcp = report.get("claude_mcp", {})
    if mcp.get("has_c2c_server"):
        print("✓ Claude Code MCP: c2c server configured in ~/.claude.json")
    elif mcp.get("exists"):
        print("~ Claude Code MCP: ~/.claude.json exists but has no c2c server entry")
        print("    Run: c2c setup claude-code")
    else:
        print("○ Claude Code MCP: ~/.claude.json not found")
        print("    Run: c2c setup claude-code")

    # Claude Code wake daemon
    cwd = report.get("claude_wake_daemon", {})
    if cwd.get("checked"):
        if cwd.get("running"):
            print(f"✓ Claude wake daemon: running (pid {cwd['pid']})")
        else:
            sid = report.get("session", {}).get("session_id", "")
            print("~ Claude wake daemon: not running")
            print(f"    Run: nohup c2c-claude-wake --claude-session {sid} &")

    # Deliver daemon (Kimi / OpenCode / Codex / Crush auto-delivery).
    # Skip the warning for Claude Code sessions that have the PostToolUse hook
    # active — the hook already handles auto-delivery, so the daemon is redundant.
    dd = report.get("deliver_daemon", {})
    hook_active = report.get("hook", {}).get("settings_registered", False)
    if dd.get("checked"):
        if dd.get("running"):
            print(f"✓ Deliver daemon: running (pid {dd['pid']})")
        elif hook_active:
            pass  # PostToolUse hook covers Claude Code; no daemon needed
        else:
            sid = report.get("session", {}).get("session_id", "")
            alias = report.get("session", {}).get("alias", "")
            print("~ Deliver daemon: not running")
            print(f"    Run: python3 c2c_deliver_inbox.py --client <client> --session-id {sid} --notify-only --loop &")
            if alias:
                print(f"    Or rearm via your outer-loop helper (e.g. run-kimi-inst-rearm {alias})")

    # Dead-letter
    dl = report.get("dead_letter", {})
    dl_count = dl.get("count", 0)
    if dl_count == 0:
        print("✓ Dead-letter: empty (no undelivered messages)")
    else:
        age = dl.get("oldest_age_seconds")
        age_str = f", oldest {int(age)}s ago" if age is not None else ""
        sessions_str = ", ".join(dl.get("sessions", []))
        print(f"~ Dead-letter: {dl_count} message(s) pending{age_str}")
        if sessions_str:
            print(f"    Sessions with queued messages: {sessions_str}")
        print("    Messages auto-redeliver when the session re-registers.")
        print("    To inspect: cat .git/c2c/mcp/dead-letter.jsonl")

    # Stale inboxes
    si = report.get("stale_inboxes", {})
    stale = si.get("stale", [])
    inactive_stale = si.get("inactive_stale", [])
    total_pending = si.get("total_pending", 0)
    inactive_pending = si.get("inactive_pending", 0)
    below_threshold_pending = si.get("below_threshold_pending", 0)
    below_threshold_inbox_count = si.get("below_threshold_inbox_count", 0)
    threshold = si.get("threshold", 5)

    def print_below_threshold_summary() -> None:
        if below_threshold_pending > 0:
            print(
                f"    {below_threshold_pending} additional message(s) queued "
                f"below threshold in {below_threshold_inbox_count} inbox(es)"
            )

    if stale:
        print(f"~ Stale inboxes: {len(stale)} session(s) with >={threshold} messages pending (total {total_pending})")
        for entry in stale:
            print(f"    {entry['alias']}: {entry['count']} pending (not draining inbox)")
        if not inactive_stale:
            print_below_threshold_summary()
        if inactive_stale:
            print(
                f"~ Inactive inbox artifacts: {len(inactive_stale)} session(s) "
                f"with >={threshold} messages pending (inactive total {inactive_pending})"
            )
            for entry in inactive_stale:
                print(f"    {entry['alias']}: {entry['count']} pending (inactive)")
            print_below_threshold_summary()
    elif inactive_stale:
        print(
            f"~ Inactive inbox artifacts: {len(inactive_stale)} session(s) "
            f"with >={threshold} messages pending (inactive total {inactive_pending}, total {total_pending})"
        )
        for entry in inactive_stale:
            print(f"    {entry['alias']}: {entry['count']} pending (inactive)")
        print_below_threshold_summary()
    elif total_pending > 0:
        print(f"✓ Inboxes: {total_pending} message(s) queued (<{threshold} each, nominal)")
    else:
        print("✓ Inboxes: all empty")

    # /tmp disk space
    tmp = report.get("tmp_space", {})
    if tmp.get("checked"):
        free_gb = tmp.get("free_gb", 0)
        used_pct = tmp.get("used_pct", 0)
        fea_count = tmp.get("fea_so_count", 0)
        fea_mb = round(tmp.get("fea_so_bytes", 0) / 1e6, 0)
        if tmp.get("low"):
            print(f"✗ /tmp: {free_gb}GB free ({used_pct}% used) — LOW DISK SPACE")
            if fea_count > 0:
                print(f"    {fea_count} stale .fea*.so file(s) using {fea_mb:.0f}MB — clean up with:")
                print("    find /tmp -maxdepth 1 -name '.fea*.so' -mmin +5 -delete")
        elif fea_count > 0:
            print(f"~ /tmp: {free_gb}GB free ({used_pct}% used) — {fea_count} .fea*.so file(s) ({fea_mb:.0f}MB)")
            print("    find /tmp -maxdepth 1 -name '.fea*.so' -mmin +5 -delete  to clean")
        else:
            print(f"✓ /tmp: {free_gb}GB free ({used_pct}% used)")
    elif "error" in tmp:
        print(f"○ /tmp: could not check space ({tmp['error']})")

    # Outer loops
    ol = report.get("outer_loops", {})
    running = ol.get("running", [])
    if running:
        clients = ", ".join(sorted({r["client"] for r in running}))
        print(f"~ Outer loops: {len(running)} running ({clients})")
        for r in sorted(running, key=lambda x: (x["client"], x.get("instance", ""))):
            inst = r.get("instance", "")
            label = f"{r['client']}/{inst}" if inst else r["client"]
            print(f"    [{r['pid']}] {label}")
        print("    Do NOT call c2c sweep while outer loops are active — managed")
        print("    sessions restart between iterations; sweep would drop them.")
        print("    Use c2c sweep-dryrun for a read-only cleanup preview.")
    else:
        print("✓ Outer loops: none running (safe to sweep if needed)")

    # Wire bridge daemon (relevant for Kimi sessions or if a daemon is running)
    wd = report.get("wire_daemon", {})
    if wd.get("checked"):
        sid = wd.get("session_id", "")
        alias = report.get("session", {}).get("alias", "") or ""
        is_kimi = "kimi" in alias.lower() or "kimi" in sid.lower()
        if wd.get("running"):
            print(f"✓ Wire daemon: running (pid {wd['pid']}) for {sid}")
        elif is_kimi:
            print(f"○ Wire daemon: not running for {alias or sid}")
            print(f"    Run: c2c wire-daemon start --session-id {alias or sid}")

    # Relay
    relay = report.get("relay", {})
    if relay.get("configured"):
        url = relay.get("url", "?")
        if relay.get("reachable"):
            n = relay.get("alive_peers", "?")
            print(f"✓ Relay: {url} ({n} alive peers)")
        else:
            err = relay.get("error", "unreachable")
            print(f"✗ Relay: {url} — {err}")
            print("    Run: c2c relay status  to diagnose")
    else:
        print("○ Relay: not configured (local-only; run 'c2c relay setup' to enable)")

    # Broker binary
    bb = report.get("broker_binary", {})
    if not bb.get("exists"):
        print("✗ Broker binary: not built — run: opam exec -- dune build ./ocaml/server/c2c_mcp_server.exe")
    else:
        src_ver = bb.get("source_version", "unknown")
        if bb.get("fresh"):
            print(f"✓ Broker binary: v{src_ver} (binary is up-to-date)")
        else:
            print(f"~ Broker binary: binary is STALE (source is v{src_ver} but binary predates source)")
            print("    Run: opam exec -- dune build ./ocaml/server/c2c_mcp_server.exe")
            print("    Then restart your agent session to pick up the new binary.")

    # Managed instances (c2c start)
    inst_report = report.get("instances", {})
    if inst_report.get("checked"):
        instances = inst_report.get("instances", [])
        alive_count = inst_report.get("alive_count", 0)
        total_count = inst_report.get("total_count", 0)
        if total_count == 0:
            print("○ Instances: none (use 'c2c start <client>' to launch managed sessions)")
        elif alive_count == total_count:
            print(f"✓ Instances: {alive_count}/{total_count} alive")
            for inst in instances:
                status = "↑" if inst.get("outer_alive") else "↓"
                print(f"    {status} {inst['name']} ({inst['client']}) pid={inst.get('outer_pid') or '?'}")
        else:
            print(f"~ Instances: {alive_count}/{total_count} alive")
            for inst in instances:
                status = "↑" if inst.get("outer_alive") else "↓"
                print(f"    {status} {inst['name']} ({inst['client']}) pid={inst.get('outer_pid') or '?'}")
    elif "error" in inst_report:
        print(f"○ Instances: could not check ({inst_report['error']})")

    print()

    # Overall status
    # When no agent context is available (CLI run outside an agent), don't
    # count the missing session as an issue — just assess broker health.
    no_agent_context = not sess["resolved"] and not sess.get("operator_check")
    if no_agent_context:
        healthy = br["writable"]
    else:
        healthy = br["writable"] and sess["registered"] and sess["inbox_writable"]

    if healthy:
        print("Overall: HEALTHY")
        if no_agent_context:
            print("Broker is reachable. Run inside an agent or pass --session-id to check session health.")
        else:
            print("You can send and receive c2c messages.")
    else:
        print("Overall: ISSUES DETECTED")
        print("Fix the errors above before using c2c.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Health check for c2c broker and components"
    )
    parser.add_argument(
        "--broker-root",
        type=Path,
        help="broker root directory (default: auto-detect)",
    )
    parser.add_argument(
        "--session-id",
        help="check this session_id specifically (operator mode; skips auto-detect)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="output JSON instead of human-readable text",
    )
    args = parser.parse_args(argv)

    # Resolve broker root
    if args.broker_root:
        broker_root = args.broker_root
    else:
        env_root = os.environ.get("C2C_MCP_BROKER_ROOT")
        if env_root:
            broker_root = Path(env_root)
        else:
            broker_root = Path(c2c_mcp.default_broker_root())

    report = run_health_check(broker_root, session_id=args.session_id)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_health_report(report)

    # Return 0 if healthy, 1 if issues
    sess = report["session"]
    no_agent_context = not sess["resolved"] and not sess.get("operator_check")
    if no_agent_context:
        healthy = report["broker_root"]["writable"]
    else:
        healthy = (
            report["broker_root"]["writable"]
            and sess["registered"]
            and sess["inbox_writable"]
        )

    return 0 if healthy else 1


if __name__ == "__main__":
    raise SystemExit(main())
