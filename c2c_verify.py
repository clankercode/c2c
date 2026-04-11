#!/usr/bin/env python3
import argparse
import json
import os
import sys
from pathlib import Path

from c2c_registry import prune_registrations, update_registry
from claude_list_sessions import load_sessions


GOAL_COUNT = 20
OPEN_TAG = "<c2c-message>"
close_tag = "</c2c-message>"


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
    return isinstance(content, str) and OPEN_TAG in content and close_tag in content


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

    def mutate_registry(registry: dict) -> dict:
        pruned_registry = prune_registrations(registry, set(sessions_by_id))
        registry["registrations"] = pruned_registry["registrations"]
        return registry

    pruned_registry = update_registry(mutate_registry)
    sessions = sorted(
        [
            sessions_by_id[registration["session_id"]]
            for registration in pruned_registry.get("registrations", [])
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify transcript-backed c2c progress across participants."
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        payload = verify_progress()
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1

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
