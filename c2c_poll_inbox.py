#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import c2c_mcp

ROOT = Path(__file__).resolve().parent
FALSE_STRINGS = {"", "0", "false", "no", "off"}


def truthy(value: str | None) -> bool:
    return (value or "").strip().lower() not in FALSE_STRINGS


def resolve_session_id(value: str | None) -> str:
    if value:
        return value
    for name in ("RUN_CODEX_INST_C2C_SESSION_ID", "C2C_MCP_SESSION_ID"):
        candidate = os.environ.get(name, "").strip()
        if candidate:
            return candidate
    return "codex-local"


def default_broker_root() -> Path:
    return Path(os.environ.get("C2C_MCP_BROKER_ROOT") or c2c_mcp.default_broker_root())


def inbox_path(broker_root: Path, session_id: str) -> Path:
    return broker_root / f"{session_id}.inbox.json"


def inbox_lock_path(broker_root: Path, session_id: str) -> Path:
    return broker_root / f"{session_id}.inbox.lock"


@contextlib.contextmanager
def inbox_lock(broker_root: Path, session_id: str):
    broker_root.mkdir(parents=True, exist_ok=True)
    with open(inbox_lock_path(broker_root, session_id), "w", encoding="utf-8") as handle:
        fcntl.lockf(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.lockf(handle, fcntl.LOCK_UN)


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        json.dump(value, handle)
        handle.flush()
        os.fsync(handle.fileno())
        temp_path = Path(handle.name)
    os.replace(temp_path, path)


def archive_dir(broker_root: Path) -> Path:
    return broker_root / "archive"


def archive_path(broker_root: Path, session_id: str) -> Path:
    return archive_dir(broker_root) / f"{session_id}.jsonl"


def archive_lock_path(broker_root: Path, session_id: str) -> Path:
    return archive_dir(broker_root) / f"{session_id}.lock"


@contextlib.contextmanager
def archive_lock(broker_root: Path, session_id: str):
    archive_dir(broker_root).mkdir(parents=True, exist_ok=True)
    with open(archive_lock_path(broker_root, session_id), "w", encoding="utf-8") as handle:
        fcntl.lockf(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.lockf(handle, fcntl.LOCK_UN)


def append_archive(
    broker_root: Path, session_id: str, messages: list[dict[str, Any]]
) -> None:
    if not messages:
        return
    path = archive_path(broker_root, session_id)
    archive_dir(broker_root).mkdir(parents=True, exist_ok=True)
    with archive_lock(broker_root, session_id):
        with open(path, "a", encoding="utf-8") as handle:
            drained_at = time.time()
            for message in messages:
                entry = {
                    "drained_at": drained_at,
                    "session_id": session_id,
                    "from_alias": str(message.get("from_alias", "")),
                    "to_alias": str(message.get("to_alias", "")),
                    "content": str(message.get("content", "")),
                }
                if message.get("deferrable"):
                    entry["deferrable"] = True
                handle.write(json.dumps(entry))
                handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())


def file_fallback_poll(broker_root: Path, session_id: str) -> list[dict[str, Any]]:
    path = inbox_path(broker_root, session_id)
    with inbox_lock(broker_root, session_id):
        if not path.exists():
            atomic_write_json(path, [])
            return []
        raw = path.read_text(encoding="utf-8").strip()
        if not raw:
            messages: list[dict[str, Any]] = []
        else:
            loaded = json.loads(raw)
            if not isinstance(loaded, list):
                raise ValueError(f"inbox is not a JSON list: {path}")
            messages = [item for item in loaded if isinstance(item, dict)]
        append_archive(broker_root, session_id, messages)
        atomic_write_json(path, [])
        return messages


def file_fallback_peek(broker_root: Path, session_id: str) -> list[dict[str, Any]]:
    """Read the inbox without draining it (non-destructive)."""
    path = inbox_path(broker_root, session_id)
    with inbox_lock(broker_root, session_id):
        if not path.exists():
            return []
        raw = path.read_text(encoding="utf-8").strip()
        if not raw:
            return []
        loaded = json.loads(raw)
        if not isinstance(loaded, list):
            raise ValueError(f"inbox is not a JSON list: {path}")
        return [item for item in loaded if isinstance(item, dict)]


def call_mcp_tool(
    name: str,
    arguments: dict[str, Any],
    *,
    broker_root: Path,
    session_id: str,
    timeout: float,
) -> tuple[str, list[dict[str, Any]]]:
    env = os.environ.copy()
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
    env["C2C_MCP_SESSION_ID"] = session_id
    env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "0"
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / "c2c_mcp.py")],
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    requests = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "c2c-poll-inbox", "version": "0"},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        },
    ]
    request_body = "".join(json.dumps(request) + "\n" for request in requests)
    try:
        stdout, stderr = proc.communicate(request_body, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        terminate_process_group(proc, timeout=timeout)
        raise TimeoutError(f"MCP server did not reply within {timeout:g}s") from exc
    replies = [json.loads(line) for line in stdout.splitlines() if line.strip()]
    if len(replies) < len(requests):
        stderr_hint = stderr.strip()
        if stderr_hint:
            raise RuntimeError(f"MCP server exited before replying: {stderr_hint}")
        raise RuntimeError("MCP server exited before replying")
    payload = replies[-1]
    if payload.get("result", {}).get("isError"):
        raise RuntimeError(json.dumps(payload))
    text = payload["result"]["content"][0]["text"]
    parsed = json.loads(text) if name == "poll_inbox" else []
    if not isinstance(parsed, list):
        raise RuntimeError(f"unexpected poll_inbox payload: {text}")
    return "mcp", [item for item in parsed if isinstance(item, dict)]


def terminate_process_group(proc: subprocess.Popen, *, timeout: float) -> None:
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=timeout)
        return
    except Exception:
        pass
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGKILL)
    proc.wait(timeout=timeout)


