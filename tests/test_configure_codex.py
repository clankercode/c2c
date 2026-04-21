import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_configure_codex


class ConfigureCodexTests(unittest.TestCase):
    def test_build_toml_block_omits_global_identity_env(self):
        block = c2c_configure_codex.build_toml_block(Path("/tmp/broker"), "codex-user-host")

        self.assertIn('C2C_MCP_BROKER_ROOT = "/tmp/broker"', block)
        self.assertIn('C2C_MCP_AUTO_JOIN_ROOMS = "swarm-lounge"', block)
        self.assertNotIn("C2C_MCP_SESSION_ID", block)
        self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", block)

    def test_configure_force_rewrites_without_identity_env(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = Path(temp_dir) / "config.toml"
            config_path.write_text(
                "[mcp_servers.c2c]\ncommand = \"python3\"\n\n[mcp_servers.c2c.env]\nC2C_MCP_SESSION_ID = \"old\"\nC2C_MCP_AUTO_REGISTER_ALIAS = \"old\"\n",
                encoding="utf-8",
            )
            with mock.patch.object(c2c_configure_codex, "CODEX_CONFIG_PATH", config_path):
                c2c_configure_codex.configure(Path("/tmp/broker"), "codex-user-host", force=True)

            text = config_path.read_text(encoding="utf-8")
            self.assertIn('C2C_MCP_BROKER_ROOT = "/tmp/broker"', text)
            self.assertNotIn("C2C_MCP_SESSION_ID", text)
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", text)


if __name__ == "__main__":
    unittest.main()
