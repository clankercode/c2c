#!/usr/bin/env python3
"""
c2c_coord_cherry_pick.py — Coordinator helper for cherry-picking SHAs with dirty-tree safety.

Usage: c2c coord-cherry-pick <sha>...

AC:
1. Multi-SHA cherry-pick (sequential)
2. Pre-flight git status: if dirty, auto-stash (only working-tree dirty, not staged)
3. On conflict: abort + report blocking SHA + restore stash + exit non-zero
4. On success: pop stash; if pop conflicts, leave stash + warn
5. Run just install-all and report build success/failure
6. Tier-2 utility, coordinator-only (check C2C_COORDINATOR env or require explicit flag)
"""

import argparse
import os
import subprocess
import sys
import time
from datetime import datetime, timezone


def ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")


def run(cmd: list[str], check: bool = False, capture: bool = True, cwd: str | None = None) -> subprocess.CompletedProcess | None:
    """Run a command, optionally checking exit code."""
    try:
        return subprocess.run(
            cmd,
            capture_output=capture,
            text=True,
            cwd=cwd,
            check=check,
        )
    except subprocess.CalledProcessError as e:
        return e
    except FileNotFoundError:
        return None


def git_status(repo: str) -> tuple[bool, bool, list[str]]:
    """Check git status. Returns (is_clean, is_dirty_working, output_lines)."""
    result = run(["git", "status", "--porcelain"], cwd=repo)
    if result is None or result.returncode != 0:
        return True, False, []
    lines = result.stdout.strip().splitlines()
    if not lines:
        return True, False, []
    # staged changes (index) vs unstaged (working tree)
    # Lines starting with space then letter = working tree dirty
    # Lines starting with letter then space = staged changes
    working_dirty = any(l.strip() and l[0] in " MADRC" for l in lines if not l.startswith("??"))
    return False, working_dirty, lines


def git_stash_push(repo: str, message: str) -> bool:
    """Stash working-tree changes. Returns True on success."""
    result = run(["git", "stash", "push", "-u", "-m", message], cwd=repo)
    return result is not None and result.returncode == 0


def git_stash_pop(repo: str) -> tuple[bool, bool]:
    """Pop stash. Returns (success, conflict)."""
    result = run(["git", "stash", "pop"], cwd=repo)
    if result is None:
        return False, False
    if result.returncode == 0:
        return True, False
    # Conflict
    return False, True


def git_cherry_pick(repo: str, sha: str) -> tuple[bool, str]:
    """Cherry-pick a single SHA. Returns (success, error_message)."""
    result = run(["git", "cherry-pick", sha], cwd=repo)
    if result is None:
        return False, "git cherry-pick not found"
    if result.returncode == 0:
        return True, ""
    # Check for conflict
    status = run(["git", "status", "--porcelain"], cwd=repo)
    conflicted = []
    if status and status.returncode == 0:
        conflicted = [l for l in status.stdout.strip().splitlines() if l.startswith("UU") or l.startswith("AA") or l.startswith("DD")]
    if conflicted:
        return False, f"conflict"
    return False, result.stderr.strip() or f"exit {result.returncode}"


def git_abort_cherry_pick(repo: str) -> None:
    run(["git", "cherry-pick", "--abort"], cwd=repo)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="c2c coord-cherry-pick",
        description="Coordinator helper: cherry-pick SHAs with dirty-tree safety + install.",
    )
    parser.add_argument(
        "--no-install",
        action="store_true",
        help="Skip just install-all after cherry-pick",
    )
    parser.add_argument(
        "shas",
        nargs="*",
        metavar="SHA",
        help="SHA(s) to cherry-pick (default: prompt-freeze uses C2C_COORDINATOR=1)",
    )
    args = parser.parse_args(argv)

    # Coordinator gate: C2C_COORDINATOR=1 env required
    if os.environ.get("C2C_COORDINATOR") != "1":
        print("error: C2C_COORDINATOR=1 required", file=sys.stderr)
        return 1

    shas = args.shas
    if not shas:
        parser.print_help()
        return 2

    repo = os.environ.get("C2C_REPO_ROOT", os.getcwd())
    print(f"[coord-cherry-pick] repo={repo}")
    print(f"[coord-cherry-pick] will cherry-pick: {shas}")

    # Pre-flight: git status
    is_clean, working_dirty, status_lines = git_status(repo)
    stash_msg = f"coord-cherry-pick-wip-{ts()}"
    stashed = False

    if not is_clean:
        if working_dirty:
            print(f"[coord-cherry-pick] working tree dirty — stashing: {stash_msg}")
            if git_stash_push(repo, stash_msg):
                stashed = True
                print("[coord-cherry-pick] stash created")
            else:
                print("[coord-cherry-pick] ERROR: failed to stash dirty working tree", file=sys.stderr)
                return 1
        else:
            print("[coord-cherry-pick] staged changes present but working tree clean — proceeding")

    # Cherry-pick sequentially
    for sha in shas:
        print(f"[coord-cherry-pick] cherry-picking {sha}...")
        ok, err = git_cherry_pick(repo, sha)
        if not ok:
            print(f"[coord-cherry-pick] FAILED on {sha}: {err}", file=sys.stderr)
            print(f"[coord-cherry-pick] aborting cherry-pick...")
            git_abort_cherry_pick(repo)
            print(f"[coord-cherry-pick] cherry-pick aborted")
            if stashed:
                print(f"[coord-cherry-pick] restoring stash...")
                success, conflict = git_stash_pop(repo)
                if conflict:
                    print(f"[coord-cherry-pick] WARNING: stash pop conflicted — stash left on stack", file=sys.stderr)
                elif success:
                    print("[coord-cherry-pick] stash restored")
            print(f"[coord-cherry-pick] BLOCKED at SHA: {sha}", file=sys.stderr)
            return 1
        print(f"[coord-cherry-pick] {sha} applied ✓")

    # Success: pop stash
    if stashed:
        print(f"[coord-cherry-pick] cherry-picks succeeded — popping stash...")
        success, conflict = git_stash_pop(repo)
        if conflict:
            print(f"[coord-cherry-pick] WARNING: stash pop conflicted — stash left on stack", file=sys.stderr)
        elif success:
            print("[coord-cherry-pick] stash restored ✓")
        else:
            print(f"[coord-cherry-pick] WARNING: stash pop failed silently", file=sys.stderr)

    # Run just install-all
    if not args.no_install:
        print("[coord-cherry-pick] running just install-all...")
        result = run(["just", "install-all"], cwd=repo)
        if result is None or result.returncode != 0:
            print(f"[coord-cherry-pick] just install-all FAILED", file=sys.stderr)
            if result:
                print(result.stdout, file=sys.stderr)
                print(result.stderr, file=sys.stderr)
            return 1
        print("[coord-cherry-pick] just install-all succeeded ✓")

    print("[coord-cherry-pick] done")
    return 0


if __name__ == "__main__":
    sys.exit(main())