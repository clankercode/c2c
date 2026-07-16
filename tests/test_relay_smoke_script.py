"""Tests for scripts/relay-smoke-test.sh structure and syntax."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SMOKE_SCRIPT = REPO / "scripts" / "relay-smoke-test.sh"

EXPECTED_SECTIONS = [
    "Health",
    "Register",
    "List",
    "Loopback DM",
    "Poll inbox",
    "Room operations",
    "Ed25519 identity",
]


class RelaySmokeSriptExistenceTests(unittest.TestCase):
    def test_script_exists(self):
        self.assertTrue(SMOKE_SCRIPT.exists(), f"relay-smoke-test.sh not found at {SMOKE_SCRIPT}")

    def test_script_is_executable(self):
        self.assertTrue(os.access(SMOKE_SCRIPT, os.X_OK),
                        "relay-smoke-test.sh is not executable")

    def test_script_shebang(self):
        first_line = SMOKE_SCRIPT.read_text().splitlines()[0]
        self.assertTrue(first_line.startswith("#!/"),
                        f"Missing shebang: {first_line!r}")

    def test_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(SMOKE_SCRIPT)],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0,
                         f"bash -n failed: {result.stderr}")


class RelaySmokeSectionTests(unittest.TestCase):
    """Verify all expected test sections are present in the script."""

    def setUp(self):
        self.content = SMOKE_SCRIPT.read_text()

    def test_has_health_section(self):
        self.assertIn("Health", self.content)

    def test_has_register_section(self):
        self.assertIn("Register", self.content)

    def test_has_loopback_dm_section(self):
        self.assertIn("Loopback DM", self.content)

    def test_has_poll_inbox_section(self):
        self.assertIn("Poll inbox", self.content)

    def test_has_room_operations_section(self):
        self.assertIn("Room operations", self.content)

    def test_has_ed25519_identity_section(self):
        self.assertIn("Ed25519 identity", self.content)

    def test_uses_c2c_relay_register(self):
        self.assertIn('"$C2C_BIN" relay register', self.content)

    def test_uses_c2c_relay_dm_poll(self):
        self.assertIn('"$C2C_BIN" relay dm poll', self.content)

    def test_uses_c2c_relay_rooms_join(self):
        self.assertIn('"$C2C_BIN" relay rooms join', self.content)

    def test_uses_c2c_relay_rooms_leave(self):
        self.assertIn('"$C2C_BIN" relay rooms leave', self.content)

    def test_checks_health_ok_and_auth_mode(self):
        self.assertIn("health_ok", self.content)
        self.assertIn("auth_mode", self.content)

    def test_reports_pass_fail_summary(self):
        self.assertIn("PASS", self.content)
        self.assertIn("FAIL", self.content)

    def test_default_relay_url(self):
        self.assertIn('RELAY="${1:-http://127.0.0.1:7331}"', self.content)

    def test_refuses_non_loopback_relay_before_running_commands(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            marker = tmp / "called"
            for command in ("curl", "c2c"):
                stub = tmp / command
                stub.write_text(
                    "#!/bin/sh\n"
                    f"touch {marker}\n"
                    "exit 99\n"
                )
                stub.chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = f"{tmp}:{env['PATH']}"
            env["C2C_BIN"] = str(tmp / "c2c")
            result = subprocess.run(
                [str(SMOKE_SCRIPT), "https://relay.example.invalid"],
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn("loopback", result.stderr.lower())
            self.assertFalse(marker.exists(), "remote guard ran after a network-capable command")

    def test_write_operations_are_not_retried(self):
        for assignment in ("dm_out", "join_out", "send_room_out", "leave_out", "ch_out", "sa_out"):
            with self.subTest(assignment=assignment):
                self.assertNotIn(f'{assignment}=$(retry', self.content)
