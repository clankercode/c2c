#!/usr/bin/env python3
"""Grant CAP_SYS_PTRACE to the running Python interpreter so pidfd_getfd
works for PTY injection in c2c_deliver_inbox / c2c_poker.

Usage:
    c2c setcap             # print what would run, check current state
    c2c setcap --apply     # exec `sudo setcap cap_sys_ptrace=ep <interp>`
    c2c setcap --json      # machine-readable status

Rationale lives in .collab/findings/2026-04-20T12-54-04Z-coder1-pidfd-eperm-deliver-spam.md.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def resolve_interpreter() -> str:
    """Return the realpath of the current python interpreter, resolving
    any shim layer (pyenv, asdf, linuxbrew shell scripts)."""
    exe = Path("/proc/self/exe")
    if exe.exists():
        try:
            return os.path.realpath(str(exe))
        except OSError:
            pass
    return os.path.realpath(sys.executable)


def current_caps(interp: str) -> str:
    """Return trimmed stdout of `getcap <interp>`, or '' on missing getcap."""
    getcap = shutil.which("getcap")
    if getcap is None:
        return ""
    try:
        result = subprocess.run(
            [getcap, interp],
            capture_output=True,
            text=True,
            check=False,
            timeout=5.0,
        )
        return result.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def has_cap_sys_ptrace(caps_line: str) -> bool:
    return "cap_sys_ptrace" in caps_line.lower()


def ptrace_scope() -> int | None:
    try:
        raw = Path("/proc/sys/kernel/yama/ptrace_scope").read_text().strip()
    except OSError:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="c2c setcap",
        description="Grant CAP_SYS_PTRACE to the Python interpreter used by c2c.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="exec `sudo setcap cap_sys_ptrace=ep <interp>` (interactive, needs tty + sudo).",
    )
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args(argv)

    interp = resolve_interpreter()
    caps = current_caps(interp)
    has_cap = has_cap_sys_ptrace(caps)
    scope = ptrace_scope()
    setcap_cmd = ["sudo", "setcap", "cap_sys_ptrace=ep", interp]

    status = {
        "interpreter": interp,
        "current_caps": caps,
        "has_cap_sys_ptrace": has_cap,
        "ptrace_scope": scope,
        "setcap_command": " ".join(setcap_cmd),
        "needs_action": (not has_cap) and (scope is None or scope > 0),
    }

    if not args.apply:
        if args.json:
            print(json.dumps(status, indent=2))
            return 0
        print(f"interpreter:  {interp}")
        print(f"current caps: {caps or '(none)'}")
        print(f"ptrace_scope: {scope if scope is not None else '?'}")
        if has_cap:
            print("status:       OK — cap_sys_ptrace already present")
            return 0
        if scope == 0:
            print("status:       OK — ptrace_scope=0 (cap not required)")
            return 0
        print("status:       MISSING — PTY injection will fail")
        print(f"fix:          {' '.join(setcap_cmd)}")
        print("              (or re-run with --apply to exec sudo now)")
        return 0

    # --apply path — guard against running without a tty or without sudo.
    if shutil.which("sudo") is None:
        msg = "sudo not found on PATH; install sudo or run setcap manually as root."
        if args.json:
            print(json.dumps({**status, "ok": False, "error": msg}))
        else:
            print(f"error: {msg}", file=sys.stderr)
        return 1
    if not sys.stdin.isatty():
        msg = (
            "stdin is not a tty; refusing to exec sudo (would hang on password prompt). "
            f"Run this from an interactive shell, or run manually: {' '.join(setcap_cmd)}"
        )
        if args.json:
            print(json.dumps({**status, "ok": False, "error": msg}))
        else:
            print(f"error: {msg}", file=sys.stderr)
        return 1

    if not args.json:
        print(f"exec: {' '.join(setcap_cmd)}", flush=True)
    os.execvp("sudo", setcap_cmd)
    return 1  # unreachable


if __name__ == "__main__":
    raise SystemExit(main())
