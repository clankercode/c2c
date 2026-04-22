# Terminal E2E Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable `pytest` terminal E2E framework with shared `Scenario` / `TerminalDriver` abstractions, then use it to add first-class Codex and `codex-headless` early-eval coverage.

**Architecture:** Add a small Python framework under `tests/e2e/framework/` with four layers: terminal mechanics, scenario orchestration, client adapters, and artifact collection. Land deterministic framework tests first, then add opt-in tmux live tests for `c2c start codex` and `c2c start codex-headless`, using explicit capability-gated `xfail` for updated Codex surfaces that are not installed yet.

**Tech Stack:** Python `pytest`, stdlib `subprocess`/`pty`/`pathlib`/`json`, `tmux`, existing repo scripts (`scripts/c2c_tmux.py`, `scripts/c2c-tmux-enter.sh`, `scripts/c2c-tmux-exec.sh`, `scripts/tui-snapshot.sh`), real `c2c` / `codex` / `codex-turn-start-bridge` binaries for opt-in live tests.

---

## File Map

### New framework files

- Create: `tests/e2e/framework/__init__.py`
  - Small export surface for `Scenario`, `TerminalDriver`, `TmuxDriver`, `FakePtyDriver`, and adapters.
- Create: `tests/e2e/framework/terminal_driver.py`
  - Driver-neutral dataclasses and abstract base class.
- Create: `tests/e2e/framework/artifacts.py`
  - Artifact root management, timeline writing, and opt-in golden snapshot comparisons.
- Create: `tests/e2e/framework/scenario.py`
  - Main orchestration object, agent lifecycle, waits, comments, capability gating, and teardown.
- Create: `tests/e2e/framework/tmux_driver.py`
  - Real tmux backend for live TUI sessions.
- Create: `tests/e2e/framework/fake_pty_driver.py`
  - CI-safe fake PTY backend for framework validation and low-cost protocol tests.
- Create: `tests/e2e/framework/client_adapters.py`
  - `CodexAdapter` and `CodexHeadlessAdapter`, plus common adapter dataclasses/helpers.
- Create: `tests/e2e/fixtures/fake_terminal_child.py`
  - Tiny echo/ready child process used by `FakePtyDriver` tests.

### New tests

- Create: `tests/test_terminal_e2e_framework.py`
  - Deterministic framework tests plus fake-PTY round-trip coverage.
- Create: `tests/test_terminal_e2e_client_adapters.py`
  - Capability probes, command construction, and readiness checks for Codex adapters.
- Create: `tests/test_c2c_codex_twin_e2e.py`
  - Opt-in live tmux Codex tests: fallback path now, XML path `xfail` until updated binary.
- Create: `tests/test_c2c_codex_headless_e2e.py`
  - Opt-in live tmux/bridge `codex-headless` smoke tests, capability-gated and `xfail` until bridge support lands.

### Existing files to modify

- Modify: `.gitignore`
  - Ignore `.artifacts/e2e/`.
- Modify: `tests/conftest.py`
  - Add a `scenario` fixture and best-effort cleanup for framework-owned tmux sessions / processes.

## Task 1: Artifact Root And Core Driver Types

**Files:**
- Modify: `.gitignore`
- Create: `tests/e2e/framework/__init__.py`
- Create: `tests/e2e/framework/terminal_driver.py`
- Create: `tests/e2e/framework/artifacts.py`
- Test: `tests/test_terminal_e2e_framework.py`

- [ ] **Step 1: Write the failing framework-core tests**

```python
from pathlib import Path

import pytest

from tests.e2e.framework.artifacts import ArtifactCollector
from tests.e2e.framework.terminal_driver import TerminalCapture, TerminalHandle


def test_artifact_collector_creates_run_dir_and_timeline(tmp_path: Path) -> None:
    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    run_dir = collector.start_run()

    assert run_dir.parent == tmp_path / "test_demo"
    assert (run_dir / "timeline.jsonl").exists()


def test_artifact_collector_writes_actual_on_golden_mismatch(tmp_path: Path) -> None:
    golden = tmp_path / "golden.txt"
    golden.write_text("expected screen\n", encoding="utf-8")

    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    collector.start_run()

    with pytest.raises(AssertionError):
        collector.compare_golden("screen", "actual screen\n", golden)

    assert (collector.run_dir / "screen.actual.txt").exists()


def test_terminal_types_keep_backend_and_target_explicit() -> None:
    handle = TerminalHandle(
        backend="fake-pty",
        target="pty-1",
        process_pid=12345,
    )
    capture = TerminalCapture(
        text="READY\n",
        raw="READY\r\n",
    )

    assert handle.backend == "fake-pty"
    assert handle.target == "pty-1"
    assert capture.text == "READY\n"
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run:

```bash
pytest -q tests/test_terminal_e2e_framework.py -k "artifact_collector or terminal_types"
```

Expected:

```text
E   ModuleNotFoundError: No module named 'tests.e2e.framework'
```

- [ ] **Step 3: Write the minimal framework-core implementation**

```python
# tests/e2e/framework/terminal_driver.py
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol


