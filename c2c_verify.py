#!/usr/bin/env python3
import argparse
import json
import os
import sys
from pathlib import Path
from c2c_registry import load_registry
from claude_list_sessions import load_sessions


GOAL_COUNT = 20
C2C_MESSAGE_MARKER = '<c2c event="message"'
C2C_CLOSE_TAG = "</c2c>"


def resolve_transcript_path(transcript: str) -> Path:
    path = Path(transcript)
    if path.is_absolute() or path.exists():
        return path

    sessions_fixture = os.environ.get("C2C_SESSIONS_FIXTURE")
    if sessions_fixture:
        fixture_relative_path = Path(sessions_fixture).resolve().parent / path
        if fixture_relative_path.exists():
            return fixture_relative_path

    fixture_root = os.environ.get("C2C_VERIFY_FIXTURE")
    if fixture_root:
        fixture_path = Path(fixture_root) / path
        if fixture_path.exists():
            return fixture_path

    return path


def is_c2c_user_message(entry: dict) -> bool:
    if entry.get("type") != "user":
        return False
    content = entry.get("message", {}).get("content", "")
    return (
        isinstance(content, str)
        and C2C_MESSAGE_MARKER in content
        and C2C_CLOSE_TAG in content
    )


def has_assistant_text(entry: dict) -> bool:
    if entry.get("type") != "assistant":
        return False
    content = entry.get("message", {}).get("content", [])
    if not isinstance(content, list):
        return False
    for item in content:
        if item.get("type") == "text" and item.get("text", ""):
            return True
    return False


def is_assistant_tool_use(entry: dict) -> bool:
    if entry.get("type") != "assistant":
        return False
    content = entry.get("message", {}).get("content", [])
    return isinstance(content, list) and any(
        item.get("type") == "tool_use" for item in content
    )


def is_user_tool_result(entry: dict) -> bool:
    if entry.get("type") != "user":
        return False
    content = entry.get("message", {}).get("content", [])
    return isinstance(content, list) and any(
        item.get("type") == "tool_result" for item in content
    )


def summarize_transcript(transcript_path: str) -> dict:
    counts = {"received": 0, "sent": 0}
    pending_replies = 0

    with resolve_transcript_path(transcript_path).open(encoding="utf-8") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            if is_c2c_user_message(entry):
                counts["received"] += 1
                pending_replies += 1
                continue

            if pending_replies > 0 and has_assistant_text(entry):
                counts["sent"] += 1
                pending_replies -= 1
                continue

            if pending_replies > 0 and (
                is_assistant_tool_use(entry) or is_user_tool_result(entry)
            ):
                continue

            pending_replies = 0

    return counts


def participant_name(session: dict) -> str:
    return session.get("name") or session.get("session_id") or "unknown-session"


def participant_label(session: dict, duplicate_names: set[str]) -> str:
    name = participant_name(session)
    if name not in duplicate_names:
        return name

    session_id = session.get("session_id") or "unknown"
    return f"{name} ({session_id[:8]})"


def verify_progress() -> dict:
    sessions_by_id = {
        session.get("session_id"): session
        for session in load_sessions()
        if session.get("session_id")
    }

    registry = load_registry()
    sessions = sorted(
        [
            sessions_by_id[registration["session_id"]]
            for registration in registry.get("registrations", [])
            if registration.get("session_id") in sessions_by_id
        ],
        key=participant_name,
    )
    name_counts = {}
    for session in sessions:
        name = participant_name(session)
        name_counts[name] = name_counts.get(name, 0) + 1

    duplicate_names = {name for name, count in name_counts.items() if count > 1}
    participants = {}
    for session in sessions:
        transcript = session.get("transcript")
        if not transcript:
            raise ValueError(f"session has no transcript: {participant_name(session)}")
        participants[participant_label(session, duplicate_names)] = (
            summarize_transcript(transcript)
        )

    goal_met = bool(participants) and all(
        counts["sent"] >= GOAL_COUNT and counts["received"] >= GOAL_COUNT
        for counts in participants.values()
    )
    return {"participants": participants, "goal_met": goal_met}


def _count_archive_lines(path: Path) -> int:
    """Count non-empty lines in an archive JSONL file."""
    try:
        return sum(1 for line in path.read_text(encoding="utf-8").splitlines() if line.strip())
    except OSError:
        return 0


