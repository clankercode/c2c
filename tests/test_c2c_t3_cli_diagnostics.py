"""T3 CLI diagnostics against the freshly built binary; no live T3 required."""

import json
import fcntl
import subprocess
from pathlib import Path

import pytest


BINARY = Path(__file__).resolve().parents[1] / "_build/default/ocaml/cli/c2c.exe"
pytestmark = pytest.mark.skipif(not BINARY.exists(), reason="run just build first")


def connector_env(tmp_path):
    home = tmp_path / "home"
    home.mkdir(mode=0o700)
    return {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin",
        "T3CODE_HOME": str(tmp_path / "absent-t3"),
        "C2C_T3_CONFIG_DIR": str(tmp_path / "config"),
        "C2C_T3_STATE_DIR": str(tmp_path / "state"),
        "C2C_MCP_BROKER_ROOT": str(tmp_path / "broker"),
        "C2C_SYSTEMCTL_FIXTURE": "1",
    }


def run_connector(env, tmp_path, *args):
    return subprocess.run(
        [str(BINARY), "t3", *args], env=env, cwd=tmp_path,
        capture_output=True, text=True, timeout=15,
    )


def initialize_state(env, tmp_path):
    # Exercise the real state initializer before absent-runtime authorization
    # fails. Fixtures then preserve its complete version/environment schema.
    result = run_connector(env, tmp_path, "service", "--once")
    assert result.returncode == 0, result.stderr
    state_file = Path(env["C2C_T3_STATE_DIR"]) / "state.json"
    return state_file, json.loads(state_file.read_text())


@pytest.mark.parametrize("command", [["service", "--once"], ["send", "target", "body"]])
def test_bad_mode_rejected_before_connector_side_effects(tmp_path, command):
    env = connector_env(tmp_path)
    result = subprocess.run(
        [str(BINARY), "t3", *command, "--mode", "steeer"],
        env=env, cwd=tmp_path, capture_output=True, text=True, timeout=15,
    )
    assert result.returncode == 124
    assert "--mode" in result.stderr
    for path in ("state", "config", "broker"):
        assert not (tmp_path / path).exists()


@pytest.mark.parametrize("payload,uncertain,retained,healthy", [
    ({"status": "held", "attempts": 1}, 1, 0, False),
    ({"status": "held", "attempts": 0, "last_submission_at": 123.0}, 1, 0, False),
    ({"status": "held", "attempts": 0, "last_submission_at": None}, 1, 0, False),
    ({"status": "held", "attempts": 0, "uncertain": True}, 1, 0, False),
    ({"status": "uncertain", "attempts": 0}, 1, 0, False),
    ({"status": "in_flight", "attempts": 1}, 1, 0, False),
    ({"status": "in_flight", "attempts": 0}, 1, 0, False),
    ({"status": "in_flight"}, 1, 0, False),
    ({"status": "held", "attempts": 0, "preflight_failed": True}, 0, 1, False),
    ({"status": "pending", "attempts": 1, "last_error": "private failure"}, 0, 1, False),
    ({"status": "held", "attempts": 0, "uncertain": False,
      "reason": "thread has queued work"}, 0, 0, True),
    ({"status": "pending", "attempts": 0}, 0, 0, True),
])
def test_doctor_reports_journal_uncertainty_without_private_payload(
    tmp_path, payload, uncertain, retained, healthy,
):
    env = connector_env(tmp_path)
    state_file, state = initialize_state(env, tmp_path)
    payload = {**payload, "formatted": "PRIVATE-MESSAGE-SENTINEL",
               "token": "PRIVATE-TOKEN-SENTINEL"}
    state["journal"] = [{"seq": 1, "kind": "inbound", "key": "fixture-entry",
                         "at": 123, "payload": payload}]
    state["next_seq"] = 2
    original = json.dumps(state)
    state_file.write_text(original)
    state_file.chmod(0o600)
    result = subprocess.run(
        [str(BINARY), "t3", "service", "doctor", "--json"],
        env=env, cwd=tmp_path, capture_output=True, text=True, timeout=15,
    )
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["state"]["uncertainEntries"] == uncertain
    assert report["state"]["retainedErrorEntries"] == retained
    assert report["state"]["healthy"] is healthy
    assert report["healthy"] is False  # this fixture has no T3 runtime
    assert "PRIVATE-MESSAGE-SENTINEL" not in result.stdout + result.stderr
    assert "PRIVATE-TOKEN-SENTINEL" not in result.stdout + result.stderr
    assert "private failure" not in result.stdout + result.stderr
    assert state_file.read_text() == original
    assert not Path(env["C2C_T3_CONFIG_DIR"]).exists()


