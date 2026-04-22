from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path

from .terminal_driver import TerminalCapture, TerminalHandle, TerminalStartSpec


class TmuxDriver:
    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root
        self.enter_helper = repo_root / "scripts" / "c2c-tmux-enter.sh"

    def start(self, spec: TerminalStartSpec) -> TerminalHandle:
        shell_cmd = " ".join(shlex.quote(part) for part in spec.command)
        result = subprocess.run(
            [
                "tmux",
                "new-session",
                "-d",
                "-P",
                "-F",
                "#{pane_id}",
                "-x",
                str(spec.cols),
                "-y",
                str(spec.rows),
                "bash",
                "-lc",
                f"cd {shlex.quote(str(spec.cwd))} && {shell_cmd}",
            ],
            capture_output=True,
            text=True,
            check=True,
            env={**os.environ, **spec.env},
        )
        return TerminalHandle(backend="tmux", target=result.stdout.strip())

    def send_text(self, handle: TerminalHandle, text: str) -> None:
        subprocess.run(["tmux", "send-keys", "-t", handle.target, "-l", text], check=True)

    def send_key(self, handle: TerminalHandle, key: str) -> None:
        if key == "Enter":
            subprocess.run([str(self.enter_helper), handle.target], check=True)
            return
        subprocess.run(["tmux", "send-keys", "-t", handle.target, key], check=True)

    def capture(self, handle: TerminalHandle) -> TerminalCapture:
        result = subprocess.run(
            ["tmux", "capture-pane", "-t", handle.target, "-p", "-S", "-200"],
            capture_output=True,
            text=True,
            check=True,
        )
        return TerminalCapture(text=result.stdout, raw=result.stdout)

    def is_alive(self, handle: TerminalHandle) -> bool:
        result = subprocess.run(
            ["tmux", "display-message", "-t", handle.target, "-p", "#{pane_dead}"],
            capture_output=True,
            text=True,
            check=False,
        )
        return result.returncode == 0 and result.stdout.strip() == "0"

    def stop(self, handle: TerminalHandle) -> None:
        subprocess.run(["tmux", "kill-pane", "-t", handle.target], check=False)
