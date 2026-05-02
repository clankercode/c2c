#!/usr/bin/env python3
"""Kimi Wire Bridge: deliver c2c inbox messages through Kimi's Wire JSON-RPC protocol.

.. deprecated::
    OCaml `c2c_wire_bridge.ml` + `c2c_wire_daemon.ml` are the canonical
    implementations. The OCaml `c2c wire-daemon` subcommand is primary.
    This Python version is retained only for the Python CLI's wire-daemon
    subcommand (c2c_cli.py dispatch). Delete when Python CLI is retired.

The Kimi Wire protocol (`kimi --wire`) exposes a newline-delimited JSON-RPC 2.0
interface over stdin/stdout.  This bridge:

1. Starts (or wraps) a Kimi Wire subprocess.
2. Polls or watches the c2c broker inbox.
3. Drains broker messages, persists them to a spool, then delivers via Wire `prompt`.
4. Clears the spool after successful delivery.

This is the preferred native Kimi delivery path because it avoids all PTY/PTS
terminal hacks.  The PTY master-side wake daemon (c2c_kimi_wake_daemon.py)
remains as a fallback for manual TUI sessions that need TUI-level wake.
Note: writing to /dev/pts/<N> (slave side) is display-only and does NOT deliver
keyboard input to the program; PTY wake must use the master fd via pty_inject.

Usage:
    c2c-kimi-wire-bridge --session-id kimi-wire --dry-run --json
    c2c-kimi-wire-bridge --session-id kimi-wire --once --json
"""
from __future__ import annotations

import argparse
import contextlib
import html
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent

import c2c_poll_inbox


# ---------------------------------------------------------------------------
# Daemon management helpers (mirrors c2c_deliver_inbox.py pattern)
# ---------------------------------------------------------------------------

def _write_pidfile(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"{os.getpid()}\n", encoding="utf-8")


def _read_pidfile(path: Path) -> int | None:
    try:
        raw = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    try:
        return int(raw)
    except ValueError:
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


def _strip_daemon_args(argv: list[str]) -> list[str]:
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


def start_daemon(
    *,
    child_argv: list[str],
    pidfile: Path,
    log_path: Path,
    wait_timeout: float,
) -> dict[str, Any]:
    """Start the wire bridge as a background daemon; return status dict.

    If a daemon is already running (live pidfile), returns immediately with
    ``already_running: True``.  Otherwise spawns a new session, waits up to
    ``wait_timeout`` for the child to write its pidfile, and returns the result.
    """
    existing_pid = _read_pidfile(pidfile)
    if existing_pid is not None and _pid_is_alive(existing_pid):
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
        written_pid = _read_pidfile(pidfile)
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


# ---------------------------------------------------------------------------
# Wire state tracker
# ---------------------------------------------------------------------------

class WireState:
    """Track Kimi Wire agent turn state from incoming Wire notifications."""

    def __init__(self) -> None:
        self.turn_active: bool = False
        self.steer_inputs: list[str] = []

    def apply_message(self, message: dict[str, Any]) -> None:
        if message.get("method") != "event":
            return
        params = message.get("params") or {}
        event_type = params.get("type")
        payload = params.get("payload") or {}
        if event_type == "TurnBegin":
            self.turn_active = True
        elif event_type == "TurnEnd":
            self.turn_active = False
        elif event_type == "SteerInput":
            user_input = payload.get("user_input")
            if isinstance(user_input, str):
                self.steer_inputs.append(user_input)


# ---------------------------------------------------------------------------
# Message formatting
# ---------------------------------------------------------------------------

def _xml_attr(value: object) -> str:
    return html.escape(str(value or ""), quote=True)


def format_c2c_envelope(message: dict[str, Any]) -> str:
    sender = _xml_attr(message.get("from_alias") or "unknown")
    alias = _xml_attr(message.get("to_alias") or "")
    content = str(message.get("content") or "")
    return (
        f'<c2c event="message" from="{sender}" to="{alias}" '
        'source="broker" reply_via="c2c_send" action_after="continue">\n'
        f"{content}\n"
        "</c2c>"
    )


def format_prompt(messages: list[dict[str, Any]]) -> str:
    return "\n\n".join(format_c2c_envelope(message) for message in messages)


# ---------------------------------------------------------------------------
# Durable spool (persists between drain and Wire prompt success)
# ---------------------------------------------------------------------------

