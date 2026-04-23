from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import TYPE_CHECKING

from .capabilities import (
    CLAUDE_CHANNEL,
    CODEX_HEADLESS_THREAD_ID_FD,
    CODEX_XML_FD,
    KIMI_WIRE,
    OPENCODE_PLUGIN,
)
from .scenario import AgentConfig

if TYPE_CHECKING:
    from .scenario import Scenario, StartedAgent


_HELP_PROBE_TIMEOUT_SECONDS = 2.0
_CODEX_HEADLESS_READY_GRACE_SECONDS = 1.0


def _help_contains(binary: str, flag: str) -> bool:
    try:
        result = subprocess.run(
            [binary, "--help"],
            capture_output=True,
            text=True,
            check=False,
            timeout=_HELP_PROBE_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, OSError, subprocess.SubprocessError):
        return False
    return flag in (result.stdout + result.stderr)


def _instance_dir(name: str) -> Path:
    return Path.home() / ".local" / "share" / "c2c" / "instances" / name


def compile_role(workdir: Path, alias: str, client: str) -> Path:
    """Compile a minimal canonical role to a client-specific agent file.

    Writes a bare-bones role to .c2c/roles/<alias>.md then runs
    ``c2c roles compile <alias> --client <client>`` to render the
    client-specific agent file.

    Returns the Path of the compiled agent file on success.
    Raises RuntimeError if the compiled file is not created.
    """
    roles_dir = workdir / ".c2c" / "roles"
    roles_dir.mkdir(parents=True, exist_ok=True)
    role_file = roles_dir / f"{alias}.md"
    role_file.write_text(
        "---\nrole: subagent\ndescription: smoke-test\n---\n\nYou are a test agent.\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        ["c2c", "roles", "compile", alias, "--client", client],
        cwd=workdir,
        capture_output=True,
        text=True,
        check=True,
    )
    client_dir_map = {
        "opencode": workdir / ".opencode" / "agents",
        "kimi": workdir / ".kimi" / "agents",
        "claude": workdir / ".claude" / "agents",
        "codex": workdir / ".codex" / "agents",
    }
    agent_file = client_dir_map.get(client, workdir) / f"{alias}.md"
    if not agent_file.exists():
        raise RuntimeError(
            f"compile_role: {agent_file} not created after "
            f"'c2c roles compile {alias} --client {client}'\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return agent_file


def _has_live_pid(pidfile: Path) -> bool:
    try:
        pid = int(pidfile.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


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
        return _has_live_pid(_instance_dir(agent.name) / "inner.pid")

    def probe_capabilities(self, scenario: Scenario | None) -> dict[str, bool]:
        return {CODEX_XML_FD: _help_contains("codex", "--xml-input-fd")}


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
        instance_dir = _instance_dir(agent.name)
        config_path = instance_dir / "config.json"
        inner_pid = instance_dir / "inner.pid"
        deliver_pid = instance_dir / "deliver.pid"
        handoff_path = instance_dir / "thread-id-handoff.jsonl"
        fifo_path = instance_dir / "xml-input.fifo"
        meta_path = instance_dir / "meta.json"
        if not config_path.exists() or not handoff_path.exists() or not fifo_path.exists():
            return False
        if not _has_live_pid(inner_pid) or not _has_live_pid(deliver_pid):
            return False
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            start_ts = float(meta["start_ts"])
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
            return False
        # Headless is only really ready once the bridge, fifo, and deliver
        # daemon have all settled. Without a short grace period the first DM
        # can race startup and make the live tmux tests flaky even though the
        # managed path itself works.
        return time.time() - start_ts >= _CODEX_HEADLESS_READY_GRACE_SECONDS

    def probe_capabilities(self, scenario: Scenario | None) -> dict[str, bool]:
        return {
            CODEX_HEADLESS_THREAD_ID_FD: _help_contains(
                "codex-turn-start-bridge",
                "--thread-id-fd",
            )
        }


class OpenCodeAdapter:
    client_name = "opencode"
    default_backend = "tmux"

    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root

    def build_launch(self, scenario: Scenario, config: AgentConfig) -> dict[str, object]:
        command = ["c2c", "start", self.client_name, "-n", config.name]
        if config.role:
            command.extend(["--agent", config.role])
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
        if not scenario.drivers[agent.backend].is_alive(agent.handle):
            return False
        return _has_live_pid(_instance_dir(agent.name) / "inner.pid")

    def probe_capabilities(self, scenario: Scenario | None) -> dict[str, bool]:
        plugin_path = self.repo_root / ".opencode" / "plugins" / "c2c.ts"
        return {OPENCODE_PLUGIN: plugin_path.exists()}


class ClaudeAdapter:
    client_name = "claude"
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
        if not scenario.drivers[agent.backend].is_alive(agent.handle):
            return False
        return _has_live_pid(_instance_dir(agent.name) / "inner.pid")

    def probe_capabilities(self, scenario: Scenario | None) -> dict[str, bool]:
        return {CLAUDE_CHANNEL: shutil.which("claude") is not None}


class KimiAdapter:
    client_name = "kimi"
    default_backend = "tmux"

    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root

    def build_launch(self, scenario: Scenario, config: AgentConfig) -> dict[str, object]:
        command = ["c2c", "start", self.client_name, "-n", config.name]
        if config.role:
            command.extend(["--agent", config.role])
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
        if not scenario.drivers[agent.backend].is_alive(agent.handle):
            return False
        return _has_live_pid(_instance_dir(agent.name) / "inner.pid")

    def probe_capabilities(self, scenario: Scenario | None) -> dict[str, bool]:
        return {KIMI_WIRE: shutil.which("kimi") is not None}
