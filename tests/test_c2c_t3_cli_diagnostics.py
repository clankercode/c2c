"""T3 CLI diagnostics against the freshly built binary; no live T3 required."""

import json
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
    state_dir = Path(env["C2C_T3_STATE_DIR"])
    state_dir.mkdir(mode=0o700)
    state_file = state_dir / "state.json"
    payload = {**payload, "formatted": "PRIVATE-MESSAGE-SENTINEL",
               "token": "PRIVATE-TOKEN-SENTINEL"}
    original = json.dumps({"journal": [{"at": 123, "payload": payload}],
                           "mappings": [], "acked": []})
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
