from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path

from .terminal_driver import TerminalCapture, TerminalHandle, TerminalStartSpec


class TmuxDriver:
    def __init__(self, repo_root: Path, socket: str | None = None) -> None:
        self.repo_root = repo_root
        self.enter_helper = repo_root / "scripts" / "c2c-tmux-enter.sh"
        # When set, every tmux invocation targets a dedicated server via
        # `tmux -L <socket>` so a crash in this driver's sessions cannot take
        # down the user's main tmux server (default socket). Used to isolate
        # heavy/fragile live tests (e.g. the chess e2e) from real sessions.
        self.socket = socket

    def _tmux(self, *args: str) -> list[str]:
        base = ["tmux"]
        if self.socket:
            base += ["-L", self.socket]
        return base + list(args)

    def start(self, spec: TerminalStartSpec) -> TerminalHandle:
        shell_cmd = " ".join(shlex.quote(part) for part in spec.command)
        command = self._tmux(
            "new-session",
            "-d",
            "-P",
            "-F",
            "#{pane_id}",
            "-x",
            str(spec.cols),
            "-y",
            str(spec.rows),
        )
        for key, value in spec.env.items():
            command.extend(["-e", f"{key}={value}"])
        command.extend(
            [
                "bash",
                "-lc",
                f"cd {shlex.quote(str(spec.cwd))} && {shell_cmd}",
            ]
        )
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=True,
            env=os.environ.copy(),
        )
        return TerminalHandle(backend="tmux", target=result.stdout.strip())

    def send_text(self, handle: TerminalHandle, text: str) -> None:
        subprocess.run(self._tmux("send-keys", "-t", handle.target, "-l", text), check=True)

    def send_key(self, handle: TerminalHandle, key: str) -> None:
        if key == "Enter":
            # The enter helper shells out to tmux on the DEFAULT socket, so it
            # cannot target a dedicated socket. Socket-isolated drivers don't
            # exercise the bracketed-paste path the helper exists for, so use a
            # plain send-keys against the isolated server instead.
            if self.socket:
                subprocess.run(self._tmux("send-keys", "-t", handle.target, "Enter"), check=True)
                return
            subprocess.run([str(self.enter_helper), handle.target], check=True)
            return
        subprocess.run(self._tmux("send-keys", "-t", handle.target, key), check=True)

    def capture(self, handle: TerminalHandle) -> TerminalCapture:
        result = subprocess.run(
            self._tmux("capture-pane", "-t", handle.target, "-p", "-S", "-200"),
            capture_output=True,
            text=True,
            check=True,
        )
        return TerminalCapture(text=result.stdout, raw=result.stdout)

    def is_alive(self, handle: TerminalHandle) -> bool:
        result = subprocess.run(
            self._tmux("display-message", "-t", handle.target, "-p", "#{pane_dead}"),
            capture_output=True,
            text=True,
            check=False,
        )
        return result.returncode == 0 and result.stdout.strip() == "0"

    def stop(self, handle: TerminalHandle) -> None:
        subprocess.run(self._tmux("kill-pane", "-t", handle.target), check=False)
