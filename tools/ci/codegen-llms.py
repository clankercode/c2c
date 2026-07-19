#!/usr/bin/env python3
"""codegen-llms: generate the Docs link-list section of llms.txt from docs/ front-matter.

The bulk of llms.txt is hand-maintained prose (quick-start, tools table, CLI
subcommands). The one part that silently drifts is the Docs link-list — when a
new docs/*.md page is added it should appear in llms.txt but usually doesn't.

This script scans docs/*.md (and docs/reference/*.md, docs/clients/*.md) for
Jekyll front-matter (title + permalink) and emits the link-list block. It can
either print the block (for manual splicing) or check llms.txt for drift.

Usage:
    python3 tools/ci/codegen-llms.py            # print the Docs section
    python3 tools/ci/codegen-llms.py --check     # check llms.txt for drift (exit 1 if stale)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Pages to include in the Docs link-list, with the label to show.
# We curate the set rather than dumping every file (some are internal/research).
CURATED_PAGES = [
    ("docs/index.md", "Homepage / Agent Quick-Start"),
    ("docs/get-started.md", "Getting Started"),
    ("docs/overview.md", "Overview"),
    ("docs/commands.md", "Command Reference"),
    ("docs/reference/index.md", "Reference (index)"),
    ("docs/reference/scopes.md", "Reference: Scopes and Brokers"),
    ("docs/reference/identifiers.md", "Reference: Identifiers"),
    ("docs/reference/rooms.md", "Reference: Rooms and Visibility"),
    ("docs/architecture.md", "Architecture"),
    ("docs/connect.md", "Connect (cross-machine setup)"),
    ("docs/client-delivery.md", "Per-Client Delivery"),
    ("docs/wake-contract.md", "Delivery & Wake Contract"),
    ("docs/clients/feature-matrix.md", "Client Feature Matrix"),
    ("docs/known-issues.md", "Known Issues"),
    ("docs/changelog.md", "Changelog"),
]

DOCS_SECTION_BEGIN = "## Docs"
DOCS_SECTION_END = "## MCP Tools"


def read_frontmatter(path: Path) -> dict[str, str]:
    """Read Jekyll YAML front-matter (title, permalink) from a markdown file."""
    fm: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return fm
    if not text.startswith("---"):
        return fm
    end = text.find("\n---", 3)
    if end < 0:
        return fm
    block = text[3:end]
    for line in block.splitlines():
        m = re.match(r'^(\w+):\s*"?(.+?)"?\s*$', line.strip())
        if m:
            fm[m.group(1)] = m.group(2)
    return fm


def generate_docs_section(root: Path) -> str:
    """Generate the ## Docs link-list block from curated docs pages."""
    lines = [DOCS_SECTION_BEGIN, ""]
    for relpath, fallback_label in CURATED_PAGES:
        src = root / relpath
        if not src.exists():
            continue  # skip pages that don't exist (don't fail the build)
        fm = read_frontmatter(src)
        label = fm.get("title", fallback_label)
        permalink = fm.get("permalink", "")
        # In llms.txt, links are relative to the repo root: ./docs/<page>.md
        lines.append(f"- [{label}](./{relpath})")
    lines.append("")
    return "\n".join(lines)


def check_llms(root: Path) -> int:
    """Check if llms.txt's Docs section matches the generated one. Returns 0 if ok, 1 if drift."""
    llms = root / "llms.txt"
    if not llms.exists():
        print("error: llms.txt not found", file=sys.stderr)
        return 1
    text = llms.read_text(encoding="utf-8")
    # Extract the current Docs section
    begin = text.find(DOCS_SECTION_BEGIN)
    end = text.find(DOCS_SECTION_END)
    if begin < 0 or end < 0:
        print("error: could not find Docs section boundaries in llms.txt", file=sys.stderr)
        return 1
    current = text[begin:end].rstrip()
    expected = generate_docs_section(root).rstrip()
    if current == expected:
        print("codegen-llms: Docs section is up to date")
        return 0
    print("codegen-llms: Docs section has drifted. Update with:", file=sys.stderr)
    print("  python3 tools/ci/codegen-llms.py  # copy the output into llms.txt", file=sys.stderr)
    print("\n--- expected ---\n", expected, "\n--- current ---\n", current, sep="", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check llms.txt for drift (exit 1 if stale)")
    parser.add_argument("--root", default=".", help="repo root (default: cwd)")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    if args.check:
        return check_llms(root)
    print(generate_docs_section(root))
    return 0


if __name__ == "__main__":
    sys.exit(main())
