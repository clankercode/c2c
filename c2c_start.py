#!/usr/bin/env python3
"""Unified instance launcher for c2c-managed agent sessions.

Usage:
    c2c start <client> [-n NAME] [--detach] [-- EXTRA_ARGS...]
    c2c stop <NAME>
    c2c restart <NAME>
    c2c instances [--json]

Replaces the per-client run-*-inst-outer + run-*-inst harness scripts with a
single command that manages the outer restart loop, deliver daemon, and poker
for any client type.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import c2c_mcp

# ---------------------------------------------------------------------------
# Per-client configuration
# ---------------------------------------------------------------------------

CLIENT_CONFIGS: dict[str, dict[str, Any]] = {
    "claude": {
        "binary": "claude",
        "deliver_client": "claude",
        "needs_poker": True,
        "poker_event": "heartbeat",
        "poker_from": "claude-poker",
        "extra_env": {},
    },
    "codex": {
        "binary": "codex",
        "deliver_client": "codex",
        "needs_poker": False,
        "extra_env": {},
    },
    "opencode": {
        "binary": "opencode",
        "deliver_client": "opencode",
        "needs_poker": False,
        "extra_env": {},
    },
    "kimi": {
        "binary": "kimi",
        "deliver_client": "kimi",
        "needs_poker": True,
        "poker_event": "heartbeat",
        "poker_from": "kimi-poker",
        "extra_env": {},
    },
    "crush": {
        "binary": "crush",
        "deliver_client": "crush",
        "needs_poker": False,
        "extra_env": {},
    },
}

# ---------------------------------------------------------------------------
# State directory
# ---------------------------------------------------------------------------

INSTANCES_DIR = Path.home() / ".local" / "share" / "c2c" / "instances"
MIN_RUN_SECONDS = 10.0
RESTART_PAUSE_SECONDS = 1.5
INITIAL_BACKOFF_SECONDS = 2.0
MAX_BACKOFF_SECONDS = 60.0
DOUBLE_SIGINT_WINDOW_SECONDS = 2.0

HERE = Path(__file__).resolve().parent


def _instance_dir(name: str) -> Path:
    return INSTANCES_DIR / name


def _instance_config_path(name: str) -> Path:
    return _instance_dir(name) / "config.json"


def _outer_pid_path(name: str) -> Path:
    return _instance_dir(name) / "outer.pid"


def _deliver_pid_path(name: str) -> Path:
    return _instance_dir(name) / "deliver.pid"


def _poker_pid_path(name: str) -> Path:
    return _instance_dir(name) / "poker.pid"


def default_name(client: str) -> str:
    """Default instance name: <client>-<hostname>."""
    hostname = socket.gethostname().split(".")[0]
    return f"{client}-{hostname}"


# ---------------------------------------------------------------------------
# Instance state helpers
# ---------------------------------------------------------------------------

def _read_pid(path: Path) -> int | None:
    """Read a PID from a pidfile, return None if not found or invalid."""
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return None


def _pid_alive(pid: int | None) -> bool:
    if pid is None or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def _write_pidfile(path: Path, pid: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(pid), encoding="utf-8")


def _remove_pidfile(path: Path) -> None:
    try:
        path.unlink()
    except OSError:
        pass


def load_instance_config(name: str) -> dict[str, Any] | None:
    """Load instance config.json; return None if not found."""
    path = _instance_config_path(name)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def save_instance_config(name: str, cfg: dict[str, Any]) -> None:
    path = _instance_config_path(name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")


# ---------------------------------------------------------------------------
# Instance enumeration
# ---------------------------------------------------------------------------

def list_instances() -> list[dict[str, Any]]:
    """Enumerate all known instances under INSTANCES_DIR."""
    results = []
    if not INSTANCES_DIR.exists():
        return results
    for entry in sorted(INSTANCES_DIR.iterdir()):
        if not entry.is_dir():
            continue
        name = entry.name
        cfg = load_instance_config(name)
        if cfg is None:
            continue
        outer_pid = _read_pid(_outer_pid_path(name))
        deliver_pid = _read_pid(_deliver_pid_path(name))
        poker_pid = _read_pid(_poker_pid_path(name))
        outer_alive = _pid_alive(outer_pid)

        uptime_s: float | None = None
        if outer_alive and outer_pid:
            try:
                stat = Path(f"/proc/{outer_pid}/stat").read_text()
                # Field 22 is starttime in clock ticks since boot
                fields = stat.split()
                starttime_ticks = int(fields[21])
                hz = os.sysconf("SC_CLK_TCK")
                boot_time = float(Path("/proc/uptime").read_text().split()[0])
                start_since_boot = starttime_ticks / hz
                uptime_s = boot_time - start_since_boot
            except (OSError, IndexError, ValueError):
                created_at = cfg.get("created_at")
                if created_at is not None:
                    uptime_s = time.time() - created_at

        results.append({
            "name": name,
            "client": cfg.get("client", "?"),
            "session_id": cfg.get("session_id", name),
            "alias": cfg.get("alias", name),
            "outer_pid": outer_pid,
            "outer_alive": outer_alive,
            "deliver_pid": deliver_pid,
            "deliver_alive": _pid_alive(deliver_pid),
            "poker_pid": poker_pid,
            "poker_alive": _pid_alive(poker_pid),
            "uptime_s": uptime_s,
            "created_at": cfg.get("created_at"),
        })
    return results


# ---------------------------------------------------------------------------
# Build env for a client subprocess
# ---------------------------------------------------------------------------

def build_env(name: str, client: str, broker_root: Path) -> dict[str, str]:
    """Build environment dict for a managed client subprocess."""
    env = dict(os.environ)
    env["C2C_MCP_SESSION_ID"] = name
    env["C2C_MCP_AUTO_REGISTER_ALIAS"] = name
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
    env["C2C_MCP_AUTO_JOIN_ROOMS"] = "swarm-lounge"
    env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "0"
    # CLIENT_PID is set by the outer loop to its own PID so the broker
    # tracks the persistent durable outer PID, not the ephemeral child PID.
    # We set it later after we know the outer loop PID.
    cfg = CLIENT_CONFIGS.get(client, {})
    env.update(cfg.get("extra_env", {}))
    return env


# ---------------------------------------------------------------------------
# Outer loop (foreground)
# ---------------------------------------------------------------------------

def _find_binary(name: str) -> str | None:
    """Find a binary in PATH; return its path or None."""
    import shutil
    return shutil.which(name)


def _start_deliver_daemon(
    name: str, client: str, broker_root: Path
) -> subprocess.Popen | None:
    """Start deliver daemon in the background, return Popen or None."""
    deliver_script = HERE / "c2c_deliver_inbox.py"
    if not deliver_script.exists():
        return None
    cmd = [
        sys.executable,
        str(deliver_script),
        "--client", client,
        "--session-id", name,
        "--notify-only",
        "--loop",
        "--broker-root", str(broker_root),
    ]
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return proc
    except OSError:
        return None


def _start_poker(name: str, client: str) -> subprocess.Popen | None:
    """Start poker in the background for clients that need it."""
    cfg = CLIENT_CONFIGS.get(client, {})
    if not cfg.get("needs_poker"):
        return None
    poker_script = HERE / "c2c_poker.py"
    if not poker_script.exists():
        return None
    cmd = [
        sys.executable,
        str(poker_script),
        "--claude-session", name,
        "--interval", "600",
        "--event", cfg.get("poker_event", "heartbeat"),
    ]
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return proc
    except OSError:
        return None


def run_outer_loop(
    name: str,
    client: str,
    extra_args: list[str],
    broker_root: Path,
) -> int:
    """Run the outer restart loop for the given instance (blocking)."""
    cfg = CLIENT_CONFIGS[client]
    binary = cfg["binary"]
    binary_path = _find_binary(binary)
    if binary_path is None:
        print(f"c2c start: '{binary}' not found in PATH", file=sys.stderr)
        print(f"Install {client} first, then re-run.", file=sys.stderr)
        return 2

    inst_dir = _instance_dir(name)
    inst_dir.mkdir(parents=True, exist_ok=True)

    # Write outer loop PID so c2c stop can find us.
    _write_pidfile(_outer_pid_path(name), os.getpid())

    backoff = INITIAL_BACKOFF_SECONDS
    last_sigint = 0.0
    iteration = 0
    child_proc: subprocess.Popen | None = None
    deliver_proc: subprocess.Popen | None = None
    poker_proc: subprocess.Popen | None = None

    def _stop_sidecar(proc: subprocess.Popen | None) -> None:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    def _cleanup_and_exit(code: int) -> int:
        _stop_sidecar(deliver_proc)
        _stop_sidecar(poker_proc)
        _remove_pidfile(_outer_pid_path(name))
        _remove_pidfile(_deliver_pid_path(name))
        _remove_pidfile(_poker_pid_path(name))
        return code

    try:
        env = build_env(name, client, broker_root)
        # Pin CLIENT_PID to outer loop's PID so the broker tracks the durable PID.
        env["C2C_MCP_CLIENT_PID"] = str(os.getpid())

        while True:
            iteration += 1
            # Clean stale fonttools /tmp/.fea*.so files before each iteration.
            try:
                _n = c2c_mcp.cleanup_stale_tmp_fea_so()
                if _n:
                    print(f"[c2c-start/{name}] cleaned {_n} stale /tmp/.fea*.so file(s)", flush=True)
            except Exception:
                pass

            print(f"[c2c-start/{name}] iter {iteration}: launching {client}", flush=True)
            started = time.monotonic()
            child_proc = None
            try:
                cmd = [binary_path, *extra_args]
                child_proc = subprocess.Popen(cmd, env=env)

                # Start deliver daemon and poker on first iteration (or restart if dead).
                if deliver_proc is None or deliver_proc.poll() is not None:
                    deliver_proc = _start_deliver_daemon(name, cfg["deliver_client"], broker_root)
                    if deliver_proc is not None:
                        _write_pidfile(_deliver_pid_path(name), deliver_proc.pid)

                if poker_proc is None or poker_proc.poll() is not None:
                    poker_proc = _start_poker(name, client)
                    if poker_proc is not None:
                        _write_pidfile(_poker_pid_path(name), poker_proc.pid)

                exit_code = child_proc.wait()
            except KeyboardInterrupt:
                if child_proc is not None and child_proc.poll() is None:
                    child_proc.terminate()
                    try:
                        child_proc.wait(timeout=2.0)
                    except subprocess.TimeoutExpired:
                        child_proc.kill()
                        child_proc.wait()
                now = time.monotonic()
                if now - last_sigint < DOUBLE_SIGINT_WINDOW_SECONDS:
                    print(f"[c2c-start/{name}] double SIGINT — exiting.", flush=True)
                    return _cleanup_and_exit(130)
                last_sigint = now
                print(
                    f"[c2c-start/{name}] SIGINT received. Send again within "
                    f"{DOUBLE_SIGINT_WINDOW_SECONDS:.1f}s to exit.",
                    flush=True,
                )
                exit_code = 130

            elapsed = time.monotonic() - started
            print(
                f"[c2c-start/{name}] inner exited code={exit_code} after {elapsed:.1f}s",
                flush=True,
            )

            if elapsed < MIN_RUN_SECONDS:
                print(f"[c2c-start/{name}] fast exit — backing off {backoff:.1f}s", flush=True)
                time.sleep(backoff)
                backoff = min(backoff * 2.0, MAX_BACKOFF_SECONDS)
            else:
                backoff = INITIAL_BACKOFF_SECONDS
                print(
                    f"[c2c-start/{name}] restarting in {RESTART_PAUSE_SECONDS:.1f}s",
                    flush=True,
                )
                time.sleep(RESTART_PAUSE_SECONDS)
    except Exception as exc:
        print(f"[c2c-start/{name}] fatal error: {exc}", file=sys.stderr, flush=True)
        return _cleanup_and_exit(1)


# ---------------------------------------------------------------------------
# start / stop / restart
# ---------------------------------------------------------------------------

def cmd_start(
    client: str,
    name: str,
    extra_args: list[str],
    broker_root: Path,
    json_out: bool = False,
) -> int:
    if client not in CLIENT_CONFIGS:
        msg = f"unknown client: {client!r}. Choose from: {', '.join(sorted(CLIENT_CONFIGS))}"
        if json_out:
            print(json.dumps({"ok": False, "error": msg}))
        else:
            print(f"error: {msg}", file=sys.stderr)
        return 1

    # Check for duplicate running instance.
    pid = _read_pid(_outer_pid_path(name))
    if _pid_alive(pid):
        msg = f"instance {name!r} is already running (pid {pid}). Use 'c2c stop {name}' first."
        if json_out:
            print(json.dumps({"ok": False, "error": msg, "pid": pid}))
        else:
            print(f"error: {msg}", file=sys.stderr)
        return 1

    # Stale pidfile cleanup.
    _remove_pidfile(_outer_pid_path(name))

    # Write instance config.
    cfg = {
        "name": name,
        "client": client,
        "session_id": name,
        "alias": name,
        "extra_args": extra_args,
        "created_at": time.time(),
        "broker_root": str(broker_root),
        "auto_join_rooms": "swarm-lounge",
    }
    save_instance_config(name, cfg)

    if json_out:
        print(json.dumps({"ok": True, "name": name, "client": client}))

    return run_outer_loop(name, client, extra_args, broker_root)


def cmd_stop(name: str, json_out: bool = False) -> int:
    pid = _read_pid(_outer_pid_path(name))
    if not _pid_alive(pid):
        msg = f"instance {name!r} is not running (no live pidfile)."
        if json_out:
            print(json.dumps({"ok": False, "error": msg}))
        else:
            print(msg, file=sys.stderr)
        return 1
    assert pid is not None
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as exc:
        msg = f"failed to stop {name!r} (pid {pid}): {exc}"
        if json_out:
            print(json.dumps({"ok": False, "error": msg}))
        else:
            print(msg, file=sys.stderr)
        return 1

    # Wait up to 10s for the outer loop to clean up.
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if not _pid_alive(pid):
            break
        time.sleep(0.1)

    if json_out:
        print(json.dumps({"ok": True, "name": name, "pid": pid}))
    else:
        alive = _pid_alive(pid)
        status = "still running" if alive else "stopped"
        print(f"c2c stop: {name} {status} (pid {pid})")
    return 0


def cmd_restart(name: str, json_out: bool = False) -> int:
    cfg = load_instance_config(name)
    if cfg is None:
        msg = f"no config found for instance {name!r}"
        if json_out:
            print(json.dumps({"ok": False, "error": msg}))
        else:
            print(msg, file=sys.stderr)
        return 1
    rc = cmd_stop(name, json_out=False)
    if rc != 0:
        # Not running — that's fine, just start fresh.
        pass
    broker_root = Path(cfg.get("broker_root") or c2c_mcp.default_broker_root())
    return cmd_start(
        cfg["client"],
        name,
        cfg.get("extra_args", []),
        broker_root,
        json_out=json_out,
    )


def cmd_instances(json_out: bool = False) -> int:
    instances = list_instances()
    if json_out:
        print(json.dumps(instances, indent=2))
        return 0

    if not instances:
        print("No c2c instances found.")
        return 0

    print(f"{'NAME':<20} {'CLIENT':<10} {'STATUS':<8} {'UPTIME':<12} {'PID'}")
    print("-" * 65)
    for inst in instances:
        status = "ALIVE" if inst["outer_alive"] else "DEAD"
        uptime = ""
        if inst["uptime_s"] is not None:
            u = inst["uptime_s"]
            if u < 60:
                uptime = f"{u:.0f}s"
            elif u < 3600:
                uptime = f"{u/60:.0f}m"
            else:
                uptime = f"{u/3600:.1f}h"
        pid = str(inst["outer_pid"] or "?")
        print(
            f"{inst['name']:<20} {inst['client']:<10} {status:<8} {uptime:<12} {pid}"
        )
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Unified c2c instance launcher",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
subcommands:
  start <client> [-n NAME] [-- EXTRA...]   Launch a managed instance
  stop <NAME>                              Stop a running instance
  restart <NAME>                           Stop and restart an instance
  instances [--json]                       List all known instances
""",
    )
    parser.add_argument(
        "subcommand",
        choices=["start", "stop", "restart", "instances"],
        help="subcommand to run",
    )
    parser.add_argument("args", nargs=argparse.REMAINDER)
    parser.add_argument("--json", action="store_true", help="JSON output")
    parser.add_argument("--broker-root", type=Path, default=None)

    args = parser.parse_args(argv)
    broker_root = args.broker_root or Path(c2c_mcp.default_broker_root())
    json_out = args.json

    if args.subcommand == "instances":
        sub = argparse.ArgumentParser(prog="c2c instances")
        sub.add_argument("--json", action="store_true")
        parsed = sub.parse_args(args.args)
        return cmd_instances(json_out=json_out or parsed.json)

    if args.subcommand == "stop":
        sub = argparse.ArgumentParser(prog="c2c stop")
        sub.add_argument("name")
        sub.add_argument("--json", action="store_true")
        parsed = sub.parse_args(args.args)
        return cmd_stop(parsed.name, json_out=json_out or parsed.json)

    if args.subcommand == "restart":
        sub = argparse.ArgumentParser(prog="c2c restart")
        sub.add_argument("name")
        sub.add_argument("--json", action="store_true")
        parsed = sub.parse_args(args.args)
        return cmd_restart(parsed.name, json_out=json_out or parsed.json)

    # start
    sub = argparse.ArgumentParser(prog="c2c start")
    sub.add_argument("client", choices=list(CLIENT_CONFIGS))
    sub.add_argument("-n", "--name", default=None)
    parsed, remainder = sub.parse_known_args(args.args)
    # strip leading '--' separator if present
    if remainder and remainder[0] == "--":
        remainder = remainder[1:]
    name = parsed.name or default_name(parsed.client)
    return cmd_start(parsed.client, name, remainder, broker_root, json_out=json_out)


if __name__ == "__main__":
    raise SystemExit(main())