class C2CSpool:
    """Durable JSON spool: messages are written here before Wire delivery.

    If the process crashes between drain and prompt, messages survive in the
    spool and will be retried on the next bridge run.
    """

    def __init__(self, path: Path) -> None:
        self.path = path

    def read(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        raw = self.path.read_text(encoding="utf-8").strip()
        if not raw:
            return []
        loaded = json.loads(raw)
        return [item for item in loaded if isinstance(item, dict)] if isinstance(loaded, list) else []

    def replace(self, messages: list[dict[str, Any]]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=self.path.name + ".", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(messages, handle)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp, self.path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def append(self, messages: list[dict[str, Any]]) -> None:
        self.replace([*self.read(), *messages])

    def clear(self) -> None:
        self.replace([])


# ---------------------------------------------------------------------------
# MCP config helper
# ---------------------------------------------------------------------------

def build_kimi_mcp_config(
    *,
    broker_root: Path,
    session_id: str,
    alias: str,
    mcp_script: Path,
) -> dict[str, Any]:
    """Build an explicit c2c MCP config dict for a Kimi Wire subprocess."""
    return {
        "mcpServers": {
            "c2c": {
                "type": "stdio",
                "command": "python3",
                "args": [str(mcp_script)],
                "env": {
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    "C2C_MCP_SESSION_ID": session_id,
                    "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
                    "C2C_MCP_CLIENT_PID": str(os.getpid()),
                    "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge",
                    "C2C_MCP_AUTO_DRAIN_CHANNEL": "0",
                },
            }
        }
    }


# ---------------------------------------------------------------------------
# Wire JSON-RPC client
# ---------------------------------------------------------------------------

class WireClient:
    """Minimal Kimi Wire JSON-RPC 2.0 client over stdin/stdout streams."""

    def __init__(self, *, stdin: Any, stdout: Any) -> None:
        self.stdin = stdin
        self.stdout = stdout
        self._next_id = 1
        self.state = WireState()

    def _request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        request_id = str(self._next_id)
        self._next_id += 1
        request = {
            "jsonrpc": "2.0",
            "method": method,
            "id": request_id,
            "params": params,
        }
        self.stdin.write(json.dumps(request) + "\n")
        self.stdin.flush()
        while True:
            line = self.stdout.readline()
            if not line:
                raise RuntimeError(f"wire closed before response to {method!r}")
            message = json.loads(line)
            self.state.apply_message(message)
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(json.dumps(message["error"]))
                return message.get("result") or {}

    def initialize(self) -> dict[str, Any]:
        return self._request(
            "initialize",
            {
                "protocol_version": "1.9",
                "client": {"name": "c2c-kimi-wire-bridge", "version": "0"},
                "capabilities": {"supports_question": False},
            },
        )

    def prompt(self, user_input: str) -> dict[str, Any]:
        return self._request("prompt", {"user_input": user_input})

    def steer(self, user_input: str) -> dict[str, Any]:
        return self._request("steer", {"user_input": user_input})


# ---------------------------------------------------------------------------
# Delivery logic
# ---------------------------------------------------------------------------

def default_spool_path(broker_root: Path, session_id: str) -> Path:
    return broker_root.parent / "kimi-wire" / f"{session_id}.spool.json"


def deliver_once(
    *,
    wire: WireClient,
    spool: C2CSpool,
    broker_root: Path,
    session_id: str,
    timeout: float,
) -> dict[str, Any]:
    """Initialize Wire, drain inbox to spool, deliver via prompt, clear spool.

    Spool is never cleared until after a successful prompt call — crash-safe.
    Raises RuntimeError if Wire responds with an error.
    """
    wire.initialize()
    messages = spool.read()
    if not messages:
        _source, fresh = c2c_poll_inbox.poll_inbox(
            broker_root=broker_root,
            session_id=session_id,
            timeout=timeout,
            force_file=True,
            allow_file_fallback=True,
        )
        if fresh:
            spool.append(fresh)
        messages = spool.read()
    if not messages:
        return {"ok": True, "delivered": 0}
    wire.prompt(format_prompt(messages))
    delivered = len(messages)
    spool.clear()
    return {"ok": True, "delivered": delivered}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_launch(command: str, work_dir: Path, mcp_config_file: Path) -> list[str]:
    return [command, "--wire", "--yolo", "--work-dir", str(work_dir),
            "--mcp-config-file", str(mcp_config_file)]


def run_once_live(
    *,
    session_id: str,
    alias: str,
    broker_root: Path,
    work_dir: Path,
    command: str,
    spool_path: Path,
    timeout: float,
) -> dict[str, Any]:
    """Start a real Kimi Wire subprocess, deliver messages, and exit.

    Creates an isolated temp MCP config file, launches `kimi --wire`,
    connects WireClient to its stdin/stdout, calls deliver_once, then
    terminates the subprocess.
    """
    import subprocess as _subp

    mcp_script = ROOT / "c2c_mcp.py"
    config = build_kimi_mcp_config(
        broker_root=broker_root,
        session_id=session_id,
        alias=alias,
        mcp_script=mcp_script,
    )
    fd, tmp_config = tempfile.mkstemp(suffix=".json", prefix="c2c-kimi-wire-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(config, f)
        mcp_config_path = Path(tmp_config)
        launch = build_launch(command, work_dir, mcp_config_path)
        proc = _subp.Popen(
            launch,
            stdin=_subp.PIPE,
            stdout=_subp.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        try:
            assert proc.stdin is not None
            assert proc.stdout is not None
            wire = WireClient(stdin=proc.stdin, stdout=proc.stdout)
            spool = C2CSpool(spool_path)
            result = deliver_once(
                wire=wire,
                spool=spool,
                broker_root=broker_root,
                session_id=session_id,
                timeout=timeout,
            )
            return result
        finally:
            try:
                proc.stdin.close()
            except Exception:
                pass
            try:
                proc.wait(timeout=15)
            except Exception:
                proc.kill()
    finally:
        try:
            os.unlink(tmp_config)
        except OSError:
            pass


def _has_pending_messages(broker_root: Path, session_id: str, spool_path: Path) -> bool:
    """Return True if the spool or broker inbox has queued messages (non-destructive)."""
    if C2CSpool(spool_path).read():
        return True
    try:
        return bool(c2c_poll_inbox.file_fallback_peek(broker_root, session_id))
    except Exception as exc:
        print(f"[kimi-wire] inbox peek error: {exc}", file=sys.stderr, flush=True)
        return False


_LOOP_MAX_BACKOFF = 300.0  # cap error-backoff at 5 minutes


def run_loop_live(
    *,
    session_id: str,
    alias: str,
    broker_root: Path,
    work_dir: Path,
    command: str,
    spool_path: Path,
    timeout: float,
    interval: float = 5.0,
    max_iterations: int | None = None,
) -> dict[str, Any]:
    """Poll broker inbox every `interval` seconds; start Wire subprocess only when messages are queued.

    This is the daemon mode for the Wire bridge: it runs forever (or until
    `max_iterations`) and delivers batches via fresh Wire subprocesses.  The
    pre-check via `file_fallback_peek` keeps it cheap when the inbox is empty —
    no Wire subprocess is started until there is something to deliver.

    Consecutive delivery failures trigger exponential backoff (capped at 5 min)
    to avoid hammering a broken system.  The streak resets on any successful
    delivery or when the inbox is empty (idle is not an error).

    Returns after `max_iterations` cycles (or immediately if interrupted).
    """
    iterations = 0
    total_delivered = 0
    errors = 0
    error_streak = 0

    while max_iterations is None or iterations < max_iterations:
        if _has_pending_messages(broker_root, session_id, spool_path):
            try:
                result = run_once_live(
                    session_id=session_id,
                    alias=alias,
                    broker_root=broker_root,
                    work_dir=work_dir,
                    command=command,
                    spool_path=spool_path,
                    timeout=timeout,
                )
                total_delivered += result.get("delivered", 0)
                error_streak = 0
            except Exception as exc:
                errors += 1
                error_streak += 1
                print(
                    f"[kimi-wire] delivery error (streak={error_streak}): {exc}",
                    file=sys.stderr,
                    flush=True,
                )
        else:
            error_streak = 0  # idle → not an error; reset streak

        iterations += 1
        if max_iterations is None or iterations < max_iterations:
            backoff = min(interval * (2 ** min(error_streak, 6)), _LOOP_MAX_BACKOFF)
            time.sleep(backoff)

    return {"ok": errors == 0, "iterations": iterations,
            "total_delivered": total_delivered, "errors": errors}


def run_main(argv: list[str]) -> int:
    raw_argv = list(argv)
    parser = argparse.ArgumentParser(
        description="Deliver c2c inbox messages through Kimi Wire JSON-RPC."
    )
    parser.add_argument("--session-id", required=True, help="broker session ID")
    parser.add_argument("--alias", help="broker alias (default: session-id)")
    parser.add_argument(
        "--broker-root", type=Path,
        default=None,
        help="broker root directory",
    )
    parser.add_argument("--work-dir", type=Path, default=ROOT, help="Kimi work dir")
    parser.add_argument("--command", default="kimi", help="kimi binary")
    parser.add_argument("--spool-path", type=Path, help="spool file path")
    parser.add_argument("--dry-run", action="store_true",
                        help="print config without starting Kimi")
    parser.add_argument("--once", action="store_true",
                        help="start Kimi, deliver, and exit")
    parser.add_argument("--loop", action="store_true",
                        help="poll inbox repeatedly; start Wire subprocess only when messages are queued")
    parser.add_argument("--interval", type=float, default=5.0,
                        help="seconds between inbox checks in --loop mode (default: 5)")
    parser.add_argument("--max-iterations", type=int, default=None,
                        help="stop after N loop iterations (default: run forever)")
    parser.add_argument("--json", action="store_true", help="emit JSON output")
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="inbox poll timeout (seconds)")
    parser.add_argument("--pidfile", type=Path, default=None,
                        help="write daemon PID to this file when running --loop")
    parser.add_argument("--daemon", action="store_true",
                        help="daemonize: spawn detached --loop child; requires --loop and --pidfile")
    parser.add_argument("--daemon-log", type=Path, default=None,
                        help="log file for daemon stdout/stderr (default: <pidfile>.log)")
    parser.add_argument("--daemon-timeout", type=float, default=5.0,
                        help="seconds to wait for daemon pidfile after spawn (default: 5)")
    args = parser.parse_args(argv)

    broker_root = args.broker_root
    if broker_root is None:
        broker_root = Path(c2c_poll_inbox.default_broker_root())

    alias = args.alias or args.session_id
    spool_path = args.spool_path or default_spool_path(broker_root, args.session_id)
    mcp_config_placeholder = Path("<generated-mcp-config>")
    launch = build_launch(args.command, args.work_dir, mcp_config_placeholder)

    if args.dry_run:
        payload: dict[str, Any] = {
            "ok": True,
            "dry_run": True,
            "session_id": args.session_id,
            "alias": alias,
            "launch": launch,
            "spool_path": str(spool_path),
            "broker_root": str(broker_root),
        }
        if args.json:
            print(json.dumps(payload))
        else:
            print(payload)
        return 0

    if args.once and args.loop:
        parser.error("--once and --loop are mutually exclusive")

    if args.daemon:
        if not args.loop:
            parser.error("--daemon requires --loop")
        if not args.pidfile:
            parser.error("--daemon requires --pidfile")
        log_path = args.daemon_log or Path(f"{args.pidfile}.log")
        result = start_daemon(
            child_argv=_strip_daemon_args(raw_argv),
            pidfile=args.pidfile,
            log_path=log_path,
            wait_timeout=args.daemon_timeout,
        )
        if args.json:
            print(json.dumps(result))
        else:
            if result.get("already_running"):
                print(f"[kimi-wire] daemon already running (pid {result['pid']})")
            elif result.get("ok"):
                print(f"[kimi-wire] daemon started (pid {result['pid']})")
            else:
                print(f"[kimi-wire] daemon start failed: {result.get('error', result)}", file=sys.stderr)
        return 0 if result.get("ok") else 1

    if args.once:
        result = run_once_live(
            session_id=args.session_id,
            alias=alias,
            broker_root=broker_root,
            work_dir=args.work_dir,
            command=args.command,
            spool_path=spool_path,
            timeout=args.timeout,
        )
        if args.json:
            print(json.dumps(result))
        else:
            delivered = result.get("delivered", 0)
            print(f"delivered {delivered} message(s) via Kimi Wire")
        return 0 if result.get("ok") else 1

    if args.loop:
        if args.pidfile:
            _write_pidfile(args.pidfile)
        result = run_loop_live(
            session_id=args.session_id,
            alias=alias,
            broker_root=broker_root,
            work_dir=args.work_dir,
            command=args.command,
            spool_path=spool_path,
            timeout=args.timeout,
            interval=args.interval,
            max_iterations=args.max_iterations,
        )
        if args.json:
            print(json.dumps(result))
        else:
            print(
                f"loop done: {result['iterations']} iteration(s), "
                f"{result['total_delivered']} delivered, "
                f"{result['errors']} error(s)"
            )
        return 0 if result.get("ok") else 1

    parser.print_help()
    return 1


def run_main_capture(argv: list[str]) -> tuple[int, str]:
    import io as _io
    buf = _io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = run_main(argv)
    return rc, buf.getvalue()


def main(argv: list[str] | None = None) -> int:
    return run_main(sys.argv[1:] if argv is None else argv)


if __name__ == "__main__":
    raise SystemExit(main())
