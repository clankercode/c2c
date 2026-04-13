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
    }

    if registry_path.exists():
        try:
            registrations = c2c_mcp.load_broker_registrations(registry_path)
            result["readable"] = True
            result["entry_count"] = len(registrations)
        except Exception:
            pass

    return result


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
            result["running"].append({"client": client, "pid": int(pid_str), "cmdline": cmdline})
    except (OSError, subprocess.TimeoutExpired):
        pass
    result["safe_to_sweep"] = len(result["running"]) == 0
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


def run_health_check(broker_root: Path, session_id: str | None = None) -> dict[str, Any]:
    """Run full health check."""
    session = check_session(broker_root, session_id=session_id)
    return {
        "ok": True,
        "broker_root": check_broker_root(broker_root),
        "registry": check_registry(broker_root),
        "session": session,
        "rooms": check_rooms(broker_root),
        "hook": check_hook(),
        "swarm_lounge": check_swarm_lounge(broker_root, session.get("alias")),
        "dead_letter": check_dead_letter(broker_root),
        "outer_loops": check_outer_loops(),
        "relay": check_relay(broker_root),
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

    # Session
    sess = report["session"]
    if sess["resolved"]:
        if sess["registered"]:
            print(f"✓ Session: {sess['alias']} ({sess['session_id'][:8]}...)")
            inbox_status = "✓" if sess["inbox_writable"] else "✗"
            print(
                f"{inbox_status} Inbox: {'writable' if sess['inbox_writable'] else 'NOT writable'}"
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

    # Outer loops
    ol = report.get("outer_loops", {})
    running = ol.get("running", [])
    if running:
        clients = ", ".join(sorted({r["client"] for r in running}))
        print(f"~ Outer loops: {len(running)} running ({clients})")
        print("    Do NOT call c2c sweep while outer loops are active — managed")
        print("    sessions restart between iterations; sweep would drop them.")
    else:
        print("✓ Outer loops: none running (safe to sweep if needed)")

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
