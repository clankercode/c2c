#!/usr/bin/env python3
# DEPRECATED — PTY injection path. See docs/known-issues.md for current delivery paths.
"""Inject messages into live Claude/Codex sessions via PTY or history.jsonl.

For terminal-emulator sessions (Ghostty, etc.), uses bracketed paste via pty_inject.
For SSH or headless sessions, falls back to direct history.jsonl append.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any
from xml.sax.saxutils import quoteattr

import c2c_poker

KIMI_SUBMIT_DELAY = 1.5

# Keycode map: display name -> bytes to send
KEYCODES = {
    "enter": b"\r",
    "esc": b"\x1b",
    "ctrlc": b"\x03",
    "ctrlz": b"\x1a",
    "ctrlc": b"\x03",
    "ctrlz": b"\x1a",
    "up": b"\x1b[A",
    "down": b"\x1b[B",
    "right": b"\x1b[C",
    "left": b"\x1b[D",
    "tab": b"\x09",
    "backspace": b"\x7f",
    "del": b"\x1b[3~",
    "home": b"\x1b[H",
    "end": b"\x1b[F",
    "pageup": b"\x1b[5~",
    "pagedown": b"\x1b[6~",
}


def parse_keycode(token: str) -> bytes | None:
    """Parse a token like ':enter' or ':ctrlc' into bytes. Returns None if not a keycode."""
    if not token.startswith(":"):
        return None
    name = token[1:].lower()
    return KEYCODES.get(name)


def render_payload(
    message: str,
    event: str,
    sender: str,
    alias: str,
    raw: bool,
    *,
    source: str = "pty",
    source_tool: str = "c2c_inject",
) -> str:
    if raw or message.lstrip().startswith("<"):
        return message
    attrs = [f"event={quoteattr(event)}", f"from={quoteattr(sender)}"]
    if alias:
        attrs.append(f"alias={quoteattr(alias)}")
    if source:
        attrs.append(f"source={quoteattr(source)}")
    if source_tool:
        attrs.append(f"source_tool={quoteattr(source_tool)}")
    attrs.append('action_after="continue"')
    return f"<c2c {' '.join(attrs)}>\n{message}\n</c2c>"


def inject_via_pty(terminal_pid: int, pts: str, payload: str, submit_delay: float | None = None, parts: list[bytes] | None = None) -> None:
    """Inject via PTY using pty_inject helper (bracketed paste + enter)."""
    if parts:
        # Multi-part injection with delays
        for i, part in enumerate(parts):
            payload_with_brackets = b"\x1b[200~" + part + b"\x1b[201~"
            c2c_poker.inject(terminal_pid, pts, payload_with_brackets.decode('utf-8', errors='replace'))
            if i < len(parts) - 1 and submit_delay:
                time.sleep(submit_delay / 1000.0)
        # Final enter
        c2c_poker.inject(terminal_pid, pts, "\r")
    else:
        c2c_poker.inject(terminal_pid, pts, payload, submit_delay=submit_delay)


def inject_via_history(session_id: str, message: str, cwd: str | None = None) -> None:
    """Inject by appending a user message to the session's history.jsonl."""
    import uuid as uuid_lib

    slug = (cwd or "/home/xertrov").replace("/", "-")
    home = Path.home()

    # Try multiple transcript locations
    transcript_paths = [
        home / ".claude" / "projects" / slug / f"{session_id}.jsonl",
        home / ".claude-shared" / "projects" / slug / f"{session_id}.jsonl",
    ]

    transcript_path = None
    for p in transcript_paths:
        if p.exists():
            transcript_path = p
            break

    if not transcript_path:
        raise RuntimeError(f"Could not find transcript for session {session_id} (tried: {[str(p) for p in transcript_paths]})")

    entry = {
        "parentUuid": str(uuid_lib.uuid4()),
        "isSidechain": False,
        "promptId": str(uuid_lib.uuid4()),
        "type": "user",
        "message": {
            "role": "user",
            "content": message,
        },
        "uuid": str(uuid_lib.uuid4()),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "userType": "external",
        "entrypoint": "cli",
        "cwd": cwd or "/home/xertrov",
        "sessionId": session_id,
        "version": "2.1.109",
        "gitBranch": "HEAD",
    }

    with open(transcript_path, "a") as f:
        f.write(json.dumps(entry) + "\n")