@pytest.mark.parametrize("broken", ["empty", "foreign", "public-mode", "symlink"])
def test_doctor_rejects_invalid_or_unsafe_state(tmp_path, broken):
    env = connector_env(tmp_path)
    state_file, state = initialize_state(env, tmp_path)
    if broken == "empty":
        state_file.write_text('{}')
    elif broken == "foreign":
        state["environment_id"] = "unrelated-environment"
        state_file.write_text(json.dumps(state))
    elif broken == "public-mode":
        state_file.chmod(0o644)
    else:
        target = tmp_path / "private-target"
        state_file.rename(target)
        state_file.symlink_to(target)
    result = run_connector(env, tmp_path, "service", "doctor", "--json")
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["state"]["available"] is False
    assert report["healthy"] is False


@pytest.mark.parametrize("enabled", [True, False])
def test_doctor_distinguishes_disable_from_broken_configuration(tmp_path, enabled):
    env = connector_env(tmp_path)
    config = Path(env["C2C_T3_CONFIG_DIR"])
    config.mkdir(mode=0o700)
    config_file = config / "config.json"
    config_file.write_text(json.dumps({"recoveryEnabled": enabled}))
    config_file.chmod(0o600)
    result = run_connector(env, tmp_path, "service", "doctor", "--json")
    report = json.loads(result.stdout)
    assert report["recoveryConfigurationValid"] is True
    assert report["recoveryRequested"] is enabled
    if not enabled:
        assert report["recoveryHold"] is None
    config_file.write_text('{PRIVATE-CONFIG-SENTINEL')
    result = run_connector(env, tmp_path, "service", "doctor", "--json")
    report = json.loads(result.stdout)
    assert report["recoveryConfigurationValid"] is False
    assert report["healthy"] is False
    assert "configuration" in report["recoveryHold"]
    assert "PRIVATE-CONFIG-SENTINEL" not in result.stdout + result.stderr


def test_repair_dry_run_is_truthful_and_does_not_mutate(tmp_path):
    env = connector_env(tmp_path)
    state_file, _ = initialize_state(env, tmp_path)
    config = Path(env["C2C_T3_CONFIG_DIR"])
    config.mkdir(mode=0o755)
    state_file.chmod(0o644)
    original = state_file.read_bytes()
    before = sorted(str(p.relative_to(tmp_path)) for p in tmp_path.rglob("*"))
    result = run_connector(env, tmp_path, "service", "repair", "--dry-run", "--json")
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["dryRun"] is True
    assert report["applied"] == []
    assert any(p["action"] == "tighten-mode" and p["path"] == str(state_file) for p in report["planned"])
    assert any(p["action"] == "tighten-mode" and p["path"] == str(config) for p in report["planned"])
    assert any(p["action"] == "install-owned-unit" for p in report["planned"])
    assert sorted(str(p.relative_to(tmp_path)) for p in tmp_path.rglob("*")) == before
    assert config.stat().st_mode & 0o777 == 0o755
    assert state_file.stat().st_mode & 0o777 == 0o644
    assert state_file.read_bytes() == original


def test_repair_preserves_bytes_and_reports_incomplete_readiness(tmp_path):
    env = connector_env(tmp_path)
    state_file, _ = initialize_state(env, tmp_path)
    config = Path(env["C2C_T3_CONFIG_DIR"])
    config.mkdir(mode=0o755)
    credential = config / "credential.json"
    credential.write_bytes(b"PRIVATE-CREDENTIAL-SENTINEL")
    credential.chmod(0o600)
    settings = config / "config.json"
    settings.write_text('{"recoveryEnabled": false, "custom": "keep"}')
    settings.chmod(0o644)
    state_file.chmod(0o644)
    original = state_file.read_bytes()
    config_bytes = settings.read_bytes()
    result = run_connector(env, tmp_path, "service", "repair", "--json")
    assert result.returncode == 1  # fake systemd does not provide real readiness
    report = json.loads(result.stdout)
    assert report["complete"] is False
    assert report["holds"]
    assert config.stat().st_mode & 0o777 == 0o700
    assert settings.stat().st_mode & 0o777 == 0o600
    assert state_file.stat().st_mode & 0o777 == 0o600
    assert state_file.read_bytes() == original
    assert settings.read_bytes() == config_bytes
    assert credential.read_bytes() == b"PRIVATE-CREDENTIAL-SENTINEL"
    assert "PRIVATE-CREDENTIAL-SENTINEL" not in result.stdout + result.stderr
    assert report["credentialPreserved"] is True
    assert report["mailPreserved"] is True


