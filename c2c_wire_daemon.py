#!/usr/bin/env python3
"""Manage c2c Kimi Wire bridge background daemons.

Provides start/stop/status/restart lifecycle management for wire bridge
daemons that deliver c2c broker messages through `kimi --wire`.

Standard state directory: ~/.local/share/c2c/wire-daemons/

Usage:
    c2c wire-daemon start  --session-id S [--alias A] [--interval N]
    c2c wire-daemon stop   --session-id S
    c2c wire-daemon status --session-id S [--json]
    c2c wire-daemon restart --session-id S [--alias A] [--interval N]
    c2c wire-daemon list   [--json]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent

import c2c_kimi_wire_bridge
import c2c_poll_inbox
import c2c_refresh_peer


def _state_dir() -> Path:
    xdg = os.environ.get("XDG_DATA_HOME", "").strip()
    base = Path(xdg) if xdg else Path.home() / ".local" / "share"
    return base / "c2c" / "wire-daemons"


def _pidfile(session_id: str) -> Path:
    return _state_dir() / f"{session_id}.pid"


def _logfile(session_id: str) -> Path:
    return _state_dir() / f"{session_id}.log"


def _read_pid(pidfile: Path) -> int | None:
    try:
        raw = pidfile.read_text(encoding="utf-8").strip()
        return int(raw)
    except (OSError, ValueError):
        return None


def _pid_is_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _daemon_status(session_id: str) -> dict[str, Any]:
    pidfile = _pidfile(session_id)
    pid = _read_pid(pidfile)
    if pid is None:
        return {
            "session_id": session_id,
            "running": False,
            "pid": None,
            "pidfile": str(pidfile),
        }
    alive = _pid_is_alive(pid)
    return {
        "session_id": session_id,
        "running": alive,
        "pid": pid,
        "pidfile": str(pidfile),
        "log": str(_logfile(session_id)),
    }


def _refresh_broker_registration(
    *,
    alias: str,
    session_id: str,
    pid: int,
    broker_root: Path,
) -> dict[str, Any]:
    try:
        return c2c_refresh_peer.refresh_peer(
            alias,
            pid,
            broker_root,
            session_id=session_id,
        )
    except SystemExit as exc:
        return {"status": "skipped", "error": str(exc)}


def cmd_start(args: argparse.Namespace) -> int:
    session_id = args.session_id
    alias = args.alias or session_id
    pidfile = _pidfile(session_id)
    logfile = _logfile(session_id)
    broker_root = Path(args.broker_root) if args.broker_root else Path(
        c2c_poll_inbox.default_broker_root()
    )

    child_argv = [
        "--session-id", session_id,
        "--alias", alias,
        "--broker-root", str(broker_root),
        "--loop",
        "--interval", str(args.interval),
        "--pidfile", str(pidfile),
    ]
    if args.command:
        child_argv += ["--command", args.command]

    result = c2c_kimi_wire_bridge.start_daemon(
        child_argv=child_argv,
        pidfile=pidfile,
        log_path=logfile,
        wait_timeout=args.timeout,
    )
    daemon_pid = result.get("pid")
    if result.get("ok") and isinstance(daemon_pid, int):
        result["registration_refresh"] = _refresh_broker_registration(
            alias=alias,
            session_id=session_id,
            pid=daemon_pid,
            broker_root=broker_root,
        )

    if args.json:
        print(json.dumps(result))
    else:
        if result.get("already_running"):
            print(f"[wire-daemon] already running for {session_id} (pid {result['pid']})")
        elif result.get("ok"):
            print(f"[wire-daemon] started for {session_id} (pid {result['pid']})")
            print(f"  log:     {logfile}")
            print(f"  pidfile: {pidfile}")
        else:
            print(
                f"[wire-daemon] start failed for {session_id}: {result.get('error', result)}",
                file=sys.stderr,
            )
    return 0 if result.get("ok") else 1


def cmd_stop(args: argparse.Namespace) -> int:
    import signal

    session_id = args.session_id
    pidfile = _pidfile(session_id)
    pid = _read_pid(pidfile)

    if pid is None:
        if args.json:
            print(json.dumps({"session_id": session_id, "stopped": False, "reason": "no_pidfile"}))
        else:
            print(f"[wire-daemon] not running for {session_id} (no pidfile)")
        return 0

    if not _pid_is_alive(pid):
        pidfile.unlink(missing_ok=True)
        if args.json:
            print(json.dumps({"session_id": session_id, "stopped": False, "reason": "already_dead", "pid": pid}))
        else:
            print(f"[wire-daemon] not running for {session_id} (pid {pid} already dead)")
        return 0

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    pidfile.unlink(missing_ok=True)

    if args.json:
        print(json.dumps({"session_id": session_id, "stopped": True, "pid": pid}))
    else:
        print(f"[wire-daemon] stopped for {session_id} (sent SIGTERM to pid {pid})")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    status = _daemon_status(args.session_id)
    if args.json:
        print(json.dumps(status))
    else:
        running = status["running"]
        pid = status["pid"]
        if running:
            print(f"[wire-daemon] running for {args.session_id} (pid {pid})")
        elif pid is not None:
            print(f"[wire-daemon] stale pidfile for {args.session_id} (pid {pid} dead)")
        else:
            print(f"[wire-daemon] not running for {args.session_id}")
    return 0


def cmd_restart(args: argparse.Namespace) -> int:
    cmd_stop(args)
    return cmd_start(args)


def cmd_list(args: argparse.Namespace) -> int:
    state_dir = _state_dir()
    if not state_dir.exists():
        if args.json:
            print(json.dumps([]))
        else:
            print("[wire-daemon] no daemons found (state dir does not exist)")
        return 0

    statuses = []
    for pidfile in sorted(state_dir.glob("*.pid")):
        session_id = pidfile.stem
        statuses.append(_daemon_status(session_id))

    if args.json:
        print(json.dumps(statuses))
    else:
        if not statuses:
            print("[wire-daemon] no daemons found")
        else:
            for s in statuses:
                mark = "●" if s["running"] else "○"
                pid_str = f"pid {s['pid']}" if s["pid"] else "no pid"
                print(f"  {mark} {s['session_id']}  ({pid_str})")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Manage c2c Kimi Wire bridge background daemons."
    )
    sub = parser.add_subparsers(dest="subcommand")

    # --- start ---
    p_start = sub.add_parser("start", help="start wire bridge daemon")
    p_start.add_argument("--session-id", required=True)
    p_start.add_argument("--alias", default=None)
    p_start.add_argument("--broker-root", default=None)
    p_start.add_argument("--interval", type=float, default=5.0)
    p_start.add_argument("--command", default=None, help="kimi binary (default: kimi)")
    p_start.add_argument("--timeout", type=float, default=5.0,
                         help="seconds to wait for daemon startup (default: 5)")
    p_start.add_argument("--json", action="store_true")

    # --- stop ---
    p_stop = sub.add_parser("stop", help="stop wire bridge daemon")
    p_stop.add_argument("--session-id", required=True)
    p_stop.add_argument("--json", action="store_true")

    # --- status ---
    p_status = sub.add_parser("status", help="show daemon status")
    p_status.add_argument("--session-id", required=True)
    p_status.add_argument("--json", action="store_true")

    # --- restart ---
    p_restart = sub.add_parser("restart", help="stop then start daemon")
    p_restart.add_argument("--session-id", required=True)
    p_restart.add_argument("--alias", default=None)
    p_restart.add_argument("--broker-root", default=None)
    p_restart.add_argument("--interval", type=float, default=5.0)
    p_restart.add_argument("--command", default=None)
    p_restart.add_argument("--timeout", type=float, default=5.0)
    p_restart.add_argument("--json", action="store_true")

    # --- list ---
    p_list = sub.add_parser("list", help="list all known wire bridge daemons")
    p_list.add_argument("--json", action="store_true")

    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    if args.subcommand == "start":
        return cmd_start(args)
    if args.subcommand == "stop":
        return cmd_stop(args)
    if args.subcommand == "status":
        return cmd_status(args)
    if args.subcommand == "restart":
        return cmd_restart(args)
    if args.subcommand == "list":
        return cmd_list(args)

    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