def resolve_session_info(args: argparse.Namespace) -> tuple[int, str, str | None]:
    """Resolve target: return (terminal_pid, pts, transcript_path)."""
    if args.claude_session:
        return c2c_poker.resolve_claude_session(args.claude_session)
    if args.pid is not None:
        return c2c_poker.resolve_pid(args.pid)
    return int(args.terminal_pid), str(args.pts), None


def resolve_session_id_for_history(args: argparse.Namespace) -> tuple[str, str | None]:
    """Get (session_id, cwd) for history injection. Uses legacy session files as fallback."""
    import claude_list_sessions as cls

    if args.claude_session:
        sessions = cls.load_sessions(with_terminal_owner=False)
        for session in sessions:
            if args.claude_session in {session.get("session_id", ""), session.get("name", ""), str(session.get("pid", ""))}:
                return session["session_id"], session.get("cwd")
        raise RuntimeError(f"Session not found: {args.claude_session}")
    if args.pid is not None:
        sessions = cls.load_sessions(with_terminal_owner=False)
        for session in sessions:
            if session.get("pid") == args.pid:
                return session["session_id"], session.get("cwd")
        raise RuntimeError(f"Could not find session for PID {args.pid}")
    raise RuntimeError("Need --claude-session or --pid for history injection")


def resolve_cwd(args: argparse.Namespace, session_id: str) -> str | None:
    """Get cwd from session info."""
    if args.claude_session:
        for session in c2c_poker.list_claude_sessions():
            if args.claude_session in {session.get("session_id", ""), session.get("name", ""), str(session.get("pid", ""))}:
                return session.get("cwd")
    if args.pid is not None:
        for session in c2c_poker.list_claude_sessions():
            if session.get("pid") == args.pid:
                return session.get("cwd")
    return None


def build_result(
    *,
    client: str,
    method: str,
    terminal_pid: int | None,
    pts: str | None,
    payload: str,
    dry_run: bool,
    submit_delay: float | None,
    sent_at: float,
) -> dict[str, Any]:
    return {
        "ok": True,
        "client": client,
        "method": method,
        "terminal_pid": terminal_pid,
        "pts": pts,
        "payload": payload[:200],
        "dry_run": dry_run,
        "submit_delay": submit_delay,
        "sent_at": sent_at,
    }


