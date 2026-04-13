# `c2c start` Unified Instance Launcher — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all 10 `run-*-inst`/`run-*-inst-outer` harness scripts with a single `c2c start <client> [-n NAME]` command that manages instance lifecycle, env setup, and state in `~/.local/share/c2c/instances/`.

**Architecture:** Single `c2c_start.py` module with per-client config dicts. Replaces harness scripts. Fix alias drift by removing `C2C_MCP_AUTO_REGISTER_ALIAS` from global configure scripts.

**Tech Stack:** Python 3, subprocess, os.fork, argparse, json, pathlib

---

## File Map

| File | Role |
|------|------|
| `c2c_start.py` | **NEW** — Core module: CLI dispatch, instance config, outer restart loop, deliver daemon, poker, cleanup |
| `c2c_cli.py` | **MODIFY** — Add `start`, `stop`, `instances`, `restart` to dispatch + USAGE |
| `c2c_install.py` | **MODIFY** — Add wrapper scripts for start/stop/instances/restart |
| `c2c_configure_codex.py` | **MODIFY** — Remove `C2C_MCP_AUTO_REGISTER_ALIAS` from global config |
| `c2c_configure_kimi.py` | **MODIFY** — Remove `C2C_MCP_AUTO_REGISTER_ALIAS` from global config |
| `c2c_configure_crush.py` | **MODIFY** — Remove `C2C_MCP_AUTO_REGISTER_ALIAS` from global config |
| `c2c_configure_claude_code.py` | **MODIFY** — Remove `C2C_MCP_AUTO_REGISTER_ALIAS` from global config |
| `c2c_configure_opencode.py` | **MODIFY** — Remove `C2C_MCP_AUTO_REGISTER_ALIAS` from global config |
| `tests/test_c2c_cli.py` | **MODIFY** — Add unit tests for start/stop/instances/restart |

---

## Task 1: Core module — constants, client configs, state dir helpers

**Files:**
- Create: `c2c_start.py`
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the failing test**

```python
import os
import json
import tempfile
from pathlib import Path
from unittest import mock

class C2CStartConstantsTests(unittest.TestCase):
    def test_client_configs_has_all_five_clients(self):
        from c2c_start import CLIENT_CONFIGS
        self.assertEqual(set(CLIENT_CONFIGS.keys()), {"claude", "codex", "opencode", "kimi", "crush"})

    def test_client_config_has_required_keys(self):
        from c2c_start import CLIENT_CONFIGS
        for client, cfg in CLIENT_CONFIGS.items():
            self.assertIn("binary", cfg, f"{client} missing binary")
            self.assertIn("deliver_client", cfg, f"{client} missing deliver_client")
            self.assertIn("needs_poker", cfg, f"{client} missing needs_poker")

    def test_default_name_uses_hostname(self):
        from c2c_start import default_name
        with mock.patch("socket.gethostname", return_value="testhost"):
            self.assertEqual(default_name("claude"), "claude-testhost")
            self.assertEqual(default_name("codex"), "codex-testhost")

    def test_instances_dir_creates_on_access(self):
        from c2c_start import instances_dir
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {"HOME": tmp}):
                d = instances_dir()
                self.assertTrue(d.exists())
                self.assertEqual(d, Path(tmp) / ".local" / "share" / "c2c" / "instances")

    def test_instance_dir_path(self):
        from c2c_start import instance_dir
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {"HOME": tmp}):
                d = instance_dir("my-agent")
                self.assertEqual(d, Path(tmp) / ".local" / "share" / "c2c" / "instances" / "my-agent")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStartConstantsTests -v`
Expected: FAIL with "No module named 'c2c_start'"

- [ ] **Step 3: Write minimal implementation**

Create `c2c_start.py`:

