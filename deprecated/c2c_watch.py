#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time

import c2c_send


def format_message(line: str, label: str | None) -> str:
    text = line.rstrip("\r\n")
    if label:
        return f"[{label}] {text}"
    return text


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run a command and forward each stdout line to a C2C alias."
    )
    parser.add_argument("--to", required=True, help="recipient alias")
    parser.add_argument("--label", help="prefix each forwarded line")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("command is required after --")

    proc = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    forwarded = 0
    assert proc.stdout is not None
    for line in proc.stdout:
        c2c_send.send_to_alias(
            args.to,
            format_message(line, args.label),
            args.dry_run,
        )
        forwarded += 1

    returncode = proc.wait()
    payload = {
        "ok": returncode == 0,
        "to": args.to,
        "label": args.label,
        "command": command,
        "forwarded": forwarded,
        "returncode": returncode,
        "sent_at": time.time(),
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print(
            f"forwarded {forwarded} line(s) to {args.to}; "
            f"command exited {returncode}"
        )
    return returncode


if __name__ == "__main__":
    raise SystemExit(main())