def effective_submit_delay(client: str, submit_delay: float | None) -> float | None:
    if submit_delay is not None:
        return submit_delay
    if client == "kimi":
        return KIMI_SUBMIT_DELAY
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Inject a message into a live Claude, Codex, OpenCode, or generic TTY client. "
                    "Supports keycodes (:enter, :esc, :ctrlc, :up, etc.) and multi-part injection with delay."
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--claude-session", metavar="NAME_OR_ID")
    target.add_argument("--pid", type=int, metavar="PID")
    target.add_argument("--terminal-pid", type=int, metavar="PID")
    parser.add_argument("--pts", metavar="N", help="required with --terminal-pid")
    parser.add_argument(
        "--client",
        choices=["claude", "codex", "opencode", "kimi", "generic"],
        default="generic",
        help="client label for result metadata (default: generic)",
    )
    parser.add_argument("--event", default="message")
    parser.add_argument("--from", dest="sender", default="c2c-inject")
    parser.add_argument("--alias", default="")
    parser.add_argument("--raw", action="store_true", help="do not wrap in <c2c>")
    parser.add_argument(
        "--delay",
        type=float,
        default=500.0,
        metavar="MS",
        help="delay between parts in ms (default: 500)",
    )
    parser.add_argument(
        "--submit-delay",
        type=float,
        default=None,
        metavar="S",
        dest="submit_delay",
        help="seconds to wait before sending Enter after bracketed paste",
    )
    parser.add_argument(
        "--method",
        choices=["pty", "history", "auto"],
        default="auto",
        help="injection method: pty (bracketed paste), history (jsonl append), or auto (try pty first, fallback to history)",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("message", nargs="+")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    if args.terminal_pid is not None and not args.pts:
        parser.error("--terminal-pid requires --pts")

    sent_at = time.time()

    # Parse message parts into (text_or_keycode, bytes) tuples
    parts: list[tuple[str, bytes]] = []
    for token in args.message:
        kb = parse_keycode(token)
        if kb is not None:
            parts.append((token, kb))
        else:
            parts.append((token, token.encode("utf-8")))

    # Build full text for payload (only text parts, no keycodes)
    full_text = " ".join(t for t, _ in parts if not t.startswith(":"))
    payload = c2c_poker.render_payload(
        full_text,
        args.event,
        args.sender,
        args.alias,
        args.raw,
        source="pty",
        source_tool="c2c_inject",
    )

    submit_delay = effective_submit_delay(args.client, args.submit_delay)

    method_used = None
    terminal_pid = None
    pts = None

    if args.method in ("pty", "auto"):
        if args.dry_run:
            # Resolve session for dry-run output but skip injection
            try:
                terminal_pid, pts, _transcript = resolve_session_info(args)
                method_used = "pty"
            except Exception:
                pass

    if not args.dry_run:
        if args.method in ("pty", "auto"):
            try:
                terminal_pid, pts, _transcript = resolve_session_info(args)
                # Try PTY injection
                has_keycodes = any(name.startswith(":") for name, _ in parts)
                if not has_keycodes:
                    # All plain text — join into a single message and inject once
                    if submit_delay is None:
                        c2c_poker.inject(terminal_pid, pts, payload)
                    else:
                        c2c_poker.inject(terminal_pid, pts, payload, submit_delay=submit_delay)
                else:
                    # Multi-part with keycodes — inject each part sequentially
                    for i, (name, data) in enumerate(parts):
                        payload_i = render_payload(name, args.event, args.sender, args.alias, args.raw,
                                                   source="pty", source_tool="c2c_inject")
                        # Write with bracketed paste
                        bracketed = b"\x1b[200~" + name.encode("utf-8") + b"\x1b[201~"
                        c2c_poker.inject(terminal_pid, pts, bracketed.decode("utf-8", errors="replace"))
                        time.sleep(args.delay / 1000.0)
                        # Send enter
                        c2c_poker.inject(terminal_pid, pts, "\r")
                        if i < len(parts) - 1:
                            time.sleep(args.delay / 1000.0)
                method_used = "pty"
            except Exception as e:
                if args.method == "pty":
                    print(f"PTY injection failed: {e}", file=sys.stderr)
                    return 1
                # Fall through to history for auto mode
                method_used = None

        if method_used is None and args.method in ("history", "auto"):
            try:
                session_id, cwd = resolve_session_id_for_history(args)
                inject_via_history(session_id, full_text, cwd)
                method_used = "history"
                terminal_pid = None
                pts = None
            except Exception as e:
                print(f"History injection failed: {e}", file=sys.stderr)
                return 1

    result = build_result(
        client=args.client,
        method=method_used or args.method,
        terminal_pid=terminal_pid,
        pts=pts,
        payload=payload,
        dry_run=args.dry_run,
        submit_delay=submit_delay,
        sent_at=sent_at,
    )
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        action = "would inject" if args.dry_run else "injected"
        method_str = f" via {method_used}" if method_used else ""
        print(f"{action} into {args.client}{method_str}: {full_text[:50]}{'...' if len(full_text) > 50 else ''}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
