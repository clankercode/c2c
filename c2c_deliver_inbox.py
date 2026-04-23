#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import c2c_poll_inbox
import c2c_poker

# c2c_inject is only needed for the PTY-injection path (deprecated); lazy-import
# to keep bare CLI invocation working when the module has been moved to deprecated/.


KIMI_SUBMIT_DELAY = 1.5

_EPERM_STATE = {"printed": False, "skipped": 0}


def _note_inject_success() -> None:
    """Reset the EPERM banner guard after a successful inject so transient
    permission errors (e.g. cap briefly missing, then reapplied) don't
    permanently silence the banner."""
    _EPERM_STATE["printed"] = False
    _EPERM_STATE["skipped"] = 0


def _note_inject_eperm(exc: PermissionError) -> None:
    """Print the EPERM banner once per run, then silently count skipped injects."""
    if not _EPERM_STATE["printed"]:
        interp = os.path.realpath(sys.executable)
        print(
            f"[c2c-deliver-inbox] PTY injection disabled: CAP_SYS_PTRACE missing on {interp}\n"
            f"    Run: sudo setcap cap_sys_ptrace=ep {interp}\n"
            f"    Or lower kernel.yama.ptrace_scope (sysctl -w kernel.yama.ptrace_scope=0)\n"
            f"    Continuing in degraded mode (MCP delivery unaffected).\n"
            f"    Original error: {exc}",
            file=sys.stderr,
            flush=True,
        )
        _EPERM_STATE["printed"] = True
    _EPERM_STATE["skipped"] += 1


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
        content,
        event="message",
        sender=sender,
        alias=alias,
        raw=False,
        source="broker",
        source_tool="c2c_deliver_inbox",
    )


def xml_output_dir(broker_root: Path) -> Path:
    return broker_root.parent / "codex-xml"


def default_xml_spool_path(broker_root: Path, session_id: str) -> Path:
    return xml_output_dir(broker_root) / f"{session_id}.spool.json"


def _xml_attr(value: object) -> str:
    return html.escape(str(value or ""), quote=True)


def xml_message_payload(message: dict[str, Any]) -> str:
    sender = _xml_attr(message.get("from_alias") or "unknown")
    alias = _xml_attr(message.get("to_alias") or "")
    content = html.escape(str(message.get("content") or ""))
    return (
        f'<message type="user"><c2c event="message" from="{sender}" alias="{alias}" '
        'source="broker" reply_via="c2c_send" action_after="continue">'
        f"{content}</c2c></message>\n"
    )


class C2CSpool:
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
        c2c_poll_inbox.atomic_write_json(self.path, messages)

    def append(self, messages: list[dict[str, Any]]) -> None:
        self.replace([*self.read(), *messages])

    def clear(self) -> None:
        self.replace([])


def stage_inbox_into_xml_spool(
    *, broker_root: Path, session_id: str, spool: C2CSpool
) -> list[dict[str, Any]]:
    path = c2c_poll_inbox.inbox_path(broker_root, session_id)
    with c2c_poll_inbox.inbox_lock(broker_root, session_id):
        if not path.exists():
            c2c_poll_inbox.atomic_write_json(path, [])
            return spool.read()
        raw = path.read_text(encoding="utf-8").strip()
        if not raw:
            return spool.read()
        loaded = json.loads(raw)
        if not isinstance(loaded, list):
            raise ValueError(f"inbox is not a JSON list: {path}")
        fresh = [item for item in loaded if isinstance(item, dict)]
        if not fresh:
            return spool.read()

        # Persist into the delivery spool before clearing the inbox so a spool
        # write failure cannot lose drained broker messages.
        staged = spool.read()
        spool.replace([*staged, *fresh])
        try:
            c2c_poll_inbox.append_archive(broker_root, session_id, fresh)
        except Exception:
            # Best-effort rollback keeps the spool aligned with the still-live inbox.
            spool.replace(staged)
            raise
        c2c_poll_inbox.atomic_write_json(path, [])
        return [*staged, *fresh]


def deliver_xml_messages(*, fd: int, messages: list[dict[str, Any]]) -> None:
    payload = "".join(xml_message_payload(message) for message in messages).encode("utf-8")
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def deliver_xml_messages_to_path(*, path: Path, messages: list[dict[str, Any]]) -> None:
    payload = "".join(xml_message_payload(message) for message in messages).encode("utf-8")
    fd = os.open(path, os.O_WRONLY)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            view = view[written:]
    finally:
        os.close(fd)