def poll_inbox(
    *,
    broker_root: Path,
    session_id: str,
    timeout: float,
    force_file: bool,
    allow_file_fallback: bool,
) -> tuple[str, list[dict[str, Any]]]:
    if force_file:
        return "file", file_fallback_poll(broker_root, session_id)
    try:
        return call_mcp_tool(
            "poll_inbox",
            {},
            broker_root=broker_root,
            session_id=session_id,
            timeout=timeout,
        )
    except Exception:
        if not allow_file_fallback:
            raise
        return "file", file_fallback_poll(broker_root, session_id)


def print_result(
    *,
    session_id: str,
    broker_root: Path,
    source: str,
    messages: list[dict[str, Any]],
    as_json: bool,
) -> None:
    if as_json:
        print(
            json.dumps(
                {
                    "session_id": session_id,
                    "broker_root": str(broker_root),
                    "source": source,
                    "count": len(messages),
                    "messages": messages,
                }
            )
        )
        return
    if not messages:
        print(f"[c2c-poll-inbox] no messages for {session_id} ({source})")
        return
    n = len(messages)
    print(f"[c2c-poll-inbox] {n} message{'s' if n != 1 else ''} for {session_id} ({source})")
    for item in messages:
        print(
            f"<c2c event=\"message\" from=\"{item.get('from_alias', '')}\" "
            f"alias=\"{item.get('to_alias', '')}\" source=\"broker\" reply_via=\"c2c_send\" action_after=\"continue\">"
            f"{item.get('content', '')}</c2c>"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Poll a C2C inbox without relying on host-exposed MCP tools."
    )
    parser.add_argument("--session-id", help="broker session id to drain")
    parser.add_argument("--broker-root", type=Path, help="broker root directory")
    parser.add_argument(
        "--file-fallback",
        action="store_true",
        help="drain the inbox JSON file directly under a POSIX lockf sidecar",
    )
    parser.add_argument(
        "--peek",
        action="store_true",
        help="read inbox without draining (non-destructive); implies --file-fallback",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=5.0,
        help="seconds to wait for direct MCP process shutdown (default: 5)",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    session_id = resolve_session_id(args.session_id)
    broker_root = args.broker_root or default_broker_root()

    try:
        if args.peek:
            messages = file_fallback_peek(broker_root, session_id)
            source = "file-peek"
        else:
            source, messages = poll_inbox(
                broker_root=broker_root,
                session_id=session_id,
                timeout=args.timeout,
                force_file=args.file_fallback
                or truthy(os.environ.get("C2C_POLL_INBOX_FILE_FALLBACK")),
                allow_file_fallback=True,
            )
    except Exception as exc:
        print(f"[c2c-poll-inbox] {exc}", file=sys.stderr)
        return 1

    print_result(
        session_id=session_id,
        broker_root=broker_root,
        source=source,
        messages=messages,
        as_json=args.json,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
