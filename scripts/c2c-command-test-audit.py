#!/usr/bin/env python3
"""Audit Tier 1/2 c2c commands for test references.

This is intentionally static and conservative: it reports command names that do
not appear to be exercised by test files. It does not prove full coverage.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


TIER_RE = re.compile(r"let\s+(tier[12])\s*=\s*\[(.*?)\]\s*in", re.S)
COMMAND_RE = re.compile(r'\(\s*"([^"]+)"\s*,')


def extract_tier_commands(c2c_ml: Path) -> list[str]:
    text = c2c_ml.read_text(encoding="utf-8")
    commands: list[str] = []
    for match in TIER_RE.finditer(text):
        commands.extend(COMMAND_RE.findall(match.group(2)))
    return commands


def test_files(repo: Path) -> list[Path]:
    roots = [repo / "tests", repo / "ocaml" / "test", repo / "ocaml" / "cli"]
    files: list[Path] = []
    for root in roots:
        if root.exists():
            files.extend(
                p
                for p in root.rglob("*")
                if p.is_file()
                and p.suffix in {".py", ".sh", ".ml", ".ts", ".tsx"}
                and ("test" in p.name or p.parent.name == "test")
            )
    return sorted(files)


def quoted_token_re(token: str) -> re.Pattern[str]:
    return re.compile(r'["\']' + re.escape(token) + r'["\']')


def references_command(text: str, command: str) -> bool:
    tokens = command.split()
    phrase = "c2c " + command
    if phrase in text or command in text:
        return True
    if not tokens:
        return False
    if len(tokens) == 1:
        return bool(quoted_token_re(tokens[0]).search(text))
    token_patterns = [quoted_token_re(token) for token in tokens]
    pos = 0
    for pattern in token_patterns:
        match = pattern.search(text, pos)
        if match is None:
            return False
        pos = match.end()
    return True


def audit(repo: Path) -> tuple[list[str], list[str]]:
    c2c_ml = repo / "ocaml" / "cli" / "c2c.ml"
    if not c2c_ml.exists():
        return ([], [])
    commands = extract_tier_commands(c2c_ml)
    texts = []
    for path in test_files(repo):
        try:
            texts.append(path.read_text(encoding="utf-8", errors="ignore"))
        except OSError:
            pass
    referenced: list[str] = []
    missing: list[str] = []
    for command in commands:
        if any(references_command(text, command) for text in texts):
            referenced.append(command)
        else:
            missing.append(command)
    return (referenced, missing)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="repository root to audit")
    parser.add_argument("--summary", action="store_true", help="print compact output")
    parser.add_argument("--warn-only", action="store_true", help="exit 0 even when gaps exist")
    args = parser.parse_args(argv)

    repo = Path(args.repo).resolve()
    c2c_ml = repo / "ocaml" / "cli" / "c2c.ml"
    if not c2c_ml.exists():
        print("command-test-audit: skipped (ocaml/cli/c2c.ml not found)")
        return 0

    referenced, missing = audit(repo)
    total = len(referenced) + len(missing)
    print(
        f"command-test-audit: {len(referenced)}/{total} Tier 1/2 commands referenced by tests; "
        f"{len(missing)} gap(s)"
    )
    if missing:
        if args.summary:
            print("untested: " + ", ".join(missing))
        else:
            print()
            print("Commands without an obvious test reference:")
            for command in missing:
                print(f"  - {command}")
            print()
            print("Note: this is a static reference audit, not a coverage proof.")
    return 0 if args.warn_only or not missing else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
