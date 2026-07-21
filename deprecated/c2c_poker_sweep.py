#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import signal
import subprocess
import sys
from dataclasses import dataclass
from typing import Any

import c2c_poker


@dataclass(frozen=True)
class PokerProcess:
    pid: int
    argv: list[str]


def pid_is_alive(pid: int) -> bool:
    return c2c_poker.pid_is_alive(pid)


def list_poker_processes() -> list[PokerProcess]:
    current_pid = os.getpid()
    proc = subprocess.run(
        ["ps", "-eo", "pid=,args="],
        check=True,
        capture_output=True,
        text=True,
    )
    processes: list[PokerProcess] = []
    for line in proc.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, args_text = stripped.partition(" ")
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        if pid == current_pid or "c2c_poker.py" not in args_text:
            continue
        try:
            argv = shlex.split(args_text)
        except ValueError:
            argv = args_text.split()
        processes.append(PokerProcess(pid=pid, argv=argv))
    return processes


def option_value(argv: list[str], option: str) -> str | None:
    prefix = f"{option}="
    for index, item in enumerate(argv):
        if item == option and index + 1 < len(argv):
            return argv[index + 1]
        if item.startswith(prefix):
            return item[len(prefix) :]
    return None


def find_claude_session(identifier: str, sessions: list[dict[str, Any]]) -> dict[str, Any] | None:
    for session in sessions:
        if identifier in {
            str(session.get("session_id", "")),
            str(session.get("name", "")),
            str(session.get("pid", "")),
        }:
            return session
    return None


def classify_process(
    process: PokerProcess, *, claude_sessions: list[dict[str, Any]]
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "pid": process.pid,
        "argv": process.argv,
        "live": True,
        "reason": "unknown_target",
        "killed": False,
    }

    watched_pid_text = option_value(process.argv, "--pid")
    if watched_pid_text is not None:
        try:
            watched_pid = int(watched_pid_text)
        except ValueError:
            result.update(live=False, reason="invalid_watched_pid")
            return result
        result["watched_pid"] = watched_pid
        if pid_is_alive(watched_pid):
            result["reason"] = "watched_pid_alive"
        else:
            result.update(live=False, reason="watched_pid_dead")
        return result

    claude_identifier = option_value(process.argv, "--claude-session")
    if claude_identifier is not None:
        result["claude_session"] = claude_identifier
        session = find_claude_session(claude_identifier, claude_sessions)
        if session is None:
            result.update(live=False, reason="claude_session_missing")
            return result
        session_pid = session.get("pid")
        result["watched_pid"] = session_pid
        if isinstance(session_pid, int) and pid_is_alive(session_pid):
            result["reason"] = "claude_session_alive"
        else:
            result.update(live=False, reason="claude_session_pid_dead")
        return result

    result.update(live=False, reason="unrecognized_target")
    return result


def kill_process(pid: int) -> None:
    os.kill(pid, signal.SIGTERM)


def sweep_processes(
    processes: list[PokerProcess],
    *,
    claude_sessions: list[dict[str, Any]],
    kill_stale: bool,
) -> dict[str, Any]:
    results = [
        classify_process(process, claude_sessions=claude_sessions)
        for process in processes
    ]
    killed = 0
    for item in results:
        if item["live"] or not kill_stale:
            continue
        kill_process(int(item["pid"]))
        item["killed"] = True
        killed += 1
    return {
        "ok": True,
        "total": len(results),
        "live": sum(1 for item in results if item["live"]),
        "stale": sum(1 for item in results if not item["live"]),
        "killed": killed,
        "processes": results,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="List or kill stale c2c_poker.py processes whose watched target is gone."
    )
    parser.add_argument("--kill", action="store_true", help="terminate stale poker processes")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    payload = sweep_processes(
        list_poker_processes(),
        claude_sessions=c2c_poker.list_claude_sessions(),
        kill_stale=args.kill,
    )
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        action = "killed" if args.kill else "would kill"
        print(
            f"{payload['stale']} stale poker process(es); "
            f"{action} {payload['killed']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
