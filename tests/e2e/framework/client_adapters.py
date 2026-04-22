from __future__ import annotations

import subprocess
from pathlib import Path
from typing import TYPE_CHECKING

from .scenario import AgentConfig

if TYPE_CHECKING:
    from .scenario import Scenario, StartedAgent


def _help_contains(binary: str, flag: str) -> bool:
    try:
        result = subprocess.run(
            [binary, "--help"],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return False
    return flag in (result.stdout + result.stderr)


class CodexAdapter:
    client_name = "codex"
    default_backend = "tmux"

    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root

    def build_launch(self, scenario: Scenario, config: AgentConfig) -> dict[str, object]:
        command = ["c2c", "start", self.client_name, "-n", config.name]
        if config.auto:
            command.append("--auto")
        if config.extra_args:
            command.extend(["--", *config.extra_args])
        return {
            "command": command,
            "cwd": scenario.workdir,
            "env": dict(config.env),
            "title": config.name,
        }

    def is_ready(self, scenario: Scenario, agent: StartedAgent) -> bool:
        driver = scenario.drivers[agent.backend]
        if not driver.is_alive(agent.handle):
            return False
        instance_dir = Path.home() / ".local" / "share" / "c2c" / "instances" / agent.name
        return instance_dir.exists()

    def probe_capabilities(self, scenario: Scenario | None) -> dict[str, bool]:
        return {"codex_xml_fd": _help_contains("codex", "--xml-input-fd")}


class CodexHeadlessAdapter:
    client_name = "codex-headless"
    default_backend = "tmux"

    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root

    def build_launch(self, scenario: Scenario, config: AgentConfig) -> dict[str, object]:
        command = ["c2c", "start", self.client_name, "-n", config.name]
        if config.auto:
            command.append("--auto")
        if config.extra_args:
            command.extend(["--", *config.extra_args])
        return {
            "command": command,
            "cwd": scenario.workdir,
            "env": dict(config.env),
            "title": config.name,
        }

    def is_ready(self, scenario: Scenario, agent: StartedAgent) -> bool:
        driver = scenario.drivers[agent.backend]
        if not driver.is_alive(agent.handle):
            return False
        instance_dir = Path.home() / ".local" / "share" / "c2c" / "instances" / agent.name
        return (instance_dir / "config.json").exists()

    def probe_capabilities(self, scenario: Scenario | None) -> dict[str, bool]:
        return {
            "codex_headless_thread_id_fd": _help_contains(
                "codex-turn-start-bridge",
                "--thread-id-fd",
            )
        }
