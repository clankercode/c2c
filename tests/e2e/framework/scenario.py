from __future__ import annotations

import hashlib
import json
import os
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
    role: str | None = None
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
        role: str | None = None,
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
            role=role,
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
        env = dict(os.environ)
        env["C2C_MCP_BROKER_ROOT"] = str(self.broker_root())
        if from_agent is not None:
            # The broker refuses `c2c send --from <alias>` from a process that
            # isn't that alias's own session ("registered to a different
            # session than yours"). The controller IS relaying on behalf of the
            # agent, so take the sanctioned escape hatch instead of spoofing a
            # session id. See CLAUDE.md: `C2C_COORDINATOR=1` bypasses the guard.
            env["C2C_COORDINATOR"] = "1"
        result = subprocess.run(
            command,
            cwd=self.workdir,
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            # Surface stderr — check=True would swallow it behind a bare
            # CalledProcessError and make live failures undebuggable.
            raise AssertionError(
                f"send_dm failed (exit {result.returncode}): "
                f"{result.stderr.strip() or result.stdout.strip()}"
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
        # Resolve the CANONICAL per-repo broker, mirroring
        # C2c_repo_fp.resolve_broker_root (OCaml, used by the c2c CLI + MCP
        # server) and resolveBrokerRoot (opencode plugin TS). We deliberately do
        # NOT invent a custom broker path: `c2c start` strips C2C_MCP_BROKER_ROOT
        # from managed clients (opencode/codex/kimi/claude register to the
        # canonical broker regardless of the env), and the CLI rejects the legacy
        # ".git/c2c/mcp" path outright. The only broker every client AND the
        # controller-side `c2c send` agree on is this canonical one.
        #
        #   <fp> = sha256(remote.origin.url)[:12], else sha256(git toplevel)[:12],
        #          else "default"
        #   root = $XDG_STATE_HOME/c2c/repos/<fp>/broker
        #          else $HOME/.c2c/repos/<fp>/broker
        #          else /tmp/c2c/repos/<fp>/broker
        if self._broker_root is None:
            fp = ""
            remote = subprocess.run(
                ["git", "config", "--get", "remote.origin.url"],
                cwd=self.workdir, capture_output=True, text=True,
            ).stdout.strip()
            if remote:
                fp = hashlib.sha256(remote.encode("utf-8")).hexdigest()[:12]
            if not fp:
                toplevel = subprocess.run(
                    ["git", "rev-parse", "--show-toplevel"],
                    cwd=self.workdir, capture_output=True, text=True,
                ).stdout.strip()
                if toplevel:
                    fp = hashlib.sha256(toplevel.encode("utf-8")).hexdigest()[:12]
            if not fp:
                fp = "default"
            xdg = os.environ.get("XDG_STATE_HOME", "").strip()
            home = os.environ.get("HOME", "").strip()
            if xdg:
                base = Path(xdg)
                self._broker_root = base / "c2c" / "repos" / fp / "broker"
            elif home:
                self._broker_root = Path(home) / ".c2c" / "repos" / fp / "broker"
            else:
                self._broker_root = Path("/tmp") / "c2c" / "repos" / fp / "broker"
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
