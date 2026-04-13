#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path


COMMANDS = [
    "c2c",
    "c2c-deliver-inbox",
    "c2c-inject",
    "c2c-install",
    "c2c-list",
    "c2c-poll-inbox",
    "c2c-register",
    "c2c-send",
    "c2c-send-all",
    "c2c-verify",
    "c2c-whoami",
]


def install_bin_dir() -> Path:
    override = os.environ.get("C2C_INSTALL_BIN_DIR")
    if override:
        return Path(override)
    return Path.home() / ".local" / "bin"


def write_wrapper(target_dir: Path, command: str, repo_root: Path) -> None:
    wrapper_path = target_dir / command
    wrapper_path.write_text(
        f'#!/usr/bin/env bash\nset -euo pipefail\nexec "{repo_root / command}" "$@"\n',
        encoding="utf-8",
    )
    wrapper_path.chmod(0o755)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Install c2c commands into a user-local bin directory."
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parent
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