def notify_payload(*, session_id: str, count: int, client: str = "generic") -> str:
    noun = "message" if count == 1 else "messages"
    if client == "crush":
        message = (
            f"You have {count} c2c {noun}. "
            "Call mcp__c2c__poll_inbox and reply via mcp__c2c__send now."
        )
        raw = True
    else:
        message = (
            f"{count} broker-native C2C {noun} queued for session {session_id}. "
            "Call mcp__c2c__poll_inbox now to read the content from the broker. "
            "This PTY nudge intentionally does not contain the message body."
        )
        raw = False
    return c2c_poker.render_payload(
        message,
        event="notify",
        sender="c2c-deliver-inbox",
        alias=session_id,
        raw=raw,
        source="broker-notify",
        source_tool="c2c_deliver_inbox",
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
    delivered: int | None = None,
    notified: bool = False,
) -> dict[str, Any]:
    delivered_count = 0 if dry_run else (len(messages) if delivered is None else delivered)
    return {
        "ok": True,
        "session_id": session_id,
        "broker_root": str(broker_root),
        "source": source,
        "target": {"client": client, "terminal_pid": terminal_pid, "pts": pts},
        "messages": messages,
        "delivered": delivered_count,
        "notified": notified,
        "dry_run": dry_run,
        "sent_at": time.time(),
    }


def public_result(result: dict[str, Any], *, redact_messages: bool) -> dict[str, Any]:
    """Return a JSON-safe result for operator output.

    Notify-only mode intentionally leaves messages in the broker. Its public
    JSON should prove a nudge happened without echoing broker message bodies.
    """
    if not redact_messages:
        return result

    def sanitize(value: Any) -> Any:
        if isinstance(value, dict):
            sanitized = {key: sanitize(item) for key, item in value.items()}
            messages = value.get("messages")
            if isinstance(messages, list):
                sanitized["message_count"] = len(messages)
                sanitized["messages"] = []
                sanitized["messages_redacted"] = True
            return sanitized
        if isinstance(value, list):
            return [sanitize(item) for item in value]
        return value

    return sanitize(result)


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


def watched_pid_from_args(args: argparse.Namespace) -> int | None:
    if args.pid is not None:
        return int(args.pid)
    if args.terminal_pid is not None:
        return int(args.terminal_pid)
    if args.claude_session:
        session = c2c_poker.find_claude_session(args.claude_session)
        pid = session.get("pid")
        return int(pid) if pid is not None else None
    return None


def watched_pid_exited(watched_pid: int | None) -> bool:
    return watched_pid is not None and not pid_is_alive(watched_pid)


def effective_submit_delay(client: str, submit_delay: float | None) -> float | None:
    if submit_delay is not None:
        return submit_delay
    if client == "kimi":
        return KIMI_SUBMIT_DELAY
    return None


def inject_payload(
    *,
    client: str,
    terminal_pid: int,
    pts: str,
    payload: str,
    submit_delay: float | None,
) -> bool:
    """Inject payload via PTY. Returns True on success, False if CAP_SYS_PTRACE
    is missing (logs an actionable banner once, silently counts subsequent skips)."""
    delay = effective_submit_delay(client, submit_delay)
    try:
        if delay is None:
            c2c_poker.inject(terminal_pid, pts, payload)
        else:
            c2c_poker.inject(terminal_pid, pts, payload, submit_delay=delay)
    except PermissionError as exc:
        _note_inject_eperm(exc)
        return False
    _note_inject_success()
    return True


