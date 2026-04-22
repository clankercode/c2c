from __future__ import annotations

import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from .artifacts import ArtifactCollector
from .terminal_driver import TerminalDriver, TerminalHandle, TerminalStartSpec


@dataclass(frozen=True)
class AgentConfig:
    client: str
    name: str
    auto: bool = False
    backend: str | None = None
    model: str | None = None
    extra_args: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)


@dataclass
class StartedAgent:
    client: str
    name: str
    backend: str
    handle: TerminalHandle
    config: AgentConfig


class Adapter(Protocol):
    client_name: str
    default_backend: str

    def build_launch(self, scenario: "Scenario", config: AgentConfig) -> dict[str, object]: ...

    def is_ready(self, scenario: "Scenario", agent: StartedAgent) -> bool: ...

    def probe_capabilities(self, scenario: "Scenario") -> dict[str, bool]: ...


class Scenario:
    def __init__(
        self,
        test_name: str,
        workdir: Path,
        artifacts: ArtifactCollector,
        drivers: dict[str, TerminalDriver],
        adapters: dict[str, Adapter],
    ) -> None:
        self.test_name = test_name
        self.workdir = workdir
        self.artifacts = artifacts
        self.drivers = drivers
        self.adapters = adapters
        self.agents: dict[str, StartedAgent] = {}
        self._capability_cache: dict[str, dict[str, bool]] = {}
        self.workdir.mkdir(parents=True, exist_ok=True)

    def comment(self, text: str) -> None:
        self.artifacts.append_event("comment", {"text": text})

    def start_agent(
        self,
        client: str,
        *,
        name: str,
        auto: bool = False,
        backend: str | None = None,
        model: str | None = None,
        extra_args: list[str] | None = None,
        env: dict[str, str] | None = None,
    ) -> StartedAgent:
        config = AgentConfig(
            client=client,
            name=name,
            auto=auto,
            backend=backend,
            model=model,
            extra_args=list(extra_args or []),
            env=dict(env or {}),
        )
        adapter = self.adapters[client]
        driver_name = backend or adapter.default_backend
        driver = self.drivers[driver_name]
        launch = adapter.build_launch(self, config)
        spec = TerminalStartSpec(
            command=list(launch["command"]),
            cwd=Path(launch["cwd"]),
            env=dict(launch["env"]),
            title=str(launch["title"]),
            cols=int(launch.get("cols", 220)),
            rows=int(launch.get("rows", 60)),
        )
        handle = driver.start(spec)
        agent = StartedAgent(
            client=client,
            name=name,
            backend=driver_name,
            handle=handle,
            config=config,
        )
        self.agents[name] = agent
        self.artifacts.append_event(
            "agent.started",
            {"client": client, "name": name, "backend": driver_name},
        )
        return agent

    def wait_for(self, predicate: object, timeout: float, interval: float = 0.2) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if callable(predicate) and predicate():
                return
            time.sleep(interval)
        raise AssertionError("scenario.wait_for timed out")

    def wait_for_init(self, *agents: StartedAgent, timeout: float = 60.0) -> None:
        def _ready() -> bool:
            return all(self.adapters[agent.client].is_ready(self, agent) for agent in agents)

        self.wait_for(_ready, timeout=timeout)

    def probe_capabilities(self, client: str) -> dict[str, bool]:
        if client not in self._capability_cache:
            self._capability_cache[client] = self.adapters[client].probe_capabilities(self)
        return dict(self._capability_cache[client])

    def require_binary(self, name: str) -> None:
        if shutil.which(name) is None:
            raise AssertionError(f"required binary missing: {name}")
