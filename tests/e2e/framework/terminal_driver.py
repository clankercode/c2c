from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol


@dataclass
class TerminalHandle:
    backend: str
    target: str
    process_pid: int | None = None
    metadata: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class TerminalCapture:
    text: str
    raw: str


@dataclass
class TerminalStartSpec:
    command: list[str]
    cwd: Path
    env: dict[str, str]
    title: str
    cols: int = 220
    rows: int = 60


class TerminalDriver(Protocol):
    def start(self, spec: TerminalStartSpec) -> TerminalHandle: ...

    def send_text(self, handle: TerminalHandle, text: str) -> None: ...

    def send_key(self, handle: TerminalHandle, key: str) -> None: ...

    def capture(self, handle: TerminalHandle) -> TerminalCapture: ...

    def is_alive(self, handle: TerminalHandle) -> bool: ...

    def stop(self, handle: TerminalHandle) -> None: ...