@dataclass(frozen=True)
class TerminalHandle:
    backend: str
    target: str
    process_pid: int | None = None
    metadata: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class TerminalCapture:
    text: str
    raw: str


@dataclass(frozen=True)
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
```

```python
# tests/e2e/framework/artifacts.py
from __future__ import annotations

import json
import time
from pathlib import Path


class ArtifactCollector:
    def __init__(self, root: Path, test_name: str) -> None:
        self.root = root
        self.test_name = test_name
        self.run_dir: Path | None = None

    def start_run(self) -> Path:
        run_id = time.strftime("%Y%m%d-%H%M%S")
        self.run_dir = self.root / self.test_name / run_id
        self.run_dir.mkdir(parents=True, exist_ok=True)
        (self.run_dir / "timeline.jsonl").write_text("", encoding="utf-8")
        return self.run_dir

    def append_event(self, event: str, payload: dict[str, object]) -> None:
        assert self.run_dir is not None
        path = self.run_dir / "timeline.jsonl"
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"event": event, **payload}) + "\n")

    def write_text(self, name: str, text: str) -> Path:
        assert self.run_dir is not None
        path = self.run_dir / name
        path.write_text(text, encoding="utf-8")
        return path

    def compare_golden(self, stem: str, actual: str, golden_path: Path) -> None:
        expected = golden_path.read_text(encoding="utf-8")
        if actual != expected:
            self.write_text(f"{stem}.actual.txt", actual)
            raise AssertionError(f"{stem} did not match golden snapshot {golden_path}")
```

```python
# tests/e2e/framework/__init__.py
from .artifacts import ArtifactCollector
from .terminal_driver import TerminalCapture, TerminalDriver, TerminalHandle, TerminalStartSpec
```

```gitignore
# .gitignore
.artifacts/e2e/
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
pytest -q tests/test_terminal_e2e_framework.py -k "artifact_collector or terminal_types"
```

Expected:

```text
3 passed
```

- [ ] **Step 5: Commit**

```bash
git add .gitignore tests/e2e/framework/__init__.py tests/e2e/framework/terminal_driver.py tests/e2e/framework/artifacts.py tests/test_terminal_e2e_framework.py
git commit -m "test: add terminal e2e framework core types"
```

## Task 2: Scenario Orchestration And Pytest Fixture

**Files:**
- Create: `tests/e2e/framework/scenario.py`
- Modify: `tests/conftest.py`
- Modify: `tests/test_terminal_e2e_framework.py`

- [ ] **Step 1: Write the failing `Scenario` tests**

```python
from pathlib import Path

from tests.e2e.framework.artifacts import ArtifactCollector
from tests.e2e.framework.scenario import AgentConfig, Scenario
from tests.e2e.framework.terminal_driver import TerminalCapture, TerminalHandle


class DummyDriver:
    def __init__(self) -> None:
        self.started = []

    def start(self, spec):
        self.started.append(spec)
        return TerminalHandle(backend="dummy", target="dummy-1", process_pid=111)

    def send_text(self, handle, text: str) -> None:
        return None

    def send_key(self, handle, key: str) -> None:
        return None

    def capture(self, handle) -> TerminalCapture:
        return TerminalCapture(text="READY\n", raw="READY\r\n")

    def is_alive(self, handle) -> bool:
        return True

    def stop(self, handle) -> None:
        return None


class DummyAdapter:
    client_name = "dummy"
    default_backend = "dummy"

    def build_launch(self, scenario, config):
        return {
            "command": ["python3", "-c", "print('ready')"],
            "cwd": scenario.workdir,
            "env": {},
            "title": config.name,
        }

    def is_ready(self, scenario, agent) -> bool:
        return True

    def probe_capabilities(self, scenario) -> dict[str, bool]:
        return {"dummy_ready": True}


def test_scenario_comment_writes_timeline(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": DummyDriver()},
        adapters={"dummy": DummyAdapter()},
    )
    scenario.artifacts.start_run()
    scenario.comment("hello world")

    timeline = (scenario.artifacts.run_dir / "timeline.jsonl").read_text(encoding="utf-8")
    assert "hello world" in timeline


def test_scenario_start_agent_tracks_started_agent(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": DummyDriver()},
        adapters={"dummy": DummyAdapter()},
    )
    scenario.artifacts.start_run()
    agent = scenario.start_agent("dummy", name="dummy-a")

    assert agent.client == "dummy"
    assert agent.name == "dummy-a"
    assert agent.handle.target == "dummy-1"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
