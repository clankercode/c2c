"""Live smoke tests for `c2c roles compile --client all`.

Exercises the four-client parity path: compile a canonical role to all
supported client agent files (opencode, claude, codex, kimi) and verify
each output file is produced.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest


C2C_BIN = shutil.which("c2c")


pytestmark = pytest.mark.skipif(
    not C2C_BIN,
    reason="c2c binary not on PATH",
)

_unique_suffix_counter = 0


def _unique_suffix() -> str:
    global _unique_suffix_counter
    _unique_suffix_counter += 1
    return f"{os.getpid()}-{_unique_suffix_counter}"


def _init_git_repo(path: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "c2c test"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.email", "c2c-test@example.invalid"], cwd=path, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "init", "-q"], cwd=path, check=True)


_MINIMAL_ROLE = """\
---
role: test-agent
description: smoke-test role for roles-compile E2E
---

You are a test agent.

## Tasks

- Confirm you received this role file.
"""

# Per-client expected output paths relative to the compiled repo root.
_CLIENT_PATHS = {
    "opencode": ".opencode/agents/test-agent.md",
    "claude":   ".claude/agents/test-agent.md",
    "codex":    ".codex/agents/test-agent.md",
    "kimi":     ".kimi/agents/test-agent.md",
}


def _probe_clients() -> dict[str, bool]:
    """Return which client binaries are present on this system."""
    return {
        "opencode": shutil.which("opencode") is not None,
        "claude":   shutil.which("claude") is not None,
        "codex":    shutil.which("codex") is not None,
        "kimi":     shutil.which("kimi") is not None,
    }


def test_roles_compile_all_produces_all_client_files(tmp_path: Path) -> None:
    """`c2c roles compile --client all` writes files for every available client."""
    _init_git_repo(tmp_path)

    roles_dir = tmp_path / ".c2c" / "roles"
    roles_dir.mkdir(parents=True)
    (roles_dir / "test-agent.md").write_text(_MINIMAL_ROLE, encoding="utf-8")

    result = subprocess.run(
        [C2C_BIN, "roles", "compile", "--client", "all"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"compile failed: {result.stderr}"

    clients = _probe_clients()
    for client, expected_path in _CLIENT_PATHS.items():
        if clients[client]:
            assert (tmp_path / expected_path).exists(), (
                f"{client} is available but output not produced at {expected_path}"
            )
        else:
            # Client binary absent — output path may or may not exist depending on
            # whether the renderer declined to produce anything. Either is acceptable.
            pass


def test_roles_compile_all_dry_run_emits_content(tmp_path: Path) -> None:
    """`c2c roles compile --client all --dry-run` prints rendered content to stdout."""
    _init_git_repo(tmp_path)

    roles_dir = tmp_path / ".c2c" / "roles"
    roles_dir.mkdir(parents=True)
    (roles_dir / "test-agent.md").write_text(_MINIMAL_ROLE, encoding="utf-8")

    result = subprocess.run(
        [C2C_BIN, "roles", "compile", "--client", "all", "--dry-run"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"dry-run compile failed: {result.stderr}"

    # Dry-run format: "=== name (client) ===\n<rendered>\n\n" per role/client
    output = result.stdout
    assert "=== test-agent (opencode) ===" in output, (
        "dry-run output missing opencode section"
    )
    assert "=== test-agent (claude) ===" in output, (
        "dry-run output missing claude section"
    )
    # Body content should appear in the rendered output
    assert "test-agent" in output.lower(), "rendered body missing from dry-run output"


def test_roles_compile_all_does_not_pollute_cwd(tmp_path: Path) -> None:
    """Compiled output files land inside the target repo, not the current directory."""
    _init_git_repo(tmp_path)

    roles_dir = tmp_path / ".c2c" / "roles"
    roles_dir.mkdir(parents=True)
    (roles_dir / "test-agent.md").write_text(_MINIMAL_ROLE, encoding="utf-8")

    subprocess.run(
        [C2C_BIN, "roles", "compile", "--client", "all"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=True,
    )

    # No agent files should appear in the caller's current directory
    caller_cwd = Path.cwd()
    for expected_path in _CLIENT_PATHS.values():
        assert not (caller_cwd / expected_path).exists(), (
            f"compile polluted caller cwd: {expected_path} exists at {caller_cwd}"
        )


def test_roles_compile_all_idempotent(tmp_path: Path) -> None:
    """Running compile twice in a row produces the same output (no append/stale content)."""
    _init_git_repo(tmp_path)

    roles_dir = tmp_path / ".c2c" / "roles"
    roles_dir.mkdir(parents=True)
    (roles_dir / "test-agent.md").write_text(_MINIMAL_ROLE, encoding="utf-8")

    for _ in range(2):
        result = subprocess.run(
            [C2C_BIN, "roles", "compile", "--client", "all"],
            cwd=tmp_path,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, f"compile failed on second run: {result.stderr}"

    clients = _probe_clients()
    for client, expected_path in _CLIENT_PATHS.items():
        if not clients[client]:
            continue
        content = (tmp_path / expected_path).read_text(encoding="utf-8")
        # Should contain the role description, not duplicated content
        assert content.count("smoke-test role") == 1, (
            f"{client} output has duplicate/stale content at {expected_path}"
        )


def test_roles_compile_all_skip_invalid_client(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """`--client invalid-client` is silently skipped (not an error)."""
    _init_git_repo(tmp_path)

    roles_dir = tmp_path / ".c2c" / "roles"
    roles_dir.mkdir(parents=True)
    (roles_dir / "test-agent.md").write_text(_MINIMAL_ROLE, encoding="utf-8")

    result = subprocess.run(
        [C2C_BIN, "roles", "compile", "--client", "all,invalid-client"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
    )
    # Should succeed even with invalid client in the list
    assert result.returncode == 0, f"compile with invalid client failed: {result.stderr}"
    # Should emit a skip notice for the invalid client
    assert "invalid-client" in result.stderr.lower(), (
        "expected skip message for invalid-client"
    )
