#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
from pathlib import Path


COMMANDS = [
    "c2c",
    "c2c-broker-gc",
    "c2c-claude-wake",
    "c2c-configure-claude-code",
    "c2c-configure-codex",
    "c2c-configure-kimi",
    "c2c-configure-opencode",
    "c2c-kimi-wake",
    "c2c-kimi-wire-bridge",
    "c2c-opencode-wake",
    "c2c-setup",
    "c2c-deliver-inbox",
    "c2c-health",
    "c2c-init",
    "c2c-inject",
    "c2c-install",
    "c2c-list",
    "c2c-poll-inbox",
    "c2c-poker-sweep",
    "c2c-prune",
    "c2c-register",
    "c2c-restart-me",
    "c2c-room",
    "c2c-send",
    "c2c-send-all",
    "c2c-verify",
    "c2c-instances",
    "c2c-restart",
    "c2c-start",
    "c2c-stop",
    "c2c-wake-peer",
    "c2c-watch",
    "c2c-whoami",
    "cc-quota",
    "restart-codex-self",
    "restart-kimi-self",
    "restart-opencode-self",
    "run-kimi-inst",
    "run-kimi-inst-outer",
    "run-kimi-inst-rearm",
]


def install_bin_dir() -> Path:
    override = os.environ.get("C2C_INSTALL_BIN_DIR")
    if override:
        return Path(override)
    return Path.home() / ".local" / "bin"


def write_wrapper(target_dir: Path, command: str, repo_root: Path) -> None:
    wrapper_path = target_dir / command
    command_path = repo_root / command
    if not command_path.exists():
        command_path = repo_root / "scripts" / command
    wrapper_path.write_text(
        f'#!/usr/bin/env bash\nset -euo pipefail\nexec "{command_path}" "$@"\n',
        encoding="utf-8",
    )
    wrapper_path.chmod(0o755)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Install c2c commands into a user-local bin directory."
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    # Resolve the canonical main-worktree root via git-common-dir so that
    # running `c2c install` from a linked worktree still writes wrappers that
    # point at the main repo checkout (which persists when worktrees are deleted).
    script_dir = Path(__file__).resolve().parent
    try:
        git_common_dir = subprocess.check_output(
            ["git", "rev-parse", "--git-common-dir"],
            cwd=str(script_dir),
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        common_path = Path(git_common_dir)
        if not common_path.is_absolute():
            common_path = (script_dir / common_path).resolve()
        # common_path is the main .git dir; its parent is the main worktree root.
        repo_root = common_path.parent
    except (subprocess.CalledProcessError, OSError):
        repo_root = script_dir
    target_dir = install_bin_dir()
    target_dir.mkdir(parents=True, exist_ok=True)

    for command in COMMANDS:
        write_wrapper(target_dir, command, repo_root)

    bin_on_path = str(target_dir) in os.environ.get("PATH", "").split(os.pathsep)
    payload = {
        "bin_dir": str(target_dir),
        "installed_commands": COMMANDS,
        "bin_on_path": bin_on_path,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    print(f"Installed c2c commands into {target_dir}")
    if not bin_on_path:
        print(f"{target_dir} is not currently on PATH")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