pytest -q tests/test_terminal_e2e_framework.py -k "scenario_comment or start_agent_tracks"
```

Expected:

```text
E   ModuleNotFoundError: No module named 'tests.e2e.framework.scenario'
```

- [ ] **Step 3: Write the minimal `Scenario` implementation and fixture**

```python
# tests/e2e/framework/scenario.py
from __future__ import annotations

import os
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path

from .artifacts import ArtifactCollector
from .terminal_driver import TerminalHandle, TerminalStartSpec


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


class Scenario:
    def __init__(self, test_name: str, workdir: Path, artifacts: ArtifactCollector, drivers: dict, adapters: dict) -> None:
        self.test_name = test_name
        self.workdir = workdir
        self.artifacts = artifacts
        self.drivers = drivers
        self.adapters = adapters
        self.agents: dict[str, StartedAgent] = {}
        self._capability_cache: dict[str, bool] = {}
        self.workdir.mkdir(parents=True, exist_ok=True)

    def comment(self, text: str) -> None:
        self.artifacts.append_event("comment", {"text": text})

    def start_agent(self, client: str, *, name: str, auto: bool = False, backend: str | None = None, model: str | None = None, extra_args: list[str] | None = None, env: dict[str, str] | None = None) -> StartedAgent:
        config = AgentConfig(client=client, name=name, auto=auto, backend=backend, model=model, extra_args=extra_args or [], env=env or {})
        adapter = self.adapters[client]
        driver_name = backend or adapter.default_backend
        driver = self.drivers[driver_name]
        launch = adapter.build_launch(self, config)
        spec = TerminalStartSpec(**launch)
        handle = driver.start(spec)
        agent = StartedAgent(client=client, name=name, backend=driver_name, handle=handle, config=config)
        self.agents[name] = agent
        self.artifacts.append_event("agent.started", {"client": client, "name": name, "backend": driver_name})
        return agent

    def wait_for(self, predicate, timeout: float, interval: float = 0.2) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(interval)
        raise AssertionError("scenario.wait_for timed out")

    def wait_for_init(self, *agents: StartedAgent, timeout: float = 60.0) -> None:
        def _ready() -> bool:
            return all(self.adapters[a.client].is_ready(self, a) for a in agents)
        self.wait_for(_ready, timeout=timeout)

    def require_binary(self, name: str) -> None:
        if shutil.which(name) is None:
            raise AssertionError(f"required binary missing: {name}")
```

```python
# tests/conftest.py
from pathlib import Path

from tests.e2e.framework import ArtifactCollector
from tests.e2e.framework.scenario import Scenario


@pytest.fixture
def scenario(request: pytest.FixtureRequest, tmp_path: Path) -> Scenario:
    artifact_root = Path(".artifacts") / "e2e"
    artifacts = ArtifactCollector(artifact_root, request.node.name)
    artifacts.start_run()
    sc = Scenario(
        test_name=request.node.name,
        workdir=tmp_path / "workdir",
        artifacts=artifacts,
        drivers={},
        adapters={},
    )
    yield sc
    for agent in list(sc.agents.values()):
        sc.drivers[agent.backend].stop(agent.handle)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
pytest -q tests/test_terminal_e2e_framework.py -k "scenario_comment or start_agent_tracks"
```

Expected:

```text
2 passed
```

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/framework/scenario.py tests/conftest.py tests/test_terminal_e2e_framework.py
git commit -m "test: add scenario orchestration for terminal e2e"
```

## Task 3: `TmuxDriver`

**Files:**
- Create: `tests/e2e/framework/tmux_driver.py`
- Modify: `tests/test_terminal_e2e_framework.py`

- [ ] **Step 1: Write the failing `TmuxDriver` contract tests**

```python
from pathlib import Path
from unittest import mock

from tests.e2e.framework.terminal_driver import TerminalHandle, TerminalStartSpec
from tests.e2e.framework.tmux_driver import TmuxDriver


def test_tmux_driver_start_uses_new_session_and_returns_pane_handle(tmp_path: Path, monkeypatch) -> None:
    completed = mock.Mock(stdout="%42\n")
    monkeypatch.setattr("tests.e2e.framework.tmux_driver.subprocess.run", lambda *a, **k: completed)

    driver = TmuxDriver(repo_root=tmp_path)
    handle = driver.start(
        TerminalStartSpec(
            command=["bash", "-lc", "echo hi"],
            cwd=tmp_path,
            env={},
            title="demo",
        )
    )

    assert handle.backend == "tmux"
    assert handle.target == "%42"


def test_tmux_driver_enter_uses_repo_helper(tmp_path: Path, monkeypatch) -> None:
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        return mock.Mock(stdout="")

    monkeypatch.setattr("tests.e2e.framework.tmux_driver.subprocess.run", fake_run)

    driver = TmuxDriver(repo_root=tmp_path)
    handle = TerminalHandle(backend="tmux", target="%99", process_pid=999)
    driver.send_key(handle, "Enter")

    assert calls[0][0] == str(tmp_path / "scripts" / "c2c-tmux-enter.sh")
    assert calls[0][1] == "%99"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
pytest -q tests/test_terminal_e2e_framework.py -k "tmux_driver"
```