def verify_progress_broker(broker_root: Path | None = None, alive_only: bool = False) -> dict:
    """Broker-based verification using archive JSONL files.

    Works across all client types (Claude, Codex, OpenCode, Kimi, Crush).
    ``received`` is the count of messages drained from a session's inbox
    (archived).  ``sent`` is inferred by scanning all archive files for
    entries where ``from_alias`` matches the session's registered alias.

    Returns the same schema as ``verify_progress()`` so callers can use
    either mode interchangeably.
    """
    if broker_root is None:
        import c2c_mcp as _mcp
        broker_root = _mcp.default_broker_root()

    archive_dir = broker_root / "archive"

    # The OCaml broker stores its registry as a JSON array at
    # <broker_root>/registry.json.  Fall back to the Python YAML registry
    # if the JSON file is absent (e.g. in tests using a temp broker root).
    broker_registry_path = broker_root / "registry.json"
    if broker_registry_path.exists():
        try:
            raw_regs = json.loads(broker_registry_path.read_text(encoding="utf-8"))
            registrations = raw_regs if isinstance(raw_regs, list) else []
        except (json.JSONDecodeError, OSError):
            registrations = []
    else:
        registry = load_registry()
        registrations = registry.get("registrations", [])

    # session_id → received count (from own archive file)
    received_by_session: dict[str, int] = {}
    # alias → sent count (from_alias entries in any archive file)
    sent_by_alias: dict[str, int] = {}

    if archive_dir.exists():
        for archive_file in sorted(archive_dir.glob("*.jsonl")):
            session_id = archive_file.stem
            received_by_session[session_id] = _count_archive_lines(archive_file)
            try:
                for raw in archive_file.read_text(encoding="utf-8").splitlines():
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        msg = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    from_alias = msg.get("from_alias") or ""
                    if not from_alias or from_alias == "c2c-system":
                        continue
                    sent_by_alias[from_alias] = sent_by_alias.get(from_alias, 0) + 1
            except OSError:
                continue

    participants: dict[str, dict[str, int]] = {}
    for reg in registrations:
        alias = reg.get("alias") or ""
        session_id = reg.get("session_id") or ""
        if not alias:
            continue
        if alive_only:
            import c2c_mcp as _mcp
            if not _mcp.broker_registration_is_alive(reg):
                continue
        # received: look for archive by session_id first, then alias (named sessions)
        received = received_by_session.get(session_id, received_by_session.get(alias, 0))
        sent = sent_by_alias.get(alias, 0)
        participants[alias] = {"sent": sent, "received": received}

    goal_met = bool(participants) and all(
        counts["sent"] >= GOAL_COUNT and counts["received"] >= GOAL_COUNT
        for counts in participants.values()
    )
    return {"participants": participants, "goal_met": goal_met, "source": "broker"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify c2c message exchange progress across participants."
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--broker",
        action="store_true",
        help=(
            "Use broker archive data instead of Claude transcripts. "
            "Works across all client types (Claude, Codex, OpenCode, Kimi, Crush)."
        ),
    )
    parser.add_argument(
        "--broker-root",
        metavar="DIR",
        help="Override broker root directory (default: auto-detected via git).",
    )
    parser.add_argument(
        "--alive-only",
        action="store_true",
        help=(
            "In --broker mode: exclude dead registrations from results "
            "so ghost/test entries don't skew the goal_met calculation."
        ),
    )
    args = parser.parse_args(argv)

    if args.broker or args.broker_root:
        broker_root = Path(args.broker_root) if args.broker_root else None
        alive_only = getattr(args, "alive_only", False)
        try:
            payload = verify_progress_broker(broker_root, alive_only=alive_only)
        except (OSError, ValueError) as error:
            print(str(error), file=sys.stderr)
            return 1
    else:
        try:
            payload = verify_progress()
        except (OSError, ValueError) as error:
            print(str(error), file=sys.stderr)
            return 1
        # If transcript mode finds fewer participants than the broker, or none at all
        # (e.g. mixed-client swarm with Codex/Kimi/Crush), fall back to broker archive
        # mode which works across all client types.
        # Skip the fallback when test fixtures are in use (C2C_SESSIONS_FIXTURE or
        # C2C_VERIFY_FIXTURE) to avoid contaminating fixture-based tests with live data.
        in_test_mode = bool(
            os.environ.get("C2C_SESSIONS_FIXTURE") or os.environ.get("C2C_VERIFY_FIXTURE")
        )
        if not in_test_mode:
            transcript_count = len(payload["participants"])
            try:
                broker_payload = verify_progress_broker(alive_only=True)
                broker_count = len(broker_payload["participants"])
            except (OSError, ValueError):
                broker_payload = None
                broker_count = 0
            if broker_payload is not None and broker_count > transcript_count:
                payload = broker_payload
                if not args.json:
                    reason = "no Claude transcripts found" if transcript_count == 0 else f"broker has more participants ({broker_count} vs {transcript_count})"
                    print(f"(broker mode — {reason})", file=sys.stderr)

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    for name, counts in payload["participants"].items():
        status = (
            "goal_met"
            if counts["sent"] >= GOAL_COUNT and counts["received"] >= GOAL_COUNT
            else "in_progress"
        )
        print(
            f"{name}: sent={counts['sent']} received={counts['received']} status={status}"
        )
    print(f"goal_met: {'yes' if payload['goal_met'] else 'no'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