def messages_signature(messages: list[dict[str, Any]]) -> str:
    if not messages:
        return ""
    return json.dumps(messages, sort_keys=True, separators=(",", ":"))


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
    notify_only: bool,
    submit_delay: float | None = None,
    suppress_notify: bool = False,
    xml_output_fd: int | None = None,
    xml_output_path: Path | None = None,
) -> dict[str, Any]:
    notified = False
    delivered = None
    if dry_run or notify_only:
        source = "peek"
        messages = peek_inbox(broker_root, session_id)
        delivered = 0
        if notify_only and messages and not dry_run and not suppress_notify:
            payload = notify_payload(session_id=session_id, count=len(messages), client=client)
            notified = inject_payload(
                client=client,
                terminal_pid=terminal_pid,
                pts=pts,
                payload=payload,
                submit_delay=submit_delay,
            )
    else:
        if xml_output_fd is not None or xml_output_path is not None:
            source = "xml"
            spool = C2CSpool(default_xml_spool_path(broker_root, session_id))
            messages = spool.read()
            if not messages:
                messages = stage_inbox_into_xml_spool(
                    broker_root=broker_root,
                    session_id=session_id,
                    spool=spool,
                )
            delivered = 0
            if messages:
                if xml_output_fd is not None:
                    deliver_xml_messages(fd=xml_output_fd, messages=messages)
                else:
                    deliver_xml_messages_to_path(path=xml_output_path, messages=messages)
                delivered = len(messages)
                spool.clear()
            return build_result(
                session_id=session_id,
                broker_root=broker_root,
                source=source,
                client=client,
                terminal_pid=terminal_pid,
                pts=pts,
                messages=messages,
                dry_run=dry_run,
                delivered=delivered,
                notified=notified,
            )
        source, messages = c2c_poll_inbox.poll_inbox(
            broker_root=broker_root,
            session_id=session_id,
            timeout=timeout,
            force_file=file_fallback,
            allow_file_fallback=True,
        )
        delivered = 0
        for message in messages:
            if inject_payload(
                client=client,
                terminal_pid=terminal_pid,
                pts=pts,
                payload=message_payload(message),
                submit_delay=submit_delay,
            ):
                delivered += 1

    return build_result(
        session_id=session_id,
        broker_root=broker_root,
        source=source,
        client=client,
        terminal_pid=terminal_pid,
        pts=pts,
        messages=messages,
        dry_run=dry_run,
        delivered=delivered,
        notified=notified,
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
    notify_only: bool,
    submit_delay: float | None,
    notify_debounce: float,
    interval: float,
    max_iterations: int | None,
    watched_pid: int | None,
    xml_output_fd: int | None = None,
    xml_output_path: Path | None = None,
) -> dict[str, Any]:
    iterations = 0
    total_delivered = 0
    last_result: dict[str, Any] | None = None
    stopped_reason: str | None = None
    last_notify_at = 0.0
    last_notify_signature = ""

    while max_iterations is None or iterations < max_iterations:
        if watched_pid_exited(watched_pid):
            stopped_reason = "watched_pid_exited"
            break
        iterations += 1
        suppress_notify = False
        current_notify_signature = ""
        if notify_only and notify_debounce > 0:
            current_notify_signature = messages_signature(peek_inbox(broker_root, session_id))
            suppress_notify = (
                current_notify_signature == last_notify_signature
                and (time.monotonic() - last_notify_at) < notify_debounce
            )
        last_result = deliver_once(
            session_id=session_id,
            broker_root=broker_root,
            client=client,
            terminal_pid=terminal_pid,
            pts=pts,
            dry_run=dry_run,
            timeout=timeout,
            file_fallback=file_fallback,
            notify_only=notify_only,
            submit_delay=submit_delay,
            suppress_notify=suppress_notify,
            xml_output_fd=xml_output_fd,
            xml_output_path=xml_output_path,
        )
        if notify_only and last_result.get("notified"):
            last_notify_at = time.monotonic()
            last_notify_signature = current_notify_signature or messages_signature(
                last_result.get("messages", [])
            )
        elif notify_only and not last_result.get("messages"):
            last_notify_signature = ""
        total_delivered += int(last_result.get("delivered", 0))
        if max_iterations is not None and iterations >= max_iterations:
            break
        time.sleep(interval)

    result = {
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
    if watched_pid is not None:
        result["watched_pid"] = watched_pid
    if stopped_reason:
        result["stopped_reason"] = stopped_reason
    return result


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
    parser.add_argument(
        "--notify-only",
        action="store_true",
        help=(
            "peek for queued messages and inject only a poll_inbox nudge; "
            "do not drain or inject message content"
        ),
    )
    parser.add_argument(
        "--notify-debounce",
        type=float,
        default=30.0,
        help="minimum seconds between repeated notify-only nudges (default: 30)",
    )
    parser.add_argument(
        "--submit-delay",
        type=float,
        default=None,
        help="override delay between bracketed paste and Enter for PTY injection",
    )
    parser.add_argument("--loop", action="store_true", help="keep polling and delivering")
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--max-iterations", type=int, default=None)
    parser.add_argument("--pidfile", type=Path, default=None)
    parser.add_argument("--daemon", action="store_true", help="start detached")
    parser.add_argument("--daemon-log", type=Path, default=None)
    parser.add_argument("--daemon-timeout", type=float, default=10.0)
    parser.add_argument(
        "--client",
        choices=["claude", "codex", "codex-headless", "opencode", "kimi", "crush", "generic"],
        default="generic",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="peek and render without draining or injecting",
    )
    parser.add_argument(
        "--xml-output-fd",
        type=int,
        default=None,
        help="write Codex XML user-turn frames to this inherited fd instead of PTY injection",
    )
    parser.add_argument(
        "--xml-output-path",
        type=Path,
        default=None,
        help="write Codex XML user-turn frames by opening this fifo/path for write",
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
    watched_pid = watched_pid_from_args(args)
    if args.pidfile:
        write_pidfile(args.pidfile)

    if args.xml_output_fd is not None and args.xml_output_path is not None:
        parser.error("--xml-output-fd and --xml-output-path are mutually exclusive")

    try:
        if args.xml_output_fd is None and args.xml_output_path is None:
            import c2c_inject  # PTY-injection path; fails cleanly with ImportError if the module is in deprecated/
            terminal_pid, pts, _transcript = c2c_inject.resolve_session_info(args)
        else:
            terminal_pid = args.terminal_pid or args.pid or 0
            pts = args.pts or ""
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
                notify_only=args.notify_only,
                submit_delay=args.submit_delay,
                notify_debounce=args.notify_debounce,
                interval=args.interval,
                max_iterations=args.max_iterations,
                watched_pid=watched_pid,
                xml_output_fd=args.xml_output_fd,
                xml_output_path=args.xml_output_path,
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
                notify_only=args.notify_only,
                submit_delay=args.submit_delay,
                xml_output_fd=args.xml_output_fd,
                xml_output_path=args.xml_output_path,
            )
    except Exception as exc:
        print(f"[c2c-deliver-inbox] {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(
            json.dumps(
                public_result(result, redact_messages=args.notify_only),
                indent=2,
            )
        )
    else:
        action = "would deliver" if args.dry_run else "delivered"
        print(f"{action} {result['delivered']} message(s) to {args.client}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