Expected:

```text
E   ModuleNotFoundError: No module named 'tests.e2e.framework.tmux_driver'
```

- [ ] **Step 3: Write the minimal `TmuxDriver` implementation**

```python
# tests/e2e/framework/tmux_driver.py
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
        res = subprocess.run(
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
        return TerminalHandle(backend="tmux", target=res.stdout.strip())

    def send_text(self, handle: TerminalHandle, text: str) -> None:
        subprocess.run(["tmux", "send-keys", "-t", handle.target, "-l", text], check=True)

    def send_key(self, handle: TerminalHandle, key: str) -> None:
        if key == "Enter":
            subprocess.run([str(self.enter_helper), handle.target], check=True)
            return
        subprocess.run(["tmux", "send-keys", "-t", handle.target, key], check=True)

    def capture(self, handle: TerminalHandle) -> TerminalCapture:
        res = subprocess.run(
            ["tmux", "capture-pane", "-t", handle.target, "-p", "-S", "-200"],
            capture_output=True,
            text=True,
            check=True,
        )
        return TerminalCapture(text=res.stdout, raw=res.stdout)

    def is_alive(self, handle: TerminalHandle) -> bool:
        res = subprocess.run(["tmux", "display-message", "-t", handle.target, "-p", "#{pane_dead}"], capture_output=True, text=True, check=False)
        return res.returncode == 0 and res.stdout.strip() == "0"

    def stop(self, handle: TerminalHandle) -> None:
        subprocess.run(["tmux", "kill-pane", "-t", handle.target], check=False)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
pytest -q tests/test_terminal_e2e_framework.py -k "tmux_driver"
```

Expected:

```text
2 passed
```

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/framework/tmux_driver.py tests/test_terminal_e2e_framework.py
git commit -m "test: add tmux terminal driver"
```

## Task 4: `FakePtyDriver` And Cross-Backend Framework Smoke

**Files:**
- Create: `tests/e2e/framework/fake_pty_driver.py`
- Create: `tests/e2e/fixtures/fake_terminal_child.py`
- Modify: `tests/test_terminal_e2e_framework.py`

- [ ] **Step 1: Write the failing fake-PTY round-trip tests**

```python
import os
import sys
import time
import shutil
from pathlib import Path

import pytest

from tests.e2e.framework.fake_pty_driver import FakePtyDriver
from tests.e2e.framework.terminal_driver import TerminalStartSpec


FIXTURE = Path(__file__).resolve().parent / "e2e" / "fixtures" / "fake_terminal_child.py"


def test_fake_pty_driver_round_trips_input(tmp_path: Path) -> None:
    driver = FakePtyDriver()
    handle = driver.start(
        TerminalStartSpec(
            command=[sys.executable, str(FIXTURE)],
            cwd=tmp_path,
            env={},
            title="fake-child",
        )
    )

    driver.send_text(handle, "hello")
    driver.send_key(handle, "Enter")

    def _captured() -> str:
        return driver.capture(handle).text

    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if "ECHO: hello" in _captured():
            break
        time.sleep(0.05)
    else:
        raise AssertionError(_captured())


@pytest.mark.skipif(
    os.environ.get("C2C_TEST_TMUX") != "1" or shutil.which("tmux") is None,
    reason="set C2C_TEST_TMUX=1 and install tmux to run live tmux backend parity smoke",
)
def test_tmux_driver_can_run_same_fake_child(scenario) -> None:
    driver = scenario.drivers["tmux"]
    handle = driver.start(
        TerminalStartSpec(
            command=[sys.executable, str(FIXTURE)],
            cwd=scenario.workdir,
            env={},
            title="tmux-fake-child",
        )
    )
    driver.send_text(handle, "hello")
    driver.send_key(handle, "Enter")
    scenario.wait_for(lambda: "ECHO: hello" in driver.capture(handle).text, timeout=5.0)
