#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import c2c_inject
import c2c_poll_inbox
import c2c_poker


def peek_inbox(broker_root: Path, session_id: str) -> list[dict[str, Any]]:
    path = c2c_poll_inbox.inbox_path(broker_root, session_id)
    with c2c_poll_inbox.inbox_lock(broker_root, session_id):
        if not path.exists():
            return []
        raw = path.read_text(encoding="utf-8").strip()
        if not raw:
            return []
        loaded = json.loads(raw)
        if not isinstance(loaded, list):
            raise ValueError(f"inbox is not a JSON list: {path}")
        return [item for item in loaded if isinstance(item, dict)]


def message_payload(message: dict[str, Any]) -> str:
    content = str(message.get("content", ""))
    sender = str(message.get("from_alias", "") or "c2c")
    alias = str(message.get("to_alias", "") or "")
    return c2c_poker.render_payload(
        content, event="message", sender=sender, alias=alias, raw=False
    )


def build_result(
    *,
    session_id: str,
    broker_root: Path,
    source: str,
    client: str,
    terminal_pid: int,
    pts: str,
    messages: list[dict[str, Any]],
    dry_run: bool,
) -> dict[str, Any]:
    return {
        "ok": True,
        "session_id": session_id,
        "broker_root": str(broker_root),
        "source": source,
        "target": {"client": client, "terminal_pid": terminal_pid, "pts": pts},
        "messages": messages,
        "delivered": 0 if dry_run else len(messages),
        "dry_run": dry_run,
        "sent_at": time.time(),
    }


def write_pidfile(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"{os.getpid()}\n", encoding="utf-8")


def read_pidfile(path: Path) -> int | None:
    try:
        raw = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def pid_is_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def start_daemon(
    *,
    child_argv: list[str],
    pidfile: Path,
    log_path: Path,
    wait_timeout: float,
) -> dict[str, Any]:
    existing_pid = read_pidfile(pidfile)
    if existing_pid is not None and pid_is_alive(existing_pid):
        return {
            "ok": True,
            "daemon": True,
            "already_running": True,
            "pid": existing_pid,
            "pidfile": str(pidfile),
            "log_path": str(log_path),
        }
    if pidfile.exists():
        pidfile.unlink()

    pidfile.parent.mkdir(parents=True, exist_ok=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, str(Path(__file__).resolve()), *child_argv]
    with log_path.open("ab") as log:
        proc = subprocess.Popen(
            command,
            cwd=Path(__file__).resolve().parent,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            close_fds=True,
            start_new_session=True,
        )

    deadline = time.monotonic() + wait_timeout
    while time.monotonic() < deadline:
        written_pid = read_pidfile(pidfile)
        if written_pid is not None:
            return {
                "ok": True,
                "daemon": True,
                "already_running": False,
                "pid": written_pid,
                "process_pid": proc.pid,
                "pidfile": str(pidfile),
                "log_path": str(log_path),
            }
        returncode = proc.poll()
        if returncode is not None:
            return {
                "ok": False,
                "daemon": True,
                "already_running": False,
                "pid": proc.pid,
                "returncode": returncode,
                "pidfile": str(pidfile),
                "log_path": str(log_path),
                "error": "daemon exited before writing pidfile",
            }
        time.sleep(0.1)

    return {
        "ok": proc.poll() is None,
        "daemon": True,
        "already_running": False,
        "pid": proc.pid,
        "pidfile": str(pidfile),
        "log_path": str(log_path),
        "pidfile_written": False,
        "warning": "daemon did not write pidfile before timeout",
    }


def strip_daemon_args(argv: list[str]) -> list[str]:
    result: list[str] = []
    skip_next = False
    value_options = {"--daemon-log", "--daemon-timeout"}
    for item in argv:
        if skip_next:
            skip_next = False
            continue
        if item == "--daemon":
            continue
        if item in value_options:
            skip_next = True
            continue
        if any(item.startswith(f"{option}=") for option in value_options):
            continue
        result.append(item)
    return result


def deliver_once(
    *,
    session_id: str,
    broker_root: Path,
    client: str,
    terminal_pid: int,
    pts: str,
    dry_run: bool,
    timeout: float,
    file_fallback: bool,
) -> dict[str, Any]:
    if dry_run:
        source = "peek"
        messages = peek_inbox(broker_root, session_id)
    else:
        source, messages = c2c_poll_inbox.poll_inbox(
            broker_root=broker_root,
            session_id=session_id,
            timeout=timeout,
            force_file=file_fallback,
            allow_file_fallback=True,
        )
        for message in messages:
            c2c_poker.inject(terminal_pid, pts, message_payload(message))

    return build_result(
        session_id=session_id,
        broker_root=broker_root,
        source=source,
        client=client,
        terminal_pid=terminal_pid,
        pts=pts,
        messages=messages,
        dry_run=dry_run,
    )


