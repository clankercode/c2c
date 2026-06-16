#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys


def load_sessions(json_output=True):
    cmd = [sys.executable, "/home/xertrov/src/c2c-msg/claude_list_sessions.py"]
    if json_output:
        cmd.append("--json")
    result = subprocess.run(
        cmd,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def find_session(identifier: str, sessions: list[dict]):
    for session in sessions:
        if identifier in {
            session.get("session_id", ""),
            session.get("name", ""),
            str(session.get("pid", "")),
        }:
            return session
    return None


def extract_text_lines(transcript_path: str, limit: int):
    out = []
    with open(transcript_path) as f:
        for line in f:
            try:
                entry = json.loads(line)
            except Exception:
                continue
            etype = entry.get("type")
            if etype == "user":
                content = entry.get("message", {}).get("content", "")
                out.append({"role": "user", "text": content})
            elif etype == "assistant":
                content = entry.get("message", {}).get("content", [])
                texts = []
                for item in content:
                    if item.get("type") == "text":
                        texts.append(item.get("text", ""))
                if texts:
                    out.append({"role": "assistant", "text": "\n".join(texts)})
    return out[-limit:]


def main():
    parser = argparse.ArgumentParser(
        description="Read recent user/assistant messages from a Claude session transcript.",
        epilog="Example: claude-read-history 'C2C-test-agent2' --limit 6",
    )
    parser.add_argument("session")
    parser.add_argument("--limit", type=int, default=12)
    parser.add_argument(
        "--json", action="store_true", help="emit JSON instead of plain text"
    )
    args = parser.parse_args()

    sessions = load_sessions(json_output=True)
    session = find_session(args.session, sessions)
    if not session:
        print(f"session not found: {args.session}", file=sys.stderr)
        sys.exit(1)

    transcript = session.get("transcript")
    if not transcript:
        print("session has no transcript", file=sys.stderr)
        sys.exit(2)

    rows = extract_text_lines(transcript, args.limit)
    if args.json:
        print(
            json.dumps(
                {
                    "name": session.get("name"),
                    "session_id": session.get("session_id"),
                    "messages": rows,
                },
                indent=2,
            )
        )
        return

    print(f"Session: {session.get('name') or '<unnamed>'}")
    print(f"Session ID: {session.get('session_id')}")
    print("Recent messages:")
    for row in rows:
        print(f"[{row['role']}] {row['text']}")


if __name__ == "__main__":
    main()
