from __future__ import annotations

import json
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

import pytest

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


class ScenarioAgentAssertion:
    def __init__(self, scenario: "Scenario", agent: StartedAgent) -> None:
        self._scenario = scenario
        self._agent = agent

    def alive(self) -> None:
        if not self._scenario.drivers[self._agent.backend].is_alive(self._agent.handle):
            raise AssertionError(f"{self._agent.name} is not alive")

    def registered_alive(self) -> None:
        registry = self._scenario.broker_root() / "registry.json"
        if not registry.exists():
            raise AssertionError(f"broker registry missing: {registry}")
        registrations = json.loads(registry.read_text(encoding="utf-8") or "[]")
        rows = registrations if isinstance(registrations, list) else registrations.get("registrations", [])
        for row in rows:
            if row.get("alias") == self._agent.name and row.get("alive") is not False:
                return
        raise AssertionError(f"{self._agent.name} is not registered alive in broker registry")


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
        self._adapter_capability_cache: dict[str, dict[str, bool]] = {}
        self._capability_cache: dict[str, bool] = {}
        self._broker_root: Path | None = None
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
        if name in self.agents:
            raise ValueError(f"duplicate agent name: {name}")
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

    def capture(self, agent: StartedAgent) -> str:
        capture = self.drivers[agent.backend].capture(agent.handle)
        self.artifacts.write_text(f"{agent.name}.capture.txt", capture.text)
        return capture.text

    def send_dm(self, from_agent: StartedAgent | None, to_agent: StartedAgent, text: str) -> None:
        # Deterministic controller-side broker injection for terminal E2E tests.
        command = ["c2c", "send"]
        if from_agent is not None:
            command.extend(["--from", from_agent.name])
        command.extend([to_agent.name, text])
        subprocess.run(
            command,
            cwd=self.workdir,
            check=True,
            capture_output=True,
            text=True,
        )
        self.artifacts.append_event(
            "dm.sent",
            {
                "from_agent": None if from_agent is None else from_agent.name,
                "to_agent": to_agent.name,
                "text": text,
            },
        )

    def broker_root(self) -> Path:
        if self._broker_root is None:
            git_common = subprocess.run(
                ["git", "rev-parse", "--git-common-dir"],
                cwd=self.workdir,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            self._broker_root = (self.workdir / git_common / "c2c" / "mcp").resolve()
        return self._broker_root

    def broker_inbox_contains(self, agent: StartedAgent, text: str) -> bool:
        inbox = self.broker_root() / f"{agent.name}.inbox.json"
        if not inbox.exists():
            return False
        payload = json.loads(inbox.read_text(encoding="utf-8") or "[]")
        return text in json.dumps(payload)

    def managed_inner_cmdline(self, agent: StartedAgent) -> str:
        inner_pid_path = Path.home() / ".local" / "share" / "c2c" / "instances" / agent.name / "inner.pid"
        try:
            pid = int(inner_pid_path.read_text(encoding="utf-8").strip())
        except (OSError, ValueError) as exc:
            raise AssertionError(f"could not read inner pid for {agent.name}: {inner_pid_path}") from exc
        try:
            raw = Path(f"/proc/{pid}/cmdline").read_bytes()
        except OSError as exc:
            raise AssertionError(f"could not read inner cmdline for {agent.name} pid {pid}") from exc
        cmdline = raw.replace(b"\0", b" ").decode("utf-8", errors="replace").strip()
        if not cmdline:
            raise AssertionError(f"inner cmdline empty for {agent.name} pid {pid}")
        return cmdline

    def assert_agent(self, agent: StartedAgent) -> ScenarioAgentAssertion:
        return ScenarioAgentAssertion(self, agent)

    def probe_capabilities(self, client: str) -> dict[str, bool]:
        if client not in self._adapter_capability_cache:
            self._adapter_capability_cache[client] = self.adapters[client].probe_capabilities(self)
        self._capability_cache.update(self._adapter_capability_cache[client])
        return dict(self._adapter_capability_cache[client])

    def require_capability(self, name: str) -> None:
        if not self._capability_cache.get(name, False):
            raise AssertionError(f"required capability missing: {name}")

    def xfail_unless(self, name: str, reason: str) -> None:
        if not self._capability_cache.get(name, False):
            pytest.xfail(reason)

    def refresh_capabilities(self) -> dict[str, bool]:
        merged: dict[str, bool] = {}
        for client in self.adapters:
            client_caps = self.adapters[client].probe_capabilities(self)
            self._adapter_capability_cache[client] = dict(client_caps)
            merged.update(client_caps)
        self._capability_cache = merged
        return dict(merged)

    def require_binary(self, name: str) -> None:
        if shutil.which(name) is None:
            raise AssertionError(f"required binary missing: {name}")