```

- [ ] **Step 2: Run the fake-PTY test to verify it fails**

Run:

```bash
pytest -q tests/test_terminal_e2e_framework.py -k "fake_pty_driver_round_trips_input"
```

Expected:

```text
E   ModuleNotFoundError: No module named 'tests.e2e.framework.fake_pty_driver'
```

- [ ] **Step 3: Write the fake-PTY child fixture and driver**

```python
# tests/e2e/fixtures/fake_terminal_child.py
from __future__ import annotations

import sys

print("READY", flush=True)
for line in sys.stdin:
    text = line.rstrip("\n")
    if text == "/quit":
        print("BYE", flush=True)
        break
    print(f"ECHO: {text}", flush=True)
```

```python
# tests/e2e/framework/fake_pty_driver.py
from __future__ import annotations

import os
import pty
import subprocess
import time

from .terminal_driver import TerminalCapture, TerminalHandle, TerminalStartSpec


class FakePtyDriver:
    def __init__(self) -> None:
        self._masters: dict[str, int] = {}
        self._buffers: dict[str, str] = {}

    def start(self, spec: TerminalStartSpec) -> TerminalHandle:
        master_fd, slave_fd = pty.openpty()
        proc = subprocess.Popen(
            spec.command,
            cwd=spec.cwd,
            env={**os.environ, **spec.env},
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            text=False,
            start_new_session=True,
        )
        os.close(slave_fd)
        target = f"pty-{proc.pid}"
        self._masters[target] = master_fd
        self._buffers[target] = ""
        return TerminalHandle(backend="fake-pty", target=target, process_pid=proc.pid)

    def send_text(self, handle: TerminalHandle, text: str) -> None:
        os.write(self._masters[handle.target], text.encode("utf-8"))

    def send_key(self, handle: TerminalHandle, key: str) -> None:
        if key == "Enter":
            os.write(self._masters[handle.target], b"\n")
            return
        raise NotImplementedError(f"unsupported fake-pty key: {key}")

    def capture(self, handle: TerminalHandle) -> TerminalCapture:
        master_fd = self._masters[handle.target]
        try:
            chunk = os.read(master_fd, 8192).decode("utf-8", errors="replace")
            self._buffers[handle.target] += chunk
        except BlockingIOError:
            pass
        return TerminalCapture(text=self._buffers[handle.target], raw=self._buffers[handle.target])

    def is_alive(self, handle: TerminalHandle) -> bool:
        if handle.process_pid is None:
            return False
        try:
            os.kill(handle.process_pid, 0)
            return True
        except OSError:
            return False

    def stop(self, handle: TerminalHandle) -> None:
        if handle.process_pid is not None:
            try:
                os.kill(handle.process_pid, 15)
            except OSError:
                pass
        master_fd = self._masters.pop(handle.target, None)
        if master_fd is not None:
            os.close(master_fd)
```

- [ ] **Step 4: Run the tests to verify the fake-PTY path passes**

Run:

```bash
pytest -q tests/test_terminal_e2e_framework.py -k "fake_pty_driver_round_trips_input"
```

Expected:

```text
1 passed
```

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/framework/fake_pty_driver.py tests/e2e/fixtures/fake_terminal_child.py tests/test_terminal_e2e_framework.py
git commit -m "test: add fake pty terminal driver"
```

## Task 5: Codex Client Adapters And Capability Probes

**Files:**
- Create: `tests/e2e/framework/client_adapters.py`
- Create: `tests/test_terminal_e2e_client_adapters.py`
- Modify: `tests/e2e/framework/scenario.py`
- Modify: `tests/conftest.py`

- [ ] **Step 1: Write the failing adapter tests**

```python
from pathlib import Path
from unittest import mock

from tests.e2e.framework.client_adapters import CodexAdapter, CodexHeadlessAdapter
from tests.e2e.framework.scenario import AgentConfig


def test_codex_adapter_detects_xml_fd_capability(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(
        "tests.e2e.framework.client_adapters.subprocess.run",
        lambda *a, **k: mock.Mock(stdout="Usage: codex --xml-input-fd <fd>\n"),
    )

    adapter = CodexAdapter(tmp_path)
    capabilities = adapter.probe_capabilities(None)

    assert capabilities["codex_xml_fd"] is True


def test_codex_headless_adapter_detects_thread_id_fd_capability(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(
        "tests.e2e.framework.client_adapters.subprocess.run",
        lambda *a, **k: mock.Mock(stdout="Usage: codex-turn-start-bridge --thread-id-fd <fd>\n"),
    )

    adapter = CodexHeadlessAdapter(tmp_path)
    capabilities = adapter.probe_capabilities(None)

    assert capabilities["codex_headless_thread_id_fd"] is True


def test_codex_adapter_builds_managed_launch_command(tmp_path: Path) -> None:
    adapter = CodexAdapter(tmp_path)
    config = AgentConfig(client="codex", name="codex-a", auto=True, extra_args=["--approval-policy", "never"])
    scenario = mock.Mock(workdir=tmp_path / "work")

    launch = adapter.build_launch(scenario, config)

    assert launch["command"][:5] == ["c2c", "start", "codex", "-n", "codex-a"]
    assert "--auto" in launch["command"]
    assert "--" in launch["command"]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
pytest -q tests/test_terminal_e2e_client_adapters.py
```