```python
#!/usr/bin/env python3
"""Unified instance launcher for c2c clients."""
from __future__ import annotations

import json
import os
import socket
import sys
import time
from pathlib import Path

SUPPORTED_CLIENTS = {"claude", "codex", "opencode", "kimi", "crush"}

CLIENT_CONFIGS = {
    "claude": {
        "binary": "claude",
        "deliver_client": "claude",
        "needs_poker": True,
        "poker_event": "heartbeat",
        "poker_from": "claude-poker",
    },
    "codex": {
        "binary": "codex",
        "deliver_client": "codex",
        "needs_poker": False,
    },
    "opencode": {
        "binary": "opencode",
        "deliver_client": "opencode",
        "needs_poker": False,
    },
    "kimi": {
        "binary": "kimi",
        "deliver_client": "kimi",
        "needs_poker": True,
        "poker_event": "heartbeat",
        "poker_from": "kimi-poker",
    },
    "crush": {
        "binary": "crush",
        "deliver_client": "crush",
        "needs_poker": False,
    },
}

MIN_RUN_SECONDS = 10.0
RESTART_PAUSE_SECONDS = 1.5
INITIAL_BACKOFF_SECONDS = 2.0
MAX_BACKOFF_SECONDS = 60.0

ROOT = Path(__file__).resolve().parent


def default_name(client: str) -> str:
    return f"{client}-{socket.gethostname()}"


def instances_dir() -> Path:
    d = Path.home() / ".local" / "share" / "c2c" / "instances"
    d.mkdir(parents=True, exist_ok=True)
    return d


def instance_dir(name: str) -> Path:
    return instances_dir() / name


def broker_root() -> Path:
    import subprocess
    result = subprocess.run(
        ["git", "rev-parse", "--git-common-dir"],
        capture_output=True, text=True,
        cwd=str(ROOT),
    )
    common = Path(result.stdout.strip())
    mcp = common / "c2c" / "mcp"
    mcp.mkdir(parents=True, exist_ok=True)
    return mcp


def build_env(name: str) -> dict[str, str]:
    env = os.environ.copy()
    env["C2C_MCP_SESSION_ID"] = name
    env["C2C_MCP_AUTO_REGISTER_ALIAS"] = name
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root())
    env["C2C_MCP_CLIENT_PID"] = str(os.getpid())
    env["C2C_MCP_AUTO_JOIN_ROOMS"] = "swarm-lounge"
    env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "0"
    return env


def write_config(name: str, client: str, extra_args: list[str]) -> None:
    d = instance_dir(name)
    d.mkdir(parents=True, exist_ok=True)
    config = {
        "name": name,
        "client": client,
        "session_id": name,
        "alias": name,
        "extra_args": extra_args,
        "created_at": time.time(),
        "broker_root": str(broker_root()),
        "auto_join_rooms": "swarm-lounge",
    }
    (d / "config.json").write_text(json.dumps(config, indent=2), encoding="utf-8")


def load_config(name: str) -> dict | None:
    path = instance_dir(name) / "config.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def pid_alive(pid: int) -> bool:
    return Path(f"/proc/{pid}").exists()


def read_pid(pidfile: Path) -> int | None:
    try:
        pid = int(pidfile.read_text().strip())
        if pid_alive(pid):
            return pid
    except (ValueError, OSError):
        pass
    return None


def write_pid(pidfile: Path, pid: int) -> None:
    pidfile.write_text(str(pid), encoding="utf-8")


def cleanup_pidfiles(d: Path) -> None:
    for name in ("outer.pid", "deliver.pid", "poker.pid"):
        p = d / name
        if p.exists():
            try:
                p.unlink()
            except OSError:
                pass


def cleanup_fea_so() -> None:
    """Clean up fonttools .fea*.so residue in /tmp that fills disk."""
    try:
        import glob as glob_mod
        for f in glob_mod.glob("/tmp/.fea*.so"):
            try:
                os.unlink(f)
            except OSError:
                pass
    except Exception:
        pass


if __name__ == "__main__":
    print("c2c_start.py is a library, not a script. Use 'c2c start' instead.", file=sys.stderr)
    sys.exit(1)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStartConstantsTests -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add c2c_start.py tests/test_c2c_cli.py
git commit -m "feat(start): add c2c_start module skeleton with constants, client configs, helpers"
```

---

## Task 2: CLI dispatch — `c2c start`, `c2c stop`, `c2c instances`, `c2c restart`

**Files:**
- Modify: `c2c_cli.py`
- Modify: `c2c_start.py`

- [ ] **Step 1: Write the failing test**