def test_repair_refuses_live_singleton_owner(tmp_path):
    env = connector_env(tmp_path)
    state_file, _ = initialize_state(env, tmp_path)
    config = Path(env["C2C_T3_CONFIG_DIR"])
    config.mkdir(mode=0o755)
    lock_file = state_file.parent / "t3-state.lock"
    with lock_file.open("r+") as lock:
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = run_connector(env, tmp_path, "service", "repair", "--json")
        assert result.returncode == 1
        report = json.loads(result.stdout)
        assert report["applied"] == []
        assert any("live connector" in hold for hold in report["holds"])
        assert config.stat().st_mode & 0o777 == 0o755
        assert lock_file.exists()


def test_repair_removes_only_proven_stale_status(tmp_path):
    env = connector_env(tmp_path)
    state_file, state = initialize_state(env, tmp_path)
    status_file = state_file.parent / "service-status.json"
    status_file.write_text(json.dumps({"environmentId": state["environment_id"],
                                       "pid": 2147483647, "pidGeneration": 1}))
    original = state_file.read_bytes()
    result = run_connector(env, tmp_path, "service", "repair", "--json")
    assert result.returncode == 1  # no real supervised connector in this fixture
    report = json.loads(result.stdout)
    assert any(action["action"] == "remove-stale-status" for action in report["applied"])
    assert not status_file.exists()
    assert state_file.read_bytes() == original
    status_file.write_text('{"pid": 2147483647}')
    status_file.chmod(0o600)
    malformed = status_file.read_bytes()
    result = run_connector(env, tmp_path, "service", "repair", "--json")
    assert result.returncode == 1
    assert status_file.read_bytes() == malformed


@pytest.mark.parametrize("operation", ["stop", "uninstall"])
def test_foreign_unit_is_preserved_and_failure_reported(tmp_path, operation):
    env = connector_env(tmp_path)
    unit = Path(env["HOME"]) / ".config/systemd/user/c2c-t3.service"
    unit.parent.mkdir(parents=True)
    unit.write_text("[Service]\nExecStart=/bin/true\n")
    original = unit.read_bytes()
    capture = tmp_path / "systemctl-calls"
    env["C2C_SYSTEMCTL_CAPTURE_FILE"] = str(capture)
    result = run_connector(env, tmp_path, "service", operation)
    assert result.returncode == 1
    assert unit.read_bytes() == original
    assert not capture.exists()


@pytest.mark.parametrize("operation", ["stop", "uninstall"])
def test_marked_unit_for_different_environment_is_preserved(tmp_path, operation):
    env = connector_env(tmp_path)
    unit = Path(env["HOME"]) / ".config/systemd/user/c2c-t3.service"
    unit.parent.mkdir(parents=True)
    unit.write_text(
        "# c2c-managed-unit: c2c-t3.service:v1\n[Service]\n"
        "ExecStart=/opt/c2c t3 service --foreground\n"
        f"Environment=T3CODE_HOME={env['T3CODE_HOME']}-other\n"
        f"Environment=C2C_T3_CONFIG_DIR={env['C2C_T3_CONFIG_DIR']}\n"
        f"Environment=C2C_T3_STATE_DIR={env['C2C_T3_STATE_DIR']}\n"
    )
    original = unit.read_bytes()
    capture = tmp_path / "systemctl-calls"
    env["C2C_SYSTEMCTL_CAPTURE_FILE"] = str(capture)
    result = run_connector(env, tmp_path, "service", operation)
    assert result.returncode == 1
    assert unit.read_bytes() == original
    assert not capture.exists()


@pytest.mark.parametrize("status", ["missing", "dead", "old"])
def test_doctor_requires_a_verified_fresh_live_monitor(tmp_path, status):
    env = connector_env(tmp_path)
    state_file, state = initialize_state(env, tmp_path)
    status_file = state_file.parent / "service-status.json"
    if status == "missing":
        status_file.unlink()
    else:
        record = json.loads(status_file.read_text())
        record.update({"healthy": True, "completedAt": 0,
                       "intervalSeconds": 1000000000,
                       "environmentId": state["environment_id"]})
        if status == "dead":
            record.update({"pid": 2147483647, "pidGeneration": 1})
        status_file.write_text(json.dumps(record))
    result = run_connector(env, tmp_path, "service", "doctor", "--json")
    assert result.returncode == 0
    report = json.loads(result.stdout)
    assert report["healthy"] is False
    assert report["monitor"]["verifiedHealthy"] is False
    assert report["monitor"]["readinessError"]
    assert "configuredReady" in report


def test_human_doctor_describes_requested_but_unavailable_recovery_as_held(tmp_path):
    env = connector_env(tmp_path)
    initialize_state(env, tmp_path)
    result = run_connector(env, tmp_path, "service", "doctor")
    assert result.returncode == 0
    assert "recovery: held:" in result.stdout
    assert "recovery: enabled" not in result.stdout