Expected:

```text
E   ModuleNotFoundError: No module named 'tests.e2e.framework.client_adapters'
```

- [ ] **Step 3: Implement the adapter registry and Codex-family adapters**

```python
# tests/e2e/framework/client_adapters.py
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from .scenario import AgentConfig


def _help_contains(binary: str, flag: str) -> bool:
    res = subprocess.run([binary, "--help"], capture_output=True, text=True, check=False)
    return flag in (res.stdout + res.stderr)


class CodexAdapter:
    client_name = "codex"
    default_backend = "tmux"

    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root

    def build_launch(self, scenario, config: AgentConfig) -> dict[str, object]:
        command = ["c2c", "start", "codex", "-n", config.name]
        if config.auto:
            command.append("--auto")
        if config.extra_args:
            command.extend(["--", *config.extra_args])
        return {
            "command": command,
            "cwd": scenario.workdir,
            "env": config.env,
            "title": config.name,
        }

    def probe_capabilities(self, scenario) -> dict[str, bool]:
        return {"codex_xml_fd": _help_contains("codex", "--xml-input-fd")}

    def is_ready(self, scenario, agent) -> bool:
        driver = scenario.drivers[agent.backend]
        if not driver.is_alive(agent.handle):
            return False
        instance_dir = Path.home() / ".local" / "share" / "c2c" / "instances" / agent.name
        return instance_dir.exists()


class CodexHeadlessAdapter:
    client_name = "codex-headless"
    default_backend = "tmux"

    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root

    def build_launch(self, scenario, config: AgentConfig) -> dict[str, object]:
        command = ["c2c", "start", "codex-headless", "-n", config.name]
        if config.auto:
            command.append("--auto")
        if config.extra_args:
            command.extend(["--", *config.extra_args])
        return {
            "command": command,
            "cwd": scenario.workdir,
            "env": config.env,
            "title": config.name,
        }

    def probe_capabilities(self, scenario) -> dict[str, bool]:
        return {"codex_headless_thread_id_fd": _help_contains("codex-turn-start-bridge", "--thread-id-fd")}

    def is_ready(self, scenario, agent) -> bool:
        driver = scenario.drivers[agent.backend]
        if not driver.is_alive(agent.handle):
            return False
        instance_dir = Path.home() / ".local" / "share" / "c2c" / "instances" / agent.name
        config_json = instance_dir / "config.json"
        return config_json.exists()
```

```python
# tests/e2e/framework/scenario.py
    def require_capability(self, name: str) -> None:
        if not self._capability_cache.get(name, False):
            raise AssertionError(f"required capability missing: {name}")

    def xfail_unless(self, name: str, reason: str) -> None:
        import pytest
        if not self._capability_cache.get(name, False):
            pytest.xfail(reason)

    def refresh_capabilities(self) -> dict[str, bool]:
        merged: dict[str, bool] = {}
        for adapter in self.adapters.values():
            merged.update(adapter.probe_capabilities(self))
        self._capability_cache = merged
        return merged
```

```python
# tests/conftest.py
from pathlib import Path

from tests.e2e.framework import ArtifactCollector
from tests.e2e.framework.fake_pty_driver import FakePtyDriver
from tests.e2e.framework.scenario import Scenario
from tests.e2e.framework.tmux_driver import TmuxDriver
from tests.e2e.framework.client_adapters import CodexAdapter, CodexHeadlessAdapter


@pytest.fixture
def scenario(request: pytest.FixtureRequest, tmp_path: Path) -> Scenario:
    artifact_root = Path(".artifacts") / "e2e"
    artifacts = ArtifactCollector(artifact_root, request.node.name)
    artifacts.start_run()
    sc = Scenario(
        test_name=request.node.name,
        workdir=tmp_path / "workdir",
        artifacts=artifacts,
        drivers={
            "tmux": TmuxDriver(Path.cwd()),
            "fake-pty": FakePtyDriver(),
        },
        adapters={
            "codex": CodexAdapter(Path.cwd()),
            "codex-headless": CodexHeadlessAdapter(Path.cwd()),
        },
    )
    sc.refresh_capabilities()
    yield sc
    for agent in list(sc.agents.values()):
        sc.drivers[agent.backend].stop(agent.handle)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
pytest -q tests/test_terminal_e2e_client_adapters.py
```

Expected:

