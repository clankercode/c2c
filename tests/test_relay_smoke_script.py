"""Tests for scripts/relay-smoke-test.sh structure and syntax."""
import os
import subprocess
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
        self.assertIn("c2c relay register", self.content)

    def test_uses_c2c_relay_dm_poll(self):
        self.assertIn("c2c relay dm poll", self.content)

    def test_uses_c2c_relay_rooms_join(self):
        self.assertIn("c2c relay rooms join", self.content)

    def test_uses_c2c_relay_rooms_leave(self):
        self.assertIn("c2c relay rooms leave", self.content)

    def test_checks_auth_mode_prod(self):
        self.assertIn("auth_mode", self.content)
        self.assertIn("prod", self.content)

    def test_reports_pass_fail_summary(self):
        self.assertIn("PASS", self.content)
        self.assertIn("FAIL", self.content)

    def test_default_relay_url(self):
        self.assertIn("relay.c2c.im", self.content)