def run_loop(
    *,
    session_id: str,
    broker_root: Path,
    client: str,
    terminal_pid: int,
    pts: str,
    dry_run: bool,
    timeout: float,
    file_fallback: bool,
    interval: float,
    max_iterations: int | None,
) -> dict[str, Any]:
    iterations = 0
    total_delivered = 0
    last_result: dict[str, Any] | None = None

    while max_iterations is None or iterations < max_iterations:
        iterations += 1
        last_result = deliver_once(
            session_id=session_id,
            broker_root=broker_root,
            client=client,
            terminal_pid=terminal_pid,
            pts=pts,
            dry_run=dry_run,
            timeout=timeout,
            file_fallback=file_fallback,
        )
        total_delivered += int(last_result.get("delivered", 0))
        if max_iterations is not None and iterations >= max_iterations:
            break
        time.sleep(interval)

    return {
        "ok": True,
        "session_id": session_id,
        "broker_root": str(broker_root),
        "target": {"client": client, "terminal_pid": terminal_pid, "pts": pts},
        "loop": True,
        "iterations": iterations,
        "delivered": total_delivered,
        "last_result": last_result,
        "dry_run": dry_run,
        "sent_at": time.time(),
    }


def main(argv: list[str] | None = None) -> int:
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(
        description="Drain a C2C broker inbox and inject queued messages into a live client terminal."
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--claude-session", metavar="NAME_OR_ID")
    target.add_argument("--pid", type=int, metavar="PID")
    target.add_argument("--terminal-pid", type=int, metavar="PID")
    parser.add_argument("--pts", metavar="N", help="required with --terminal-pid")
    parser.add_argument("--session-id", help="broker session id to deliver")
    parser.add_argument("--broker-root", type=Path, help="broker root directory")
    parser.add_argument("--file-fallback", action="store_true")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--loop", action="store_true", help="keep polling and delivering")
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--max-iterations", type=int, default=None)
    parser.add_argument("--pidfile", type=Path, default=None)
    parser.add_argument("--daemon", action="store_true", help="start detached")
    parser.add_argument("--daemon-log", type=Path, default=None)
    parser.add_argument("--daemon-timeout", type=float, default=10.0)
    parser.add_argument(
        "--client",
        choices=["claude", "codex", "opencode", "generic"],
        default="generic",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="peek and render without draining or injecting",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(raw_argv)

    if args.terminal_pid is not None and not args.pts:
        parser.error("--terminal-pid requires --pts")
    if args.daemon:
        if not args.loop:
            parser.error("--daemon requires --loop")
        if not args.pidfile:
            parser.error("--daemon requires --pidfile")
        log_path = args.daemon_log or Path(f"{args.pidfile}.log")
        result = start_daemon(
            child_argv=strip_daemon_args(raw_argv),
            pidfile=args.pidfile,
            log_path=log_path,
            wait_timeout=args.daemon_timeout,
        )
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            state = "already running" if result.get("already_running") else "started"
            print(f"daemon {state} pid={result.get('pid')} log={result.get('log_path')}")
        return 0 if result.get("ok") else 1

    session_id = c2c_poll_inbox.resolve_session_id(args.session_id)
    broker_root = args.broker_root or c2c_poll_inbox.default_broker_root()
    terminal_pid, pts, _transcript = c2c_inject.resolve_target(args)
    if args.pidfile:
        write_pidfile(args.pidfile)

    try:
        if args.loop:
            result = run_loop(
                session_id=session_id,
                broker_root=broker_root,
                client=args.client,
                terminal_pid=terminal_pid,
                pts=pts,
                dry_run=args.dry_run,
                timeout=args.timeout,
                file_fallback=args.file_fallback,
                interval=args.interval,
                max_iterations=args.max_iterations,
            )
        else:
            result = deliver_once(
                session_id=session_id,
                broker_root=broker_root,
                client=args.client,
                terminal_pid=terminal_pid,
                pts=pts,
                dry_run=args.dry_run,
                timeout=args.timeout,
                file_fallback=args.file_fallback,
            )
    except Exception as exc:
        print(f"[c2c-deliver-inbox] {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        action = "would deliver" if args.dry_run else "delivered"
        print(f"{action} {result['delivered']} message(s) to {args.client}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