```python
class C2CStartCLITests(unittest.TestCase):
    def test_start_dispatches_to_main(self):
        with mock.patch("c2c_start.main") as mock_main:
            mock_main.return_value = 0
            import c2c_cli
            result = c2c_cli.main(["start", "claude", "-n", "test"])
            mock_main.assert_called_once()

    def test_stop_dispatches(self):
        with mock.patch("c2c_start.stop_instance") as mock_stop:
            mock_stop.return_value = 0
            import c2c_cli
            result = c2c_cli.main(["stop", "my-agent"])
            mock_stop.assert_called_once_with("my-agent")

    def test_instances_dispatches(self):
        with mock.patch("c2c_start.list_instances") as mock_list:
            mock_list.return_value = 0
            import c2c_cli
            result = c2c_cli.main(["instances"])
            mock_list.assert_called_once()

    def test_restart_dispatches(self):
        with mock.patch("c2c_start.restart_instance") as mock_restart:
            mock_restart.return_value = 0
            import c2c_cli
            result = c2c_cli.main(["restart", "my-agent"])
            mock_restart.assert_called_once_with("my-agent")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStartCLITests -v`
Expected: FAIL

- [ ] **Step 3: Add dispatch to `c2c_cli.py`**

Add to imports:
```python
import c2c_start
```

Add to USAGE string:
```
<broker-gc|configure-claude-code|...|start|stop|instances|restart|...>
```

Add to dispatch section (after existing elif blocks):
```python
    elif command == "start":
        return c2c_start.main(rest)
    elif command == "stop":
        return c2c_start.stop_instance(rest[0]) if rest else _usage_error("c2c stop <NAME>")
    elif command == "instances":
        return c2c_start.list_instances(rest)
    elif command == "restart":
        return c2c_start.restart_instance(rest[0]) if rest else _usage_error("c2c restart <NAME>")
```

Add to SAFE_AUTO_APPROVE_SUBCOMMANDS:
```python
    "instances",
```

- [ ] **Step 4: Add stub functions to `c2c_start.py`**

```python
def main(argv: list[str] | None = None) -> int:
    """Entry point for 'c2c start'."""
    import argparse
    parser = argparse.ArgumentParser(prog="c2c start")
    parser.add_argument("client", choices=SUPPORTED_CLIENTS)
    parser.add_argument("-n", "--name", default=None)
    parser.add_argument("--detach", action="store_true")
    parser.add_argument("extra", nargs="*")
    args = parser.parse_args(argv or [])

    name = args.name or default_name(args.client)
    client = args.client
    extra_args = args.extra

    print(f"[c2c-start] starting {client} as {name}")
    # TODO: implement launch
    return 0


def stop_instance(name: str) -> int:
    """Stop a running instance."""
    print(f"[c2c-stop] stopping {name}")
    # TODO: implement stop
    return 0


def list_instances(argv: list[str] | None = None) -> int:
    """List running instances."""
    print("[c2c-instances] no instances running")
    # TODO: implement listing
    return 0


def restart_instance(name: str) -> int:
    """Restart a running instance."""
    print(f"[c2c-restart] restarting {name}")
    # TODO: implement restart
    return 0
```

