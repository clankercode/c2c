#!/usr/bin/env python3
"""Tests for c2c_configure_opencode.py sidecar config."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from c2c_configure_opencode import derive_session_id, write_config


class ConfigureOpenCodeSidecarTests(unittest.TestCase):
    def test_write_config_creates_sidecar(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "myproject"
            target.mkdir()

            _, session_id, alias, _ = write_config(
                target, force=False, alias=None, install_plugin_flag=False
            )

            sidecar = target / ".opencode" / "c2c-plugin.json"
            self.assertTrue(sidecar.exists())
            data = json.loads(sidecar.read_text(encoding="utf-8"))
            self.assertEqual(data["session_id"], session_id)
            self.assertEqual(data["alias"], alias)
            self.assertTrue(data["broker_root"])

    def test_sidecar_uses_custom_alias(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "myproject"
            target.mkdir()

            _, _, resolved_alias, _ = write_config(
                target, force=False, alias="custom-peer", install_plugin_flag=False
            )

            sidecar = target / ".opencode" / "c2c-plugin.json"
            data = json.loads(sidecar.read_text(encoding="utf-8"))
            self.assertEqual(data["alias"], "custom-peer")
            self.assertEqual(resolved_alias, "custom-peer")

    def test_sidecar_overwrites_on_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "myproject"
            target.mkdir()

            write_config(target, force=False, alias="first", install_plugin_flag=False)
            write_config(target, force=True, alias="second", install_plugin_flag=False)

            sidecar = target / ".opencode" / "c2c-plugin.json"
            data = json.loads(sidecar.read_text(encoding="utf-8"))
            self.assertEqual(data["alias"], "second")

    def test_derive_session_id_uses_dirname(self):
        self.assertEqual(
            derive_session_id(Path("/some/path/my-project")),
            "opencode-my-project",
        )

    def test_no_overwrite_without_force(self):
        """write_config must refuse to overwrite an existing opencode.json without force."""
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "myproject"
            target.mkdir()

            # First write — sets alias=first
            write_config(target, force=False, alias="first", install_plugin_flag=False)

            # Second write without force — must raise SystemExit
            with self.assertRaises(SystemExit):
                write_config(target, force=False, alias="second", install_plugin_flag=False)

            # Sidecar should still reflect the original alias
            sidecar = target / ".opencode" / "c2c-plugin.json"
            data = json.loads(sidecar.read_text(encoding="utf-8"))
            self.assertEqual(data["alias"], "first", "second write should not have overwritten alias")


if __name__ == "__main__":
    unittest.main()