```text
3 passed
```

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/framework/client_adapters.py tests/e2e/framework/scenario.py tests/conftest.py tests/test_terminal_e2e_client_adapters.py
git commit -m "test: add codex e2e client adapters"
```

## Task 6: Codex Twin E2E On The Framework

**Files:**
- Create: `tests/test_c2c_codex_twin_e2e.py`

- [ ] **Step 1: Write the Codex live tests**

```python
from __future__ import annotations

import os
import shutil
import subprocess

import pytest


pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_CODEX_TWIN_E2E") != "1"
    or shutil.which("tmux") is None
    or shutil.which("codex") is None
    or shutil.which("c2c") is None,
    reason="set C2C_TEST_CODEX_TWIN_E2E=1 and ensure tmux/codex/c2c are on PATH",
)


def _init_git_repo(path):
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "init", "-q"], cwd=path, check=True)


def test_codex_twin_fallback_notify_path(scenario) -> None:
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()

    a = scenario.start_agent("codex", name=f"codex-a-{os.getpid()}", auto=True)
    b = scenario.start_agent("codex", name=f"codex-b-{os.getpid()}", auto=True)
    scenario.wait_for_init(a, b, timeout=120.0)

    scenario.comment("stock Codex should still be launchable, broker-alive, and able to receive inbox traffic")
    message = f"fallback-ping-{os.getpid()}"
    scenario.send_dm(a, b, message)
    scenario.wait_for(lambda: scenario.broker_inbox_contains(b, message), timeout=20.0)

    scenario.assert_agent(a).registered_alive()
    scenario.assert_agent(b).registered_alive()


def test_codex_twin_xml_user_turn_delivery(scenario) -> None:
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()
    scenario.xfail_unless("codex_xml_fd", reason="updated Codex binary with --xml-input-fd not present yet")

    a = scenario.start_agent("codex", name=f"codex-xml-a-{os.getpid()}", auto=True)
    b = scenario.start_agent("codex", name=f"codex-xml-b-{os.getpid()}", auto=True)
    scenario.wait_for_init(a, b, timeout=120.0)

    scenario.send_dm(a, b, f"xml-turn-ping-{os.getpid()}")
    scenario.wait_for(lambda: f"xml-turn-ping-{os.getpid()}" in scenario.capture(b).text, timeout=90.0)
```

- [ ] **Step 2: Verify collection and gating behavior**

Run:

```bash
pytest -q tests/test_c2c_codex_twin_e2e.py --collect-only
pytest -q tests/test_c2c_codex_twin_e2e.py -k "xml_user_turn_delivery" || true
```

Expected:

```text
2 tests collected
1 xfailed or 1 skipped (depending on env gate / binary presence)
```

- [ ] **Step 3: Fill in the Scenario helpers needed by the live tests**

```python
# tests/e2e/framework/scenario.py
    def capture(self, agent: StartedAgent) -> str:
        capture = self.drivers[agent.backend].capture(agent.handle)
        self.artifacts.write_text(f"{agent.name}.capture.txt", capture.text)
        return capture.text

    def send_dm(self, from_agent: StartedAgent | None, to_agent: StartedAgent, text: str) -> None:
        import subprocess
        subprocess.run(["c2c", "send", to_agent.name, text], cwd=self.workdir, check=True, capture_output=True, text=True)
        self.artifacts.append_event(
            "dm.sent",
            {"from_agent": None if from_agent is None else from_agent.name, "to_agent": to_agent.name, "text": text},
        )

    def broker_root(self) -> Path:
        import subprocess
        git_common = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            cwd=self.workdir,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        return (self.workdir / git_common / "c2c" / "mcp").resolve()

    def broker_inbox_contains(self, agent: StartedAgent, text: str) -> bool:
        import json
        inbox = self.broker_root() / f"{agent.name}.inbox.json"
        if not inbox.exists():
            return False
        payload = json.loads(inbox.read_text(encoding="utf-8") or "[]")
        return any(text in json.dumps(item) for item in payload)

    def assert_agent(self, agent: StartedAgent):
        scenario = self

        class _AssertAgent:
            def alive(self) -> None:
                if not scenario.drivers[agent.backend].is_alive(agent.handle):
                    raise AssertionError(f"{agent.name} is not alive")

            def registered_alive(self) -> None:
                import json
                registry = scenario.broker_root() / "registry.json"
                if not registry.exists():
                    raise AssertionError(f"broker registry missing: {registry}")
                data = json.loads(registry.read_text(encoding="utf-8"))
                rows = data if isinstance(data, list) else data.get("registrations", [])
                for row in rows:
                    if row.get("alias") == agent.name and row.get("alive") is not False:
                        return
                raise AssertionError(f"{agent.name} is not registered alive in broker registry")

        return _AssertAgent()
