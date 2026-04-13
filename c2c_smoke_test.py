#!/usr/bin/env python3
"""End-to-end broker smoke test.

`c2c smoke-test` verifies the full send/receive path using the real CLI
without needing live agent sessions:

  1. Creates an isolated temporary broker root
  2. Registers two synthetic aliases (smoke-a, smoke-b)
  3. Sends a unique marker message from smoke-a to smoke-b
  4. Polls smoke-b's inbox and verifies the marker arrived
  5. Cleans up and reports pass / fail with timing

Use this to quickly verify that c2c is working correctly on a machine:

    c2c smoke-test
    c2c smoke-test --json

Exit codes:
  0  all checks passed
  1  one or more checks failed
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

_REPO = Path(__file__).resolve().parent
_C2C_BIN = _REPO / "c2c"
_SESSION_A = "smoke-session-a"
_SESSION_B = "smoke-session-b"
_ALIAS_A = "smoke-a"
_ALIAS_B = "smoke-b"


def _run(
    args: list[str],
    env: dict[str, str],
    *,
    session_id: str | None = None,
) -> subprocess.CompletedProcess[str]:
    cmd_env = dict(env)
    if session_id:
        cmd_env["C2C_MCP_SESSION_ID"] = session_id
    return subprocess.run(
        args,
        cwd=_REPO,
        env=cmd_env,
        capture_output=True,
        text=True,
    )


def _write_registry(broker_root: Path, registrations: list[dict]) -> None:
    (broker_root / "registry.json").write_text(
        json.dumps(registrations), encoding="utf-8"
    )


class SmokeResult:
    def __init__(self) -> None:
        self.checks: list[tuple[str, bool, str]] = []  # (name, ok, detail)
        self.start_ns = time.monotonic_ns()

    def add(self, name: str, ok: bool, detail: str = "") -> None:
        self.checks.append((name, ok, detail))

    @property
    def passed(self) -> bool:
        return all(ok for _, ok, _ in self.checks)

    @property
    def elapsed_ms(self) -> int:
        return (time.monotonic_ns() - self.start_ns) // 1_000_000

    def to_dict(self) -> dict:
        return {
            "ok": self.passed,
            "elapsed_ms": self.elapsed_ms,
            "checks": [
                {"name": n, "ok": ok, "detail": d} for n, ok, d in self.checks
            ],
        }


def run_smoke(broker_root: Path) -> SmokeResult:
    result = SmokeResult()
    marker = f"c2c-smoke-{uuid.uuid4().hex[:12]}"

    env: dict[str, str] = {
        **os.environ,
        "C2C_MCP_BROKER_ROOT": str(broker_root),
        # Prevent inheriting a real session from clobbering auto-register logic
        "C2C_MCP_AUTO_REGISTER_ALIAS": "",
        "C2C_MCP_AUTO_JOIN_ROOMS": "",
    }

    # Check: broker root exists / is writable
    ok = broker_root.is_dir()
    result.add("broker-root-exists", ok, str(broker_root) if not ok else "")
    if not ok:
        return result

    # Seed the registry with our two synthetic sessions
    _write_registry(
        broker_root,
        [
            {"session_id": _SESSION_A, "alias": _ALIAS_A},
            {"session_id": _SESSION_B, "alias": _ALIAS_B},
        ],
    )
    result.add("registry-seeded", True)

    # Check: send message from A to B
    t0 = time.monotonic_ns()
    proc = _run(
        [str(_C2C_BIN), "send", _ALIAS_B, marker, "--json"],
        env,
        session_id=_SESSION_A,
    )
    send_ms = (time.monotonic_ns() - t0) // 1_000_000
    send_ok = proc.returncode == 0
    detail = f"{send_ms}ms"
    if not send_ok:
        detail += f" — {proc.stderr.strip()[:120]}"
    else:
        try:
            result_data = json.loads(proc.stdout)
            if not result_data.get("ok"):
                send_ok = False
                detail += f" — server said not-ok: {proc.stdout[:120]}"
        except Exception:
            send_ok = False
            detail += f" — bad JSON: {proc.stdout[:80]}"
    result.add("send", send_ok, detail)
    if not send_ok:
        return result

    # Check: poll B's inbox and verify the marker arrived
    t0 = time.monotonic_ns()
    proc = _run(
        [str(_C2C_BIN), "poll-inbox", "--session-id", _SESSION_B, "--json"],
        env,
    )
    poll_ms = (time.monotonic_ns() - t0) // 1_000_000
    if proc.returncode != 0:
        result.add("poll", False, proc.stderr.strip()[:120])
        return result

    try:
        poll_data = json.loads(proc.stdout)
        messages = poll_data.get("messages", [])
    except Exception as exc:
        result.add("poll", False, f"JSON parse error: {exc}")
        return result

    poll_ok = len(messages) == 1
    detail = f"{poll_ms}ms, {len(messages)} message(s)"
    if not poll_ok:
        detail += " — expected exactly 1"
    result.add("poll", poll_ok, detail)
    if not poll_ok:
        return result

    # Check: message content matches the sent marker
    msg = messages[0]
    content_ok = msg.get("content") == marker
    from_ok = msg.get("from_alias") == _ALIAS_A
    to_ok = msg.get("to_alias") == _ALIAS_B
    delivery_ok = content_ok and from_ok and to_ok
    detail = ""
    if not delivery_ok:
        detail = f"got {msg}"
    result.add("delivery", delivery_ok, detail)

    return result


def print_result(result: SmokeResult, *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(result.to_dict(), indent=2))
        return

    print(f"c2c smoke test {'PASSED' if result.passed else 'FAILED'} ({result.elapsed_ms}ms)")
    for name, ok, detail in result.checks:
        icon = "✓" if ok else "✗"
        line = f"  {icon} {name}"
        if detail:
            line += f": {detail}"
        print(line)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "End-to-end broker smoke test. "
            "Sends a message through the broker and verifies it arrives."
        )
    )
    parser.add_argument(
        "--broker-root",
        type=Path,
        help="Use this broker root instead of a temporary directory",
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON result")
    args = parser.parse_args(argv)

    if args.broker_root:
        args.broker_root.mkdir(parents=True, exist_ok=True)
        result = run_smoke(args.broker_root)
        print_result(result, as_json=args.json)
        return 0 if result.passed else 1

    with tempfile.TemporaryDirectory() as td:
        broker_root = Path(td) / "smoke-broker"
        broker_root.mkdir()
        result = run_smoke(broker_root)

    print_result(result, as_json=args.json)
    return 0 if result.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