- [ ] **Step 5: Run test to verify it passes**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStartCLITests -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add c2c_cli.py c2c_start.py tests/test_c2c_cli.py
git commit -m "feat(start): add CLI dispatch for c2c start/stop/instances/restart"
```

---

## Task 3: Implement `c2c start` — validation + config + env setup

**Files:**
- Modify: `c2c_start.py`
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the failing tests**

```python
class C2CStartValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.instances = Path(self.tmp) / "instances"
        self.instances.mkdir(parents=True)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_invalid_client_rejected(self):
        from c2c_start import main
        result = main(["fakeclient"])
        self.assertNotEqual(result, 0)

    def test_explicit_name_used(self):
        from c2c_start import main
        with mock.patch("c2c_start.run_outer_loop") as mock_run:
            mock_run.return_value = 0
            result = main(["claude", "-n", "story-tree"])
            mock_run.assert_called_once()
            call_args = mock_run.call_args
            self.assertEqual(call_args[1]["name"], "story-tree")

    def test_env_setup_includes_all_vars(self):
        from c2c_start import build_env
        env = build_env("test-agent")
        self.assertEqual(env["C2C_MCP_SESSION_ID"], "test-agent")
        self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "test-agent")
        self.assertIn("C2C_MCP_BROKER_ROOT", env)
        self.assertIn("C2C_MCP_CLIENT_PID", env)
        self.assertEqual(env["C2C_MCP_AUTO_JOIN_ROOMS"], "swarm-lounge")
        self.assertEqual(env["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")

    def test_config_json_written(self):
        from c2c_start import write_config
        with mock.patch("c2c_start.instance_dir", return_value=self.instances / "test"):
            write_config("test", "claude", ["--model", "sonnet"])
            cfg = json.loads((self.instances / "test" / "config.json").read_text())
            self.assertEqual(cfg["name"], "test")
            self.assertEqual(cfg["client"], "claude")
            self.assertEqual(cfg["session_id"], "test")
            self.assertEqual(cfg["alias"], "test")
            self.assertEqual(cfg["extra_args"], ["--model", "sonnet"])

    def test_duplicate_name_rejected(self):
        from c2c_start import main
        # Create a fake running instance
        d = self.instances / "existing"
        d.mkdir()
        (d / "outer.pid").write_text(str(os.getpid()))  # current process is "alive"
        (d / "config.json").write_text('{"name":"existing","client":"claude"}')
        with mock.patch("c2c_start.instance_dir", return_value=d):
            result = main(["claude", "-n", "existing"])
            self.assertNotEqual(result, 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStartValidationTests -v`
Expected: FAIL

- [ ] **Step 3: Implement validation in `c2c_start.py`**

Update `main()`:

```python
def main(argv: list[str] | None = None) -> int:
    import argparse
    parser = argparse.ArgumentParser(prog="c2c start")
    parser.add_argument("client", choices=sorted(SUPPORTED_CLIENTS))
    parser.add_argument("-n", "--name", default=None)
    parser.add_argument("--detach", action="store_true")
    args, extra = parser.parse_known_args(argv or [])

    # Strip leading '--' from extra args
    if extra and extra[0] == "--":
        extra = extra[1:]

    name = args.name or default_name(args.client)
    client = args.client

    # Check binary exists
    import shutil
    if not shutil.which(CLIENT_CONFIGS[client]["binary"]):
        print(f"[c2c-start] error: {CLIENT_CONFIGS[client]['binary']} not found in PATH", file=sys.stderr)
        return 1

    # Check for duplicate name
    d = instance_dir(name)
    pidfile = d / "outer.pid"
    existing_pid = read_pid(pidfile)
    if existing_pid is not None:
        print(f"[c2c-start] error: instance '{name}' already running (PID {existing_pid})", file=sys.stderr)
        print(f"  Use 'c2c stop {name}' or 'c2c restart {name}' first", file=sys.stderr)
        return 1

    # Clean up stale state
    if d.exists():
        cleanup_pidfiles(d)

    # Write config and env
    write_config(name, client, extra)
    env = build_env(name)

    print(f"[c2c-start] starting {client} as '{name}'")
    return run_outer_loop(name=name, client=client, env=env, detach=args.detach)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStartValidationTests -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add c2c_start.py tests/test_c2c_cli.py
git commit -m "feat(start): add validation, config writing, env setup for c2c start"
```

---

## Task 4: Outer restart loop

**Files:**
- Modify: `c2c_start.py`
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the failing test**

```python
class C2CStartOuterLoopTests(unittest.TestCase):
    def test_run_outer_loop_launches_client(self):
        from c2c_start import run_outer_loop
        call_count = 0
        def fake_subprocess(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            result = mock.MagicMock()
            result.returncode = 0
            return result
        with mock.patch("subprocess.run", side_effect=fake_subprocess):
            with mock.patch("c2c_start.start_deliver_daemon"):
                with mock.patch("c2c_start.start_poker"):
                    with mock.patch("c2c_start.maybe_refresh_peer"):
                        with mock.patch("c2c_start.cleanup_fea_so"):
                            result = run_outer_loop(
                                name="test", client="claude",
                                env={"PATH": os.environ.get("PATH", "")},
                                detach=False,
                            )
        self.assertEqual(result, 0)
        self.assertEqual(call_count, 1)  # Clean exit stops loop

    def test_run_outer_loop_restarts_on_fast_exit(self):
        from c2c_start import run_outer_loop, MIN_RUN_SECONDS
        call_count = 0
        def fake_subprocess(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            result = mock.MagicMock()
            result.returncode = 1
            return result
        with mock.patch("subprocess.run", side_effect=fake_subprocess):
            with mock.patch("c2c_start.start_deliver_daemon"):
                with mock.patch("c2c_start.start_poker"):
                    with mock.patch("c2c_start.maybe_refresh_peer"):
                        with mock.patch("c2c_start.cleanup_fea_so"):
                            with mock.patch("time.sleep"):
                                with mock.patch("time.monotonic", side_effect=[0, 0.5, 0.5]):
                                    result = run_outer_loop(
                                        name="test", client="claude",
                                        env={"PATH": os.environ.get("PATH", "")},
                                        detach=False,
                                    )
        # Fast crash triggers restart attempt (but we exit because monotonic only gives 3 values)
        self.assertGreater(call_count, 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStartOuterLoopTests -v`
Expected: FAIL

- [ ] **Step 3: Implement `run_outer_loop`**

```python
def run_outer_loop(name: str, client: str, env: dict[str, str], detach: bool) -> int:
    cfg = CLIENT_CONFIGS[client]
    binary = cfg["binary"]
    d = instance_dir(name)

    if detach:
        pid = os.fork()
        if pid > 0:
            print(f"[c2c-start] detached as PID {pid}")
            return 0
        os.setsid()
        # Second fork
        pid = os.fork()
        if pid > 0:
            sys.exit(0)
        # Redirect stdout/stderr to log
        log_path = d / "outer.log"
        log_file = open(str(log_path), "a")
        sys.stdout = log_file
        sys.stderr = log_file

    write_pid(d / "outer.pid", os.getpid())

    backoff = INITIAL_BACKOFF_SECONDS
    deliver_daemon_pid = None
    poker_pid = None

    try:
        while True:
            start_time = time.monotonic()

            # Launch client
            cmd = [binary]
            config = load_config(name)
            if config and config.get("extra_args"):
                cmd.extend(config["extra_args"])

            try:
                proc = subprocess.run(cmd, env=env)
            except FileNotFoundError:
                print(f"[c2c-start] error: {binary} not found", file=sys.stderr)
                return 1
            except KeyboardInterrupt:
                print(f"[c2c-start] interrupted, stopping {name}")
                return 0

            elapsed = time.monotonic() - start_time

            # Start services after first launch
            if deliver_daemon_pid is None:
                deliver_daemon_pid = start_deliver_daemon(name, client, d, env)
            if poker_pid is None and cfg["needs_poker"]:
                poker_pid = start_poker(name, cfg, d, env)

            # Refresh peer registration
            maybe_refresh_peer(name, os.getpid())

            # Clean up fonttools residue
            cleanup_fea_so()

            # Restart logic
            if elapsed < MIN_RUN_SECONDS:
                print(f"[c2c-start] {name} exited after {elapsed:.1f}s (fast), backing off {backoff:.1f}s")
                time.sleep(backoff)
                backoff = min(backoff * 2, MAX_BACKOFF_SECONDS)
            else:
                print(f"[c2c-start] {name} exited after {elapsed:.1f}s, restarting in {RESTART_PAUSE_SECONDS}s")
                backoff = INITIAL_BACKOFF_SECONDS
                time.sleep(RESTART_PAUSE_SECONDS)
    finally:
        cleanup_services(deliver_daemon_pid, poker_pid)
        cleanup_pidfiles(d)


def start_deliver_daemon(name: str, client: str, d: Path, env: dict) -> int | None:
    deliver = ROOT / "c2c_deliver_inbox.py"
    if not deliver.exists():
        return None
    cmd = [
        sys.executable, str(deliver),
        "--client", client,
        "--session-id", name,
        "--file-fallback",
        "--notify-only",
        "--notify-debounce", "30",
        "--loop",
        "--interval", "2",
        "--pidfile", str(d / "deliver.pid"),
        "--json",
    ]
    try:
        proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        write_pid(d / "deliver.pid", proc.pid)
        return proc.pid
    except OSError:
        return None


def start_poker(name: str, cfg: dict, d: Path, env: dict) -> int | None:
    poker = ROOT / "c2c_poker.py"
    if not poker.exists():
        return None
    cmd = [
        sys.executable, str(poker),
        "--session-id", name,
        "--interval", "600",
        "--initial-delay", "600",
        "--event", cfg.get("poker_event", "heartbeat"),
        "--from", cfg.get("poker_from", f"{name}-poker"),
        "--alias", name,
        "--pidfile", str(d / "poker.pid"),
    ]
    try:
        proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        write_pid(d / "poker.pid", proc.pid)
        return proc.pid
    except OSError:
        return None


def maybe_refresh_peer(name: str, pid: int) -> None:
    refresh = ROOT / "c2c_refresh_peer.py"
    if not refresh.exists():
        return
    cmd = [sys.executable, str(refresh), name, "--pid", str(pid), "--session-id", name]
    try:
        subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True, timeout=5.0)
    except (subprocess.TimeoutExpired, OSError):
        pass


def cleanup_services(deliver_pid: int | None, poker_pid: int | None) -> None:
    for pid in (deliver_pid, poker_pid):
        if pid and pid_alive(pid):
            try:
                os.kill(pid, 15)  # SIGTERM
            except OSError:
                pass
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStartOuterLoopTests -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add c2c_start.py tests/test_c2c_cli.py
git commit -m "feat(start): implement outer restart loop with deliver daemon and poker"
```

---

## Task 5: Implement `c2c stop` and `c2c instances`

**Files:**
- Modify: `c2c_start.py`
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the failing tests**

```python
class C2CStopTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.instances = Path(self.tmp) / "instances"

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_stop_nonexistent_errors(self):
        from c2c_start import stop_instance
        with mock.patch("c2c_start.instances_dir", return_value=self.instances):
            result = stop_instance("nonexistent")
            self.assertNotEqual(result, 0)

    def test_stop_sends_sigterm(self):
        from c2c_start import stop_instance
        d = self.instances / "test"
        d.mkdir(parents=True)
        (d / "outer.pid").write_text(str(os.getpid()))
        (d / "config.json").write_text('{"name":"test","client":"claude"}')
        killed = []
        orig_kill = os.kill
        def fake_kill(pid, sig):
            killed.append((pid, sig))
        with mock.patch("c2c_start.instances_dir", return_value=self.instances):
            with mock.patch("os.kill", side_effect=fake_kill):
                with mock.patch("c2c_start.pid_alive", return_value=True):
                    result = stop_instance("test")
        self.assertEqual(result, 0)
        self.assertTrue(any(sig == 15 for _, sig in killed))


class C2CInstancesTests(unittest.TestCase):
    def test_instances_empty(self):
        from c2c_start import list_instances
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "instances"
            d.mkdir()
            with mock.patch("c2c_start.instances_dir", return_value=d):
                result = list_instances()
        self.assertEqual(result, 0)

    def test_instances_lists_running(self):
        from c2c_start import list_instances
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "instances" / "test-agent"
            d.mkdir(parents=True)
            (d / "config.json").write_text(json.dumps({
                "name": "test-agent", "client": "claude",
                "session_id": "test-agent", "alias": "test-agent",
                "created_at": time.time() - 3600,
            }))
            (d / "outer.pid").write_text(str(os.getpid()))
            with mock.patch("c2c_start.instances_dir", return_value=d.parent):
                result = list_instances()
        self.assertEqual(result, 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStopTests tests/test_c2c_cli.py::C2CInstancesTests -v`
Expected: FAIL

- [ ] **Step 3: Implement `stop_instance` and `list_instances`**

```python
def stop_instance(name: str) -> int:
    d = instance_dir(name)
    pidfile = d / "outer.pid"
    pid = read_pid(pidfile)
    if pid is None:
        print(f"[c2c-stop] error: instance '{name}' not running", file=sys.stderr)
        return 1

    print(f"[c2c-stop] stopping {name} (PID {pid})")
    try:
        os.kill(pid, 15)  # SIGTERM
    except OSError as e:
        print(f"[c2c-stop] error: {e}", file=sys.stderr)
        return 1

    # Wait briefly for cleanup
    for _ in range(10):
        if not pid_alive(pid):
            break
        time.sleep(0.5)

    cleanup_pidfiles(d)
    print(f"[c2c-stop] stopped {name}")
    return 0


def list_instances(argv: list[str] | None = None) -> int:
    import argparse
    parser = argparse.ArgumentParser(prog="c2c instances")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv or [])

    d = instances_dir()
    if not d.exists():
        rows = []
    else:
        rows = []
        for child in sorted(d.iterdir()):
            if not child.is_dir():
                continue
            config = load_config(child.name)
            if config is None:
                continue
            pidfile = child / "outer.pid"
            pid = read_pid(pidfile)
            alive = pid is not None
            uptime = None
            if alive and config.get("created_at"):
                uptime = time.time() - config["created_at"]
            rows.append({
                "name": child.name,
                "client": config.get("client", "?"),
                "alias": config.get("alias", "?"),
                "pid": pid,
                "alive": alive,
                "uptime_seconds": int(uptime) if uptime else None,
            })

    if args.json:
        print(json.dumps(rows, indent=2))
    elif not rows:
        print("[c2c-instances] no instances")
    else:
        print(f"{'NAME':<25s} {'CLIENT':<10s} {'PID':>8s} {'UPTIME':>10s} {'ALIVE':>6s}")
        print("-" * 65)
        for r in rows:
            uptime_str = f"{r['uptime_seconds']}s" if r["uptime_seconds"] else "-"
            pid_str = str(r["pid"]) if r["pid"] else "-"
            alive_str = "yes" if r["alive"] else "no"
            print(f"{r['name']:<25s} {r['client']:<10s} {pid_str:>8s} {uptime_str:>10s} {alive_str:>6s}")
    return 0


def restart_instance(name: str) -> int:
    config = load_config(name)
    if config is None:
        print(f"[c2c-restart] error: no config for '{name}'", file=sys.stderr)
        return 1
    stop_instance(name)
    client = config["client"]
    extra_args = config.get("extra_args", [])
    env = build_env(name)
    print(f"[c2c-restart] restarting {client} as '{name}'")
    return run_outer_loop(name=name, client=client, env=env, detach=False)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStopTests tests/test_c2c_cli.py::C2CInstancesTests -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add c2c_start.py tests/test_c2c_cli.py
git commit -m "feat(start): implement c2c stop, instances, restart commands"
```

---

## Task 6: Fix configure scripts — remove AUTO_REGISTER_ALIAS from global config

**Files:**
- Modify: `c2c_configure_codex.py`
- Modify: `c2c_configure_kimi.py`
- Modify: `c2c_configure_crush.py`
- Modify: `c2c_configure_claude_code.py`
- Modify: `c2c_configure_opencode.py`
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the failing tests**

```python
class C2CConfigureAliasFixTests(unittest.TestCase):
    def test_configure_codex_no_alias_in_block(self):
        from c2c_configure_codex import build_toml_block
        block = build_toml_block(Path("/tmp/broker"), "test-alias")
        self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", block)
        self.assertIn("C2C_MCP_BROKER_ROOT", block)
        self.assertIn("C2C_MCP_SESSION_ID", block)

    def test_configure_kimi_no_alias_in_block(self):
        from c2c_configure_kimi import build_mcp_config
        cfg = build_mcp_config(Path("/tmp/broker"), "test-alias")
        env = cfg["mcpServers"]["c2c"]["env"]
        self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
        self.assertIn("C2C_MCP_BROKER_ROOT", env)

    def test_configure_crush_no_alias_in_block(self):
        from c2c_configure_crush import build_mcp_config
        cfg = build_mcp_config(Path("/tmp/broker"), "test-alias")
        env = cfg["mcpServers"]["c2c"]["env"]
        self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CConfigureAliasFixTests -v`
Expected: FAIL

- [ ] **Step 3: Remove AUTO_REGISTER_ALIAS from each configure script**

For each of the 5 configure scripts, find the line that writes `C2C_MCP_AUTO_REGISTER_ALIAS` and remove it. The pattern is:

**c2c_configure_codex.py** — `build_toml_block()`:
```python
# REMOVE: f'C2C_MCP_AUTO_REGISTER_ALIAS = "{alias}"',
```

**c2c_configure_kimi.py** — `build_mcp_config()`:
```python
# REMOVE: "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
```

**c2c_configure_crush.py** — `build_mcp_config()`:
```python
# REMOVE: "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
```

**c2c_configure_claude_code.py** — look for the env dict:
```python
# REMOVE: "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
```

**c2c_configure_opencode.py** — look for the env dict:
```python
# REMOVE: "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CConfigureAliasFixTests -v`
Expected: PASS

- [ ] **Step 5: Run full test suite to check for regressions**

Run: `python3 -m pytest tests/test_c2c_cli.py -x -q`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add c2c_configure_*.py tests/test_c2c_cli.py
git commit -m "fix(configure): remove AUTO_REGISTER_ALIAS from global config files — alias set by c2c start via env"
```

---

## Task 7: Wire up install + docs

**Files:**
- Modify: `c2c_install.py`
- Modify: `c2c_cli.py` (USAGE string)
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write the failing test**

```python
class C2CStartInstallTests(unittest.TestCase):
    def test_start_in_usage(self):
        import c2c_cli
        self.assertIn("start", c2c_cli.USAGE)
        self.assertIn("stop", c2c_cli.USAGE)
        self.assertIn("instances", c2c_cli.USAGE)
        self.assertIn("restart", c2c_cli.USAGE)

    def test_install_has_start_wrappers(self):
        from c2c_install import COMMANDS
        self.assertIn("start", COMMANDS)
        self.assertIn("stop", COMMANDS)
        self.assertIn("instances", COMMANDS)
        self.assertIn("restart", COMMANDS)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStartInstallTests -v`
Expected: FAIL

- [ ] **Step 3: Update USAGE string in `c2c_cli.py`**

Add `start|stop|instances|restart` to the USAGE command list.

- [ ] **Step 4: Update `c2c_install.py`**

Add to COMMANDS dict:
```python
"start": "start",
"stop": "stop",
"instances": "instances",
"restart": "restart",
```

- [ ] **Step 5: Run test to verify it passes**

Run: `python3 -m pytest tests/test_c2c_cli.py::C2CStartInstallTests -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add c2c_cli.py c2c_install.py tests/test_c2c_cli.py
git commit -m "feat(install): wire up c2c start/stop/instances/restart wrappers"
```

---

## Task 8: Integration test + full suite verification

**Files:**
- Test: `tests/test_c2c_cli.py`

- [ ] **Step 1: Write integration test**

```python
class C2CStartIntegrationTests(unittest.TestCase):
    def test_full_lifecycle_with_mock_client(self):
        """Start a mock client, verify state dir, stop it."""
        from c2c_start import main, stop_instance, load_config, instance_dir
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {"HOME": tmp}):
                with mock.patch("c2c_start.run_outer_loop", return_value=0) as mock_run:
                    result = main(["claude", "-n", "test-life"])
                    self.assertEqual(result, 0)
                    mock_run.assert_called_once()

                    # Verify config was written
                    cfg = load_config("test-life")
                    self.assertIsNotNone(cfg)
                    self.assertEqual(cfg["name"], "test-life")
                    self.assertEqual(cfg["client"], "claude")
                    self.assertEqual(cfg["alias"], "test-life")
```

- [ ] **Step 2: Run full test suite**

Run: `python3 -m pytest tests/test_c2c_cli.py -x -q`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_c2c_cli.py
git commit -m "test(start): add integration test for c2c start lifecycle"
```

---

## Self-Review Checklist

- [ ] Every step has exact file paths
- [ ] Every code step has complete code (no "implement X" placeholders)
- [ ] Test steps have exact pytest commands with expected output
- [ ] Types/methods match across tasks (e.g., `instance_dir` signature consistent)
- [ ] All 5 client types covered in CLIENT_CONFIGS
- [ ] All configure scripts covered in Task 6
- [ ] Deprecated scripts noted but not deleted (separate cleanup commit)