```

- [ ] **Step 4: Run the live fallback test**

Run:

```bash
C2C_TEST_CODEX_TWIN_E2E=1 pytest -q tests/test_c2c_codex_twin_e2e.py -k "fallback_notify_path" --force-test-env
```

Expected:

```text
1 passed
```

If the installed Codex binary does not yet support `--xml-input-fd`, also run:

```bash
C2C_TEST_CODEX_TWIN_E2E=1 pytest -q tests/test_c2c_codex_twin_e2e.py -k "xml_user_turn_delivery" --force-test-env
```

Expected:

```text
1 xfailed
```

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/framework/scenario.py tests/test_c2c_codex_twin_e2e.py
git commit -m "test: add codex twin e2e coverage"
```

## Task 7: `codex-headless` E2E On The Framework

**Files:**
- Create: `tests/test_c2c_codex_headless_e2e.py`

- [ ] **Step 1: Write the `codex-headless` live smoke tests**

```python
from __future__ import annotations

import os
import shutil
import subprocess

import pytest


pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_CODEX_HEADLESS_E2E") != "1"
    or shutil.which("tmux") is None
    or shutil.which("codex-turn-start-bridge") is None
    or shutil.which("c2c") is None,
    reason="set C2C_TEST_CODEX_HEADLESS_E2E=1 and ensure tmux/codex-turn-start-bridge/c2c are on PATH",
)


def _init_git_repo(path):
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "init", "-q"], cwd=path, check=True)


def test_codex_headless_bridge_capability_smoke(scenario) -> None:
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()
    scenario.xfail_unless(
        "codex_headless_thread_id_fd",
        reason="updated codex-turn-start-bridge with --thread-id-fd not present yet",
    )

    agent = scenario.start_agent("codex-headless", name=f"codex-headless-{os.getpid()}", auto=True)
    scenario.wait_for_init(agent, timeout=90.0)
    scenario.assert_agent(agent).registered_alive()
```

- [ ] **Step 2: Verify collection and xfail behavior**

Run:

```bash
pytest -q tests/test_c2c_codex_headless_e2e.py --collect-only
pytest -q tests/test_c2c_codex_headless_e2e.py || true
```

Expected:

```text
1 test collected
1 xfailed or 1 skipped (depending on env gate / bridge presence)
```

- [ ] **Step 3: Extend readiness and artifacts for headless sessions**

```python
# tests/e2e/framework/client_adapters.py
    def is_ready(self, scenario, agent) -> bool:
        driver = scenario.drivers[agent.backend]
        if not driver.is_alive(agent.handle):
            return False
        instance_dir = Path.home() / ".local" / "share" / "c2c" / "instances" / agent.name
        config_json = instance_dir / "config.json"
        if not config_json.exists():
            return False
        data = json.loads(config_json.read_text(encoding="utf-8"))
        return "resume_session_id" in data
```

```python
# tests/e2e/framework/scenario.py
    def snapshot_instance_dir(self, agent: StartedAgent) -> None:
        import shutil
        instance_dir = Path.home() / ".local" / "share" / "c2c" / "instances" / agent.name
        if instance_dir.exists():
            target = self.artifacts.run_dir / f"{agent.name}.instance"
            shutil.copytree(instance_dir, target, dirs_exist_ok=True)
```

- [ ] **Step 4: Run the live headless smoke test**

Run:

```bash
C2C_TEST_CODEX_HEADLESS_E2E=1 pytest -q tests/test_c2c_codex_headless_e2e.py --force-test-env
```

Expected until updated bridge support lands:

```text
1 xfailed
```

Expected once the updated bridge is installed:

```text
1 passed
```

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/framework/client_adapters.py tests/e2e/framework/scenario.py tests/test_c2c_codex_headless_e2e.py
git commit -m "test: add codex headless e2e coverage"
```

## Self-Review Checklist

- Spec coverage:
  - `Scenario`, `TerminalDriver`, `TmuxDriver`, `FakePtyDriver`, `ClientAdapter`, and `ArtifactCollector` are each covered by a task.
  - `.artifacts/e2e/<test-name>/<run-id>/` is explicitly implemented and ignored.
  - Codex and `codex-headless` are the first live consumers.
  - capability-gated `xfail` behavior is explicitly implemented for XML TUI and bridge handoff surfaces.
- Placeholder scan:
  - no `TODO`, `TBD`, or “implement later” placeholders remain in the task steps.
  - every code-changing step includes a concrete code block.
- Type consistency:
  - the plan consistently uses `TerminalHandle`, `TerminalCapture`, `TerminalStartSpec`, `Scenario`, `AgentConfig`, and `StartedAgent`.
