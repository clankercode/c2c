#!/usr/bin/env python3
"""Audit CLAUDE.md for stale repo paths and top-level c2c commands.

This is intentionally conservative. It checks high-signal claims that are cheap
to verify statically and reports drift as warnings for c2c doctor.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


CODE_SPAN_RE = re.compile(r"`([^`\n]+)`")
CMD_INFO_RE = re.compile(r'Cmdliner\.Cmd\.info\s+"([^"]+)"')
C2C_CMD_RE = re.compile(r"(?:^|\s)c2c\s+([a-z][a-z0-9_/-]*)")
PATH_SUFFIXES = (
    ".md",
    ".py",
    ".sh",
    ".ml",
    ".mli",
    ".ts",
    ".tsx",
    ".json",
    ".toml",
    ".yml",
    ".yaml",
)
PATH_PREFIXES = (".collab/", ".c2c/", "docs/", "scripts/", "ocaml/", "./")


@dataclass(frozen=True)
class Finding:
    kind: str
    source: str
    line: int
    claim: str
    message: str


def strip_punctuation(token: str) -> str:
    return token.strip().rstrip(".,);:")


def is_placeholder(token: str) -> bool:
    return "<" in token or ">" in token or "$" in token or "*" in token


def looks_repo_path(token: str) -> bool:
    token = strip_punctuation(token)
    if not token or is_placeholder(token):
        return False
    if token.startswith(("~", "/", "http://", "https://")):
        return False
    if token.startswith(PATH_PREFIXES):
        return True
    # Bare root-level scripts in the deprecated script list are useful to check,
    # but bare OCaml/module filenames in prose are usually illustrative.
    return "/" not in token and token.endswith((".py", ".sh"))


def normalize_repo_path(token: str) -> str:
    token = strip_punctuation(token)
    if token.startswith("./"):
        token = token[2:]
    return token


def iter_code_claims(path: Path):
    in_fence = False
    for lineno, line in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        for match in CODE_SPAN_RE.finditer(line):
            yield lineno, match.group(1)
        if in_fence and stripped:
            first = stripped.split()[0]
            yield lineno, first


def extract_top_level_commands(repo: Path) -> set[str]:
    c2c_ml = repo / "ocaml" / "cli" / "c2c.ml"
    if not c2c_ml.exists():
        return set()
    text = c2c_ml.read_text(encoding="utf-8", errors="ignore")
    all_cmds_match = re.search(r"let\s+all_cmds\s*=\s*\[(.*?)\]\s*in", text, re.S)
    if not all_cmds_match:
        return set(CMD_INFO_RE.findall(text))
    all_cmds = all_cmds_match.group(1)
    names = set(CMD_INFO_RE.findall(all_cmds))
    # Most top-level commands are variables listed in all_cmds, so map variable
    # names back to their Cmd.info names.
    variable_names = set(re.findall(r"\b([A-Za-z0-9_]+)\b", all_cmds))
    for var in variable_names:
        match = re.search(
            r"let\s+%s\s*=\s*Cmdliner\.Cmd\.v\s*\(Cmdliner\.Cmd\.info\s+\"([^\"]+)\""
            % re.escape(var),
            text,
        )
        if match:
            names.add(match.group(1))
    # External module groups are top-level, but their concrete names are not in
    # this file in the simple pattern above.
    for module_path, command in [
        ("ocaml/cli/c2c_setup.ml", "install"),
        ("ocaml/cli/c2c.ml", "wire-daemon"),
        ("ocaml/cli/c2c_rooms.ml", "rooms"),
        ("ocaml/cli/c2c_rooms.ml", "room"),
        ("ocaml/cli/c2c_agent.ml", "agent"),
        ("ocaml/cli/c2c_agent.ml", "roles"),
        ("ocaml/cli/c2c_worktree.ml", "worktree"),
        ("ocaml/cli/c2c_stickers.ml", "sticker"),
        ("ocaml/cli/c2c_memory.ml", "memory"),
        ("ocaml/cli/c2c_peer_pass.ml", "peer-pass"),
    ]:
        if (repo / module_path).exists():
            names.add(command)
    return names


def audit_docs(repo: Path, docs: list[Path]) -> list[Finding]:
    commands = extract_top_level_commands(repo)
    findings: list[Finding] = []
    seen: set[tuple[str, str, int]] = set()

    for doc in docs:
        if not doc.exists():
            findings.append(Finding("doc", str(doc), 0, str(doc), "document is missing"))
            continue
        rel_doc = str(doc.relative_to(repo)) if doc.is_relative_to(repo) else str(doc)
        for line, claim in iter_code_claims(doc):
            for raw in claim.split():
                if looks_repo_path(raw):
                    path_claim = normalize_repo_path(raw)
                    key = ("path", path_claim, line)
                    if key in seen:
                        continue
                    seen.add(key)
                    if not (repo / path_claim).exists():
                        findings.append(
                            Finding("path", rel_doc, line, path_claim, "repo path does not exist")
                        )
            for cmd_match in C2C_CMD_RE.finditer(claim):
                raw_cmd = strip_punctuation(cmd_match.group(1))
                for command in raw_cmd.split("/"):
                    if not command or is_placeholder(command):
                        continue
                    key = ("command", command, line)
                    if key in seen:
                        continue
                    seen.add(key)
                    if commands and command not in commands:
                        findings.append(
                            Finding(
                                "command",
                                rel_doc,
                                line,
                                f"c2c {command}",
                                "top-level c2c command is not registered",
                            )
                        )
    return findings


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="repository root")
    parser.add_argument(
        "--doc",
        action="append",
        default=[],
        help="doc path relative to repo; defaults to CLAUDE.md",
    )
    parser.add_argument("--summary", action="store_true", help="print compact output")
    parser.add_argument("--warn-only", action="store_true", help="exit 0 even when drift exists")
    args = parser.parse_args(argv)

    repo = Path(args.repo).resolve()
    default_docs = not args.doc
    docs = [repo / d for d in (args.doc or ["CLAUDE.md"])]
    if default_docs and not docs[0].exists():
        print("docs-drift: skipped (CLAUDE.md not found)")
        return 0
    findings = audit_docs(repo, docs)

    print(f"docs-drift: checked {len(docs)} doc(s); {len(findings)} drift finding(s)")
    if findings:
        if args.summary:
            rendered = "; ".join(
                f"{f.source}:{f.line} {f.claim} ({f.message})" for f in findings
            )
            print("drift: " + rendered)
        else:
            print()
            print("Documentation claims that appear stale:")
            for f in findings:
                print(f"  - {f.source}:{f.line}: {f.claim} — {f.message}")
            print()
            print("Note: this is a static docs drift audit, not a full documentation review.")

    return 0 if args.warn_only or not findings else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
