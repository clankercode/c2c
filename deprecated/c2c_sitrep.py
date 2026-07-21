#!/usr/bin/env python3
"""c2c_sitrep.py — create a new hourly sitrep entry.

Creates `.sitreps/<YYYY>/<MM>/<DD>/<HH>.md` for the given UTC hour (default:
current UTC hour) pre-filled with the standard template from `.sitreps/PROTOCOL.md`.

Usage:
    c2c_sitrep.py                          # create sitrep for current UTC hour
    c2c_sitrep.py --hour 09                # create sitrep for 09 UTC today
    c2c_sitrep.py --date 2026-04-22 --hour 08
    c2c_sitrep.py --agent jungel-coder     # override drafting agent
    c2c_sitrep.py --force                  # overwrite existing file

Errors if the target file already exists (unless --force).

Environment variables consumed (for autofill):
    C2C_MCP_AUTO_REGISTER_ALIAS  — drafting agent alias
    C2C_MCP_CLIENT_TYPE          — drafting client type (opencode/claude/codex/...)
    C2C_MCP_SESSION_ID           — drafting session id
    USER                          — fallback author
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent
SITREPS_DIR = REPO_ROOT / ".sitreps"


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def resolve_target(date: dt.date, hour: int) -> Path:
    return SITREPS_DIR / f"{date.year:04d}" / f"{date.month:02d}" / f"{date.day:02d}" / f"{hour:02d}.md"


def prior_sitrep_link(target: Path) -> str:
    """Return a relative markdown link to the previous sitrep if one exists."""
    date_dir = target.parent
    hour = int(target.stem)
    # Try earlier hour same day first.
    for h in range(hour - 1, -1, -1):
        candidate = date_dir / f"{h:02d}.md"
        if candidate.exists():
            return f"[{candidate.stem} UTC]({candidate.name})"
    # Walk back up to three days of history.
    today = dt.date(int(date_dir.parent.parent.name), int(date_dir.parent.name), int(date_dir.name))
    for back in range(1, 4):
        prior_date = today - dt.timedelta(days=back)
        prior_day_dir = SITREPS_DIR / f"{prior_date.year:04d}" / f"{prior_date.month:02d}" / f"{prior_date.day:02d}"
        if not prior_day_dir.exists():
            continue
        md_files = sorted(prior_day_dir.glob("[0-9][0-9].md"))
        if md_files:
            latest = md_files[-1]
            rel = os.path.relpath(latest, date_dir)
            return f"[{prior_date.isoformat()} {latest.stem} UTC]({rel})"
    return "none (first sitrep)"


def git_head_sha() -> str:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(REPO_ROOT), "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        return out.strip()
    except Exception:
        return "(unknown)"


def commits_ahead_of_origin() -> str:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(REPO_ROOT), "rev-list", "--count", "origin/master..HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        return out.strip()
    except Exception:
        return "?"


def render_template(
    *,
    target: Path,
    utc_ts: str,
    draft_agent: str,
    draft_client: str,
    draft_session: str,
    prior: str,
    head_sha: str,
    commits_ahead: str,
) -> str:
    return f"""# Sitrep {target.stem}:00 UTC ({draft_agent})

> **Draft metadata**
> - drafted: {utc_ts}
> - agent: `{draft_agent}`
> - client: `{draft_client}`
> - session: `{draft_session}`
> - git HEAD: `{head_sha}` ({commits_ahead} commits ahead of origin/master)
> - previous sitrep: {prior}

## 1. Swarm roster

| Alias        | PID | Client | Current focus | Last activity |
|--------------|-----|--------|---------------|---------------|
|              |     |        |               |               |

Dead registrations: _count_.

## 2. Recent activity (since prior sitrep)

- Commits landed:
- Bugs closed:
- Findings filed:
- Design docs updated:
- Permissions / notable broker events:

## 3. Active tasks

- **coordinator1**:
- **jungel-coder**:
- **galaxy-coder**:
- **ceo**:

## 4. Blocked tasks

- Upstream:
- Human:
- External dep:
- Review:

## 5. Next actions per agent

- **coordinator1**:
- **jungel-coder**:
- **galaxy-coder**:
- **ceo**:

## 6. Goal tree

- **North star**: unify Claude Code, Codex, OpenCode, Kimi as first-class
  peers on the c2c broker
  - **[feature] agent-file epic**
  - **[feature] codex-headless**
  - **[feature] c2c GUI**
  - **[flow] cross-client messaging**
  - **[sidequest] relay health + deploys**
  - **[sidequest] swarm social layer**
  - **[sidequest] sitrep discipline**

_(restructure if drift shows; collapse stale sidequests into a single
bucket when no activity in 6+ hours)_

## 7. Gaps & concerns

- _(or "no new gaps this hour")_
"""


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Create a new c2c hourly sitrep entry.")
    parser.add_argument("--date", help="UTC date (YYYY-MM-DD). Defaults to today UTC.", default=None)
    parser.add_argument(
        "--hour", help="UTC hour (00-23). Defaults to current UTC hour.", type=int, default=None
    )
    parser.add_argument(
        "--agent",
        help="Drafting agent alias. Defaults to $C2C_MCP_AUTO_REGISTER_ALIAS or 'coordinator1'.",
        default=None,
    )
    parser.add_argument("--force", action="store_true", help="Overwrite if sitrep already exists.")
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Print the template to stdout instead of writing the file.",
    )
    args = parser.parse_args(argv)

    now = utc_now()
    if args.date:
        target_date = dt.date.fromisoformat(args.date)
    else:
        target_date = now.date()
    target_hour = args.hour if args.hour is not None else now.hour
    if not 0 <= target_hour <= 23:
        print(f"error: --hour must be 0-23, got {target_hour}", file=sys.stderr)
        return 2

    target = resolve_target(target_date, target_hour)

    draft_agent = (
        args.agent
        or os.environ.get("C2C_MCP_AUTO_REGISTER_ALIAS")
        or os.environ.get("USER")
        or "coordinator1"
    )
    draft_client = os.environ.get("C2C_MCP_CLIENT_TYPE", "(unset)")
    draft_session = os.environ.get("C2C_MCP_SESSION_ID", "(unset)")
    utc_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    body = render_template(
        target=target,
        utc_ts=utc_ts,
        draft_agent=draft_agent,
        draft_client=draft_client,
        draft_session=draft_session,
        prior=prior_sitrep_link(target) if target.parent.exists() else "none (first sitrep)",
        head_sha=git_head_sha(),
        commits_ahead=commits_ahead_of_origin(),
    )

    if args.stdout:
        sys.stdout.write(body)
        return 0

    if target.exists() and not args.force:
        print(f"error: {target} already exists (use --force to overwrite)", file=sys.stderr)
        return 1

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body)
    # Intentionally do NOT print the body — the caller (coordinator1) should
    # Read the file to populate it, not ingest the scaffold into their own
    # context window. Emit path + explicit instruction only.
    print(f"scaffold written: {target}")
    print(f"next: Read {target}, then fill in the required sections per .sitreps/PROTOCOL.md")
    print(f"      (swarm roster, recent activity, active/blocked tasks, next actions, goal tree, gaps)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
