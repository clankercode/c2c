from __future__ import annotations

import fcntl
import os
import pty
import signal
import struct
import subprocess
import termios
from pathlib import Path

from .terminal_driver import TerminalCapture, TerminalHandle, TerminalStartSpec


class FakePtyDriver:
    def __init__(self) -> None:
        self._masters: dict[str, int] = {}
        self._buffers: dict[str, str] = {}
        self._procs: dict[str, subprocess.Popen[bytes]] = {}

    def start(self, spec: TerminalStartSpec) -> TerminalHandle:
        master_fd, slave_fd = pty.openpty()
        os.set_blocking(master_fd, False)
        try:
            self._set_winsize(slave_fd, rows=spec.rows, cols=spec.cols)
            proc = subprocess.Popen(
                spec.command,
                cwd=Path(spec.cwd),
                env={**os.environ, **spec.env},
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                text=False,
                start_new_session=True,
            )
        except Exception:
            os.close(master_fd)
            os.close(slave_fd)
            raise
        os.close(slave_fd)
        target = f"pty-{proc.pid}"
        self._masters[target] = master_fd
        self._buffers[target] = ""
        self._procs[target] = proc
        return TerminalHandle(backend="fake-pty", target=target, process_pid=proc.pid)

    def send_text(self, handle: TerminalHandle, text: str) -> None:
        os.write(self._require_master(handle), text.encode("utf-8"))

    def send_key(self, handle: TerminalHandle, key: str) -> None:
        if key != "Enter":
            raise NotImplementedError(f"unsupported fake-pty key: {key}")
        os.write(self._require_master(handle), b"\n")

    def capture(self, handle: TerminalHandle) -> TerminalCapture:
        target = handle.target
        master_fd = self._require_master(handle)
        chunks: list[str] = []
        while True:
            try:
                chunk = os.read(master_fd, 8192)
            except BlockingIOError:
                break
            except OSError:
                break
            if not chunk:
                break
            chunks.append(chunk.decode("utf-8", errors="replace"))
        if chunks:
            self._buffers[target] += "".join(chunks)
        captured = self._buffers.get(target, "")
        return TerminalCapture(text=captured, raw=captured)

    def is_alive(self, handle: TerminalHandle) -> bool:
        proc = self._procs.get(handle.target)
        return proc is not None and proc.poll() is None

    def stop(self, handle: TerminalHandle) -> None:
        proc = self._procs.pop(handle.target, None)
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=2.0)
        master_fd = self._masters.pop(handle.target, None)
        if master_fd is not None:
            os.close(master_fd)
        self._buffers.pop(handle.target, None)

    def _require_master(self, handle: TerminalHandle) -> int:
        try:
            return self._masters[handle.target]
        except KeyError as exc:
            raise KeyError(f"unknown fake-pty target: {handle.target}") from exc

    def _set_winsize(self, slave_fd: int, *, rows: int, cols: int) -> None:
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
